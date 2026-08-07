// node --test
import { test } from "node:test";
import assert from "node:assert/strict";

import {
  keyBetween,
  keySequence,
  termsOf,
  depthOf,
  fractionOf,
  encodeKey,
  decodeKey,
  planRebalance,
} from "./rank.js";

/**
 * The worst case for any scheme that writes one row: squeeze a gap from *both*
 * sides. The alternation matters -- converging from one side walks a spine and
 * costs almost nothing, while alternating walks the Fibonacci path and costs a
 * character a move.
 */
function squeeze(keys, at, moves) {
  for (let move = 0; move < moves; move++) {
    if (move % 2 === 0) {
      keys[at + 1] = keyBetween(keys[at], keys[at + 1]);
    } else {
      keys[at] = keyBetween(keys[at], keys[at + 1]);
    }
  }
}

function expectKeyOrderMatchesValue(keys) {
  const byValue = [...keys].sort((a, b) => {
    const [an, ad] = fractionOf(a);
    const [bn, bd] = fractionOf(b);
    const l = an * bd;
    const r = bn * ad;
    return l < r ? -1 : l > r ? 1 : 0;
  });
  const byKey = [...keys].sort();
  assert.deepEqual(byKey, byValue);
}

test("an empty list gets the root", () => {
  const only = keyBetween(null, null);
  assert.deepEqual(fractionOf(only), [1n, 1n]);
  assert.deepEqual(termsOf(only), [0]);
});

test("open ends prepend and append", () => {
  const middle = keyBetween(null, null);
  assert.ok(keyBetween(middle, null) > middle);
  assert.ok(keyBetween(null, middle) < middle);
});

test("the result always lands strictly between", () => {
  let lower = keyBetween(null, null);
  let upper = keyBetween(lower, null);
  for (let i = 0; i < 400; i++) {
    const between = keyBetween(lower, upper);
    assert.ok(between > lower, "above the lower bound");
    assert.ok(between < upper, "below the upper bound");
    if (i % 2 === 0) lower = between;
    else upper = between;
  }
});

test("rejects bounds that are not ordered", () => {
  const a = keyBetween(null, null);
  const b = keyBetween(a, null);
  assert.throws(() => keyBetween(b, a), RangeError);
  assert.throws(() => keyBetween(a, a), RangeError);
});

test("picks the shortest key available in the interval", () => {
  // 5/7 .. 3/2 brackets 1/1, the root.
  const low = encodeKey([0, 1, 2, 1]);
  const high = encodeKey([1, 1]);
  const between = keyBetween(low, high);
  assert.deepEqual(fractionOf(between), [1n, 1n]);
  assert.equal(depthOf(between), 0n);
});

test("keys round-trip through the codec", () => {
  for (const key of keySequence(64)) {
    assert.equal(encodeKey(decodeKey(key)), key);
  }
});

test("digits only, so collation cannot reorder them", () => {
  for (const key of keySequence(200)) assert.match(key, /^[0-9]+$/);
});

test("malformed input is rejected at the boundary", () => {
  assert.throws(() => decodeKey(""), SyntaxError);
  assert.throws(() => decodeKey("9"), SyntaxError);
  assert.throws(() => decodeKey("99"), SyntaxError);
});

test("keys stay short where the depth explodes", () => {
  const deep = encodeKey([1000000000000]);
  assert.equal(depthOf(deep), 1000000000000n);
  assert.ok(deep.length < 32);
});

test("sequence is balanced and compact", () => {
  for (const count of [1, 2, 10, 100, 1000]) {
    const keys = keySequence(count);
    assert.equal(keys.length, count);
    expectKeyOrderMatchesValue(keys);
    assert.ok(Math.max(...keys.map((k) => k.length)) < 40, `count=${count}`);
  }
});

test("random reordering keeps key order and value order identical", () => {
  // Deterministic LCG so a failure is reproducible.
  let seed = 3;
  const next = (n) => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) % n);

  const keys = keySequence(40);
  for (let move = 0; move < 3000; move++) {
    const from = next(keys.length);
    let to = next(keys.length);
    if (to === from) to = (from + 1) % keys.length;

    const [moved] = keys.splice(from, 1);
    keys.splice(to, 0, moved);
    keys[to] = keyBetween(
      to === 0 ? null : keys[to - 1],
      to === keys.length - 1 ? null : keys[to + 1],
    );

    for (let i = 0; i < keys.length - 1; i++) {
      assert.ok(keys[i] < keys[i + 1], `order broke at move ${move}, index ${i}`);
    }
  }
  expectKeyOrderMatchesValue(keys);
});

test("a move rewrites exactly one key", () => {
  const keys = keySequence(30);
  const before = new Set(keys);
  const [moved] = keys.splice(2, 1);
  keys.splice(20, 0, moved);
  keys[20] = keyBetween(keys[19], keys[21]);
  assert.equal(keys.filter((k) => !before.has(k)).length, 1);
});

test("rebalance proposes nothing while keys are short", () => {
  assert.equal(planRebalance(keySequence(500)), null);
});

test("rebalance triggers past the limit and shortens", () => {
  const keys = keySequence(6);
  squeeze(keys, 2, 80);
  assert.ok(Math.max(...keys.map((k) => k.length)) > 60);

  const plan = planRebalance(keys, { limit: 60, target: 24 });
  assert.ok(plan);
  keys.splice(plan.start, plan.keys.length, ...plan.keys);

  assert.ok(Math.max(...keys.map((k) => k.length)) <= 60);
  for (let i = 0; i < keys.length - 1; i++) assert.ok(keys[i] < keys[i + 1]);
  assert.equal(planRebalance(keys, { limit: 60, target: 24 }), null);
});

test("rebalance leaves untouched rows alone", () => {
  const keys = keySequence(40);
  squeeze(keys, 20, 100);

  const plan = planRebalance(keys, { limit: 80, target: 20 });
  assert.ok(plan);
  const untouched = [
    ...keys.slice(0, plan.start),
    ...keys.slice(plan.start + plan.keys.length),
  ];
  keys.splice(plan.start, plan.keys.length, ...plan.keys);
  for (const key of untouched) assert.ok(keys.includes(key));
  expectKeyOrderMatchesValue(keys);
});

test("survives the adversarial pattern at close to one write a move", () => {
  const moves = 2000;
  const keys = keySequence(12);
  let writes = 0;
  let rebalances = 0;

  for (let move = 0; move < moves; move++) {
    if (move % 2 === 0) keys[7] = keyBetween(keys[6], keys[7]);
    else keys[6] = keyBetween(keys[6], keys[7]);
    writes += 1;

    const plan = planRebalance(keys, { limit: 64, target: 20 });
    if (plan) {
      keys.splice(plan.start, plan.keys.length, ...plan.keys);
      writes += plan.keys.length;
      rebalances += 1;
    }
  }

  assert.ok(Math.max(...keys.map((k) => k.length)) <= 64);
  for (let i = 0; i < keys.length - 1; i++) assert.ok(keys[i] < keys[i + 1]);
  assert.ok(rebalances > 0, "the pattern must trigger it");
  assert.ok(writes / moves < 2.0, "amortised cost stays near one write a move");
});
