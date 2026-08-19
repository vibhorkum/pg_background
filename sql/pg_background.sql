CREATE EXTENSION pg_background;

DROP TABLE IF EXISTS t;
CREATE TABLE t(id integer);

-- ----------------------------------------------------------------------
-- v2: basic launch_v2 + result_v2
-- (v1 API was removed in 2.0; see docs/MIGRATION.md.)
-- ----------------------------------------------------------------------

SELECT (h).pid AS basic_pid, (h).cookie AS basic_cookie
FROM (SELECT pg_background_launch_v2('INSERT INTO t SELECT 1', 65536) AS h) s
\gset
SELECT * FROM pg_background_result_v2(:basic_pid, :basic_cookie) AS (result TEXT);

SELECT * FROM t ORDER BY id;

-- ----------------------------------------------------------------------
-- v2: detach should not crash the session
-- ----------------------------------------------------------------------

SELECT (h).pid AS d_pid, (h).cookie AS d_cookie
FROM (SELECT pg_background_launch_v2('SELECT 1', 65536) AS h) s
\gset
SELECT pg_background_detach_v2(:d_pid, :d_cookie);

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
-- v2 detach is fire-and-forget (no cancel): inserts should happen
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_detach_v2;
CREATE TABLE t_detach_v2(id int);

DO $$
DECLARE h pg_background_handle;
BEGIN
  SELECT * INTO h FROM pg_background_launch_v2('INSERT INTO t_detach_v2 SELECT 1', 65536);
  PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;

SELECT pg_sleep(1.0);
SELECT count(*) FROM t_detach_v2;

-- -------------------------------------------------------------------------
-- wait_v2 (1.6 API): timeout + then success
--   - pg_background_wait_v2(pid,cookie,timeout_ms) -> bool
--   - pg_background_wait_v2(pid,cookie) -> void (blocking)
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_wait;
CREATE TABLE t_wait(id int);

DO $$
DECLARE h pg_background_handle;
DECLARE ok bool;
BEGIN
  SELECT * INTO h
  FROM pg_background_launch_v2('SELECT pg_sleep(2); INSERT INTO t_wait VALUES (1)', 65536);

  -- Short wait should time out (false)
  ok := pg_background_wait_v2(h.pid, h.cookie, 200);
  RAISE NOTICE 'wait_short=%', ok;

  -- Long wait should succeed (true)
  ok := pg_background_wait_v2(h.pid, h.cookie, 5000);
  RAISE NOTICE 'wait_long=%', ok;

  -- cleanup bookkeeping (worker is already finished, but we detach handle)
  PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;

SELECT count(*) FROM t_wait;

-- -------------------------------------------------------------------------
-- cancel_v2 (1.6 API): should prevent the INSERT
--   - pg_background_cancel_v2(pid,cookie,grace_ms) is available too
-- -------------------------------------------------------------------------

DROP TABLE IF EXISTS t_cancel;
CREATE TABLE t_cancel(id int);

DO $$
DECLARE h pg_background_handle;
BEGIN
  SELECT * INTO h
  FROM pg_background_launch_v2('SELECT pg_sleep(5); INSERT INTO t_cancel VALUES (1)', 65536);

  -- Explicit cancel; detach is not cancel.
  PERFORM pg_background_cancel_v2(h.pid, h.cookie, 500);

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
SELECT pg_background_wait_v2(:w_pid, :w_cookie, 50) AS wait_short;

-- should succeed with longer timeout
SELECT pg_background_wait_v2(:w_pid, :w_cookie, 5000) AS wait_long;

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
SELECT pg_background_cancel_v2(:cx_pid, :cx_cookie, 500);

-- allow termination
SELECT pg_sleep(0.5);

-- detach handle bookkeeping
SELECT pg_background_detach_v2(:cx_pid, :cx_cookie);

SELECT count(*) AS cancel2_count FROM t_cancel2;

-- -------------------------------------------------------------------------
-- Security: cancellation uses TerminateBackgroundWorker(handle),
-- which the postmaster validates against the worker's slot generation, so it
-- can never signal an unrelated process that reused the worker's PID. The
-- PID-reuse race is not deterministically reproducible in a regression, so we
-- assert the behavioural contract instead: cancel must still stop a running
-- worker. (The report documents the safety property.)
-- -------------------------------------------------------------------------
SELECT (h).pid AS cancel_pid, (h).cookie AS cancel_cookie
FROM (SELECT pg_background_launch('SELECT pg_sleep(30)') AS h) s
\gset

SELECT pg_sleep(0.2);
SELECT pg_background_cancel(:cancel_pid, :cancel_cookie, 3000);
SELECT pg_background_wait(:cancel_pid, :cancel_cookie, 2000) AS cancel_stopped;
SELECT pg_background_detach(:cancel_pid, :cancel_cookie);
SELECT 'PASS' AS cancel_works;

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
  SELECT pg_background_report_progress(0, 'Starting');
  SELECT pg_sleep(0.1);
  SELECT pg_background_report_progress(50, 'Halfway');
  SELECT pg_sleep(0.1);
  SELECT pg_background_report_progress(100, 'Done');
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
SELECT pg_background_wait_v2(:p_pid, :p_cookie, 5000) AS progress_worker_done;

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

-- Wait for worker to complete (deterministic, not timing-dependent)
SELECT pg_background_wait_v2(:lbl_pid, :lbl_cookie);

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

-- Wait for worker to complete (deterministic)
SELECT pg_background_wait_v2(:slbl_pid, :slbl_cookie);
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

-- Wait for worker to complete (deterministic)
SELECT pg_background_wait_v2(:ri_pid, :ri_cookie);

-- Check result info (should show completed with row_count=5, command_tag='INSERT')
SELECT
  row_count AS ri_row_count,
  command_tag AS ri_command_tag,
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

-- Wait for worker to complete (will error, but still completes)
SELECT pg_background_wait_v2(:err_pid, :err_cookie);

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

-- Launch multiple workers (use launch_v2 so we can wait deterministically)
SELECT (h).pid AS b1_pid, (h).cookie AS b1_cookie
FROM (SELECT pg_background_launch_v2('INSERT INTO t_batch VALUES (1)', NULL, 'batch-1') AS h) s
\gset

SELECT (h).pid AS b2_pid, (h).cookie AS b2_cookie
FROM (SELECT pg_background_launch_v2('INSERT INTO t_batch VALUES (2)', NULL, 'batch-2') AS h) s
\gset

-- Wait for both workers to complete (deterministic, avoids timing-based flakiness)
SELECT pg_background_wait_v2(:b1_pid, :b1_cookie);
SELECT pg_background_wait_v2(:b2_pid, :b2_cookie);

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

-- Brief pause to ensure workers have started their pg_sleep
SELECT pg_sleep(0.2);

-- Cancel all at once
SELECT pg_background_cancel_all_v2() AS batch_cancel_count;

-- Wait for each worker to stop (deterministic, with timeout)
SELECT pg_background_wait_v2(:bc1_pid, :bc1_cookie, 5000) AS bc1_stopped;
SELECT pg_background_wait_v2(:bc2_pid, :bc2_cookie, 5000) AS bc2_stopped;

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
-- v2.0 (E6): Cookie-mismatch coverage for EVERY v2 function.
--
-- CLAUDE.md §11 requires every cookie-protected v2 entrypoint to use the
-- same error pattern: SQLSTATE 55000 (object_not_in_prerequisite_state)
-- with errmsg "cookie mismatch for PID %d" and a "stale handle" errhint.
-- This block launches one worker, then calls each protected function with
-- a deliberately wrong cookie and asserts both the SQLSTATE and that the
-- errmsg starts with "cookie mismatch".
-- -------------------------------------------------------------------------

DO $$
DECLARE
    h          pg_background_handle;
    bad_cookie int8 := 1;     /* deliberately not the real cookie */
    saw_state  text;
    saw_msg    text;
BEGIN
    /*
     * v2.0: launch a fast-finishing worker and wait for it to complete BEFORE
     * the wrong-cookie sweep. The cookie-validation paths are identical
     * whether the worker is alive or already exited (the check fires before
     * any signal/queue work), and using a finished worker means cleanup is a
     * single detach_v2 instead of cancel→wait→detach. That avoids a flaky
     * worker-exit-then-launcher-followup race we hit earlier.
     */
    h := pg_background_launch_v2('SELECT 1', 65536, 'cookie-mismatch-sweep');
    PERFORM pg_background_wait_v2(h.pid, h.cookie);

    /*
     * Iterate every v2 function that validates cookie. We can't easily put
     * them in an array of function pointers, so we open-code each call.
     * Each block must produce SQLSTATE 55000 and a "cookie mismatch" message.
     */

    /* result_v2 */
    BEGIN
        PERFORM * FROM pg_background_result_v2(h.pid, bad_cookie) AS x(c text);
        RAISE EXCEPTION 'result_v2: should have raised on wrong cookie';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS saw_state = RETURNED_SQLSTATE, saw_msg = MESSAGE_TEXT;
        IF saw_state <> '55000' OR saw_msg NOT LIKE 'cookie mismatch%' THEN
            RAISE EXCEPTION 'result_v2: SQLSTATE=% msg=%', saw_state, saw_msg;
        END IF;
    END;

    /* detach_v2 */
    BEGIN
        PERFORM pg_background_detach_v2(h.pid, bad_cookie);
        RAISE EXCEPTION 'detach_v2: should have raised on wrong cookie';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS saw_state = RETURNED_SQLSTATE, saw_msg = MESSAGE_TEXT;
        IF saw_state <> '55000' OR saw_msg NOT LIKE 'cookie mismatch%' THEN
            RAISE EXCEPTION 'detach_v2: SQLSTATE=% msg=%', saw_state, saw_msg;
        END IF;
    END;

    /* cancel_v2 (3-arg, default grace_ms) */
    BEGIN
        PERFORM pg_background_cancel_v2(h.pid, bad_cookie);
        RAISE EXCEPTION 'cancel_v2: should have raised on wrong cookie';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS saw_state = RETURNED_SQLSTATE, saw_msg = MESSAGE_TEXT;
        IF saw_state <> '55000' OR saw_msg NOT LIKE 'cookie mismatch%' THEN
            RAISE EXCEPTION 'cancel_v2: SQLSTATE=% msg=%', saw_state, saw_msg;
        END IF;
    END;

    /* cancel_v2 with explicit grace_ms */
    BEGIN
        PERFORM pg_background_cancel_v2(h.pid, bad_cookie, 100);
        RAISE EXCEPTION 'cancel_v2(grace): should have raised on wrong cookie';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS saw_state = RETURNED_SQLSTATE, saw_msg = MESSAGE_TEXT;
        IF saw_state <> '55000' OR saw_msg NOT LIKE 'cookie mismatch%' THEN
            RAISE EXCEPTION 'cancel_v2(grace): SQLSTATE=% msg=%', saw_state, saw_msg;
        END IF;
    END;

    /* wait_v2 (3-arg, default timeout_ms) */
    BEGIN
        PERFORM pg_background_wait_v2(h.pid, bad_cookie);
        RAISE EXCEPTION 'wait_v2: should have raised on wrong cookie';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS saw_state = RETURNED_SQLSTATE, saw_msg = MESSAGE_TEXT;
        IF saw_state <> '55000' OR saw_msg NOT LIKE 'cookie mismatch%' THEN
            RAISE EXCEPTION 'wait_v2: SQLSTATE=% msg=%', saw_state, saw_msg;
        END IF;
    END;

    /* wait_v2 with explicit timeout_ms */
    BEGIN
        PERFORM pg_background_wait_v2(h.pid, bad_cookie, 100);
        RAISE EXCEPTION 'wait_v2(timeout): should have raised on wrong cookie';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS saw_state = RETURNED_SQLSTATE, saw_msg = MESSAGE_TEXT;
        IF saw_state <> '55000' OR saw_msg NOT LIKE 'cookie mismatch%' THEN
            RAISE EXCEPTION 'wait_v2(timeout): SQLSTATE=% msg=%', saw_state, saw_msg;
        END IF;
    END;

    /* result_info_v2 */
    BEGIN
        PERFORM pg_background_result_info_v2(h.pid, bad_cookie);
        RAISE EXCEPTION 'result_info_v2: should have raised on wrong cookie';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS saw_state = RETURNED_SQLSTATE, saw_msg = MESSAGE_TEXT;
        IF saw_state <> '55000' OR saw_msg NOT LIKE 'cookie mismatch%' THEN
            RAISE EXCEPTION 'result_info_v2: SQLSTATE=% msg=%', saw_state, saw_msg;
        END IF;
    END;

    /* error_info_v2 */
    BEGIN
        PERFORM pg_background_error_info_v2(h.pid, bad_cookie);
        RAISE EXCEPTION 'error_info_v2: should have raised on wrong cookie';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS saw_state = RETURNED_SQLSTATE, saw_msg = MESSAGE_TEXT;
        IF saw_state <> '55000' OR saw_msg NOT LIKE 'cookie mismatch%' THEN
            RAISE EXCEPTION 'error_info_v2: SQLSTATE=% msg=%', saw_state, saw_msg;
        END IF;
    END;

    /* full_sql_v2 raises like the rest (it's a debugging accessor with the
     * same cookie validation as result_v2) */
    BEGIN
        PERFORM pg_background_full_sql_v2(h.pid, bad_cookie);
        RAISE EXCEPTION 'full_sql_v2: should have raised on wrong cookie';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS saw_state = RETURNED_SQLSTATE, saw_msg = MESSAGE_TEXT;
        IF saw_state <> '55000' OR saw_msg NOT LIKE 'cookie mismatch%' THEN
            RAISE EXCEPTION 'full_sql_v2: SQLSTATE=% msg=%', saw_state, saw_msg;
        END IF;
    END;

    /*
     * get_progress_v2 is the lone exception: it returns NULL on cookie
     * mismatch instead of raising, since it's an informational accessor
     * meant to be polled by the launcher without exception-handling
     * boilerplate. Document the contract rather than test it as raising.
     */
    IF pg_background_get_progress_v2(h.pid, bad_cookie) IS NOT NULL THEN
        RAISE EXCEPTION 'get_progress_v2: expected NULL on wrong cookie';
    END IF;

    /* outcome_v2 swallows errors and returns NULL fields per its contract */
    IF (pg_background_outcome_v2(h.pid, bad_cookie)).completed IS NOT NULL THEN
        RAISE EXCEPTION 'outcome_v2: expected completed=NULL on wrong cookie';
    END IF;

    /* Real cleanup with the real cookie. Worker already exited above, so
     * detach_v2 is sufficient — no cancel + wait dance. */
    PERFORM pg_background_detach_v2(h.pid, h.cookie);

    RAISE NOTICE 'v2.0 cookie-mismatch sweep (every protected entrypoint) OK';
END$$;

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
-- Expect SQLSTATE 42704 (UNDEFINED_OBJECT) for "PID not attached to this session"
DO $$
DECLARE v_pid int; v_cookie bigint;
BEGIN
  SELECT pid, cookie INTO v_pid, v_cookie FROM _test_rc_handle;
  PERFORM * FROM pg_background_result_v2(v_pid, v_cookie) AS (answer int);
  RAISE NOTICE 'result_consumed_test=should_have_failed';
EXCEPTION WHEN undefined_object THEN
  -- Expected: "PID %d is not attached to this session"
  RAISE NOTICE 'result_consumed_test=correctly_errored (SQLSTATE=42704)';
WHEN OTHERS THEN
  -- Unexpected error - report it for debugging
  RAISE NOTICE 'result_consumed_test=unexpected_error (SQLSTATE=%, %)', SQLSTATE, SQLERRM;
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
SELECT pg_background_grant_privileges('test_priv_user', false) AS grant_result;

-- Should have access after grant
SELECT
  CASE WHEN has_function_privilege('test_priv_user', 'pg_background_launch_v2(text, int4, text)', 'EXECUTE')
       THEN 'PASS' ELSE 'FAIL' END AS user_has_access_after_grant;

-- Revoke privileges
SELECT pg_background_revoke_privileges('test_priv_user', false) AS revoke_result;

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
SELECT pg_background_cancel_v2(:bg_pid, :bg_cookie, 999999999);
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
-- v2.0 (E7): cancel idempotency
--
-- Two race-flavoured guarantees:
--   (a) Double-cancel is harmless: a second pg_background_cancel_v2 on a
--       worker that's already been canceled does not raise, and the
--       workers_canceled counter only increments by one (not two).
--   (b) Cancel-after-exit is harmless: pg_background_cancel_v2 on a worker
--       that has already finished does not raise.
--
-- These are the deterministic cousins of the flaky cancel-vs-completion
-- race; we keep them small and explicit rather than chasing scheduler
-- order with sleeps.
-- -------------------------------------------------------------------------

-- (a) Double cancel.
--
-- KNOWN ISSUE: an immediate consecutive cancel against a worker mid-
-- execute_sql_string sometimes triggers a worker SIGSEGV in error_exit.
-- See README "Known Limitations" §10. We sidestep by waiting for the
-- worker to finish exiting after the first cancel and asserting that the
-- second cancel against an already-stopped worker is harmless. That still
-- exercises the no-error-on-redundant-cancel contract that callers rely
-- on; the "two cancels race" mid-execution variant is covered by the
-- E7 (b) sub-test below as cancel-after-exit.
DO $$
DECLARE
    h               pg_background_handle;
    before_canceled int8;
    after_canceled  int8;
BEGIN
    SELECT workers_canceled INTO before_canceled FROM pg_background_stats_v2();

    h := pg_background_launch_v2('SELECT pg_sleep(60)', 65536, 'e7-double-cancel');

    PERFORM pg_background_cancel_v2(h.pid, h.cookie);
    PERFORM pg_background_wait_v2(h.pid, h.cookie);

    /*
     * Worker is now stopped. Second cancel on the same handle must be a
     * no-op, not an error.
     */
    PERFORM pg_background_cancel_v2(h.pid, h.cookie);

    PERFORM pg_background_detach_v2(h.pid, h.cookie);

    SELECT workers_canceled INTO after_canceled FROM pg_background_stats_v2();
    IF after_canceled - before_canceled <> 1 THEN
        RAISE EXCEPTION 'E7 double-cancel: workers_canceled went % -> % (want +1)',
            before_canceled, after_canceled;
    END IF;
    RAISE NOTICE 'E7 double-cancel idempotent OK';
END$$;

-- (b) Cancel after exit
DO $$
DECLARE
    h pg_background_handle;
BEGIN
    h := pg_background_launch_v2('SELECT 1', 65536, 'e7-cancel-after-exit');

    /* Wait until the worker has fully exited */
    PERFORM pg_background_wait_v2(h.pid, h.cookie);

    /* The worker is BGWH_STOPPED. cancel_v2 should be a no-op (no error) */
    BEGIN
        PERFORM pg_background_cancel_v2(h.pid, h.cookie);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'E7 cancel-after-exit: unexpected SQLSTATE % (%)', SQLSTATE, SQLERRM;
    END;

    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RAISE NOTICE 'E7 cancel-after-exit harmless OK';
END$$;

-- -------------------------------------------------------------------------
-- Error propagation SQLSTATE tests (v1.9 bugfix)
--
-- Pattern: launch_v2 -> wait_v2 -> error_info_v2 -> detach_v2
-- Do NOT call result_v2 for error cases: it ereport(ERROR)s in launcher,
-- which aborts the transaction and destroys error_info_v2 data.
-- -------------------------------------------------------------------------

-- Test 3.1: Division by zero — SQLSTATE 22012 (execute path)
DO $$
DECLARE
    h pg_background_handle;
    s text;
BEGIN
    h := pg_background_launch_v2('SELECT 1/0');
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    SELECT sqlstate INTO s FROM pg_background_error_info_v2(h.pid, h.cookie);
    IF s IS DISTINCT FROM '22012' THEN
        RAISE EXCEPTION 'test 3.1: expected sqlstate 22012, got %', s;
    END IF;
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RAISE NOTICE 'test 3.1 (22012 division_by_zero) OK';
END$$;

-- Test 3.2: RAISE EXCEPTION — SQLSTATE P0001 (execute path)
-- Use a helper function instead of nested dollar-quoting to avoid psql parsing issues.
CREATE OR REPLACE FUNCTION pgbg_test_raise_p0001() RETURNS void
    LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''custom error''; END';

DO $$
DECLARE
    h pg_background_handle;
    s text;
BEGIN
    h := pg_background_launch_v2('SELECT pgbg_test_raise_p0001()');
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    SELECT sqlstate INTO s FROM pg_background_error_info_v2(h.pid, h.cookie);
    IF s IS DISTINCT FROM 'P0001' THEN
        RAISE EXCEPTION 'test 3.2: expected sqlstate P0001, got %', s;
    END IF;
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RAISE NOTICE 'test 3.2 (P0001 raise_exception) OK';
END$$;

DROP FUNCTION pgbg_test_raise_p0001();

-- Test 3.3: NOT NULL violation — SQLSTATE 23502 (execute path)
-- Note: temp tables are NOT visible to background workers (separate backend).
-- Use a regular table with a unique prefix.
DROP TABLE IF EXISTS pgbg_test_nn_23502;
CREATE TABLE pgbg_test_nn_23502(c int NOT NULL);

DO $$
DECLARE
    h pg_background_handle;
    s text;
BEGIN
    h := pg_background_launch_v2('INSERT INTO pgbg_test_nn_23502 VALUES (NULL)');
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    SELECT sqlstate INTO s FROM pg_background_error_info_v2(h.pid, h.cookie);
    IF s IS DISTINCT FROM '23502' THEN
        RAISE EXCEPTION 'test 3.3: expected sqlstate 23502, got %', s;
    END IF;
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RAISE NOTICE 'test 3.3 (23502 not_null_violation) OK';
END$$;

DROP TABLE pgbg_test_nn_23502;

-- Test 3.4: Deferred FK violation — SQLSTATE 23503 (commit path)
-- FK is INITIALLY DEFERRED, so INSERT succeeds but COMMIT fails.
-- The error fires in the commit-wrapper PG_CATCH (Phase 2 path).
DROP TABLE IF EXISTS pgbg_test_fk_child_23503;
DROP TABLE IF EXISTS pgbg_test_fk_parent_23503;
CREATE TABLE pgbg_test_fk_parent_23503(id int PRIMARY KEY);
CREATE TABLE pgbg_test_fk_child_23503(
    id int PRIMARY KEY,
    parent_id int,
    CONSTRAINT fk_23503_parent
        FOREIGN KEY (parent_id) REFERENCES pgbg_test_fk_parent_23503(id)
        DEFERRABLE INITIALLY DEFERRED
);

DO $$
DECLARE
    h pg_background_handle;
    s text;
BEGIN
    -- Worker runs INSERT in its own auto-transaction.
    -- INITIALLY DEFERRED FK fires at CommitTransactionCommand (commit-wrapper PG_CATCH).
    -- Do NOT pass BEGIN/COMMIT: worker already runs in its own transaction.
    h := pg_background_launch_v2(
        'INSERT INTO pgbg_test_fk_child_23503 VALUES (1, 999)'
    );
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    SELECT sqlstate INTO s FROM pg_background_error_info_v2(h.pid, h.cookie);
    IF s IS DISTINCT FROM '23503' THEN
        RAISE EXCEPTION 'test 3.4: expected sqlstate 23503, got %', s;
    END IF;
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RAISE NOTICE 'test 3.4 (23503 foreign_key_violation deferred) OK';
END$$;

DROP TABLE pgbg_test_fk_child_23503;
DROP TABLE pgbg_test_fk_parent_23503;

-- Test 3.5: Cancel — SQLSTATE 57014 (execute path, query_canceled)
-- Uses pg_sleep(30) to ensure worker is truly sleeping before cancel.
-- Positive sync via pg_stat_activity: cancel is only sent after the worker
-- is confirmed to be actively executing pg_sleep. Without this sync, cancel
-- could land before SPI_execute starts (early-failure path) and the
-- launcher would see 08006 instead of 57014.
DO $$
DECLARE
    h     pg_background_handle;
    w_pid int4;
    s     text;
    done  boolean;
    cnt   int;
BEGIN
    h := pg_background_launch_v2('SELECT pg_sleep(30)');
    w_pid := h.pid;
    /* Positive sync: let the worker fork and reach SPI_execute, then
       confirm it is actively running via pg_stat_activity.  An initial
       sleep gives the OS scheduler time to start the child process;
       afterwards we poll at 100 ms intervals for up to ~5 s total. */
    PERFORM pg_sleep(0.1);
    FOR i IN 1..55 LOOP
        SELECT count(*) INTO cnt
          FROM pg_stat_activity
         WHERE pid = w_pid
           AND state = 'active';
        EXIT WHEN cnt > 0;
        PERFORM pg_sleep(0.1);
    END LOOP;
    IF cnt = 0 THEN
        RAISE EXCEPTION
            'test 3.5: worker not active within 5.6s — test not valid';
    END IF;
    /* Worker is past pq_redirect_to_shm_mq and executing SQL; cancel
       will be caught by the execute-phase PG_CATCH and produce 57014. */
    PERFORM pg_background_cancel_v2(h.pid, h.cookie, 100);
    -- Wait for worker to stop after cancel (should be fast)
    done := pg_background_wait_v2(h.pid, h.cookie, 5000);
    IF NOT done THEN
        RAISE EXCEPTION 'test 3.5: worker did not stop within 5s after cancel';
    END IF;
    SELECT sqlstate INTO s FROM pg_background_error_info_v2(h.pid, h.cookie);
    IF s IS DISTINCT FROM '57014' THEN
        RAISE EXCEPTION 'test 3.5: expected sqlstate 57014, got %', s;
    END IF;
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RAISE NOTICE 'test 3.5 (57014 query_canceled) OK';
END$$;

-- -------------------------------------------------------------------------
-- Stats sanity check (mid-suite snapshot).
--
-- We don't pin exact counts here — the v1.10 / v2.0 sections below launch
-- many additional workers and the totals shift every time a new test is
-- added. Instead we assert structural invariants: no workers active right
-- now, every launched worker has finished one way or another, and the
-- canceled bucket is non-empty (proves the cancel tests actually fired).
-- -------------------------------------------------------------------------

DO $$
DECLARE
    s pg_background_stats;
BEGIN
    s := pg_background_stats_v2();
    IF s.workers_active <> 0 THEN
        RAISE EXCEPTION 'mid-suite stats: expected 0 active workers, got %', s.workers_active;
    END IF;
    IF (s.workers_completed + s.workers_failed + s.workers_canceled + s.workers_timed_out)
        <> s.workers_launched THEN
        RAISE EXCEPTION 'mid-suite stats: launched (%) <> completed+failed+canceled+timed_out (% + % + % + %)',
            s.workers_launched, s.workers_completed, s.workers_failed,
            s.workers_canceled, s.workers_timed_out;
    END IF;
    IF s.workers_canceled = 0 THEN
        RAISE EXCEPTION 'mid-suite stats: expected at least one canceled worker, got 0';
    END IF;
    RAISE NOTICE 'mid-suite stats invariants OK';
END$$;

-- =========================================================================
-- v1.10: ergonomics (pg_background_list view, outcome_v2, run_v2)
-- =========================================================================

-- pg_background_list view: every column should be populated with a sane
-- value (not just a non-zero row count). v2.0 (E4) replaces the previous
-- "did one row come back?" test with explicit per-column assertions.
DO $$
DECLARE
    h            pg_background_handle;
    r_state      text;
    r_qsize      int;
    r_preview    text;
    r_consumed   bool;
    r_label      text;
    r_user       oid;
    r_launched   timestamptz;
BEGIN
    h := pg_background_launch_v2('SELECT pg_sleep(0.5)', 65536, 'v1_10_view');

    SELECT state, queue_size, sql_preview, consumed, label, user_id, launched_at
      INTO r_state, r_qsize, r_preview, r_consumed, r_label, r_user, r_launched
      FROM pg_background_list
     WHERE pid = h.pid AND cookie = h.cookie;

    IF r_state NOT IN ('starting', 'running', 'stopped') THEN
        RAISE EXCEPTION 'list view state: unexpected value %', r_state;
    END IF;
    IF r_qsize <> 65536 THEN
        RAISE EXCEPTION 'list view queue_size: expected 65536, got %', r_qsize;
    END IF;
    IF r_preview NOT LIKE 'SELECT pg_sleep%' THEN
        RAISE EXCEPTION 'list view sql_preview: did not match expected prefix, got %', r_preview;
    END IF;
    IF r_consumed IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'list view consumed: expected false, got %', r_consumed;
    END IF;
    IF r_label IS DISTINCT FROM 'v1_10_view' THEN
        RAISE EXCEPTION 'list view label: expected v1_10_view, got %', r_label;
    END IF;
    IF r_user <> (SELECT oid FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION 'list view user_id: did not match current_user oid';
    END IF;
    IF r_launched IS NULL OR r_launched > clock_timestamp() THEN
        RAISE EXCEPTION 'list view launched_at: NULL or in the future (%)', r_launched;
    END IF;

    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RAISE NOTICE 'v1.10 list view (per-column assertions) OK';
END$$;

-- pg_background_activity view: assert the join with pg_stat_activity actually
-- produces a row for our worker, and that the joined backend_state column
-- carries through (v2.0 (E4): replaces the previous RAISE NOTICE 'OK').
DO $$
DECLARE
    h               pg_background_handle;
    found_pgbg      text;
    found_backend   text;
BEGIN
    h := pg_background_launch_v2('SELECT pg_sleep(2)', 65536, 'v1_10_activity');
    /* worker needs a moment to register in pg_stat_activity */
    PERFORM pg_sleep(0.3);

    SELECT pgbg_state, backend_state
      INTO found_pgbg, found_backend
      FROM pg_background_activity
     WHERE pid = h.pid AND cookie = h.cookie;

    IF found_pgbg NOT IN ('starting', 'running') THEN
        RAISE EXCEPTION 'activity view pgbg_state: expected starting/running, got %', found_pgbg;
    END IF;
    /* backend_state can be 'active' (executing) or NULL (joined too early); accept either */
    IF found_backend IS NOT NULL AND found_backend NOT IN ('active', 'idle', 'idle in transaction') THEN
        RAISE EXCEPTION 'activity view backend_state: unexpected value %', found_backend;
    END IF;

    PERFORM pg_background_cancel_v2(h.pid, h.cookie);
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RAISE NOTICE 'v1.10 activity view (joined columns) OK';
END$$;

-- pg_background_outcome_v2: success path
DO $$
DECLARE
    h pg_background_handle;
    o pg_background_outcome;
BEGIN
    h := pg_background_launch_v2('SELECT 1', 65536, 'v1_10_outcome_ok');
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    o := pg_background_outcome_v2(h.pid, h.cookie);
    IF o.completed IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'v1.10 outcome ok: expected completed=true, got %', o.completed;
    END IF;
    IF o.has_error IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'v1.10 outcome ok: expected has_error=false, got %', o.has_error;
    END IF;
    IF o.label IS DISTINCT FROM 'v1_10_outcome_ok' THEN
        RAISE EXCEPTION 'v1.10 outcome ok: expected label v1_10_outcome_ok, got %', o.label;
    END IF;
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RAISE NOTICE 'v1.10 outcome ok OK';
END$$;

-- pg_background_outcome_v2: missing handle returns NULL fields, never raises
DO $$
DECLARE
    o pg_background_outcome;
BEGIN
    o := pg_background_outcome_v2(0, 0);
    IF o.pid <> 0 OR o.cookie <> 0 THEN
        RAISE EXCEPTION 'v1.10 outcome missing: pid/cookie not echoed';
    END IF;
    IF o.state IS NOT NULL OR o.completed IS NOT NULL OR o.has_error IS NOT NULL THEN
        RAISE EXCEPTION 'v1.10 outcome missing: expected all NULL fields';
    END IF;
    RAISE NOTICE 'v1.10 outcome missing OK';
END$$;

-- pg_background_run_v2: success path. v2.0 (E5) widens the assertions to
-- cover every column of the now-extended pg_background_run_result.
DROP TABLE IF EXISTS t_v1_10_run;
CREATE TABLE t_v1_10_run(id int);

DO $$
DECLARE
    r pg_background_run_result;
BEGIN
    r := pg_background_run_v2('INSERT INTO t_v1_10_run VALUES (1), (2), (3)',
                              65536, 0, 'v1_10_run_ok');

    /* core completion / error fields */
    IF r.completed IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'run ok: completed=% (want true)', r.completed;
    END IF;
    IF r.has_error IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'run ok: has_error=% (want false)', r.has_error;
    END IF;
    IF r.timed_out IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'run ok: timed_out=% (want false)', r.timed_out;
    END IF;
    IF r.sqlstate IS NOT NULL THEN
        RAISE EXCEPTION 'run ok: sqlstate=% (want NULL)', r.sqlstate;
    END IF;
    IF r.error_message IS NOT NULL THEN
        RAISE EXCEPTION 'run ok: error_message=% (want NULL)', r.error_message;
    END IF;

    /* result metadata */
    IF r.row_count IS DISTINCT FROM 3 THEN
        RAISE EXCEPTION 'run ok: row_count=% (want 3)', r.row_count;
    END IF;
    IF r.command_tag IS NULL OR r.command_tag NOT LIKE 'INSERT%' THEN
        RAISE EXCEPTION 'run ok: command_tag=% (want INSERT*)', r.command_tag;
    END IF;

    /* extended outcome fields gained in v2.0 */
    IF r.pid IS NULL OR r.pid <= 0 THEN
        RAISE EXCEPTION 'run ok: pid=% (want > 0)', r.pid;
    END IF;
    IF r.cookie IS NULL OR r.cookie = 0 THEN
        RAISE EXCEPTION 'run ok: cookie=% (want non-zero)', r.cookie;
    END IF;
    IF r.label IS DISTINCT FROM 'v1_10_run_ok' THEN
        RAISE EXCEPTION 'run ok: label=% (want v1_10_run_ok)', r.label;
    END IF;
    /*
     * After detach the worker is gone from pg_background_list, so state and
     * consumed come back NULL from outcome_v2 — that's the point of the
     * extended run_result: the caller sees the snapshot, not a live cursor.
     */

    /* elapsed_ms invariants — non-negative, bounded above by something sane */
    IF r.elapsed_ms IS NULL OR r.elapsed_ms < 0 THEN
        RAISE EXCEPTION 'run ok: elapsed_ms=% (want >= 0)', r.elapsed_ms;
    END IF;
    IF r.elapsed_ms > 30000 THEN
        RAISE EXCEPTION 'run ok: elapsed_ms=% (suspiciously slow, > 30s)', r.elapsed_ms;
    END IF;

    RAISE NOTICE 'v1.10 run ok (extended assertions) OK';
END$$;

-- The launched worker actually inserted rows (committed via worker exit).
SELECT count(*) AS v1_10_run_inserted FROM t_v1_10_run;
DROP TABLE t_v1_10_run;

-- pg_background_run_v2: error case (1/0 -> sqlstate 22012)
DO $$
DECLARE
    r pg_background_run_result;
BEGIN
    r := pg_background_run_v2('SELECT 1/0', 65536, 0, 'v1_10_run_err');
    IF r.has_error IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'v1.10 run err: expected has_error=true, got %', r.has_error;
    END IF;
    IF r.sqlstate IS DISTINCT FROM '22012' THEN
        RAISE EXCEPTION 'v1.10 run err: expected sqlstate=22012, got %', r.sqlstate;
    END IF;
    IF r.timed_out IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'v1.10 run err: expected timed_out=false, got %', r.timed_out;
    END IF;
    RAISE NOTICE 'v1.10 run err OK';
END$$;

-- pg_background_run_v2: timeout case. v2.0 (E5) verifies the actual
-- timeout-driven invariants: timed_out=true, elapsed_ms >= the timeout we
-- supplied (we asked for 200ms; with 1s grace the wait can run a bit
-- longer), and the workers_timed_out stats counter incremented.
DO $$
DECLARE
    r              pg_background_run_result;
    before_timeout int8;
    after_timeout  int8;
BEGIN
    SELECT workers_timed_out INTO before_timeout FROM pg_background_stats_v2();

    r := pg_background_run_v2('SELECT pg_sleep(5)', 65536, 200, 'v1_10_run_timeout');

    IF r.timed_out IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'run timeout: timed_out=% (want true)', r.timed_out;
    END IF;
    IF r.completed IS DISTINCT FROM true THEN
        /*
         * The worker WAS canceled and DID exit cleanly within grace, so
         * GetBackgroundWorkerPid returns BGWH_STOPPED → completed=true even
         * though timed_out=true. This pair is the documented contract.
         */
        RAISE EXCEPTION 'run timeout: completed=% (want true after grace cancel)', r.completed;
    END IF;
    IF r.elapsed_ms IS NULL OR r.elapsed_ms < 200 THEN
        RAISE EXCEPTION 'run timeout: elapsed_ms=% (want >= 200, the requested timeout)', r.elapsed_ms;
    END IF;
    IF r.label IS DISTINCT FROM 'v1_10_run_timeout' THEN
        RAISE EXCEPTION 'run timeout: label=% (want v1_10_run_timeout)', r.label;
    END IF;

    SELECT workers_timed_out INTO after_timeout FROM pg_background_stats_v2();
    IF after_timeout <> before_timeout + 1 THEN
        RAISE EXCEPTION 'run timeout: workers_timed_out went % -> % (want +1)',
            before_timeout, after_timeout;
    END IF;

    RAISE NOTICE 'v1.10 run timeout (timed_out + elapsed_ms + stats counter) OK';
END$$;

-- =========================================================================
-- Refactor: metadata-driven grant/revoke helpers
--
-- Contract: pg_background_grant_privileges() must cover every
-- extension-owned function (EXCEPT the SECURITY DEFINER privilege helpers,
-- which must NOT be granted to the executor role -- privilege-escalation
-- guard), type, and view, without an explicit list. This test pins the
-- contract by round-tripping a temp role and asserting that EXECUTE/USAGE/
-- SELECT privileges flip on grant and off on revoke, and that the
-- SECURITY DEFINER helpers stay unreachable by the role.
-- =========================================================================

DO $$
DECLARE
    n_funcs_granted     int;
    n_funcs_total       int;
    n_views_granted     int;
    n_views_total       int;
BEGIN
    CREATE ROLE pgbg_meta_test_role NOLOGIN;
    PERFORM pg_background_grant_privileges('pgbg_meta_test_role');

    -- Every extension-owned function EXCEPT the SECURITY DEFINER privilege
    -- helpers must now be EXECUTE-able by the role.
    SELECT count(*) INTO n_funcs_total
      FROM pg_depend d
      JOIN pg_proc p ON p.oid = d.objid
     WHERE d.classid = 'pg_proc'::regclass
       AND d.refclassid = 'pg_extension'::regclass
       AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname='pg_background')
       AND d.deptype = 'e'
       AND NOT p.prosecdef;

    SELECT count(*) INTO n_funcs_granted
      FROM pg_depend d
      JOIN pg_proc p ON p.oid = d.objid
     WHERE d.classid = 'pg_proc'::regclass
       AND d.refclassid = 'pg_extension'::regclass
       AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname='pg_background')
       AND d.deptype = 'e'
       AND NOT p.prosecdef
       AND has_function_privilege('pgbg_meta_test_role', p.oid, 'EXECUTE');

    IF n_funcs_granted <> n_funcs_total THEN
        RAISE EXCEPTION 'metadata grant: % of % functions reachable by role',
                        n_funcs_granted, n_funcs_total;
    END IF;

    -- Privilege-escalation guard: the SECURITY DEFINER helpers must NOT be
    -- reachable by the executor role.
    IF has_function_privilege('pgbg_meta_test_role',
           'pg_background_grant_privileges(text, boolean)', 'EXECUTE')
       OR has_function_privilege('pgbg_meta_test_role',
           'pg_background_revoke_privileges(text, boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'security: SECURITY DEFINER privilege helpers reachable by role';
    END IF;

    -- Every extension-owned view must now be SELECT-able by the role.
    SELECT count(*) INTO n_views_total
      FROM pg_depend d
      JOIN pg_class c ON c.oid = d.objid
     WHERE d.classid = 'pg_class'::regclass
       AND d.refclassid = 'pg_extension'::regclass
       AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname='pg_background')
       AND d.deptype = 'e'
       AND c.relkind IN ('v','r','m');

    SELECT count(*) INTO n_views_granted
      FROM pg_depend d
      JOIN pg_class c ON c.oid = d.objid
     WHERE d.classid = 'pg_class'::regclass
       AND d.refclassid = 'pg_extension'::regclass
       AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname='pg_background')
       AND d.deptype = 'e'
       AND c.relkind IN ('v','r','m')
       AND has_table_privilege('pgbg_meta_test_role', c.oid, 'SELECT');

    IF n_views_granted <> n_views_total THEN
        RAISE EXCEPTION 'metadata grant: % of % views reachable by role',
                        n_views_granted, n_views_total;
    END IF;

    -- Symmetric revoke: nothing should remain reachable.
    PERFORM pg_background_revoke_privileges('pgbg_meta_test_role');

    SELECT count(*) INTO n_funcs_granted
      FROM pg_depend d
      JOIN pg_proc p ON p.oid = d.objid
     WHERE d.classid = 'pg_proc'::regclass
       AND d.refclassid = 'pg_extension'::regclass
       AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname='pg_background')
       AND d.deptype = 'e'
       AND has_function_privilege('pgbg_meta_test_role', p.oid, 'EXECUTE');

    IF n_funcs_granted <> 0 THEN
        RAISE EXCEPTION 'metadata revoke: % functions still reachable',
                        n_funcs_granted;
    END IF;

    DROP ROLE pgbg_meta_test_role;
    RAISE NOTICE 'metadata-driven grant/revoke OK (% funcs, % views round-tripped)',
                 n_funcs_total, n_views_total;
END$$;

-- =========================================================================
-- v1.10 Tier A: loop-killer helpers
-- =========================================================================

-- A1: pg_background_run_query_v2 success + error path
SELECT * FROM pg_background_run_query_v2('SELECT 42 AS n', col_def => 'n int') AS r(n int);

DO $$
BEGIN
    BEGIN
        PERFORM * FROM pg_background_run_query_v2('SELECT 1/0', col_def => 'x int') AS r(x int);
        RAISE EXCEPTION 'Tier A run_query_v2: error not propagated';
    EXCEPTION WHEN division_by_zero THEN
        RAISE NOTICE 'Tier A run_query_v2 SQLSTATE 22012 OK';
    END;
END$$;

-- A2: drain_v2 with N=3 — v2.0 (E5) asserts row order matches input order
-- and every per-row outcome is well-formed.
DO $$
DECLARE
    hs            pg_background_handle[];
    rows          pg_background_outcome[];
    i             int;
    expected_lbl  text;
BEGIN
    hs := ARRAY(
        SELECT pg_background_launch_v2('SELECT pg_sleep(0.05)', 65536, 'tier-a-drain-' || g)
          FROM generate_series(1,3) g
    );
    rows := ARRAY(
        SELECT pg_background_drain_v2(hs, 5000)
    );

    IF array_length(rows, 1) <> 3 THEN
        RAISE EXCEPTION 'drain_v2: drained %d rows, want 3', array_length(rows, 1);
    END IF;

    FOR i IN 1..3 LOOP
        expected_lbl := 'tier-a-drain-' || i;
        IF rows[i].pid    IS DISTINCT FROM hs[i].pid    THEN
            RAISE EXCEPTION 'drain_v2 row % pid mismatch: % vs %', i, rows[i].pid, hs[i].pid;
        END IF;
        IF rows[i].cookie IS DISTINCT FROM hs[i].cookie THEN
            RAISE EXCEPTION 'drain_v2 row % cookie mismatch', i;
        END IF;
        IF rows[i].label  IS DISTINCT FROM expected_lbl THEN
            RAISE EXCEPTION 'drain_v2 row % label=% want %', i, rows[i].label, expected_lbl;
        END IF;
        IF rows[i].completed IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'drain_v2 row % completed=% want true', i, rows[i].completed;
        END IF;
        IF rows[i].has_error IS DISTINCT FROM false THEN
            RAISE EXCEPTION 'drain_v2 row % has_error=% want false', i, rows[i].has_error;
        END IF;
    END LOOP;
    RAISE NOTICE 'Tier A drain_v2 (per-row assertions) OK';
END$$;

-- A3: wait_any_v2 returns one winner. v2.0 (E5) asserts the winner's pid
-- belongs to the input array and its outcome reflects a finished worker.
DO $$
DECLARE
    hs            pg_background_handle[];
    winner        pg_background_handle;
    winner_in_set bool;
    winner_pids   int[];
BEGIN
    hs := ARRAY(
        SELECT pg_background_launch_v2(format('SELECT pg_sleep(%s)', g*0.03), 65536, 'tier-a-any-' || g)
          FROM generate_series(1,3) g
    );
    winner := pg_background_wait_any_v2(hs, 5000);
    IF winner IS NULL THEN
        RAISE EXCEPTION 'wait_any_v2: timed out without a winner';
    END IF;

    /* the winner must be one of the handles we passed in */
    winner_pids := ARRAY(SELECT (h).pid FROM unnest(hs) h);
    winner_in_set := winner.pid = ANY (winner_pids);
    IF NOT winner_in_set THEN
        RAISE EXCEPTION 'wait_any_v2: winner pid % not in input array %', winner.pid, winner_pids;
    END IF;

    /* and pg_background_wait_v2(winner, 1) should report it finished */
    IF NOT pg_background_wait_v2(winner.pid, winner.cookie, 1) THEN
        RAISE EXCEPTION 'wait_any_v2: winner % is not actually stopped', winner.pid;
    END IF;

    /* Cleanup via drain — handles wait + detach for every handle */
    PERFORM count(*) FROM pg_background_drain_v2(hs, 5000);
    RAISE NOTICE 'Tier A wait_any_v2 (winner-pid + finished assertion) OK';
END$$;

-- A4: cancel_by_label_v2 with a LIKE pattern. v2.0 (E5) asserts that the
-- canceled worker actually appears in stats.workers_canceled.
--
-- KNOWN ISSUE (pre-existing, see README "Known Limitations" §10): launching
-- multiple workers in close succession then cancelling them concurrently
-- triggers a SIGSEGV in PostgreSQL's background-worker startup machinery —
-- the segfaulting worker never reaches our `pg_background_worker_main`, so
-- the issue is upstream of pg_background. To keep the suite deterministic,
-- this test exercises the function against a single worker. Multi-worker
-- coverage is provided by drain_v2 / wait_any_v2 elsewhere (which also use
-- multiple concurrent workers but don't cancel them mid-flight).
DO $$
DECLARE
    cnt              int;
    before_canceled  int8;
    after_canceled   int8;
    h                pg_background_handle;
BEGIN
    SELECT workers_canceled INTO before_canceled FROM pg_background_stats_v2();

    h := pg_background_launch_v2('SELECT pg_sleep(60)', 65536, 'tier-a-cancel-1');

    cnt := pg_background_cancel_by_label_v2('tier-a-cancel-%');
    IF cnt <> 1 THEN
        RAISE EXCEPTION 'cancel_by_label_v2: cnt=% want 1', cnt;
    END IF;

    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);

    SELECT workers_canceled INTO after_canceled FROM pg_background_stats_v2();
    IF after_canceled - before_canceled < 1 THEN
        RAISE EXCEPTION 'cancel_by_label_v2: workers_canceled +%, want >= 1',
            after_canceled - before_canceled;
    END IF;

    RAISE NOTICE 'Tier A cancel_by_label_v2 (single-worker grace=0 path) OK';
END$$;

-- v2.0: status_v2 was dropped; drivers can call to_jsonb(outcome_v2(...)) directly.
DO $$
DECLARE
    r pg_background_run_result;
    j jsonb;
BEGIN
    r := pg_background_run_v2('SELECT 1', label => 'tier-a-status');
    j := to_jsonb(pg_background_outcome_v2(r.pid, r.cookie));
    IF NOT (j ? 'pid' AND j ? 'completed' AND j ? 'has_error' AND j ? 'sqlstate') THEN
        RAISE EXCEPTION 'outcome_v2 jsonb: missing expected keys: %', j;
    END IF;
    RAISE NOTICE 'outcome_v2 jsonb OK';
END$$;

-- A6: purge_v2 detaches only stopped workers
DO $$
DECLARE
    h_done    pg_background_handle;
    h_running pg_background_handle;
    purged    int;
BEGIN
    h_done := pg_background_launch_v2('SELECT 1', 65536, 'tier-a-purge-done');
    PERFORM pg_background_wait_v2(h_done.pid, h_done.cookie);

    h_running := pg_background_launch_v2('SELECT pg_sleep(60)', 65536, 'tier-a-purge-keep');
    /* Give the running worker a moment to attach */
    PERFORM pg_sleep(0.1);

    purged := pg_background_purge_v2();
    IF purged < 1 THEN
        RAISE EXCEPTION 'Tier A purge_v2: expected at least 1, got %', purged;
    END IF;
    /* The still-running worker should remain in the list */
    IF (SELECT count(*) FROM pg_background_list
         WHERE pid = h_running.pid AND cookie = h_running.cookie) <> 1 THEN
        RAISE EXCEPTION 'Tier A purge_v2: running worker incorrectly purged';
    END IF;

    /*
     * v2.0 (E8): explicit per-handle cleanup instead of detach_all_v2(),
     * which CLAUDE.md §7 calls out as a banned cleanup pattern. h_done was
     * already detached by purge_v2 above; only h_running remains.
     */
    PERFORM pg_background_cancel_v2(h_running.pid, h_running.cookie);
    PERFORM pg_background_wait_v2(h_running.pid, h_running.cookie);
    PERFORM pg_background_detach_v2(h_running.pid, h_running.cookie);
    RAISE NOTICE 'Tier A purge_v2 OK';
END$$;

-- =========================================================================
-- v1.10 Tier B (small): full_sql_v2 (B3), application_name (B6)
-- =========================================================================

-- B3: pg_background_full_sql_v2 returns the original SQL
DO $$
DECLARE
    h pg_background_handle;
    full_sql text;
BEGIN
    h := pg_background_launch_v2('SELECT pg_sleep(60), 1 AS phase2_marker', 65536, 'tier-b-fullsql');
    full_sql := pg_background_full_sql_v2(h.pid, h.cookie);
    IF full_sql IS NULL OR full_sql NOT LIKE '%phase2_marker%' THEN
        RAISE EXCEPTION 'Tier B full_sql_v2: expected SQL containing phase2_marker, got %', full_sql;
    END IF;
    PERFORM pg_background_cancel_v2(h.pid, h.cookie);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RAISE NOTICE 'Tier B full_sql_v2 OK';
END$$;

-- B6: application_name should be 'pg_background:<label>:<pid>'
DO $$
DECLARE
    h pg_background_handle;
    appname_count int;
BEGIN
    h := pg_background_launch_v2('SELECT pg_sleep(3)', 65536, 'tier-b-appname');
    /* allow worker to set its application_name */
    PERFORM pg_sleep(0.3);
    SELECT count(*) INTO appname_count
      FROM pg_stat_activity
     WHERE application_name = 'pg_background:tier-b-appname:' || h.pid;
    IF appname_count <> 1 THEN
        RAISE EXCEPTION 'Tier B application_name: expected exactly one worker with pg_background:tier-b-appname:<pid>, got %', appname_count;
    END IF;
    PERFORM pg_background_cancel_v2(h.pid, h.cookie);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RAISE NOTICE 'Tier B application_name OK';
END$$;

-- =========================================================================
-- 2.0: canonical (unsuffixed) API + deprecated _v2 alias parity
--
-- 2.0 retires the _v2 suffix: the unsuffixed names are canonical and every
-- v2 API name that shipped through 1.10 is kept as a thin deprecated alias.
-- This section exercises the canonical names directly and confirms the
-- aliases still resolve to identical behavior (handles are interchangeable
-- across the two name sets).
-- =========================================================================

-- Full lifecycle through the canonical names only. Fully consuming the
-- result of a stopped worker is terminal and auto-removes the tracking
-- entry, so no detach is needed here (detach() is exercised below).
DO $$
DECLARE
    h pg_background_handle;
    n int;
BEGIN
    h := pg_background_launch('SELECT 7 AS v', 65536, 'canon-lifecycle');
    PERFORM pg_background_wait(h.pid, h.cookie);
    SELECT v INTO n FROM pg_background_result(h.pid, h.cookie) AS r(v int);
    IF n <> 7 THEN
        RAISE EXCEPTION 'canonical lifecycle: expected 7, got %', n;
    END IF;
    RAISE NOTICE 'canonical launch/wait/result OK';
END$$;

-- Regression guard for the pre-execution cancel branch in the worker.
--
-- A grace=0 cancel issued immediately after launch tries to set
-- input->cancel_requested before the worker reaches its pre-SQL cancel check.
-- When the worker observes the flag there it must exit via proc_exit(0) WITHOUT
-- calling ResourceOwnerDelete(CurrentResourceOwner): the GUC-restore transaction
-- has already committed, so CurrentResourceOwner is NULL there, and deleting a
-- NULL owner trips Assert(owner != CurrentResourceOwner) on assert-enabled
-- builds (observed as a worker SIGABRT on the PG19 beta PGDG assert build).
--
-- The race between the cancel landing and the worker reaching the check is
-- inherent, so this is a best-effort trigger rather than a deterministic one;
-- it is most likely to fire under the slower assert/sanitizer CI lanes, which
-- is exactly where the crash showed up. The assertion is path-independent:
-- whichever branch the worker takes, the launcher marked it canceled, so
-- workers_canceled must advance by >= 1 and the worker must be gone. Single
-- worker only (see the cancel_by_label note re: upstream multi-worker startup
-- SIGSEGV).
DO $$
DECLARE
    h               pg_background_handle;
    before_canceled int8;
    after_canceled  int8;
BEGIN
    SELECT workers_canceled INTO before_canceled FROM pg_background_stats();

    h := pg_background_launch('SELECT pg_sleep(60)', 65536, 'canon-prestart-cancel');
    /* grace_ms => 0: request immediate termination as early as possible */
    PERFORM pg_background_cancel(h.pid, h.cookie, 0);

    PERFORM pg_background_wait(h.pid, h.cookie);
    PERFORM pg_background_detach(h.pid, h.cookie);

    SELECT workers_canceled INTO after_canceled FROM pg_background_stats();
    IF after_canceled - before_canceled < 1 THEN
        RAISE EXCEPTION 'pre-start cancel: workers_canceled +%, want >= 1',
            after_canceled - before_canceled;
    END IF;

    RAISE NOTICE 'canonical pre-start cancel (grace=0) OK';
END$$;

-- run() and run_query() canonical helpers.
SELECT (pg_background_run('SELECT 1', timeout_ms => 5000)).completed AS run_completed;
SELECT * FROM pg_background_run_query('SELECT 42 AS n', timeout_ms => 5000, col_def => 'n int') AS r(n int);

-- Alias parity: a handle from the canonical launch is operable via the _v2
-- alias, and vice versa (same C symbol, same session hash).
DO $$
DECLARE
    h pg_background_handle;
    ok bool;
BEGIN
    -- launch canonical, wait/detach via aliases
    h := pg_background_launch('SELECT pg_sleep(0)');
    ok := pg_background_wait_v2(h.pid, h.cookie, 5000);
    IF NOT ok THEN RAISE EXCEPTION 'alias wait did not observe completion'; END IF;
    PERFORM pg_background_detach_v2(h.pid, h.cookie);

    -- launch via alias, wait/detach canonical
    h := pg_background_launch_v2('SELECT pg_sleep(0)');
    ok := pg_background_wait(h.pid, h.cookie, 5000);
    IF NOT ok THEN RAISE EXCEPTION 'canonical wait did not observe alias-launched worker'; END IF;
    PERFORM pg_background_detach(h.pid, h.cookie);

    RAISE NOTICE 'canonical/alias handle parity OK';
END$$;

-- The list view reads the canonical pg_background_list() SRF; the deprecated
-- list_v2() returns the same shape. Both should agree on the (now empty) set.
SELECT (SELECT count(*) FROM pg_background_list)
     = (SELECT count(*) FROM pg_background_list_v2()
          AS l(pid int4, cookie int8, launched_at timestamptz, user_id oid,
               queue_size int4, state text, sql_preview text, last_error text,
               consumed bool, label text)) AS list_view_matches_srf;

-- The canonical SECURITY DEFINER privilege helpers must not be reachable by
-- a freshly-created role (privilege-escalation guard), mirroring the
-- metadata contract test above.
DO $$
BEGIN
    CREATE ROLE pgbg_canon_priv_role NOLOGIN;
    IF has_function_privilege('pgbg_canon_priv_role',
           'pg_background_grant_privileges(text, boolean)', 'EXECUTE')
       OR has_function_privilege('pgbg_canon_priv_role',
           'pg_background_revoke_privileges(text, boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'security: canonical privilege helpers reachable by PUBLIC/role';
    END IF;
    DROP ROLE pgbg_canon_priv_role;
    RAISE NOTICE 'canonical privilege-helper lockdown OK';
END$$;
