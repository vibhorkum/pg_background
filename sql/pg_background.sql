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
-- v1.9: Worker labels
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_label;
CREATE TABLE t_label(id int);

-- Launch worker with label
SELECT (h).pid AS lbl_pid, (h).cookie AS lbl_cookie
FROM (SELECT pg_background_launch_v2('INSERT INTO t_label VALUES (1)', 0, 'test-label') AS h) s
\gset

SELECT pg_sleep(0.3);

-- Verify worker with label completed successfully
SELECT
  completed AS label_worker_completed,
  has_error AS label_worker_has_error
FROM pg_background_result_info_v2(:lbl_pid, :lbl_cookie);

-- Verify label is exposed through list_v2
SELECT label AS visible_label
FROM pg_background_list_v2()
  AS (pid int4, cookie int8, launched_at timestamptz, user_id oid,
      queue_size int4, state text, sql_preview text, last_error text,
      consumed bool, label text)
WHERE pid = :lbl_pid AND cookie = :lbl_cookie;

-- Cleanup
SELECT pg_background_detach_v2(:lbl_pid, :lbl_cookie);

SELECT count(*) AS label_insert_count FROM t_label;

-- -------------------------------------------------------------------------
-- v1.9: Submit with label
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_submit_label;
CREATE TABLE t_submit_label(id int);

SELECT (h).pid AS slbl_pid, (h).cookie AS slbl_cookie
FROM (SELECT pg_background_submit_v2('INSERT INTO t_submit_label VALUES (1)', 0, 'submit-label') AS h) s
\gset

SELECT pg_sleep(0.3);
SELECT count(*) AS submit_label_count FROM t_submit_label;

-- Cleanup: explicitly detach to avoid affecting later batch tests
SELECT pg_background_detach_v2(:slbl_pid, :slbl_cookie);

-- -------------------------------------------------------------------------
-- v1.9: Result info without consuming results
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_result_info;
CREATE TABLE t_result_info(id int);

SELECT (h).pid AS ri_pid, (h).cookie AS ri_cookie
FROM (SELECT pg_background_launch_v2('INSERT INTO t_result_info SELECT generate_series(1,5)') AS h) s
\gset

SELECT pg_sleep(0.3);

-- Check result info (should show completed)
SELECT
  completed AS ri_completed,
  has_error AS ri_has_error
FROM pg_background_result_info_v2(:ri_pid, :ri_cookie);

SELECT pg_background_detach_v2(:ri_pid, :ri_cookie);

SELECT count(*) AS result_info_count FROM t_result_info;

-- -------------------------------------------------------------------------
-- v1.9: Structured error info
-- -------------------------------------------------------------------------

-- Launch worker that will fail
SELECT (h).pid AS err_pid, (h).cookie AS err_cookie
FROM (SELECT pg_background_launch_v2('SELECT 1/0') AS h) s
\gset

SELECT pg_sleep(0.3);

-- Check result info shows error
SELECT
  completed AS err_completed,
  has_error AS err_has_error
FROM pg_background_result_info_v2(:err_pid, :err_cookie);

-- Get structured error (should have sqlstate for division by zero)
SELECT
  CASE WHEN sqlstate IS NOT NULL THEN 'has_sqlstate' ELSE 'no_sqlstate' END AS error_sqlstate_check,
  CASE WHEN message IS NOT NULL THEN 'has_message' ELSE 'no_message' END AS error_message_check
FROM pg_background_error_info_v2(:err_pid, :err_cookie);

SELECT pg_background_detach_v2(:err_pid, :err_cookie);

-- -------------------------------------------------------------------------
-- v1.9: Batch detach
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_batch;
CREATE TABLE t_batch(id int);

-- Launch multiple workers
SELECT (h).pid AS b1_pid, (h).cookie AS b1_cookie
FROM (SELECT pg_background_submit_v2('INSERT INTO t_batch VALUES (1)', 0, 'batch-1') AS h) s
\gset

SELECT (h).pid AS b2_pid, (h).cookie AS b2_cookie
FROM (SELECT pg_background_submit_v2('INSERT INTO t_batch VALUES (2)', 0, 'batch-2') AS h) s
\gset

SELECT pg_sleep(0.3);

-- Detach all at once
SELECT pg_background_detach_all_v2() AS batch_detach_count;

SELECT count(*) AS batch_insert_count FROM t_batch;

-- -------------------------------------------------------------------------
-- v1.9: Batch cancel
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_batch_cancel;
CREATE TABLE t_batch_cancel(id int);

-- Launch multiple long-running workers
SELECT (h).pid AS bc1_pid, (h).cookie AS bc1_cookie
FROM (SELECT pg_background_launch_v2('SELECT pg_sleep(10); INSERT INTO t_batch_cancel VALUES (1)') AS h) s
\gset

SELECT (h).pid AS bc2_pid, (h).cookie AS bc2_cookie
FROM (SELECT pg_background_launch_v2('SELECT pg_sleep(10); INSERT INTO t_batch_cancel VALUES (2)') AS h) s
\gset

SELECT pg_sleep(0.2);

-- Cancel all at once
SELECT pg_background_cancel_all_v2() AS batch_cancel_count;

SELECT pg_sleep(0.5);

-- Detach remaining
SELECT pg_background_detach_all_v2() AS batch_cancel_detach_count;

-- Inserts should not have happened
SELECT count(*) AS batch_cancel_insert_count FROM t_batch_cancel;

-- -------------------------------------------------------------------------
-- Error Path: Cookie mismatch detection
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_cookie_mismatch;
CREATE TABLE t_cookie_mismatch(id int);

-- Store handle in temp table for DO block access
DROP TABLE IF EXISTS _test_cm_handle;
CREATE TEMP TABLE _test_cm_handle AS
SELECT (h).pid, (h).cookie
FROM (SELECT pg_background_launch_v2('INSERT INTO t_cookie_mismatch VALUES (1)') AS h) s;

DO $$
DECLARE v_pid int; v_cookie bigint;
BEGIN
  SELECT pid, cookie INTO v_pid, v_cookie FROM _test_cm_handle;
  PERFORM pg_background_wait_v2(v_pid, v_cookie);
END;
$$;

-- Try operation with wrong cookie (should error)
DO $$
DECLARE v_pid int;
BEGIN
  SELECT pid INTO v_pid FROM _test_cm_handle;
  -- Use deliberately wrong cookie
  PERFORM pg_background_wait_v2(v_pid, 9999999999999999);
  RAISE NOTICE 'cookie_mismatch_test=should_have_failed';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'cookie_mismatch_test=correctly_errored';
END;
$$;

DO $$
DECLARE v_pid int; v_cookie bigint;
BEGIN
  SELECT pid, cookie INTO v_pid, v_cookie FROM _test_cm_handle;
  PERFORM pg_background_detach_v2(v_pid, v_cookie);
END;
$$;
SELECT count(*) AS cookie_mismatch_insert_count FROM t_cookie_mismatch;

-- -------------------------------------------------------------------------
-- Error Path: Result consumption guard (double-consume)
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS _test_rc_handle;
CREATE TEMP TABLE _test_rc_handle AS
SELECT (h).pid, (h).cookie
FROM (SELECT pg_background_launch_v2('SELECT 42 AS answer') AS h) s;

DO $$
DECLARE v_pid int; v_cookie bigint;
BEGIN
  SELECT pid, cookie INTO v_pid, v_cookie FROM _test_rc_handle;
  PERFORM pg_background_wait_v2(v_pid, v_cookie);
END;
$$;

-- First consumption should succeed (use direct query, not DO block)
SELECT answer FROM (
  SELECT * FROM pg_background_result_v2(
    (SELECT pid FROM _test_rc_handle),
    (SELECT cookie FROM _test_rc_handle)
  ) AS (answer int)
) sub;

-- Second consumption should error (worker auto-detached after result consumed)
DO $$
DECLARE v_pid int; v_cookie bigint;
BEGIN
  SELECT pid, cookie INTO v_pid, v_cookie FROM _test_rc_handle;
  PERFORM pg_background_result_v2(v_pid, v_cookie);
  RAISE NOTICE 'result_consumed_test=should_have_failed';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'result_consumed_test=correctly_errored';
END;
$$;
-- No explicit detach needed - worker is auto-detached after result consumption

-- -------------------------------------------------------------------------
-- Error Path: Invalid handle (detached worker)
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS _test_dh_handle;
CREATE TEMP TABLE _test_dh_handle AS
SELECT (h).pid, (h).cookie
FROM (SELECT pg_background_launch_v2('SELECT 1') AS h) s;

SELECT pg_sleep(0.2);

DO $$
DECLARE v_pid int; v_cookie bigint;
BEGIN
  SELECT pid, cookie INTO v_pid, v_cookie FROM _test_dh_handle;
  PERFORM pg_background_detach_v2(v_pid, v_cookie);
END;
$$;

-- Operations on detached handle should error
DO $$
DECLARE v_pid int; v_cookie bigint;
BEGIN
  SELECT pid, cookie INTO v_pid, v_cookie FROM _test_dh_handle;
  PERFORM pg_background_wait_v2(v_pid, v_cookie);
  RAISE NOTICE 'detached_handle_test=should_have_failed';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'detached_handle_test=correctly_errored';
END;
$$;

-- -------------------------------------------------------------------------
-- Privilege Model: pgbackground_role exists
-- -------------------------------------------------------------------------

SELECT
  CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbackground_role')
       THEN 'PASS' ELSE 'FAIL' END AS pgbackground_role_exists;

-- -------------------------------------------------------------------------
-- Privilege Model: PUBLIC has no direct access
-- -------------------------------------------------------------------------

SELECT
  CASE WHEN NOT has_function_privilege('public', 'pg_background_launch_v2(text, int4, text)', 'EXECUTE')
       THEN 'PASS' ELSE 'FAIL' END AS public_no_launch_access;

SELECT
  CASE WHEN NOT has_function_privilege('public', 'pg_background_result_v2(int4, int8)', 'EXECUTE')
       THEN 'PASS' ELSE 'FAIL' END AS public_no_result_access;

-- -------------------------------------------------------------------------
-- Privilege Model: pgbackground_role has access
-- -------------------------------------------------------------------------

SELECT
  CASE WHEN has_function_privilege('pgbackground_role', 'pg_background_launch_v2(text, int4, text)', 'EXECUTE')
       THEN 'PASS' ELSE 'FAIL' END AS role_has_launch_access;

SELECT
  CASE WHEN has_function_privilege('pgbackground_role', 'pg_background_result_v2(int4, int8)', 'EXECUTE')
       THEN 'PASS' ELSE 'FAIL' END AS role_has_result_access;

-- -------------------------------------------------------------------------
-- Privilege Model: Grant/Revoke helpers work
-- -------------------------------------------------------------------------

DROP ROLE IF EXISTS test_priv_user;
CREATE ROLE test_priv_user NOLOGIN;

-- Should not have access initially
SELECT
  CASE WHEN NOT has_function_privilege('test_priv_user', 'pg_background_launch_v2(text, int4, text)', 'EXECUTE')
       THEN 'PASS' ELSE 'FAIL' END AS user_no_initial_access;

-- Grant privileges
SELECT grant_pg_background_privileges('test_priv_user', false) AS grant_result;

-- Should have access after grant
SELECT
  CASE WHEN has_function_privilege('test_priv_user', 'pg_background_launch_v2(text, int4, text)', 'EXECUTE')
       THEN 'PASS' ELSE 'FAIL' END AS user_has_access_after_grant;

-- Revoke privileges
SELECT revoke_pg_background_privileges('test_priv_user', false) AS revoke_result;

-- Should not have access after revoke
SELECT
  CASE WHEN NOT has_function_privilege('test_priv_user', 'pg_background_launch_v2(text, int4, text)', 'EXECUTE')
       THEN 'PASS' ELSE 'FAIL' END AS user_no_access_after_revoke;

DROP ROLE test_priv_user;

-- -------------------------------------------------------------------------
-- Bounds Validation: cancel_v2_grace grace_ms bounds
-- -------------------------------------------------------------------------

-- Test that very large grace_ms is handled (capped at 1 hour = 3600000ms)
SELECT (h).pid AS bg_pid, (h).cookie AS bg_cookie
FROM (SELECT pg_background_launch_v2('SELECT pg_sleep(10)') AS h) s
\gset

SELECT pg_sleep(0.1);

-- This should work without error (grace_ms capped internally)
SELECT pg_background_cancel_v2_grace(:bg_pid, :bg_cookie, 999999999);
SELECT pg_sleep(0.3);
SELECT pg_background_detach_v2(:bg_pid, :bg_cookie);
SELECT 'PASS' AS grace_bounds_test;

-- -------------------------------------------------------------------------
-- Semantic test: detach allows worker to complete (does NOT cancel)
-- This is already tested by t_detach_v1/t_detach_v2 above, but we add
-- an explicit comment for clarity. The earlier tests verify that after
-- detach, workers still commit their transactions.
-- -------------------------------------------------------------------------
SELECT 'PASS' AS detach_semantic_verified;

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
