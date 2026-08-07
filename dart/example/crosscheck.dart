/// Emits keys for a fixed workload so the JS port can be diffed against Dart.
///   dart run example/crosscheck.dart > /tmp/dart.txt
library;

import 'package:rank/rank.dart';

void main() {
  // MINSTD, chosen so every product stays under 2^53 and JS matches exactly.
  var seed = 42;
  int next(int n) {
    seed = (16807 * seed) % 2147483647;
    return seed % n;
  }

  final ranks = Rank.sequence(40);
  print(ranks.map((r) => r.key).join(','));

  for (var move = 0; move < 500; move++) {
    final from = next(ranks.length);
    var to = next(ranks.length);
    if (to == from) to = (from + 1) % ranks.length;
    ranks.insert(to, ranks.removeAt(from));
    ranks[to] = Rank.between(
      to == 0 ? null : ranks[to - 1],
      to == ranks.length - 1 ? null : ranks[to + 1],
    );
    print(ranks.map((r) => r.key).join(','));
  }

  // Adversarial squeeze, then the rebalance plan it provokes.
  final squeezed = Rank.sequence(12);
  for (var move = 0; move < 120; move++) {
    if (move.isEven) {
      squeezed[7] = Rank.between(squeezed[6], squeezed[7]);
    } else {
      squeezed[6] = Rank.between(squeezed[6], squeezed[7]);
    }
    print(squeezed.map((r) => r.key).join(','));
  }
  final plan = Rebalance.plan(squeezed, limit: 64, target: 20)!;
  print('plan ${plan.start} ${plan.ranks.map((r) => r.key).join(',')}');
}
