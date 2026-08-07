/// Ordering rows in a SQL table so that moving one item writes exactly one row.
///
/// Store a [Rank] per row in a `text` column and `ORDER BY` it. Because ranks
/// are dense — between any two there is always another — a move only ever
/// changes the moved row's own value. Its neighbours are untouched, so the cost
/// of a reorder is one `UPDATE`, whatever the size of the list.
///
/// ```dart
/// final first  = Rank.between(null, null);        // an empty list
/// final second = Rank.between(first, null);       // append
/// final middle = Rank.between(first, second);     // insert between
/// ```
///
/// Keys sort lexicographically as plain text, and contain digits only, so no
/// collation can reorder them. See `sql/schema.sql` for the table definition.
///
/// Keys grow only when a region is repeatedly subdivided, and they grow slowly:
/// under ordinary reordering they settle around 10-20 characters and stay
/// there. Under a deliberate worst case they gain roughly one character per
/// move, which is the theoretical floor for any scheme that writes one row.
/// [Rebalance.plan] is the escape hatch when that happens.
library;

import 'src/arithmetic.dart';
import 'src/codec.dart';

export 'src/codec.dart' show decodeKey, encodeKey;

/// A position in an ordered list, stored as a sortable string.
///
/// Instances are immutable and compare by their key, which is exactly how the
/// database compares them.
class Rank implements Comparable<Rank> {
  /// Wraps an existing key, as read from the database.
  ///
  /// Throws [FormatException] if the key was not produced by this library.
  factory Rank(String key) {
    decodeKey(key); // reject anything malformed at the boundary
    return Rank._(key);
  }

  const Rank._(this.key);

  /// The stored form. Sort on this.
  final String key;

  /// A rank strictly between [lower] and [upper].
  ///
  /// Pass null for an open end: `between(null, first)` prepends,
  /// `between(last, null)` appends, and `between(null, null)` starts an empty
  /// list. The result is the simplest rank in the interval, which is also the
  /// shortest key available there.
  ///
  /// Throws [ArgumentError] if [lower] does not sort before [upper].
  factory Rank.between(Rank? lower, Rank? upper) {
    final low = lower == null ? below : ratioOfTerms(decodeKey(lower.key));
    final high = upper == null ? above : ratioOfTerms(decodeKey(upper.key));
    return Rank._(encodeKey(termsOfRatio(simplestBetween(low, high))));
  }

  /// Evenly spaced ranks for a list of [count] items, built fresh.
  ///
  /// Cheaper and shorter than appending one at a time, and the natural way to
  /// seed a list that already has an order.
  static List<Rank> sequence(int count) {
    if (count < 0) throw ArgumentError.value(count, 'count', 'must not be negative');
    return _distribute(count, below, above);
  }

  /// The continued-fraction terms behind this rank — its path's run lengths.
  List<int> get terms => decodeKey(key);

  /// How deep in the Stern-Brocot tree this rank sits.
  ///
  /// Returned as [BigInt] because it can be astronomically larger than the key:
  /// a 27-character key can name a rank a trillion moves down a spine.
  BigInt get depth =>
      terms.fold(BigInt.zero, (sum, term) => sum + BigInt.from(term));

  /// The rank as an exact fraction. Derived on demand; never stored.
  (BigInt, BigInt) get fraction => ratioOfTerms(terms);

  /// How many characters this rank costs to store.
  int get length => key.length;

  @override
  int compareTo(Rank other) => key.compareTo(other.key);

  bool operator <(Rank other) => compareTo(other) < 0;
  bool operator <=(Rank other) => compareTo(other) <= 0;
  bool operator >(Rank other) => compareTo(other) > 0;
  bool operator >=(Rank other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) => other is Rank && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'Rank($key)';
}

/// Assigns [count] ranks spread evenly through an interval.
///
/// Fills the middle first and recurses into both halves, so the result is a
/// balanced set whose keys are as short as the interval allows.
List<Rank> _distribute(int count, Ratio low, Ratio high) {
  final out = List<Rank?>.filled(count, null);

  void fill(int from, int to, Ratio lower, Ratio upper) {
    if (from > to) return;
    final mid = from + (to - from) ~/ 2;
    final value = simplestBetween(lower, upper);
    out[mid] = Rank._(encodeKey(termsOfRatio(value)));
    fill(from, mid - 1, lower, value);
    fill(mid + 1, to, value, upper);
  }

  fill(0, count - 1, low, high);
  // Growable: callers reorder these lists, so a fixed-length result would be
  // useless to them.
  return List<Rank>.of(out.cast<Rank>(), growable: true);
}

/// A set of rows to rewrite, and what to write to them.
class RebalancePlan {
  const RebalancePlan({required this.start, required this.ranks});

  /// Index of the first affected item in the list handed to [Rebalance.plan].
  final int start;

  /// Replacement ranks, in order, beginning at [start].
  final List<Rank> ranks;

  /// Index just past the last affected item.
  int get end => start + ranks.length;

  /// How many rows this costs. The whole point of the library is that ordinary
  /// moves cost 1; this is the exception.
  int get writes => ranks.length;

  @override
  String toString() => 'RebalancePlan($start..$end, $writes writes)';
}

/// Deciding when keys have grown too long, and what to rewrite.
///
/// Rebalancing trades the one-write guarantee for shorter keys. It is never
/// required for correctness — ordering stays exact at any key length — so treat
/// it as housekeeping, run rarely and off the critical path.
abstract final class Rebalance {
  /// Default ceiling before a rebalance is proposed.
  static const int defaultLimit = 120;

  /// Default ceiling for the keys a rebalance produces.
  static const int defaultTarget = 32;

  /// Proposes a rebalance for [ranks], or null if none is warranted.
  ///
  /// Only the rows in the returned plan change; everything else keeps its
  /// current rank, so the plan is safe to apply on its own.
  ///
  /// Widening is the essential part. Redistributing inside the offending region
  /// cannot help, because the keys are long precisely *because* that interval is
  /// narrow. So the window grows outward until the enclosing bounds are roomy
  /// enough to hold the items at [target] characters or fewer — in the worst
  /// case the whole list, whose bounds are open and always suffice.
  ///
  /// [ranks] must be in ascending order.
  static RebalancePlan? plan(
    List<Rank> ranks, {
    int limit = defaultLimit,
    int target = defaultTarget,
  }) {
    if (limit < target) {
      throw ArgumentError('limit ($limit) must not be below target ($target)');
    }
    if (ranks.isEmpty) return null;

    // Span every offending row, not just the worst one — they cluster, and a
    // plan that left some of them over the limit would only have to run again.
    var from = -1, to = -1;
    for (var i = 0; i < ranks.length; i++) {
      if (ranks[i].length > limit) {
        if (from < 0) from = i;
        to = i;
      }
    }
    if (from < 0) return null;
    while (true) {
      final lower = from == 0 ? below : ratioOfTerms(ranks[from - 1].terms);
      final upper =
          to == ranks.length - 1 ? above : ratioOfTerms(ranks[to + 1].terms);

      final replacement = _distribute(to - from + 1, lower, upper);
      final fits = replacement.every((r) => r.length <= target);
      final wholeList = from == 0 && to == ranks.length - 1;

      if (fits || wholeList) {
        return RebalancePlan(start: from, ranks: replacement);
      }

      // Not roomy enough yet — take in a neighbour on each side and retry.
      if (from > 0) from--;
      if (to < ranks.length - 1) to++;
    }
  }
}
