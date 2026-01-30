CREATE EXTENSION pg_background;

DROP TABLE IF EXISTS t;
CREATE TABLE t(id integer);

-- ----------------------------------------------------------------------
-- v1: basic launch + result (existing test, but more explicit/robust)
-- ----------------------------------------------------------------------

SELECT pg_background_launch('INSERT INTO t SELECT 1') AS pid \gset
SELECT * FROM pg_background_result(:pid) AS (result TEXT);

SELECT * FROM t ORDER BY id;

-- ----------------------------------------------------------------------
-- v1: detach should not crash the session
-- (we don't assert anything except that the test continues)
-- ----------------------------------------------------------------------

SELECT pg_background_launch('SELECT 1') AS pid \gset
SELECT pg_background_detach(:pid);

-- ----------------------------------------------------------------------
-- v2: launch + detach, worker should still commit its work
-- ----------------------------------------------------------------------

SELECT (h).pid AS v2_pid, (h).cookie AS v2_cookie
FROM (SELECT pg_background_launch_v2('INSERT INTO t SELECT 2', 65536) AS h) s
\gset

SELECT pg_sleep(0.2);
SELECT pg_background_detach_v2(:v2_pid, :v2_cookie);

-- give worker a moment to finish and commit
SELECT pg_sleep(0.5);

SELECT * FROM t ORDER BY id;

-- ----------------------------------------------------------------------
-- v2: cancel should prevent later statements from committing
-- We run: sleep then insert, cancel during sleep, verify 99 not inserted.
-- ----------------------------------------------------------------------

SELECT (h).pid AS c_pid, (h).cookie AS c_cookie
FROM (SELECT pg_background_launch_v2('SELECT pg_sleep(10); INSERT INTO t SELECT 99', 65536) AS h) s
\gset

SELECT pg_sleep(0.2);
SELECT pg_background_cancel_v2(:c_pid, :c_cookie);

-- allow time for termination/cleanup
SELECT pg_sleep(0.5);

SELECT count(*) AS canceled_insert_count
FROM t
WHERE id = 99;

-- -------------------------------------------------------------------------
-- v1 + v2 detach is fire-and-forget (no cancel): inserts should happen
-- -------------------------------------------------------------------------

CREATE TABLE t_detach_v1(id int);
SELECT pg_background_detach(
  pg_background_launch('INSERT INTO t_detach_v1 SELECT 1', 65536)
);
SELECT pg_sleep(0.2);
SELECT count(*) FROM t_detach_v1;

CREATE TABLE t_detach_v2(id int);
DO $$
DECLARE h public.pg_background_handle;
BEGIN
  SELECT * INTO h FROM pg_background_launch_v2('INSERT INTO t_detach_v2 SELECT 1', 65536);
  PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;
SELECT pg_sleep(0.2);
SELECT count(*) FROM t_detach_v2;

-- -------------------------------------------------------------------------
-- wait_v2 + status_v2
-- -------------------------------------------------------------------------

CREATE TABLE t_wait(id int);

DO $$
DECLARE h public.pg_background_handle;
DECLARE s public.pg_background_status;
DECLARE ok bool;
BEGIN
  SELECT * INTO h FROM pg_background_launch_v2('SELECT pg_sleep(2); INSERT INTO t_wait VALUES (1)', 65536);

  -- Should be running immediately
  s := pg_background_status_v2(h.pid, h.cookie);
  RAISE NOTICE 'status1=%', s.state;

  -- Short wait should time out
  ok := pg_background_wait_v2(h.pid, h.cookie, 200);
  RAISE NOTICE 'wait_short=%', ok;

  -- Long wait should succeed
  ok := pg_background_wait_v2(h.pid, h.cookie, 5000);
  RAISE NOTICE 'wait_long=%', ok;

  s := pg_background_status_v2(h.pid, h.cookie);
  RAISE NOTICE 'status2=%', s.state;

  -- cleanup handle by consuming (optional) or detach
  PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;

SELECT count(*) FROM t_wait;

-- -------------------------------------------------------------------------
-- cancel_v2: should prevent the INSERT (explicit cancel semantics)
-- -------------------------------------------------------------------------

CREATE TABLE t_cancel(id int);

DO $$
DECLARE h public.pg_background_handle;
BEGIN
  SELECT * INTO h FROM pg_background_launch_v2('SELECT pg_sleep(5); INSERT INTO t_cancel VALUES (1)', 65536);

  -- Explicit cancel; detach is not cancel.
  PERFORM pg_background_cancel_v2(h.pid, h.cookie, 500);

  -- Give server time to process cancel/terminate
  PERFORM pg_sleep(0.5);

  -- Detach handle bookkeeping
  PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;

SELECT count(*) FROM t_cancel;
