/// Exact rational arithmetic on ranks, in time proportional to the number of
/// continued-fraction terms rather than to the tree depth.
///
/// Nothing here is ever stored. The persisted form is the key; these routines
/// exist to get from two neighbouring keys to the key that belongs between
/// them. [BigInt] is used throughout so there is no width to overflow.
library;

/// A rational as (numerator, denominator). A zero denominator means positive
/// infinity — the open bound above the last item. `(0, 1)` is the open bound
/// below the first.
typedef Ratio = (BigInt numerator, BigInt denominator);

final BigInt _zero = BigInt.zero;
final BigInt _one = BigInt.one;

/// The open bound below every rank.
final Ratio below = (_zero, _one);

/// The open bound above every rank.
final Ratio above = (_one, _zero);

/// Exact comparison by cross-multiplication. Returns -1, 0 or 1.
int compareRatio(Ratio a, Ratio b) {
  final left = a.$1 * b.$2;
  final right = b.$1 * a.$2;
  return left < right ? -1 : (left > right ? 1 : 0);
}

/// Builds a rational from a canonical continued fraction `[t0; t1, t2, ...]`.
Ratio _fromContinuedFraction(List<int> cf) {
  var numeratorPrev = _one, numerator = BigInt.from(cf[0]);
  var denominatorPrev = _zero, denominator = _one;

  for (var i = 1; i < cf.length; i++) {
    final term = BigInt.from(cf[i]);
    final n = term * numerator + numeratorPrev;
    final d = term * denominator + denominatorPrev;
    numeratorPrev = numerator;
    denominatorPrev = denominator;
    numerator = n;
    denominator = d;
  }
  return (numerator, denominator);
}

/// The continued-fraction terms of a rank, as run lengths of its path.
///
/// The last coefficient is reduced by one because the final move lands *on* the
/// node rather than past it — which is why 1/1, the root, comes back as `[0]`.
List<int> termsOfRatio(Ratio value) {
  var n = value.$1, d = value.$2;
  final terms = <int>[];
  while (d != _zero) {
    terms.add((n ~/ d).toInt());
    final r = n % d;
    n = d;
    d = r;
  }
  if (terms.isEmpty) throw ArgumentError('not a finite rank: $value');
  terms[terms.length - 1] -= 1;
  return terms;
}

/// Rebuilds the rank from its terms, by running the convergent recurrence.
///
/// Cost is one pass over the terms — never over the depth, which can be
/// astronomically larger.
Ratio ratioOfTerms(List<int> terms) {
  if (terms.isEmpty) throw ArgumentError('a rank has at least one term');
  final cf = List<int>.of(terms);
  cf[cf.length - 1] += 1; // undo the reduction applied by [termsOfRatio]
  return _fromContinuedFraction(cf);
}

/// The simplest rank strictly between [low] and [high].
///
/// "Simplest" means smallest denominator, which is also the shallowest node in
/// the tree and — because every other candidate lies in this one's subtree and
/// so extends its path — the shortest key. One choice is optimal for all three.
///
/// The construction: peel off the integer part of the lower bound. If the next
/// whole number lands strictly inside the interval, that is the answer. If not,
/// both bounds share an integer part, so invert their fractional parts and go
/// again — inverting reverses order, which is why the bounds swap, and that
/// swap is exactly the alternating direction the tree encodes.
///
/// Each round emits one term, so this costs O(terms) divisions rather than
/// O(depth) steps down the tree. Pass [below] or [above] to leave an end open.
Ratio simplestBetween(Ratio low, Ratio high) {
  if (compareRatio(low, high) >= 0) {
    throw ArgumentError('bounds are not ordered: $low .. $high');
  }

  final cf = <int>[];
  var lo = low, hi = high;

  while (true) {
    final whole = lo.$1 ~/ lo.$2;
    final next = whole + _one;

    // Does the next whole number land strictly inside? An open upper bound
    // always admits it.
    if (hi.$2 == _zero || next * hi.$2 < hi.$1) {
      cf.add(next.toInt());
      return _fromContinuedFraction(cf);
    }

    cf.add(whole.toInt());

    // Recurse on the reciprocals of the fractional parts:
    //   lo' = 1 / (hi - whole),  hi' = 1 / (lo - whole)
    // A zero remainder on the lower bound gives an open upper bound, which is
    // correct: the interval reaches all the way up.
    final loRemainder = lo.$1 - whole * lo.$2;
    final hiRemainder = hi.$1 - whole * hi.$2;
    final nextLo = (hi.$2, hiRemainder);
    final nextHi = (lo.$2, loRemainder);
    lo = nextLo;
    hi = nextHi;
  }
}
