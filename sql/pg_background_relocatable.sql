-- ==========================================================================
-- pg_background Relocatable Schema Test Suite
-- ==========================================================================
-- This test validates that the extension works correctly when installed
-- in a custom schema (not public). It tests all functions, types, and
-- privilege helpers for schema relocatability.
--
-- REQUIREMENTS TESTED:
-- 1. Extension can be created in custom schema
-- 2. All v1 API functions work with schema qualification
-- 3. All v2 API functions work with schema qualification
-- 4. Composite types are accessible with schema qualification
-- 5. Privilege helpers correctly detect and use extension schema
-- 6. No hardcoded 'public.' references break functionality
-- ==========================================================================

-- ==========================================================================
-- SETUP: Create custom schema and install extension
-- ==========================================================================
\echo '============================================================'
\echo 'TEST SUITE: pg_background Relocatable Schema Validation'
\echo '============================================================'

-- Drop any existing test artifacts
DROP EXTENSION IF EXISTS pg_background CASCADE;
DROP SCHEMA IF EXISTS custom_ext CASCADE;
DROP SCHEMA IF EXISTS alt_schema CASCADE;
DROP ROLE IF EXISTS test_relocate_user;

-- Create custom schema for extension
CREATE SCHEMA custom_ext;

\echo ''
\echo '>>> Test 1: CREATE EXTENSION in custom schema'
CREATE EXTENSION pg_background WITH SCHEMA custom_ext;

-- Verify installation location
SELECT
    CASE WHEN nspname = 'custom_ext' THEN 'PASS' ELSE 'FAIL: wrong schema' END AS test_1_result,
    extname,
    extversion,
    nspname AS installed_schema
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname = 'pg_background';

-- ==========================================================================
-- TEST 2: Verify types are in custom schema
-- ==========================================================================
\echo ''
\echo '>>> Test 2: Composite types in custom schema'

-- Test pg_background_handle type
SELECT
    CASE WHEN n.nspname = 'custom_ext' THEN 'PASS' ELSE 'FAIL' END AS test_2a_handle_type,
    t.typname,
    n.nspname AS type_schema
FROM pg_type t
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE t.typname = 'pg_background_handle';

-- Test pg_background_stats type (v1.8)
SELECT
    CASE WHEN n.nspname = 'custom_ext' THEN 'PASS' ELSE 'FAIL' END AS test_2b_stats_type,
    t.typname,
    n.nspname AS type_schema
FROM pg_type t
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE t.typname = 'pg_background_stats';

-- Test pg_background_progress type (v1.8)
SELECT
    CASE WHEN n.nspname = 'custom_ext' THEN 'PASS' ELSE 'FAIL' END AS test_2c_progress_type,
    t.typname,
    n.nspname AS type_schema
FROM pg_type t
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE t.typname = 'pg_background_progress';

-- Test type construction with schema qualification
SELECT
    'PASS' AS test_2d_type_construct,
    (ROW(123, 9876543210)::custom_ext.pg_background_handle).*;

-- ==========================================================================
-- TEST 3: v1 API functions with schema qualification
-- ==========================================================================
\echo ''
\echo '>>> Test 3: v1 API functions with custom schema'

DROP TABLE IF EXISTS t_relocate_v1;
CREATE TABLE t_relocate_v1(id int, val text);

-- v1: launch with schema-qualified call
SELECT custom_ext.pg_background_launch('INSERT INTO t_relocate_v1 VALUES (1, ''v1_test'')') AS pid \gset

-- v1: result with schema-qualified call
SELECT * FROM custom_ext.pg_background_result(:pid) AS (result TEXT);

-- Verify data was inserted
SELECT
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS test_3a_v1_launch_result,
    'v1 launch/result' AS test_name
FROM t_relocate_v1 WHERE val = 'v1_test';

-- v1: detach with schema-qualified call
SELECT custom_ext.pg_background_launch('SELECT 1') AS pid2 \gset
SELECT custom_ext.pg_background_detach(:pid2);
SELECT 'PASS' AS test_3b_v1_detach, 'v1 detach completed' AS description;

-- ==========================================================================
-- TEST 4: v2 API functions with schema qualification
-- ==========================================================================
\echo ''
\echo '>>> Test 4: v2 API functions with custom schema'

DROP TABLE IF EXISTS t_relocate_v2;
CREATE TABLE t_relocate_v2(id int, val text);

-- v2: launch_v2 with schema qualification
SELECT (h).pid AS v2_pid, (h).cookie AS v2_cookie
FROM (SELECT custom_ext.pg_background_launch_v2('INSERT INTO t_relocate_v2 VALUES (1, ''v2_launch'')', 65536) AS h) s
\gset

-- v2: wait_v2 with schema qualification
SELECT custom_ext.pg_background_wait_v2(:v2_pid, :v2_cookie);
SELECT 'PASS' AS test_4a_v2_wait, 'v2 wait completed' AS description;

-- v2: result_v2 with schema qualification (note: results already consumed by wait behavior)
-- Launch another worker to test result retrieval
SELECT (h).pid AS v2r_pid, (h).cookie AS v2r_cookie
FROM (SELECT custom_ext.pg_background_launch_v2('SELECT 42 AS answer', 65536) AS h) s
\gset

SELECT custom_ext.pg_background_wait_v2(:v2r_pid, :v2r_cookie);
SELECT * FROM custom_ext.pg_background_result_v2(:v2r_pid, :v2r_cookie) AS (answer int);

-- v2: detach_v2 with schema qualification
SELECT custom_ext.pg_background_detach_v2(:v2_pid, :v2_cookie);
SELECT custom_ext.pg_background_detach_v2(:v2r_pid, :v2r_cookie);
SELECT 'PASS' AS test_4b_v2_detach, 'v2 detach completed' AS description;

-- Verify data
SELECT
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS test_4c_v2_launch_result,
    'v2 launch verified' AS description
FROM t_relocate_v2 WHERE val = 'v2_launch';

-- ==========================================================================
-- TEST 5: submit_v2 (fire-and-forget) with schema qualification
-- ==========================================================================
\echo ''
\echo '>>> Test 5: submit_v2 with custom schema'

DROP TABLE IF EXISTS t_relocate_submit;
CREATE TABLE t_relocate_submit(id int);

SELECT (h).pid AS sub_pid, (h).cookie AS sub_cookie
FROM (SELECT custom_ext.pg_background_submit_v2('INSERT INTO t_relocate_submit VALUES (99)', 65536) AS h) s
\gset

SELECT pg_sleep(0.3);

SELECT
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS test_5_submit_v2,
    'submit_v2 fire-and-forget' AS description
FROM t_relocate_submit WHERE id = 99;

-- ==========================================================================
-- TEST 6: cancel_v2 functions with schema qualification
-- ==========================================================================
\echo ''
\echo '>>> Test 6: cancel_v2 functions with custom schema'

DROP TABLE IF EXISTS t_relocate_cancel;
CREATE TABLE t_relocate_cancel(id int);

-- Launch long-running worker
SELECT (h).pid AS can_pid, (h).cookie AS can_cookie
FROM (SELECT custom_ext.pg_background_launch_v2('SELECT pg_sleep(10); INSERT INTO t_relocate_cancel VALUES (1)', 65536) AS h) s
\gset

SELECT pg_sleep(0.2);

-- cancel_v2 with schema qualification
SELECT custom_ext.pg_background_cancel_v2(:can_pid, :can_cookie);
SELECT pg_sleep(0.3);

SELECT
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS test_6a_cancel_v2,
    'cancel_v2 prevented insert' AS description
FROM t_relocate_cancel;

SELECT custom_ext.pg_background_detach_v2(:can_pid, :can_cookie);

-- cancel_v2_grace with schema qualification
SELECT (h).pid AS cang_pid, (h).cookie AS cang_cookie
FROM (SELECT custom_ext.pg_background_launch_v2('SELECT pg_sleep(10); INSERT INTO t_relocate_cancel VALUES (2)', 65536) AS h) s
\gset

SELECT pg_sleep(0.2);
SELECT custom_ext.pg_background_cancel_v2_grace(:cang_pid, :cang_cookie, 500);
SELECT pg_sleep(0.5);

SELECT
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS test_6b_cancel_v2_grace,
    'cancel_v2_grace prevented insert' AS description
FROM t_relocate_cancel WHERE id = 2;

SELECT custom_ext.pg_background_detach_v2(:cang_pid, :cang_cookie);

-- ==========================================================================
-- TEST 7: wait_v2_timeout with schema qualification
-- ==========================================================================
\echo ''
\echo '>>> Test 7: wait_v2_timeout with custom schema'

SELECT (h).pid AS wt_pid, (h).cookie AS wt_cookie
FROM (SELECT custom_ext.pg_background_launch_v2('SELECT pg_sleep(0.5)', 65536) AS h) s
\gset

-- Short timeout should return false
SELECT
    CASE WHEN NOT custom_ext.pg_background_wait_v2_timeout(:wt_pid, :wt_cookie, 100) THEN 'PASS' ELSE 'FAIL' END AS test_7a_timeout_short;

-- Long timeout should return true
SELECT
    CASE WHEN custom_ext.pg_background_wait_v2_timeout(:wt_pid, :wt_cookie, 5000) THEN 'PASS' ELSE 'FAIL' END AS test_7b_timeout_long;

SELECT custom_ext.pg_background_detach_v2(:wt_pid, :wt_cookie);

-- ==========================================================================
-- TEST 8: list_v2 with schema qualification
-- ==========================================================================
\echo ''
\echo '>>> Test 8: list_v2 with custom schema'

-- Launch a worker to list
SELECT (h).pid AS lst_pid, (h).cookie AS lst_cookie
FROM (SELECT custom_ext.pg_background_launch_v2('SELECT pg_sleep(1)', 65536) AS h) s
\gset

SELECT pg_sleep(0.1);

-- list_v2 with schema qualification
SELECT
    CASE WHEN count(*) >= 1 THEN 'PASS' ELSE 'FAIL' END AS test_8_list_v2,
    'list_v2 shows workers' AS description
FROM custom_ext.pg_background_list_v2()
  AS (pid int4, cookie int8, launched_at timestamptz, user_id oid,
      queue_size int4, state text, sql_preview text, last_error text, consumed bool)
WHERE pid = :lst_pid AND cookie = :lst_cookie;

SELECT custom_ext.pg_background_cancel_v2(:lst_pid, :lst_cookie);
SELECT pg_sleep(0.2);
SELECT custom_ext.pg_background_detach_v2(:lst_pid, :lst_cookie);

-- ==========================================================================
-- TEST 9: stats_v2 with schema qualification (v1.8)
-- ==========================================================================
\echo ''
\echo '>>> Test 9: stats_v2 with custom schema (v1.8)'

SELECT
    CASE
        WHEN workers_launched > 0 AND max_workers > 0 THEN 'PASS'
        ELSE 'FAIL'
    END AS test_9_stats_v2,
    workers_launched,
    workers_completed,
    workers_canceled,
    max_workers
FROM custom_ext.pg_background_stats_v2();

-- ==========================================================================
-- TEST 10: progress functions with schema qualification (v1.8)
-- ==========================================================================
\echo ''
\echo '>>> Test 10: progress reporting with custom schema (v1.8)'

SELECT (h).pid AS prg_pid, (h).cookie AS prg_cookie
FROM (SELECT custom_ext.pg_background_launch_v2($$
    SELECT custom_ext.pg_background_progress(25, 'Quarter done');
    SELECT pg_sleep(0.2);
    SELECT custom_ext.pg_background_progress(100, 'Complete');
$$, 65536) AS h) s
\gset

SELECT pg_sleep(0.15);

-- get_progress_v2 with schema qualification
SELECT
    CASE WHEN progress_pct >= 0 THEN 'PASS' ELSE 'FAIL' END AS test_10_progress,
    progress_pct,
    progress_msg
FROM custom_ext.pg_background_get_progress_v2(:prg_pid, :prg_cookie);

SELECT custom_ext.pg_background_wait_v2_timeout(:prg_pid, :prg_cookie, 5000);
SELECT custom_ext.pg_background_detach_v2(:prg_pid, :prg_cookie);

-- ==========================================================================
-- TEST 11: Privilege helper functions with custom schema
-- ==========================================================================
\echo ''
\echo '>>> Test 11: Privilege helpers with custom schema'

-- Create test role
CREATE ROLE test_relocate_user NOLOGIN;

-- grant_pg_background_privileges with schema qualification
-- This tests that the helper correctly detects the extension schema
SELECT
    CASE WHEN custom_ext.grant_pg_background_privileges('test_relocate_user', false) THEN 'PASS' ELSE 'FAIL' END AS test_11a_grant_privileges;

-- Verify grants were applied (check one function as sample)
SELECT
    CASE WHEN has_function_privilege('test_relocate_user', 'custom_ext.pg_background_launch_v2(text, int4)', 'EXECUTE') THEN 'PASS' ELSE 'FAIL' END AS test_11b_verify_grant,
    'Function privilege granted' AS description;

-- revoke_pg_background_privileges with schema qualification
SELECT
    CASE WHEN custom_ext.revoke_pg_background_privileges('test_relocate_user', false) THEN 'PASS' ELSE 'FAIL' END AS test_11c_revoke_privileges;

-- Verify revoke was applied
SELECT
    CASE WHEN NOT has_function_privilege('test_relocate_user', 'custom_ext.pg_background_launch_v2(text, int4)', 'EXECUTE') THEN 'PASS' ELSE 'FAIL' END AS test_11d_verify_revoke,
    'Function privilege revoked' AS description;

-- ==========================================================================
-- TEST 12: Using DO blocks with custom schema types
-- ==========================================================================
\echo ''
\echo '>>> Test 12: DO blocks with custom schema types'

DROP TABLE IF EXISTS t_relocate_do;
CREATE TABLE t_relocate_do(id int);

-- This tests that composite types work in PL/pgSQL with schema qualification
DO $$
DECLARE
    h custom_ext.pg_background_handle;
BEGIN
    SELECT * INTO h FROM custom_ext.pg_background_launch_v2('INSERT INTO t_relocate_do VALUES (42)', 65536);
    PERFORM custom_ext.pg_background_wait_v2(h.pid, h.cookie);
    PERFORM custom_ext.pg_background_detach_v2(h.pid, h.cookie);
END;
$$;

SELECT
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS test_12_do_block,
    'DO block with custom schema type' AS description
FROM t_relocate_do WHERE id = 42;

-- ==========================================================================
-- TEST 13: Extension works WITHOUT schema in search_path
-- ==========================================================================
\echo ''
\echo '>>> Test 13: Works without custom schema in search_path'

-- Ensure custom_ext is NOT in search_path
SET search_path = public;
SHOW search_path;

DROP TABLE IF EXISTS t_relocate_searchpath;
CREATE TABLE t_relocate_searchpath(id int);

-- Must use fully qualified names
SELECT (h).pid AS sp_pid, (h).cookie AS sp_cookie
FROM (SELECT custom_ext.pg_background_launch_v2('INSERT INTO t_relocate_searchpath VALUES (123)', 65536) AS h) s
\gset

SELECT custom_ext.pg_background_wait_v2(:sp_pid, :sp_cookie);
SELECT custom_ext.pg_background_detach_v2(:sp_pid, :sp_cookie);

SELECT
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS test_13_no_searchpath,
    'Works without schema in search_path' AS description
FROM t_relocate_searchpath WHERE id = 123;

-- ==========================================================================
-- TEST 14: Extension works WITH schema in search_path
-- ==========================================================================
\echo ''
\echo '>>> Test 14: Works with custom schema in search_path'

SET search_path = custom_ext, public;
SHOW search_path;

DROP TABLE IF EXISTS t_relocate_withpath;
CREATE TABLE t_relocate_withpath(id int);

-- Can use unqualified names when in search_path
SELECT (h).pid AS wp_pid, (h).cookie AS wp_cookie
FROM (SELECT pg_background_launch_v2('INSERT INTO t_relocate_withpath VALUES (456)', 65536) AS h) s
\gset

SELECT pg_background_wait_v2(:wp_pid, :wp_cookie);
SELECT pg_background_detach_v2(:wp_pid, :wp_cookie);

SELECT
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS test_14_with_searchpath,
    'Works with schema in search_path' AS description
FROM t_relocate_withpath WHERE id = 456;

-- Reset search_path
RESET search_path;

-- ==========================================================================
-- TEST 15: pgbackground_role exists and has privileges
-- ==========================================================================
\echo ''
\echo '>>> Test 15: pgbackground_role setup'

SELECT
    CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbackground_role') THEN 'PASS' ELSE 'FAIL' END AS test_15a_role_exists;

-- Verify role has execute privilege on functions
SELECT
    CASE WHEN has_function_privilege('pgbackground_role', 'custom_ext.pg_background_launch_v2(text, int4)', 'EXECUTE') THEN 'PASS' ELSE 'FAIL' END AS test_15b_role_has_privileges;

-- ==========================================================================
-- TEST 16: Verify no PUBLIC access (security)
-- ==========================================================================
\echo ''
\echo '>>> Test 16: No PUBLIC access (security hardening)'

SELECT
    CASE WHEN NOT has_function_privilege('public', 'custom_ext.pg_background_launch_v2(text, int4)', 'EXECUTE') THEN 'PASS' ELSE 'FAIL' END AS test_16_no_public_access,
    'PUBLIC has no execute privilege' AS description;

-- ==========================================================================
-- CLEANUP & SUMMARY
-- ==========================================================================
\echo ''
\echo '>>> Cleanup'

-- Cleanup all workers
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT *
        FROM custom_ext.pg_background_list_v2()
        AS (pid int4, cookie int8, launched_at timestamptz, user_id oid,
            queue_size int4, state text, sql_preview text, last_error text, consumed bool)
    LOOP
        BEGIN
            PERFORM custom_ext.pg_background_cancel_v2(r.pid, r.cookie);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        BEGIN
            PERFORM custom_ext.pg_background_detach_v2(r.pid, r.cookie);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;
END;
$$;

-- Show final stats
\echo ''
\echo '>>> Final Statistics'
SELECT * FROM custom_ext.pg_background_stats_v2();

-- Drop test artifacts
DROP TABLE IF EXISTS t_relocate_v1;
DROP TABLE IF EXISTS t_relocate_v2;
DROP TABLE IF EXISTS t_relocate_submit;
DROP TABLE IF EXISTS t_relocate_cancel;
DROP TABLE IF EXISTS t_relocate_do;
DROP TABLE IF EXISTS t_relocate_searchpath;
DROP TABLE IF EXISTS t_relocate_withpath;
DROP ROLE IF EXISTS test_relocate_user;

\echo ''
\echo '============================================================'
\echo 'RELOCATABLE SCHEMA TEST SUITE COMPLETE'
\echo '============================================================'
\echo ''
\echo 'If all tests show PASS, the extension is fully relocatable.'
\echo 'Any FAIL results indicate hardcoded schema dependencies.'
\echo '============================================================'
