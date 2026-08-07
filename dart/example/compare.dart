/// Head-to-head against the alternatives, on identical workloads.
///
///   dart run example/compare.dart
///
/// Five ways to keep a list ordered in a database:
///
///   dense integers      position 0..n-1, the thing everyone writes first
///   float midpoint      rank as a double, take (lo+hi)/2
///   sparse integers     integers spaced far apart, renumber when a gap closes
///   base-62 fractional  the LexoRank / Figma approach: a variable-length
///                       string over a 62-character alphabet
///   Stern-Brocot        this package
///
/// Measured on the same moves: rows written, bytes stored, and whether the
/// order survived.
library;

import 'dart:math';

import 'package:rank/rank.dart';

import 'fractional_indexing.dart';

// ---------------------------------------------------------------------------
// base-62 fractional indexing lives in fractional_indexing.dart: a faithful
// port of the reference implementation (rocicorp/fractional-indexing, CC0),
// validated against its own test vectors. Using the real thing matters here —
// its integer-part machinery is exactly what makes appending past the end cheap,
// which is one of the patterns under test.
// ---------------------------------------------------------------------------
// the strategies
// ---------------------------------------------------------------------------

class Result {
  Result(this.name);
  final String name;
  int writes = 0;
  int bytes = 0;
  int longest = 0;
  int? brokeAt;
  int rebalances = 0;
  int ms = 0;
}

/// Dense integer positions — the baseline everyone writes first.
Result denseIntegers(int items, List<(int, int)> moves) {
  final r = Result('dense integers');
  final order = List<int>.generate(items, (i) => i);
  final watch = Stopwatch()..start();

  for (final (from, to) in moves) {
    order.insert(to, order.removeAt(from));
    // Every position between the two endpoints shifts by one.
    r.writes += (to - from).abs() + 1;
  }

  r.ms = watch.elapsedMilliseconds;
  r.bytes = items * 8;
  r.longest = 8;
  return r;
}

/// Rank as a double, taking the midpoint of the neighbours.
Result floatMidpoint(int items, List<(int, int)> moves) {
  final r = Result('float midpoint');
  final ranks = List<double>.generate(items, (i) => (i + 1).toDouble());
  final watch = Stopwatch()..start();

  for (var move = 0; move < moves.length; move++) {
    final (from, to) = moves[move];
    ranks.insert(to, ranks.removeAt(from));
    final low = to == 0 ? 0.0 : ranks[to - 1];
    final high = to == ranks.length - 1 ? ranks[to - 1] + 1.0 : ranks[to + 1];
    final mid = low + (high - low) / 2;
    ranks[to] = mid;
    r.writes += 1;
    // The failure mode: the midpoint is no longer distinct from its bound.
    if (r.brokeAt == null && (mid <= low || mid >= high)) r.brokeAt = move;
  }

  r.ms = watch.elapsedMilliseconds;
  r.bytes = items * 8;
  r.longest = 8;
  return r;
}

/// Integers spaced far apart; renumber the list when a gap closes.
Result sparseIntegers(int items, List<(int, int)> moves, {int gap = 1 << 16}) {
  final r = Result('sparse integers');
  var ranks = List<int>.generate(items, (i) => (i + 1) * gap);
  final watch = Stopwatch()..start();

  for (final (from, to) in moves) {
    ranks.insert(to, ranks.removeAt(from));
    final low = to == 0 ? 0 : ranks[to - 1];
    final high = to == ranks.length - 1 ? ranks[to - 1] + gap : ranks[to + 1];

    if (high - low <= 1) {
      // No room left. Renumber everything — the write amplification this
      // scheme exists to avoid, returning at the worst possible moment.
      ranks = List<int>.generate(ranks.length, (i) => (i + 1) * gap);
      r.writes += ranks.length;
      r.rebalances += 1;
    } else {
      ranks[to] = low + (high - low) ~/ 2;
      r.writes += 1;
    }
  }

  r.ms = watch.elapsedMilliseconds;
  r.bytes = items * 8;
  r.longest = 8;
  return r;
}

/// base-62 fractional indexing.
Result base62(int items, List<(int, int)> moves) {
  final r = Result('base-62 fractional');
  final keys = generateNKeysBetween(null, null, items);
  final watch = Stopwatch()..start();

  for (var move = 0; move < moves.length; move++) {
    final (from, to) = moves[move];
    keys.insert(to, keys.removeAt(from));
    keys[to] = generateKeyBetween(
      to == 0 ? null : keys[to - 1],
      to == keys.length - 1 ? null : keys[to + 1],
    );
    r.writes += 1;
    if (r.brokeAt == null) {
      for (var i = 0; i < keys.length - 1; i++) {
        if (keys[i].compareTo(keys[i + 1]) >= 0) {
          r.brokeAt = move;
          break;
        }
      }
    }
  }

  r.ms = watch.elapsedMilliseconds;
  r.bytes = keys.fold(0, (sum, k) => sum + k.length);
  r.longest = keys.map((k) => k.length).reduce(max);
  return r;
}

/// This package.
Result sternBrocot(int items, List<(int, int)> moves, {bool rebalancing = false}) {
  final r = Result(rebalancing ? 'Stern-Brocot + rebalance' : 'Stern-Brocot');
  final ranks = Rank.sequence(items);
  final watch = Stopwatch()..start();

  for (var move = 0; move < moves.length; move++) {
    final (from, to) = moves[move];
    ranks.insert(to, ranks.removeAt(from));
    ranks[to] = Rank.between(
      to == 0 ? null : ranks[to - 1],
      to == ranks.length - 1 ? null : ranks[to + 1],
    );
    r.writes += 1;

    if (rebalancing) {
      final plan = Rebalance.plan(ranks, limit: 64, target: 20);
      if (plan != null) {
        ranks.replaceRange(plan.start, plan.end, plan.ranks);
        r.writes += plan.writes;
        r.rebalances += 1;
      }
    }

    if (r.brokeAt == null) {
      for (var i = 0; i < ranks.length - 1; i++) {
        if (ranks[i] >= ranks[i + 1]) {
          r.brokeAt = move;
          break;
        }
      }
    }
  }

  r.ms = watch.elapsedMilliseconds;
  r.bytes = ranks.fold(0, (sum, k) => sum + k.length);
  r.longest = ranks.map((k) => k.length).reduce(max);
  return r;
}

// ---------------------------------------------------------------------------

List<(int, int)> randomMoves(int items, int count, int seed) {
  final random = Random(seed);
  return List.generate(count, (_) {
    final from = random.nextInt(items);
    var to = random.nextInt(items);
    if (to == from) to = (from + 1) % items;
    return (from, to);
  });
}

/// Always drop into the same slot, so each insertion converges on one value
/// from a single side. Cheap for a scheme that can express "n steps in the same
/// direction"; expensive for one that can only bisect.
List<(int, int)> convergingMoves(int items, int count) =>
    List.generate(count, (_) => (items - 1, 6));

/// Take alternately from the bottom and the top of the list into the same slot,
/// so the target gap is squeezed from both sides. This is the pattern that
/// walks L,R,L,R down the Stern-Brocot tree.
List<(int, int)> squeezeMoves(int items, int count) =>
    List.generate(count, (move) => move.isEven ? (items - 1, 6) : (0, 6));

void report(String title, List<Result> results, int moves) {
  print('\n$title\n');
  print('  ${'strategy'.padRight(24)}'
      '${'writes'.padLeft(9)}${'per move'.padLeft(10)}'
      '${'bytes'.padLeft(9)}${'longest'.padLeft(9)}'
      '${'ms'.padLeft(6)}   status');
  for (final r in results) {
    final status = r.brokeAt != null
        ? 'ORDER LOST at move ${r.brokeAt}'
        : (r.rebalances > 0 ? '${r.rebalances} rebalances' : 'exact');
    print('  ${r.name.padRight(24)}'
        '${r.writes.toString().padLeft(9)}'
        '${(r.writes / moves).toStringAsFixed(2).padLeft(10)}'
        '${r.bytes.toString().padLeft(9)}'
        '${r.longest.toString().padLeft(9)}'
        '${r.ms.toString().padLeft(6)}   $status');
  }
}

void main() {
  const items = 200;
  const moves = 20000;
  final ordinary = randomMoves(items, moves, 1);

  report('Ordinary reordering — $items items, $moves random moves', [
    denseIntegers(items, ordinary),
    floatMidpoint(items, ordinary),
    sparseIntegers(items, ordinary),
    base62(items, ordinary),
    sternBrocot(items, ordinary),
  ], moves);

  const hard = 2000;

  final converging = convergingMoves(12, hard);
  report('Converging on one value from a single side — 12 items, $hard moves', [
    denseIntegers(12, converging),
    floatMidpoint(12, converging),
    sparseIntegers(12, converging),
    base62(12, converging),
    sternBrocot(12, converging),
    sternBrocot(12, converging, rebalancing: true),
  ], hard);

  final squeeze = squeezeMoves(12, hard);
  report('Squeezing one gap from both sides — 12 items, $hard moves', [
    denseIntegers(12, squeeze),
    floatMidpoint(12, squeeze),
    sparseIntegers(12, squeeze),
    base62(12, squeeze),
    sternBrocot(12, squeeze),
    sternBrocot(12, squeeze, rebalancing: true),
  ], hard);

  print('');
}
