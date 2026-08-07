/// Why a denser alphabet does not shrink these keys.
///
///   dart run example/codec_study.dart
///
/// The codec spends one character per continued-fraction term. That looked like
/// the thing to fix — base-62 fractional indexing stores the same orderings in a
/// third of the bytes, so surely a wider alphabet would close the gap.
///
/// It does not, and this measures why: almost every term is already small enough
/// to cost a single character in base 9, so widening the base changes nothing.
/// The waste is not in the alphabet, it is in the granularity.
library;

import 'dart:math';

import 'package:rank/rank.dart';

/// Cost of one term under the codec's self-delimiting scheme: `d - 1` markers
/// followed by a `d`-digit numeral.
int termCost(int term, int base) {
  var digits = 0, value = term;
  do {
    digits++;
    value ~/= base;
  } while (value != 0);
  return 2 * digits - 1;
}

void main() {
  const items = 200;
  const moves = 20000;

  final random = Random(1);
  final ranks = Rank.sequence(items);
  for (var move = 0; move < moves; move++) {
    final from = random.nextInt(ranks.length);
    var to = random.nextInt(ranks.length);
    if (to == from) to = (from + 1) % ranks.length;
    ranks.insert(to, ranks.removeAt(from));
    ranks[to] = Rank.between(
      to == 0 ? null : ranks[to - 1],
      to == ranks.length - 1 ? null : ranks[to + 1],
    );
  }

  final histogram = <int, int>{};
  var termCount = 0;
  for (final rank in ranks) {
    for (final term in rank.terms) {
      histogram[term] = (histogram[term] ?? 0) + 1;
      termCount++;
    }
  }

  print('\nTerm sizes after $moves random moves on $items items '
      '($termCount terms)\n');
  final sizes = histogram.keys.toList()..sort();
  var cumulative = 0;
  for (final size in sizes.take(10)) {
    cumulative += histogram[size]!;
    print('  term ${size.toString().padLeft(3)}   '
        '${histogram[size].toString().padLeft(5)}   '
        '${(100 * cumulative / termCount).toStringAsFixed(1).padLeft(5)}% cumulative');
  }
  print('  largest ${sizes.last},  ${(termCount / items).toStringAsFixed(1)} '
      'terms per rank');

  print('\nMean key length by alphabet size\n');
  for (final base in [9, 15, 31, 61]) {
    final total = ranks.fold<int>(
        0, (sum, r) => sum + r.terms.fold(1, (s, t) => s + termCost(t, base)));
    print('  base ${base.toString().padLeft(2)} '
        '(alphabet ${(base + 1).toString().padLeft(2)})   '
        '${(total / items).toStringAsFixed(1)} chars');
  }

  // How much information is actually in a term?
  var entropy = 0.0;
  histogram.forEach((_, count) {
    final p = count / termCount;
    entropy -= p * (log(p) / ln2);
  });
  final bitsPerRank = entropy * termCount / items;
  final base62Chars = bitsPerRank / (log(62) / ln2);

  print('\nWhere the bytes actually go\n');
  print('  information per term        ${entropy.toStringAsFixed(2)} bits');
  print('  information per rank        ${bitsPerRank.toStringAsFixed(1)} bits');
  print('  that is worth               ${base62Chars.toStringAsFixed(1)} '
      'characters at 5.95 bits each');
  print('  base-62 fractional achieves 5.5 characters (1.4x over — its 2-char head)');
  print('  this codec spends           '
      '${(ranks.fold<int>(0, (s, r) => s + r.length) / items).toStringAsFixed(1)} '
      'characters');
  print('  wasted per term             '
      '${(log(62) / ln2 - entropy).toStringAsFixed(2)} bits\n');
  print('  A wider alphabet cannot recover that: the floor is one character per');
  print('  term, and the terms are already smaller than base 9 can charge for.');
  print('  Closing the gap needs several terms packed into one character, which');
  print('  means an order-preserving code across the alternating directions —');
  print('  a different design, not a bigger digit set.\n');
}
