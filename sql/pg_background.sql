CREATE EXTENSION pg_background;

DROP TABLE IF EXISTS t;
CREATE TABLE t(id integer);

-- ----------------------------------------------------------------------
-- v1: basic launch + result
-- ----------------------------------------------------------------------

SELECT pg_background_launch('INSERT INTO t SELECT 1') AS pid \gset
SELECT * FROM pg_background_result(:pid) AS (result TEXT);

SELECT * FROM t ORDER BY id;

-- ----------------------------------------------------------------------
-- v1: detach should not crash the session
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

DROP TABLE IF EXISTS t_detach_v1;
CREATE TABLE t_detach_v1(id int);

SELECT pg_background_detach(
  pg_background_launch('INSERT INTO t_detach_v1 SELECT 1', 65536)
);

SELECT pg_sleep(0.2);
SELECT count(*) FROM t_detach_v1;

DROP TABLE IF EXISTS t_detach_v2;
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
-- wait_v2 (1.6 API): timeout + then success
--   - pg_background_wait_v2_timeout(pid,cookie,timeout_ms) -> bool
--   - pg_background_wait_v2(pid,cookie) -> void (blocking)
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_wait;
CREATE TABLE t_wait(id int);

DO $$
DECLARE h public.pg_background_handle;
DECLARE ok bool;
BEGIN
  SELECT * INTO h
  FROM pg_background_launch_v2('SELECT pg_sleep(2); INSERT INTO t_wait VALUES (1)', 65536);

  -- Short wait should time out (false)
  ok := pg_background_wait_v2_timeout(h.pid, h.cookie, 200);
  RAISE NOTICE 'wait_short=%', ok;

  -- Long wait should succeed (true)
  ok := pg_background_wait_v2_timeout(h.pid, h.cookie, 5000);
  RAISE NOTICE 'wait_long=%', ok;

  -- cleanup bookkeeping (worker is already finished, but we detach handle)
  PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;

SELECT count(*) FROM t_wait;

-- -------------------------------------------------------------------------
-- cancel_v2 (1.6 API): should prevent the INSERT
--   - pg_background_cancel_v2_grace(pid,cookie,grace_ms) is available too
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_cancel;
CREATE TABLE t_cancel(id int);

DO $$
DECLARE h public.pg_background_handle;
BEGIN
  SELECT * INTO h
  FROM pg_background_launch_v2('SELECT pg_sleep(5); INSERT INTO t_cancel VALUES (1)', 65536);

  -- Explicit cancel; detach is not cancel.
  PERFORM pg_background_cancel_v2_grace(h.pid, h.cookie, 500);

  -- Give server time to process cancel/terminate
  PERFORM pg_sleep(0.5);

  -- Detach handle bookkeeping
  PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;

SELECT count(*) FROM t_cancel;


-- -------------------------------------------------------------------------
-- v2: list_v2 should show running job, then disappear after cleanup
-- -------------------------------------------------------------------------

-- create a long-running job so list_v2 can observe it
SELECT (h).pid AS l_pid, (h).cookie AS l_cookie
FROM (SELECT pg_background_launch_v2('SELECT pg_sleep(2)', 65536) AS h) s
\gset

-- give it a moment to enter running state
SELECT pg_sleep(0.1);

-- list should include our pid/cookie (at least once)
SELECT COUNT(*) AS  list_contains_launched_job
FROM pg_background_list_v2()
  AS (pid int4, cookie int8, launched_at timestamptz, user_id oid,
      queue_size int4, state text, sql_preview text, last_error text, consumed bool)
WHERE pid = :l_pid
  AND cookie = :l_cookie
  AND queue_size = 65536
  AND user_id IS NOT NULL
  AND launched_at IS NOT NULL
  AND state IN ('starting', 'running', 'stopped', 'canceled');

-- cleanup explicitly (even if it already stopped)
SELECT pg_background_cancel_v2(:l_pid, :l_cookie);
SELECT pg_background_detach_v2(:l_pid, :l_cookie);

-- should be gone from list after detach
SELECT COUNT(*) AS list_contains_after_detach
FROM pg_background_list_v2()
  AS (pid int4, cookie int8, launched_at timestamptz, user_id oid,
      queue_size int4, state text, sql_preview text, last_error text, consumed bool)
WHERE pid = :l_pid
  AND cookie = :l_cookie;

-- -------------------------------------------------------------------------
-- v2: submit_v2 is fire-and-forget and should commit
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_submit;
CREATE TABLE t_submit(id int);

SELECT (h).pid AS s_pid, (h).cookie AS s_cookie
FROM (SELECT pg_background_submit_v2('INSERT INTO t_submit VALUES (1)', 65536) AS h) s
\gset

-- submit may detach internally; still allow time to commit
SELECT pg_sleep(0.2);

SELECT count(*) AS submit_count FROM t_submit;

-- -------------------------------------------------------------------------
-- v2: wait_v2_timeout times out, then succeeds; wait_v2 blocks to completion
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_wait2;
CREATE TABLE t_wait2(id int);

SELECT (h).pid AS w_pid, (h).cookie AS w_cookie
FROM (SELECT pg_background_launch_v2('SELECT pg_sleep(1); INSERT INTO t_wait2 VALUES (1)', 65536) AS h) s
\gset

-- should time out quickly
SELECT pg_background_wait_v2_timeout(:w_pid, :w_cookie, 50) AS wait_short;

-- should succeed with longer timeout
SELECT pg_background_wait_v2_timeout(:w_pid, :w_cookie, 5000) AS wait_long;

-- wait_v2 should now return immediately (already done), but it must work
SELECT pg_background_wait_v2(:w_pid, :w_cookie);

-- detach bookkeeping
SELECT pg_background_detach_v2(:w_pid, :w_cookie);

SELECT count(*) AS wait2_count FROM t_wait2;

-- -------------------------------------------------------------------------
-- v2: cancel_v2_grace should prevent later statements from committing
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_cancel2;
CREATE TABLE t_cancel2(id int);

SELECT (h).pid AS cx_pid, (h).cookie AS cx_cookie
FROM (SELECT pg_background_launch_v2('SELECT pg_sleep(10); INSERT INTO t_cancel2 VALUES (1)', 65536) AS h) s
\gset

SELECT pg_sleep(0.2);
SELECT pg_background_cancel_v2_grace(:cx_pid, :cx_cookie, 500);

-- allow termination
SELECT pg_sleep(0.5);

-- detach handle bookkeeping
SELECT pg_background_detach_v2(:cx_pid, :cx_cookie);

SELECT count(*) AS cancel2_count FROM t_cancel2;

-- -------------------------------------------------------------------------
-- ops: detach all stopped workers returned by list
-- -------------------------------------------------------------------------

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT *
    FROM pg_background_list_v2()
      AS (pid int4, cookie int8, launched_at timestamptz, user_id oid,
          queue_size int4, state text, sql_preview text, last_error text, consumed bool)
    WHERE state IN ('stopped',  'canceled')
  LOOP
    PERFORM pg_background_detach_v2(r.pid, r.cookie);
  END LOOP;
END $$;

SELECT *
FROM pg_background_list_v2()
  AS (pid int4, cookie int8, launched_at timestamptz, user_id oid,
      queue_size int4, state text, sql_preview text, last_error text, consumed bool);

-- -------------------------------------------------------------------------
-- v1.8: GUC settings
-- -------------------------------------------------------------------------

-- Show default GUC values
SHOW pg_background.max_workers;
SHOW pg_background.default_queue_size;
SHOW pg_background.worker_timeout;

-- Test max_workers limit
SET pg_background.max_workers = 2;
SHOW pg_background.max_workers;

-- Reset to default
RESET pg_background.max_workers;

-- -------------------------------------------------------------------------
-- v1.8: stats_v2 - session statistics
-- -------------------------------------------------------------------------

-- Stats should show some activity from previous tests
SELECT
  workers_launched > 0 AS has_launched,
  workers_completed >= 0 AS has_completed_field,
  workers_failed >= 0 AS has_failed_field,
  workers_canceled >= 0 AS has_canceled_field,
  workers_active >= 0 AS has_active_field,
  avg_execution_ms >= 0 AS has_avg_time,
  max_workers > 0 AS has_max_workers
FROM pg_background_stats_v2();

-- -------------------------------------------------------------------------
-- v1.8: progress reporting
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_progress;
CREATE TABLE t_progress(id int);

-- Launch worker that reports progress
SELECT (h).pid AS p_pid, (h).cookie AS p_cookie
FROM (SELECT pg_background_launch_v2($$
  SELECT pg_background_progress(0, 'Starting');
  SELECT pg_sleep(0.1);
  SELECT pg_background_progress(50, 'Halfway');
  SELECT pg_sleep(0.1);
  SELECT pg_background_progress(100, 'Done');
  INSERT INTO t_progress VALUES (1);
$$, 65536) AS h) s
\gset

-- Give worker time to start and report progress
SELECT pg_sleep(0.15);

-- Check progress (should be >= 0 if reported)
SELECT
  CASE WHEN progress_pct >= 0 THEN 'progress_reported' ELSE 'no_progress' END AS progress_status
FROM pg_background_get_progress_v2(:p_pid, :p_cookie);

-- Wait for completion
SELECT pg_background_wait_v2_timeout(:p_pid, :p_cookie, 5000) AS progress_worker_done;

-- Verify work was done
SELECT count(*) AS progress_insert_count FROM t_progress;

-- Cleanup
SELECT pg_background_detach_v2(:p_pid, :p_cookie);

-- -------------------------------------------------------------------------
-- v1.8: max_workers enforcement
-- -------------------------------------------------------------------------

-- Set very low limit
SET pg_background.max_workers = 1;

-- Launch one worker (should succeed)
SELECT (h).pid AS mw_pid, (h).cookie AS mw_cookie
FROM (SELECT pg_background_launch_v2('SELECT pg_sleep(2)', 65536) AS h) s
\gset

SELECT pg_sleep(0.1);

-- Try to launch another (should fail due to limit)
DO $$
BEGIN
  PERFORM pg_background_launch_v2('SELECT 1', 65536);
  RAISE NOTICE 'max_workers_test=should_have_failed';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'max_workers_test=correctly_limited';
END;
$$;

-- Cancel and cleanup the first worker
SELECT pg_background_cancel_v2(:mw_pid, :mw_cookie);
SELECT pg_sleep(0.2);
SELECT pg_background_detach_v2(:mw_pid, :mw_cookie);

-- Reset limit
RESET pg_background.max_workers;

-- -------------------------------------------------------------------------
-- v1.8: worker_timeout GUC
-- -------------------------------------------------------------------------

-- Test that worker_timeout can be set
SET pg_background.worker_timeout = '1s';
SHOW pg_background.worker_timeout;
RESET pg_background.worker_timeout;

-- -------------------------------------------------------------------------
-- Final stats check
-- -------------------------------------------------------------------------

SELECT
  workers_launched AS total_launched,
  workers_completed AS total_completed,
  workers_failed AS total_failed,
  workers_canceled AS total_canceled,
  workers_active AS currently_active
FROM pg_background_stats_v2();
