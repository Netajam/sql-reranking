-- Ordering rows so that moving one item writes exactly one row.
--
-- PostgreSQL. The ideas port to any database with a byte-ordered text type;
-- only the collation syntax changes.

-- ---------------------------------------------------------------- the table

CREATE TABLE list_item (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    list_id   bigint NOT NULL,
    payload   text   NOT NULL,

    -- The rank. Opaque: only its byte order carries meaning. Digits only, but
    -- pin the collation anyway so a database-wide default can never reinterpret
    -- it -- a locale collation folds characters and would silently reorder the
    -- list.
    rank_key  text   COLLATE "C" NOT NULL,

    -- Two purposes. It makes the order strictly total, so keyset pagination
    -- cannot skip or repeat a row. And it turns the concurrent-insert race into
    -- a clean error: two clients dropping an item into the same gap compute the
    -- same key, and the loser retries against the winner's key instead of
    -- silently tying.
    --
    -- DEFERRABLE because rebalancing rewrites a run of rows whose new keys may
    -- collide with the old keys of other rows in that same run. PostgreSQL
    -- checks a non-deferrable unique constraint per ROW, not per statement, so
    -- without this the rebalance UPDATE below fails with a unique_violation
    -- partway through. Verified both ways in verify.sql.
    --
    -- INITIALLY IMMEDIATE keeps the default behaviour intact: duplicates are
    -- still rejected at once, so the concurrent-insert retry path is unchanged.
    -- Only the rebalance transaction opts into deferral.
    --
    -- The one cost: ON CONFLICT cannot use a deferrable constraint as its
    -- arbiter ("ON CONFLICT does not support deferrable unique constraints").
    -- Upserting by rank is not a sensible operation anyway -- upsert on a
    -- business key, which is a different constraint and unaffected. If you do
    -- need ON CONFLICT here, drop DEFERRABLE and rebalance in two passes
    -- instead: move the run to temporary keys, then to their final values.
    CONSTRAINT list_item_rank_unique
      UNIQUE (list_id, rank_key) DEFERRABLE INITIALLY IMMEDIATE
);

-- No separate index is needed. The unique constraint above is backed by a btree
-- on (list_id, rank_key) in exactly that order, which already serves both the
-- filter and the ordering -- so reads come back pre-sorted with no sort node.
-- Confirmed on PostgreSQL 17: the plan is a plain Index Scan with
-- "Index Cond: (list_id = 1)" and no Sort above it, deferrable or not.

-- ------------------------------------------------------------ reading a list

-- Every read is this. The rank column is never interpreted, only ordered.
SELECT id, payload, rank_key
  FROM list_item
 WHERE list_id = $1
 ORDER BY rank_key
 LIMIT $2;

-- The next page. Keyset rather than OFFSET, and exact because (list_id,
-- rank_key) is unique: there are no ties for the cursor to straddle.
SELECT id, payload, rank_key
  FROM list_item
 WHERE list_id = $1
   AND rank_key > $2      -- rank_key of the last row of the previous page
 ORDER BY rank_key
 LIMIT $3;

-- ------------------------------------------------------- moving and inserting

-- The whole point. Compute the new key in the application from the keys of the
-- two rows it will sit between -- Rank.between(lower, upper) -- then:
UPDATE list_item
   SET rank_key = $1
 WHERE id = $2;
-- One row. Neighbours are untouched, whatever the length of the list.

-- Inserting is the same computation with an INSERT. Pass NULL for an open end:
-- appending is Rank.between(last, null), prepending Rank.between(null, first).
INSERT INTO list_item (list_id, payload, rank_key)
VALUES ($1, $2, $3);

-- If the neighbours are not already loaded, fetch just those two rows:
SELECT rank_key
  FROM list_item
 WHERE list_id = $1 AND rank_key < $2
 ORDER BY rank_key DESC
 LIMIT 1;                 -- the row immediately above the target position

-- ------------------------------------------------------------ rebalancing

-- Never needed for correctness: ordering stays exact at any key length. This is
-- housekeeping for when keys have grown long, which takes a deliberately
-- adversarial reordering pattern -- ordinary use settles around 10-20
-- characters and stays there.
--
-- Rebalance.plan() returns the affected rows and their new keys. Apply them in
-- one statement, inside a transaction, with the constraint deferred:
BEGIN;
SET CONSTRAINTS list_item_rank_unique DEFERRED;
UPDATE list_item AS t
   SET rank_key = v.rank_key
  FROM (VALUES
          ($1::bigint, $2::text),
          ($3::bigint, $4::text)
          -- ... one row per entry in the plan
       ) AS v(id, rank_key)
 WHERE t.id = v.id;
COMMIT;   -- the constraint is checked here, once, against the final state

-- The SET CONSTRAINTS line is not optional. New keys routinely collide with the
-- old keys of other rows in the same run, and PostgreSQL checks a
-- non-deferrable unique constraint per row -- the UPDATE fails partway through
-- without it. Deferring moves the check to COMMIT, where only the final state
-- matters.
--
-- The plan only ever rewrites a contiguous run, and every key outside it keeps
-- its value, so the statement is safe to apply on its own.

-- --------------------------------------------------------------- housekeeping

-- Worth watching. If the maximum climbs steadily rather than hovering, some
-- workload is repeatedly subdividing one region, and a rebalance is due.
SELECT list_id,
       count(*)                    AS items,
       max(length(rank_key))       AS longest_key,
       round(avg(length(rank_key)), 1) AS mean_key
  FROM list_item
 GROUP BY list_id
 ORDER BY longest_key DESC
 LIMIT 20;
