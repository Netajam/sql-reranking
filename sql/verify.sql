-- Checks every claim schema.sql makes, against a real server.
--
--   psql -f sql/verify.sql
--
-- Each check prints PASS or FAIL. Nothing here uses the application library:
-- keys are supplied literally, so this exercises the schema on its own.

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TABLE list_item (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    list_id   bigint NOT NULL,
    payload   text   NOT NULL,
    rank_key  text   COLLATE "C" NOT NULL,
    CONSTRAINT list_item_rank_unique
      UNIQUE (list_id, rank_key) DEFERRABLE INITIALLY IMMEDIATE
);

-- Two lists, so the filter has something to do.
INSERT INTO list_item (list_id, payload, rank_key)
SELECT 1, 'item ' || i, lpad(i::text, 6, '0') FROM generate_series(1, 20000) i;
INSERT INTO list_item (list_id, payload, rank_key)
SELECT 2, 'other ' || i, lpad(i::text, 6, '0') FROM generate_series(1, 20000) i;
ANALYZE list_item;

-- 1 -------------------------------------------------------------------------
-- The unique constraint's index serves the ordering query by itself: no extra
-- index needed, and no Sort node in the plan.
DO $$
DECLARE plan text;
BEGIN
  -- FORMAT JSON returns the whole plan as a single value; FORMAT TEXT returns
  -- one row per line and INTO would capture only the first.
  EXECUTE 'EXPLAIN (COSTS OFF, FORMAT JSON)
           SELECT id, payload, rank_key FROM list_item
            WHERE list_id = 1 ORDER BY rank_key LIMIT 50'
    INTO plan;
  IF plan LIKE '%Sort%' THEN
    RAISE NOTICE 'FAIL 1  a Sort node is present: %', plan;
  ELSIF plan LIKE '%list_item_rank_unique%' THEN
    RAISE NOTICE 'PASS 1  ordered straight off the unique index, no sort';
  ELSE
    RAISE NOTICE 'FAIL 1  unexpected plan: %', plan;
  END IF;
END $$;

-- 2 -------------------------------------------------------------------------
-- Keyset pagination visits every row exactly once. Only sound because
-- (list_id, rank_key) is unique — with ties a cursor can skip or repeat.
DO $$
DECLARE cursor_key text := NULL; page bigint[]; seen bigint[] := '{}'; n int := 0;
BEGIN
  LOOP
    SELECT array_agg(id ORDER BY rank_key) INTO page FROM (
      SELECT id, rank_key FROM list_item
       WHERE list_id = 1 AND (cursor_key IS NULL OR rank_key > cursor_key)
       ORDER BY rank_key LIMIT 500
    ) p;
    EXIT WHEN page IS NULL;
    seen := seen || page;
    SELECT max(rank_key) INTO cursor_key FROM list_item WHERE id = ANY(page);
    n := n + 1;
    EXIT WHEN n > 100;
  END LOOP;

  IF array_length(seen, 1) = 20000
     AND (SELECT count(DISTINCT e) FROM unnest(seen) e) = 20000 THEN
    RAISE NOTICE 'PASS 2  keyset pagination: 20000 rows, no skips, no repeats';
  ELSE
    RAISE NOTICE 'FAIL 2  saw % rows, % distinct',
      array_length(seen, 1), (SELECT count(DISTINCT e) FROM unnest(seen) e);
  END IF;
END $$;

-- 3 -------------------------------------------------------------------------
-- Two clients dropping an item into the same gap compute the same key. The
-- constraint must turn that into an error the loser can retry, not a silent tie.
DO $$
BEGIN
  BEGIN
    INSERT INTO list_item (list_id, payload, rank_key) VALUES (1, 'dup', '000001');
    RAISE NOTICE 'FAIL 3  duplicate key was accepted';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS 3  duplicate key rejected, retry path is real';
  END;
END $$;

-- 4 -------------------------------------------------------------------------
-- The column really carries C collation, so a database-wide locale default
-- cannot reinterpret key order.
DO $$
DECLARE coll text;
BEGIN
  SELECT collation_name INTO coll FROM information_schema.columns
   WHERE table_name = 'list_item' AND column_name = 'rank_key';
  IF coll = 'C' THEN
    RAISE NOTICE 'PASS 4  rank_key collation is C';
  ELSE
    RAISE NOTICE 'FAIL 4  rank_key collation is %', coalesce(coll, '(default)');
  END IF;
END $$;

-- 5 -------------------------------------------------------------------------
-- The rebalance statement, with the constraint deferred. New keys routinely
-- collide with the old keys of other rows in the same run.
DO $$
BEGIN
  SET CONSTRAINTS list_item_rank_unique DEFERRED;
  UPDATE list_item AS t SET rank_key = v.rank_key
    FROM (VALUES (1::bigint, '000002'), (2::bigint, '000001')) AS v(id, rank_key)
   WHERE t.id = v.id;
  RAISE NOTICE 'PASS 5  deferred: keys crossed inside one UPDATE';
EXCEPTION WHEN unique_violation THEN
  RAISE NOTICE 'FAIL 5  violated even when deferred';
END $$;

ROLLBACK;

-- 6 -------------------------------------------------------------------------
-- Why DEFERRABLE is in the schema at all: without it the same UPDATE fails.
-- PostgreSQL checks a non-deferrable unique constraint per row, not per
-- statement, so the rebalance breaks partway through.
BEGIN;

CREATE TABLE strict_item (
    id        bigint PRIMARY KEY,
    list_id   bigint NOT NULL,
    rank_key  text   COLLATE "C" NOT NULL,
    CONSTRAINT strict_item_rank_unique UNIQUE (list_id, rank_key)
);
INSERT INTO strict_item VALUES (1, 1, '000001'), (2, 1, '000002');

DO $$
BEGIN
  UPDATE strict_item AS t SET rank_key = v.rank_key
    FROM (VALUES (1::bigint, '000002'), (2::bigint, '000001')) AS v(id, rank_key)
   WHERE t.id = v.id;
  RAISE NOTICE 'FAIL 6  expected a non-deferrable constraint to reject this';
EXCEPTION WHEN unique_violation THEN
  RAISE NOTICE 'PASS 6  non-deferrable rejects it, as documented';
END $$;

ROLLBACK;

-- 7 -------------------------------------------------------------------------
-- The cost of DEFERRABLE, pinned so it does not surprise anyone later.
BEGIN;
CREATE TABLE conflict_item (
    id        bigint PRIMARY KEY,
    list_id   bigint NOT NULL,
    rank_key  text   COLLATE "C" NOT NULL,
    CONSTRAINT conflict_item_rank_unique
      UNIQUE (list_id, rank_key) DEFERRABLE INITIALLY IMMEDIATE
);
INSERT INTO conflict_item VALUES (1, 1, '000001');

DO $$
BEGIN
  INSERT INTO conflict_item VALUES (2, 1, '000001')
    ON CONFLICT (list_id, rank_key) DO NOTHING;
  RAISE NOTICE 'FAIL 7  expected ON CONFLICT to refuse a deferrable arbiter';
EXCEPTION WHEN others THEN
  RAISE NOTICE 'PASS 7  ON CONFLICT cannot arbitrate on it: %', SQLERRM;
END $$;
ROLLBACK;
