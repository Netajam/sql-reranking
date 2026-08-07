/// What does this actually cost? Numbers for the README.
///
///   dart run example/measure.dart
library;

import 'dart:math';

import 'package:rank/rank.dart';

int longest(List<Rank> ranks) => ranks.map((r) => r.length).reduce(max);
double mean(List<Rank> ranks) =>
    ranks.map((r) => r.length).reduce((a, b) => a + b) / ranks.length;

/// Ordinary drag-and-drop: any item, any destination.
void randomWorkload(int items, int moves, int seed) {
  final random = Random(seed);
  final ranks = Rank.sequence(items);
  var peak = 0;

  for (var move = 0; move < moves; move++) {
    final from = random.nextInt(ranks.length);
    var to = random.nextInt(ranks.length);
    if (to == from) to = (from + 1) % ranks.length;

    ranks.insert(to, ranks.removeAt(from));
    ranks[to] = Rank.between(
      to == 0 ? null : ranks[to - 1],
      to == ranks.length - 1 ? null : ranks[to + 1],
    );
    peak = max(peak, longest(ranks));
  }

  print('  ${items.toString().padLeft(5)} items, '
      '${moves.toString().padLeft(7)} moves   '
      'longest now ${longest(ranks).toString().padLeft(3)}   '
      'peak ${peak.toString().padLeft(3)}   '
      'mean ${mean(ranks).toStringAsFixed(1).padLeft(5)}');
}

/// The worst case: squeeze one gap from both sides, forever.
void adversarialWorkload(int moves, {required bool rebalancing}) {
  final ranks = Rank.sequence(12);
  var writes = 0;
  var rebalances = 0;

  for (var move = 0; move < moves; move++) {
    if (move.isEven) {
      ranks[7] = Rank.between(ranks[6], ranks[7]);
    } else {
      ranks[6] = Rank.between(ranks[6], ranks[7]);
    }
    writes += 1;

    if (rebalancing) {
      final plan = Rebalance.plan(ranks, limit: 64, target: 20);
      if (plan != null) {
        ranks.replaceRange(plan.start, plan.end, plan.ranks);
        writes += plan.writes;
        rebalances += 1;
      }
    }
  }

  final label = rebalancing ? 'with rebalancing   ' : 'without rebalancing';
  print('  $label  ${moves.toString().padLeft(6)} moves   '
      'longest ${longest(ranks).toString().padLeft(5)}   '
      'writes ${writes.toString().padLeft(6)}   '
      'per move ${(writes / moves).toStringAsFixed(3)}   '
      'rebalances ${rebalances.toString().padLeft(4)}');
}

void main() {
  print('\nOrdinary reordering — key length settles and stays there\n');
  for (final (items, moves) in [(20, 5000), (50, 20000), (200, 50000)]) {
    randomWorkload(items, moves, 1);
  }

  print('\nA fresh list costs almost nothing\n');
  for (final count in [10, 100, 1000, 10000]) {
    final ranks = Rank.sequence(count);
    print('  ${count.toString().padLeft(5)} items   '
        'longest ${longest(ranks).toString().padLeft(2)}   '
        'mean ${mean(ranks).toStringAsFixed(1)}');
  }

  print('\nThe worst case — one gap squeezed from both sides\n');
  for (final moves in [2000, 10000]) {
    adversarialWorkload(moves, rebalancing: false);
    adversarialWorkload(moves, rebalancing: true);
  }
  print('');
}
