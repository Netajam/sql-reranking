// Ordering rows in a SQL table so that moving one item writes exactly one row.
//
// A port of the Dart implementation in ../dart. The two are cross-checked
// against each other in rank.test.js: same inputs, byte-identical keys.
//
// Store a key per row in a `text` column and ORDER BY it. Because keys are
// dense -- between any two there is always another -- moving an item only
// changes that item's own value, so a reorder costs one UPDATE whatever the
// length of the list. See ../sql/schema.sql for the table.

// ---------------------------------------------------------------------------
// codec: continued-fraction terms <-> sortable string
//
// A rank is a positive rational, and every positive rational is a node of the
// Stern-Brocot tree reached by a unique path of L and R moves. That path is
// runs -- some R's, then some L's, then R's again -- and the run lengths are
// the continued-fraction terms. Encoding *terms* rather than *moves* is what
// keeps keys short: a rank a trillion moves down a spine is a single term.
//
// Ordering follows from two rules. More R moves descend toward larger values
// and more L moves toward smaller, so terms at even positions sort ascending
// and terms at odd positions descending -- every other code is complemented.
// And a key that stopped early would be a prefix of a longer one and would
// always sort first, which is wrong exactly half the time, so there is a
// terminator.
//
// Codes are self-delimiting: `d - 1` leading '9's announce a `d`-digit base-9
// numeral. Base-9 digits never reach '9', so the prefix is unambiguous, and
// because the code is prefix-free a comparison is always settled inside the
// term where two keys first differ. Digits only, so no collation can reorder a
// key.
// ---------------------------------------------------------------------------

const BASE = 9;

/**
 * @param {number} term
 * @returns {string}
 */
function ascending(term) {
  let digits = "";
  let value = term;
  do {
    digits = String(value % BASE) + digits;
    value = Math.floor(value / BASE);
  } while (value !== 0);
  return "9".repeat(digits.length - 1) + digits;
}

/**
 * @param {string} code
 * @returns {string}
 */
function complement(code) {
  let out = "";
  for (let i = 0; i < code.length; i++) {
    out += String(9 - (code.charCodeAt(i) - 0x30));
  }
  return out;
}

/**
 * Encodes one term for `position`, choosing direction from its parity.
 * @param {number} term
 * @param {number} position
 * @returns {string}
 */
function encodeTerm(term, position) {
  const code = ascending(term);
  return position % 2 === 0 ? code : complement(code);
}

/**
 * The full key for a term vector, terminator included.
 * @param {number[]} terms
 * @returns {string}
 */
export function encodeKey(terms) {
  let out = "";
  for (let i = 0; i < terms.length; i++) out += encodeTerm(terms[i], i);
  return out + encodeTerm(0, terms.length);
}

/**
 * Recovers the term vector from a key, terminator dropped.
 * @param {string} key
 * @returns {number[]}
 */
export function decodeKey(key) {
  const terms = [];
  let at = 0;
  let position = 0;

  while (at < key.length) {
    const isAscending = position % 2 === 0;
    // Leading markers announce the numeral's length: '9's when ascending, and
    // their complement '0's when descending.
    const marker = isAscending ? 0x39 : 0x30;
    let run = 0;
    while (at + run < key.length && key.charCodeAt(at + run) === marker) run++;

    const start = at + run;
    const end = start + run + 1;
    if (end > key.length) throw new SyntaxError(`truncated term at ${at}: ${key}`);

    let value = 0;
    for (let i = start; i < end; i++) {
      const digit = isAscending
        ? key.charCodeAt(i) - 0x30
        : 0x39 - key.charCodeAt(i);
      if (digit < 0 || digit >= BASE) {
        throw new SyntaxError(`digit out of range at ${i}: ${key}`);
      }
      value = value * BASE + digit;
    }

    terms.push(value);
    at = end;
    position++;
  }

  if (terms.length === 0) throw new SyntaxError("empty key");
  return terms.slice(0, -1);
}

// ---------------------------------------------------------------------------
// exact rational arithmetic
//
// None of this is stored. The persisted form is the key; these routines get
// from two neighbouring keys to the key that belongs between them. BigInt
// throughout, so there is no width to overflow.
//
// A rational is [numerator, denominator]. A zero denominator means positive
// infinity -- the open bound above the last item. [0n, 1n] is the open bound
// below the first.
// ---------------------------------------------------------------------------

/** @typedef {[bigint, bigint]} Ratio */

/** @type {Ratio} */ const BELOW = [0n, 1n];
/** @type {Ratio} */ const ABOVE = [1n, 0n];

/**
 * Builds a rational from a canonical continued fraction [t0; t1, t2, ...].
 * @param {number[]} cf
 * @returns {Ratio}
 */
function fromContinuedFraction(cf) {
  let numeratorPrev = 1n;
  let numerator = BigInt(cf[0]);
  let denominatorPrev = 0n;
  let denominator = 1n;

  for (let i = 1; i < cf.length; i++) {
    const term = BigInt(cf[i]);
    const n = term * numerator + numeratorPrev;
    const d = term * denominator + denominatorPrev;
    numeratorPrev = numerator;
    denominatorPrev = denominator;
    numerator = n;
    denominator = d;
  }
  return [numerator, denominator];
}

/**
 * The continued-fraction terms of a rank, as run lengths of its path.
 *
 * The last coefficient is reduced by one because the final move lands *on* the
 * node rather than past it -- which is why 1/1, the root, comes back as [0].
 * @param {Ratio} value
 * @returns {number[]}
 */
function termsOfRatio([n, d]) {
  const terms = [];
  while (d !== 0n) {
    terms.push(Number(n / d));
    const r = n % d;
    n = d;
    d = r;
  }
  if (terms.length === 0) throw new RangeError("not a finite rank");
  terms[terms.length - 1] -= 1;
  return terms;
}

/**
 * Rebuilds the rank from its terms. One pass over the terms -- never over the
 * depth, which can be astronomically larger.
 * @param {number[]} terms
 * @returns {Ratio}
 */
function ratioOfTerms(terms) {
  if (terms.length === 0) throw new RangeError("a rank has at least one term");
  const cf = terms.slice();
  cf[cf.length - 1] += 1;
  return fromContinuedFraction(cf);
}

/**
 * Exact comparison by cross-multiplication. Returns -1, 0 or 1.
 * @param {Ratio} a
 * @param {Ratio} b
 * @returns {number}
 */
function compareRatio(a, b) {
  const left = a[0] * b[1];
  const right = b[0] * a[1];
  return left < right ? -1 : left > right ? 1 : 0;
}

/**
 * The simplest rank strictly between `low` and `high`.
 *
 * "Simplest" means smallest denominator, which is also the shallowest node in
 * the tree and -- because every other candidate lies in this one's subtree and
 * so extends its path -- the shortest key. One choice is optimal for all three.
 *
 * Peel off the integer part of the lower bound; if the next whole number lands
 * strictly inside, that is the answer. Otherwise both bounds share an integer
 * part, so invert their fractional parts and go again -- inverting reverses
 * order, which is why the bounds swap, and that swap is exactly the alternating
 * direction the tree encodes.
 *
 * Each round emits one term, so this costs O(terms) divisions rather than
 * O(depth) steps down the tree.
 * @param {Ratio} low
 * @param {Ratio} high
 * @returns {Ratio}
 */
function simplestBetween(low, high) {
  if (compareRatio(low, high) >= 0) {
    throw new RangeError(`bounds are not ordered: ${low} .. ${high}`);
  }

  const cf = [];
  let lo = low;
  let hi = high;

  for (;;) {
    const whole = lo[0] / lo[1];
    const next = whole + 1n;

    // An open upper bound always admits the next whole number.
    if (hi[1] === 0n || next * hi[1] < hi[0]) {
      cf.push(Number(next));
      return fromContinuedFraction(cf);
    }

    cf.push(Number(whole));

    // lo' = 1 / (hi - whole), hi' = 1 / (lo - whole). A zero remainder on the
    // lower bound gives an open upper bound, which is correct: the interval
    // reaches all the way up.
    const loRemainder = lo[0] - whole * lo[1];
    const hiRemainder = hi[0] - whole * hi[1];
    const nextLo = /** @type {Ratio} */ ([hi[1], hiRemainder]);
    const nextHi = /** @type {Ratio} */ ([lo[1], loRemainder]);
    lo = nextLo;
    hi = nextHi;
  }
}

// ---------------------------------------------------------------------------
// public API
// ---------------------------------------------------------------------------

/**
 * A key sorting strictly between `a` and `b`.
 *
 * Pass null for an open end: `keyBetween(null, first)` prepends,
 * `keyBetween(last, null)` appends, `keyBetween(null, null)` starts an empty
 * list. The result is the simplest rank in the interval, which is also the
 * shortest key available there.
 *
 * @param {string | null} a lower bound, or null for the start
 * @param {string | null} b upper bound, or null for the end
 * @returns {string}
 */
export function keyBetween(a, b) {
  const low = a === null ? BELOW : ratioOfTerms(decodeKey(a));
  const high = b === null ? ABOVE : ratioOfTerms(decodeKey(b));
  return encodeKey(termsOfRatio(simplestBetween(low, high)));
}

/**
 * `count` keys spread evenly through an interval, filled middle-first so the
 * result is balanced and its keys are as short as the interval allows.
 * @param {number} count
 * @param {Ratio} [low]
 * @param {Ratio} [high]
 * @returns {string[]}
 */
function distribute(count, low = BELOW, high = ABOVE) {
  const out = new Array(count);

  const fill = (from, to, lower, upper) => {
    if (from > to) return;
    const mid = from + ((to - from) >> 1);
    const value = simplestBetween(lower, upper);
    out[mid] = encodeKey(termsOfRatio(value));
    fill(from, mid - 1, lower, value);
    fill(mid + 1, to, value, upper);
  };

  fill(0, count - 1, low, high);
  return out;
}

/**
 * Evenly spaced keys for a fresh list. Cheaper and shorter than appending one
 * at a time, and the natural way to seed a list that already has an order.
 * @param {number} count
 * @returns {string[]}
 */
export function keySequence(count) {
  if (count < 0) throw new RangeError("count must not be negative");
  return distribute(count);
}

/**
 * The continued-fraction terms behind a key -- its path's run lengths.
 * @param {string} key
 * @returns {number[]}
 */
export function termsOf(key) {
  return decodeKey(key);
}

/**
 * How deep in the Stern-Brocot tree a key sits. Returned as BigInt because it
 * can be astronomically larger than the key: a 27-character key can name a rank
 * a trillion moves down a spine.
 * @param {string} key
 * @returns {bigint}
 */
export function depthOf(key) {
  return decodeKey(key).reduce((sum, term) => sum + BigInt(term), 0n);
}

/**
 * A key as an exact fraction. Derived on demand; never stored.
 * @param {string} key
 * @returns {Ratio}
 */
export function fractionOf(key) {
  return ratioOfTerms(decodeKey(key));
}

/**
 * @typedef {object} RebalancePlan
 * @property {number} start index of the first affected item
 * @property {string[]} keys replacements, in order, beginning at `start`
 */

/**
 * Proposes a rebalance for `keys`, or null if none is warranted.
 *
 * Rebalancing trades the one-write guarantee for shorter keys. It is never
 * required for correctness -- ordering stays exact at any key length -- so
 * treat it as housekeeping, run rarely and off the critical path.
 *
 * Widening is the essential part. Redistributing inside the offending region
 * cannot help, because the keys are long precisely *because* that interval is
 * narrow. So the window grows outward until the enclosing bounds are roomy
 * enough to hold the items at `target` characters or fewer -- in the worst case
 * the whole list, whose bounds are open and always suffice.
 *
 * Only the rows in the returned plan change; everything else keeps its current
 * key, so the plan is safe to apply on its own.
 *
 * @param {string[]} keys in ascending order
 * @param {{limit?: number, target?: number}} [options]
 * @returns {RebalancePlan | null}
 */
export function planRebalance(keys, { limit = 120, target = 32 } = {}) {
  if (limit < target) {
    throw new RangeError(`limit (${limit}) must not be below target (${target})`);
  }
  if (keys.length === 0) return null;

  // Span every offending row, not just the worst one -- they cluster, and a
  // plan that left some over the limit would only have to run again.
  let from = -1;
  let to = -1;
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].length > limit) {
      if (from < 0) from = i;
      to = i;
    }
  }
  if (from < 0) return null;

  for (;;) {
    const lower = from === 0 ? BELOW : fractionOf(keys[from - 1]);
    const upper = to === keys.length - 1 ? ABOVE : fractionOf(keys[to + 1]);

    const replacement = distribute(to - from + 1, lower, upper);
    const fits = replacement.every((k) => k.length <= target);
    const wholeList = from === 0 && to === keys.length - 1;

    if (fits || wholeList) return { start: from, keys: replacement };

    // Not roomy enough yet -- take in a neighbour on each side and retry.
    if (from > 0) from--;
    if (to < keys.length - 1) to++;
  }
}
