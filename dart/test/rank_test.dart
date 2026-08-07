import 'dart:math';

import 'package:rank/rank.dart';
import 'package:test/test.dart';

/// Sorting by key must agree with sorting by exact value, always. This is the
/// property everything else rests on.
/// The worst case for any scheme that writes one row: squeeze a gap from *both*
/// sides, alternately pushing each bound toward the other.
///
/// The alternation matters. Converging on a fixed neighbour from one side walks
/// a spine and costs almost nothing — 60 such moves leave a 5-character key.
/// Alternating walks L,R,L,R, which is the Fibonacci path, the deepest in the
/// tree per unit of denominator, and costs one character a move.
void squeeze(List<Rank> ranks, int at, int moves) {
  for (var move = 0; move < moves; move++) {
    if (move.isEven) {
      ranks[at + 1] = Rank.between(ranks[at], ranks[at + 1]);
    } else {
      ranks[at] = Rank.between(ranks[at], ranks[at + 1]);
    }
  }
}

void expectKeyOrderMatchesValue(List<Rank> ranks) {
  int byValue(Rank a, Rank b) {
    final (an, ad) = a.fraction;
    final (bn, bd) = b.fraction;
    return (an * bd).compareTo(bn * ad);
  }

  final sortedByKey = [...ranks]..sort();
  final sortedByValue = [...ranks]..sort(byValue);
  expect(sortedByKey.map((r) => r.key).toList(),
      sortedByValue.map((r) => r.key).toList());
}

void main() {
  group('between', () {
    test('an empty list gets the root', () {
      final only = Rank.between(null, null);
      expect(only.fraction, (BigInt.one, BigInt.one));
      expect(only.terms, [0]);
    });

    test('open ends prepend and append', () {
      final middle = Rank.between(null, null);
      expect(Rank.between(middle, null) > middle, isTrue);
      expect(Rank.between(null, middle) < middle, isTrue);
    });

    test('the result always lands strictly between', () {
      final random = Random(7);
      var lower = Rank.between(null, null);
      var upper = Rank.between(lower, null);

      for (var i = 0; i < 400; i++) {
        final between = Rank.between(lower, upper);
        expect(between > lower, isTrue, reason: 'above the lower bound');
        expect(between < upper, isTrue, reason: 'below the upper bound');
        // Squeeze from alternating sides — the pattern that drives keys longest.
        if (random.nextBool()) {
          lower = between;
        } else {
          upper = between;
        }
      }
    });

    test('rejects bounds that are not ordered', () {
      final a = Rank.between(null, null);
      final b = Rank.between(a, null);
      expect(() => Rank.between(b, a), throwsArgumentError);
      expect(() => Rank.between(a, a), throwsArgumentError);
    });

    test('picks the shortest key available in the interval', () {
      // 5/7 .. 3/2 brackets 1/1, the root. A neighbour-anchored search would
      // return something far deeper.
      final low = Rank(encodeKey([0, 1, 2, 1])); // 5/7
      final high = Rank(encodeKey([1, 1])); // 3/2
      final between = Rank.between(low, high);
      expect(between.fraction, (BigInt.one, BigInt.one));
      expect(between.depth, BigInt.zero);
    });
  });

  group('keys', () {
    test('round-trip through the codec', () {
      final ranks = Rank.sequence(64);
      for (final rank in ranks) {
        expect(Rank(rank.key).key, rank.key);
        expect(encodeKey(rank.terms), rank.key);
      }
    });

    test('digits only, so collation cannot reorder them', () {
      for (final rank in Rank.sequence(200)) {
        expect(RegExp(r'^[0-9]+$').hasMatch(rank.key), isTrue);
      }
    });

    test('malformed input is rejected at the boundary', () {
      expect(() => Rank(''), throwsFormatException);
      expect(() => Rank('9'), throwsFormatException); // truncated
      expect(() => Rank('99'), throwsFormatException);
    });

    test('stay short where the depth explodes', () {
      // One term of a trillion: a trillion moves down the spine.
      final deep = Rank(encodeKey([1000000000000]));
      expect(deep.depth, BigInt.from(1000000000000));
      expect(deep.length, lessThan(32));
    });

    test('sequence is balanced and compact', () {
      for (final count in [1, 2, 10, 100, 1000]) {
        final ranks = Rank.sequence(count);
        expect(ranks.length, count);
        expectKeyOrderMatchesValue(ranks);
        // A balanced fill costs about log2(count) levels, not count.
        expect(ranks.map((r) => r.length).reduce(max), lessThan(40),
            reason: 'count=$count');
      }
    });
  });

  group('ordering under load', () {
    test('random reordering keeps key order and value order identical', () {
      final random = Random(3);
      final ranks = Rank.sequence(40);

      for (var move = 0; move < 3000; move++) {
        final from = random.nextInt(ranks.length);
        var to = random.nextInt(ranks.length);
        if (to == from) to = (from + 1) % ranks.length;

        final moved = ranks.removeAt(from);
        ranks.insert(to, moved);
        ranks[to] = Rank.between(
          to == 0 ? null : ranks[to - 1],
          to == ranks.length - 1 ? null : ranks[to + 1],
        );

        for (var i = 0; i < ranks.length - 1; i++) {
          expect(ranks[i] < ranks[i + 1], isTrue,
              reason: 'order broke at move $move, index $i');
        }
      }
      expectKeyOrderMatchesValue(ranks);
    });

    test('a move rewrites exactly one rank', () {
      final ranks = Rank.sequence(30);
      final before = [...ranks];

      final moved = ranks.removeAt(2);
      ranks.insert(20, moved);
      ranks[20] = Rank.between(ranks[19], ranks[21]);

      final changed =
          ranks.where((r) => !before.contains(r)).length;
      expect(changed, 1);
    });
  });

  group('rebalance', () {
    test('proposes nothing while keys are short', () {
      expect(Rebalance.plan(Rank.sequence(500)), isNull);
    });

    test('triggers once a key passes the limit, and shortens it', () {
      final ranks = Rank.sequence(6);
      squeeze(ranks, 2, 80);
      expect(ranks.map((r) => r.length).reduce(max), greaterThan(60));

      final plan = Rebalance.plan(ranks, limit: 60, target: 24)!;
      expect(plan.writes, greaterThanOrEqualTo(1));
      expect(plan.writes, lessThanOrEqualTo(ranks.length));

      ranks.replaceRange(plan.start, plan.end, plan.ranks);
      expect(ranks.map((r) => r.length).reduce(max), lessThanOrEqualTo(60));
      for (var i = 0; i < ranks.length - 1; i++) {
        expect(ranks[i] < ranks[i + 1], isTrue, reason: 'order broke at $i');
      }
      expect(Rebalance.plan(ranks, limit: 60, target: 24), isNull);
    });

    test('keeps the list ordered against its untouched neighbours', () {
      final ranks = Rank.sequence(40);
      squeeze(ranks, 20, 100);

      final plan = Rebalance.plan(ranks, limit: 80, target: 20)!;
      // Everything outside the window must keep its rank.
      final untouched = [
        ...ranks.sublist(0, plan.start),
        ...ranks.sublist(plan.end),
      ];
      ranks.replaceRange(plan.start, plan.end, plan.ranks);
      for (final rank in untouched) {
        expect(ranks.contains(rank), isTrue);
      }
      expectKeyOrderMatchesValue(ranks);
    });

    test('survives the adversarial pattern, at close to one write a move', () {
      // Without rebalancing this pattern grows keys without bound — one
      // character per move, which is the theoretical floor for any scheme that
      // writes a single row. Rebalancing trades that for occasional bulk
      // writes and holds the key length flat forever.
      const moves = 2000;
      final ranks = Rank.sequence(12);
      var writes = 0;
      var rebalances = 0;

      for (var move = 0; move < moves; move++) {
        // Alternate the side, which is what makes this the worst case. Calling
        // squeeze() once per move would always take the same branch and walk a
        // spine instead — harmless, and it would never trigger a rebalance.
        if (move.isEven) {
          ranks[7] = Rank.between(ranks[6], ranks[7]);
        } else {
          ranks[6] = Rank.between(ranks[6], ranks[7]);
        }
        writes += 1;

        final plan = Rebalance.plan(ranks, limit: 64, target: 20);
        if (plan != null) {
          ranks.replaceRange(plan.start, plan.end, plan.ranks);
          writes += plan.writes;
          rebalances += 1;
        }
      }

      expect(ranks.map((r) => r.length).reduce(max), lessThanOrEqualTo(64));
      for (var i = 0; i < ranks.length - 1; i++) {
        expect(ranks[i] < ranks[i + 1], isTrue);
      }
      expect(rebalances, greaterThan(0), reason: 'the pattern must trigger it');
      expect(writes / moves, lessThan(2.0),
          reason: 'amortised cost stays near one write a move');
    });
  });
}
