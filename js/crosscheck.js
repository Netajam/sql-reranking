// Emits keys for the same workload as dart/example/crosscheck.dart.
//   node crosscheck.js > /tmp/js.txt
import { keyBetween, keySequence, planRebalance } from "./rank.js";

let seed = 42;
const next = (n) => ((seed = (16807 * seed) % 2147483647), seed % n);

const keys = keySequence(40);
console.log(keys.join(","));

for (let move = 0; move < 500; move++) {
  const from = next(keys.length);
  let to = next(keys.length);
  if (to === from) to = (from + 1) % keys.length;
  const [moved] = keys.splice(from, 1);
  keys.splice(to, 0, moved);
  keys[to] = keyBetween(
    to === 0 ? null : keys[to - 1],
    to === keys.length - 1 ? null : keys[to + 1],
  );
  console.log(keys.join(","));
}

const squeezed = keySequence(12);
for (let move = 0; move < 120; move++) {
  if (move % 2 === 0) squeezed[7] = keyBetween(squeezed[6], squeezed[7]);
  else squeezed[6] = keyBetween(squeezed[6], squeezed[7]);
  console.log(squeezed.join(","));
}
const plan = planRebalance(squeezed, { limit: 64, target: 20 });
console.log(`plan ${plan.start} ${plan.keys.join(",")}`);
