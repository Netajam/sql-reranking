# rank

Ordering rows in a SQL table so that **moving one item writes exactly one row**.

Reordering a list is usually O(n) writes: move an item from position 2 to
position 90 and the 88 rows in between all shift by one. Batching the statements
doesn't help — the writes still happen.

The fix is to stop storing an item's *position* and store a *sort key*. Position
is a property of the whole list, so changing one changes all of them. A sort key
is a property of the item alone, and the list order becomes a derived view. Move
an item and only its own row changed.

```sql
UPDATE list_item SET rank_key = $1 WHERE id = $2;   -- the entire reorder
```

For that to work indefinitely the key type must be **dense**: between any two
keys another must always exist. Otherwise you eventually cannot express "put X
here" and you are back to shifting rows.

## Using it

```dart
import 'package:rank/rank.dart';

final a = Rank.between(null, null);   // first item in an empty list
final b = Rank.between(a, null);      // append
final c = Rank.between(null, a);      // prepend
final d = Rank.between(a, b);         // insert between two rows

final seeded = Rank.sequence(500);    // a list that already has an order

// Move the item at index 2 to index 20:
list.insert(20, list.removeAt(2));
list[20] = Rank.between(list[19], list[21]);   // one row to persist
```

```js
import { keyBetween, keySequence, planRebalance } from "./js/rank.js";

const a = keyBetween(null, null);     // first item in an empty list
const b = keyBetween(a, null);        // append
const d = keyBetween(a, b);           // insert between two rows

keys.splice(20, 0, ...keys.splice(2, 1));
keys[20] = keyBetween(keys[19], keys[21]);     // one row to persist
```

The two implementations are cross-checked against each other, not merely tested
in parallel: `crosscheck` runs the same 620-step workload through both and
diffs the output. All 150,195 bytes of generated keys are byte-identical, so a
list written by one can be read and extended by the other.

`rank.key` is what you store and what you sort on. It is opaque — only its byte
order carries meaning. See [`sql/schema.sql`](sql/schema.sql) for the table, the
queries, and the concurrency and pagination notes.

```
cd dart && dart pub get && dart test        # 16 tests
cd js   && node --test                      # the same 16
psql -f sql/verify.sql                      # 7 schema checks, on a real server

dart run example/measure.dart               # the numbers below
dart run example/compare.dart               # against the alternatives
```

The schema is verified rather than reasoned about — `verify.sql` confirms on
PostgreSQL 17 that the ordering query plans to an Index Scan with **no Sort
node**, that keyset pagination visits all 20,000 rows with no skips or repeats,
that duplicate keys are rejected so the retry path is real, that the column
carries `C` collation, and that the rebalance UPDATE behaves as documented in
both the deferrable and non-deferrable cases.

## What it costs

Ordinary drag-and-drop reordering. Key length **settles** rather than climbing —
each move replaces one rank with the simplest value between its new neighbours,
and the list only ever holds n of them, so complex ranks are discarded as fast as
they appear:

| list | moves | longest key | mean |
|---|---|---|---|
| 20 items | 5,000 | 13 | 6.9 |
| 50 items | 20,000 | 12 | 6.5 |
| 200 items | 50,000 | 35 | 12.6 |

Seeding a list is cheap — 10,000 items get a longest key of 14 characters.

## How it works

A rank is a positive rational, and every positive rational is a node of the
**Stern–Brocot tree**, reached by a unique path of L and R moves from the root.
The tree is a binary search tree over all the rationals, so the *mediant* of two
neighbours always lies strictly between them — which is exactly the density the
scheme needs, with exact integer arithmetic and no precision floor.

Two choices make it practical.

**The key encodes run lengths, not moves.** A path is some R's, then some L's,
then R's again, and those run lengths are the continued-fraction terms. There are
only O(log q) of them however long the path is. Writing the path out move by move
would be correct and useless: the tree's spines are deep by construction, so rank
*n* would need *n* characters. Encoding terms instead:

```
5/7  ->  path L R R L  ->  runs [0, 1, 2, 1]  ->  key "08190"
```

A rank sitting **a trillion moves** down a spine encodes in 27 characters.

Ordering falls out of two rules. More R moves descend toward larger values and
more L moves toward smaller, so terms at even positions sort ascending and terms
at odd positions sort descending — every other code is complemented. And a key
that stopped early would be a prefix of a longer one and would always sort first,
which is wrong exactly half the time, so there is a terminator. Codes are
self-delimiting (`d-1` leading `9`s announce a `d`-digit base-9 numeral) and
therefore prefix-free, so a comparison is always settled inside the term where
two keys first differ. Digits only, so no collation can reorder a key.

**`between` never walks the tree.** It runs the continued-fraction construction
for the simplest rational in an interval: peel off the integer part, take the
next whole number if it fits strictly inside, otherwise invert both bounds and go
again — inverting reverses their order, which is where the tree's alternation
comes from. That costs O(terms) divisions rather than O(depth) steps, so
appending to a long list is not proportional to the list.

The rank it returns is the interval's **lowest common ancestor**: minimal
denominator, shallowest node, and shortest key, all at once. Those coincide
because every other candidate in the interval lies in that node's subtree and so
extends its path.

`BigInt` is used throughout `between`, and never stored — so there is no integer
width to overflow. The persisted form is the key.

## Rebalancing

Key growth is not unbounded in practice, but it is unbounded in principle. An
adversary who repeatedly squeezes **one gap from both sides** — alternating which
bound moves, which walks L,R,L,R down the tree — gains one character per move
forever.

That is not a weakness of this implementation. One character per move is
Dietz–Sleator's floor for *any* scheme that writes a single row. The only escape
is to occasionally write more than one.

`Rebalance.plan` is that escape. It reports nothing until a key passes `limit`,
then returns a contiguous run of rows and their replacements:

```dart
final plan = Rebalance.plan(ranks, limit: 120, target: 32);
if (plan != null) {
  ranks.replaceRange(plan.start, plan.end, plan.ranks);   // plan.writes rows
}
```

The essential part is that the window **widens**. Redistributing inside the
offending region cannot help, because the keys are long precisely *because* that
interval is narrow. So the window grows outward until the enclosing bounds are
roomy enough to hold their items at `target` characters or fewer — worst case the
whole list, whose bounds are open and always suffice. Everything outside the
window keeps its key, so a plan is safe to apply on its own.

Against the adversarial pattern:

| | moves | longest key | writes/move |
|---|---|---|---|
| without rebalancing | 10,000 | 10,003 | 1.000 |
| **with rebalancing** | 10,000 | **33** | **1.017** |

169 rebalances across 10,000 moves. Under 2% extra writes buys a permanent cap on
key length — and on ordinary workloads it never fires at all.

So the guarantee is: **one write per reorder, always**, and if you want bounded
keys as well, one write *amortised*.

## Against the alternatives

`dart run example/compare.dart` runs five strategies over identical moves. The
base-62 opponent is a faithful port of the reference implementation
([rocicorp/fractional-indexing](https://github.com/rocicorp/fractional-indexing),
CC0), validated against its own test vectors — integer-part machinery included,
since that is what makes appending past the end cheap.

**Ordinary reordering** — 200 items, 20,000 random moves:

| strategy | writes/move | bytes | longest | ms | |
|---|---|---|---|---|---|
| dense integers | **67.40** | 1600 | 8 | 10 | exact |
| float midpoint | 1.00 | 1600 | 8 | 9 | exact *here* |
| sparse integers | 1.13 | 1600 | 8 | 9 | 13 full renumbers |
| base-62 fractional | 1.00 | **1099** | **10** | **48** | exact |
| Stern-Brocot | 1.00 | 2251 | 29 | 215 | exact |

**Converging on one value from one side** — always dropping into the same slot:

| strategy | writes/move | longest | |
|---|---|---|---|
| float midpoint | 1.00 | 8 | **order lost at move 50** |
| sparse integers | 1.64 | 8 | 117 full renumbers |
| base-62 fractional | 1.00 | **336** | exact |
| Stern-Brocot | 1.00 | **9** | exact |

**Squeezing one gap from both sides** — alternating which bound moves:

| strategy | writes/move | longest | |
|---|---|---|---|
| float midpoint | 1.00 | 8 | **order lost at move 50** |
| sparse integers | 1.64 | 8 | 117 full renumbers |
| base-62 fractional | 1.00 | **336** | exact |
| Stern-Brocot | 1.00 | **2002** | exact |
| Stern-Brocot + rebalance | 1.18 | **6** | 32 rebalances |

What that says:

**Position columns are hopeless** — 67 writes per move is the problem this whole
idea exists to solve.

**Floats work until they silently don't.** They survived 20,000 random moves
here, then lost the order at move 50 under either skewed pattern — with no error
raised. The failure is not rare-and-loud, it is quiet and permanent.

**Sparse integers turn one write into a full renumber**, and they do it exactly
when the list is being worked hardest: 117 renumbers in 2,000 moves.

**base-62 and Stern-Brocot both give one exact write per move.** Neither
dominates. base-62 is roughly 2x more compact and 4x faster on ordinary
workloads, because 62 characters carry more per byte than this codec's base-9
digits and because `between` here does BigInt arithmetic. But the two degrade on
*opposite* patterns, and the reason is structural: base-62 can only bisect, while
continued fractions can say "n steps in the same direction" in a single term. So
one-sided convergence — which is what "always drop it at the top" or "always put
it just under this one" actually looks like — costs base-62 336 characters and
this scheme 9. Squeezing from both sides reverses it.

**Rebalancing caps whichever worst case you meet**, at 1.18 writes per move. It
applies equally well to base-62; it just isn't implemented there.

So the choice is not obvious. If your edits are mostly interior and you want the
smallest, fastest keys, base-62 is the better engineering. If your workload skews
toward repeatedly inserting at one end or against one anchor, this scheme holds
up where base-62 does not.

### The size gap is not the alphabet

The obvious fix for the 2x — use a denser digit set — does not work, and
`dart run example/codec_study.dart` shows why.

After 20,000 random moves, **99% of terms are 8 or smaller**, so they already
cost exactly one character in base 9. Widening the alphabet barely moves it:

| alphabet | mean key |
|---|---|
| 10 (base 9, current) | 11.3 |
| 16 | 11.1 |
| 32 | 11.1 |
| 62 | 11.1 |

The waste is granularity, not density. A term carries **2.4 bits** of information
on average, and the codec spends a whole character — 5.95 bits of capacity in a
62-character alphabet — on each one. That is 3.6 bits thrown away per term, and
with 10.1 terms per rank it accounts for the entire gap:

```
information per rank        24.0 bits
worth, at 5.95 bits/char     4.0 characters
base-62 fractional          5.5 characters   <- 1.4x over, from its 2-char head
this codec                 11.3 characters   <- 2.8x over
```

base-62 pays a fixed two-character integer part on every key, which is what
buys it cheap appends; net of that it is close to optimal for this workload. Beating it would mean packing several terms into one character:
an order-preserving code across the alternating ascending/descending directions.
That is a different design, and it would cost the two properties this codec was
built for — digits-only keys that no collation can reorder, and a decoder simple
enough to verify by eye.

## Layout

| path | |
|---|---|
| `dart/lib/rank.dart` | `Rank`, `Rank.between`, `Rank.sequence`, `Rebalance` |
| `dart/lib/src/codec.dart` | terms ↔ key |
| `dart/lib/src/arithmetic.dart` | exact rational arithmetic, `simplestBetween` |
| `js/rank.js` | the same library, plain ESM, no build step |
| `dart/test/`, `js/rank.test.js` | 16 tests each, same properties |
| `*/crosscheck.*` | proves the two produce byte-identical keys |
| `dart/example/measure.dart` | the cost tables above |
| `dart/example/compare.dart` | against the alternatives |
| `dart/example/codec_study.dart` | why a wider alphabet does not help |
| `dart/example/fractional_indexing.dart` | the base-62 opponent (CC0 port) |
| `sql/schema.sql` | table, queries, pagination, concurrency, rebalance |
| `sql/verify.sql` | 7 checks against a live PostgreSQL |

## Prior art

[**pg_rational**](https://github.com/begriffs/pg_rational) is the closest thing
to this, and [User-Defined Order in
SQL](https://begriffs.com/posts/2018-03-20-user-defined-order.html) reaches the
same conclusion from the same starting point: floats collapse, integer positions
force shifting, rationals via the Stern–Brocot tree are the sound choice. It also
names the same weakness this hit — "pathological insertion patterns, particularly
alternating left-right traversals, increase denominators via Fibonacci sequences".

Two things here go beyond it. pg_rational stores the *fraction* in 64 bits, so it
has a hard ceiling around the 46th Fibonacci number; storing the *terms* removes
that class of failure rather than widening it. And that article says rebalancing
"may eventually become necessary" — pg_rational doesn't implement it, this does.

The dominant approach in practice is string fractional indexing
([fractional-indexing](https://github.com/rocicorp/fractional-indexing),
LexoRank, Figma's ordering keys), which the comparison above measures against
directly. For most workloads it is the better choice, and this README says so.

## Credits

`dart/example/fractional_indexing.dart` is a port of
[rocicorp/fractional-indexing](https://github.com/rocicorp/fractional-indexing)
(CC0), itself based on David Greenspan's
[Implementing Fractional Indexing](https://observablehq.com/@dgreensp/implementing-fractional-indexing).
It is included only as the opponent in the benchmark.
