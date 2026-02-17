-- pg_background 1.7 -> 1.8 upgrade script
\echo Use "ALTER EXTENSION pg_background UPDATE TO '1.8'" to load this file. \quit

-- ----------------------------------------------------------------------
-- pg_background 1.8 additions:
--   - pg_background_stats_v2(): Session statistics
--   - pg_background_progress(pct, msg): Worker progress reporting
--   - pg_background_get_progress_v2(pid, cookie): Get worker progress
--   - GUCs: pg_background.max_workers, pg_background.worker_timeout
--   - FIX: Support custom schema installation (relocatable)
-- ----------------------------------------------------------------------

-- Return types for new functions
CREATE TYPE @extschema@.pg_background_stats AS (
    workers_launched   pg_catalog.int8,
    workers_completed  pg_catalog.int8,
    workers_failed     pg_catalog.int8,
    workers_canceled   pg_catalog.int8,
    workers_active     pg_catalog.int4,
    avg_execution_ms   pg_catalog.float8,
    max_workers        pg_catalog.int4
);

CREATE TYPE @extschema@.pg_background_progress AS (
    progress_pct  pg_catalog.int4,
    progress_msg  pg_catalog.text
);

-- Statistics function
CREATE FUNCTION pg_background_stats_v2()
RETURNS @extschema@.pg_background_stats
AS 'MODULE_PATHNAME', 'pg_background_stats_v2'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_stats_v2() IS
'Returns session-local statistics about background workers: launched, completed, failed, canceled, active count, and average execution time.';

-- Progress reporting (called from worker SQL)
CREATE FUNCTION pg_background_progress(
    pct pg_catalog.int4,
    msg pg_catalog.text DEFAULT NULL
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_progress'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_progress(pg_catalog.int4, pg_catalog.text) IS
'Report progress from within a background worker. Call from your SQL: SELECT pg_background_progress(50, ''Halfway done'');';

-- Progress retrieval
CREATE FUNCTION pg_background_get_progress_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS @extschema@.pg_background_progress
AS 'MODULE_PATHNAME', 'pg_background_get_progress_v2'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_get_progress_v2(pg_catalog.int4, pg_catalog.int8) IS
'Get the current progress of a background worker. Returns NULL if progress not yet reported.';

-- Update grant helper to include new functions and use dynamic schema lookup
CREATE OR REPLACE FUNCTION grant_pg_background_privileges(
    role_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    _sql text;
    _schema text;
BEGIN
    -- Get the schema where this extension is installed
    SELECT n.nspname INTO _schema
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_background';

    IF _schema IS NULL THEN
        RAISE EXCEPTION 'pg_background extension not found';
    END IF;

    -- v1
    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_launch(pg_catalog.text, pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_result(pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_detach(pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v2 types
    _sql := format('GRANT USAGE ON TYPE %I.pg_background_handle TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT USAGE ON TYPE %I.pg_background_stats TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT USAGE ON TYPE %I.pg_background_progress TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v2
    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_list_v2() TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v2 stats and progress (new in 1.8)
    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_stats_v2() TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_progress(pg_catalog.int4, pg_catalog.text) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION %I.pg_background_get_progress_v2(pg_catalog.int4, pg_catalog.int8) TO %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error granting pg_background privileges to %: %', role_name, SQLERRM;
    RETURN FALSE;
END;
$function$;

-- Update revoke helper to use dynamic schema lookup
CREATE OR REPLACE FUNCTION revoke_pg_background_privileges(
    role_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    _sql text;
    _schema text;
BEGIN
    -- Get the schema where this extension is installed
    SELECT n.nspname INTO _schema
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_background';

    IF _schema IS NULL THEN
        RAISE EXCEPTION 'pg_background extension not found';
    END IF;

    -- v2 stats and progress (new in 1.8)
    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_get_progress_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_progress(pg_catalog.int4, pg_catalog.text) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_stats_v2() FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v2
    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_list_v2() FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE USAGE ON TYPE %I.pg_background_progress FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE USAGE ON TYPE %I.pg_background_stats FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE USAGE ON TYPE %I.pg_background_handle FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v1
    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_detach(pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_result(pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION %I.pg_background_launch(pg_catalog.text, pg_catalog.int4) FROM %I', _schema, role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error revoking pg_background privileges from %: %', role_name, SQLERRM;
    RETURN FALSE;
END;
$function$;

-- Grant new functions to the executor role
SELECT @extschema@.grant_pg_background_privileges('pgbackground_role', false);

-- Lock down PUBLIC on new extension objects
REVOKE ALL ON TYPE @extschema@.pg_background_stats FROM public;
REVOKE ALL ON TYPE @extschema@.pg_background_progress FROM public;
REVOKE ALL ON FUNCTION @extschema@.pg_background_stats_v2() FROM public;
REVOKE ALL ON FUNCTION @extschema@.pg_background_progress(pg_catalog.int4, pg_catalog.text) FROM public;
REVOKE ALL ON FUNCTION @extschema@.pg_background_get_progress_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
