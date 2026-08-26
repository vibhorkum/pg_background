-- pg_background upgrade script: 1.8 -> 1.9
-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_background UPDATE TO '1.9'" to load this file. \quit

-- ----------------------------------------------------------------------
-- pg_background 1.9
--   - NEW: Worker labels for operational clarity
--   - NEW: Structured error returns (pg_background_error type)
--   - NEW: Result metadata (pg_background_result_info type)
--   - NEW: Batch operations (detach_all_v2, cancel_all_v2)
--   - ENHANCED: launch_v2/submit_v2 accept optional label parameter
-- ----------------------------------------------------------------------

-- ----------------------------------------------------------------------
-- New composite types for observability
-- ----------------------------------------------------------------------

CREATE TYPE pg_background_result_info AS (
    row_count       pg_catalog.int8,
    command_tag     pg_catalog.text,
    completed       pg_catalog.bool,
    has_error       pg_catalog.bool
);

CREATE TYPE pg_background_error AS (
    sqlstate        pg_catalog.text,
    message         pg_catalog.text,
    detail          pg_catalog.text,
    hint            pg_catalog.text,
    context         pg_catalog.text
);

-- ----------------------------------------------------------------------
-- Add 3-arg overload for launch_v2 with label parameter
-- NOTE: We preserve the existing 2-arg function to maintain grants/OIDs.
-- The C function handles both signatures via PG_NARGS().
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_launch_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4,
    label pg_catalog.text
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_launch_v2'
LANGUAGE C;

-- ----------------------------------------------------------------------
-- Add 3-arg overload for submit_v2 with label parameter
-- NOTE: We preserve the existing 2-arg function to maintain grants/OIDs.
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_submit_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4,
    label pg_catalog.text
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_submit_v2'
LANGUAGE C;

-- ----------------------------------------------------------------------
-- New observability functions
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_result_info_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_background_result_info
AS 'MODULE_PATHNAME', 'pg_background_result_info_v2'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pg_background_result_info_v2(pg_catalog.int4, pg_catalog.int8) IS
'Get result metadata (row_count, command_tag, completed, has_error) without consuming results.';

CREATE FUNCTION pg_background_error_info_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_background_error
AS 'MODULE_PATHNAME', 'pg_background_error_info_v2'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pg_background_error_info_v2(pg_catalog.int4, pg_catalog.int8) IS
'Get structured error information (sqlstate, message, detail, hint, context) from a worker. Returns NULL if no error.';

-- ----------------------------------------------------------------------
-- Batch operations
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_detach_all_v2()
RETURNS pg_catalog.int4
AS 'MODULE_PATHNAME', 'pg_background_detach_all_v2'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_detach_all_v2() IS
'Detach all tracked workers in the current session. Returns number of workers detached.';

CREATE FUNCTION pg_background_cancel_all_v2()
RETURNS pg_catalog.int4
AS 'MODULE_PATHNAME', 'pg_background_cancel_all_v2'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_cancel_all_v2() IS
'Cancel all running workers in the current session. Returns number of workers for which cancel was requested.';

-- ----------------------------------------------------------------------
-- Lock down PUBLIC on new objects
-- ----------------------------------------------------------------------

REVOKE ALL ON TYPE pg_background_result_info FROM public;
REVOKE ALL ON TYPE pg_background_error FROM public;
REVOKE ALL ON FUNCTION pg_background_launch_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.text) FROM public;
REVOKE ALL ON FUNCTION pg_background_submit_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.text) FROM public;
REVOKE ALL ON FUNCTION pg_background_result_info_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_error_info_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_detach_all_v2() FROM public;
REVOKE ALL ON FUNCTION pg_background_cancel_all_v2() FROM public;

-- ----------------------------------------------------------------------
-- Update privilege helper to include new functions and types
-- ----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION grant_pg_background_privileges(
    role_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
    _sql pg_catalog.text;
    _schema pg_catalog.text;
BEGIN
    -- Get the schema where this extension is installed
    SELECT n.nspname INTO _schema
    FROM pg_catalog.pg_extension e
    JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_background';

    IF _schema IS NULL THEN
        RAISE EXCEPTION 'pg_background extension not found';
    END IF;

    -- v1
    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_launch(pg_catalog.text, pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_result(pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_detach(pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v2 types
    _sql := pg_catalog.format('GRANT USAGE ON TYPE %I.pg_background_handle TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT USAGE ON TYPE %I.pg_background_stats TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT USAGE ON TYPE %I.pg_background_progress TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v1.9 types
    _sql := pg_catalog.format('GRANT USAGE ON TYPE %I.pg_background_result_info TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT USAGE ON TYPE %I.pg_background_error TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v2 launch/submit (both 2-arg from 1.8 and 3-arg with label from 1.9)
    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_launch_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.text) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_submit_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.text) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_list_v2() TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v2 stats and progress (from 1.8)
    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_stats_v2() TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_progress(pg_catalog.int4, pg_catalog.text) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_get_progress_v2(pg_catalog.int4, pg_catalog.int8) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v1.9 new functions
    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_result_info_v2(pg_catalog.int4, pg_catalog.int8) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_error_info_v2(pg_catalog.int4, pg_catalog.int8) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_detach_all_v2() TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %I.pg_background_cancel_all_v2() TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error granting pg_background privileges to %: %', role_name, SQLERRM;
    RETURN FALSE;
END;
$function$;

CREATE OR REPLACE FUNCTION revoke_pg_background_privileges(
    role_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
    _sql pg_catalog.text;
    _schema pg_catalog.text;
BEGIN
    -- Get the schema where this extension is installed
    SELECT n.nspname INTO _schema
    FROM pg_catalog.pg_extension e
    JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_background';

    IF _schema IS NULL THEN
        RAISE EXCEPTION 'pg_background extension not found';
    END IF;

    -- v1.9 new functions first
    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_cancel_all_v2() FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_detach_all_v2() FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_error_info_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_result_info_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v2 stats and progress
    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_get_progress_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_progress(pg_catalog.int4, pg_catalog.text) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_stats_v2() FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v2
    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_list_v2() FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v2 launch/submit (both 2-arg from 1.8 and 3-arg with label from 1.9)
    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_submit_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.text) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_launch_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.text) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v1.9 types
    _sql := pg_catalog.format('REVOKE USAGE ON TYPE %I.pg_background_error FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE USAGE ON TYPE %I.pg_background_result_info FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE USAGE ON TYPE %I.pg_background_progress FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE USAGE ON TYPE %I.pg_background_stats FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE USAGE ON TYPE %I.pg_background_handle FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v1
    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_detach(pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_result(pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %I.pg_background_launch(pg_catalog.text, pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error revoking pg_background privileges from %: %', role_name, SQLERRM;
    RETURN FALSE;
END;
$function$;

-- Grant new privileges to pgbackground_role
SELECT grant_pg_background_privileges('pgbackground_role', false);
