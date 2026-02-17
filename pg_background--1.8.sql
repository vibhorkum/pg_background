-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_background" to load this file. \quit

-- ----------------------------------------------------------------------
-- pg_background 1.8
--   - v1 API (unchanged)
--   - v2 API (handle + submit/cancel/wait/list)
--   - hardened privilege model via a NOLOGIN role
--   - NEW: pg_background_stats_v2() - session statistics
--   - NEW: pg_background_progress() - worker progress reporting
--   - NEW: pg_background_get_progress_v2() - get worker progress
--   - NEW: GUCs: max_workers, worker_timeout, default_queue_size
--   - Internal: cryptographically secure cookies (pg_strong_random)
--   - Internal: dedicated memory context (prevents session bloat)
--   - Internal: exponential backoff polling (reduces CPU usage)
--   - Internal: max workers limit enforcement
--   - Internal: UTF-8 aware truncation
--   - FIX: Support custom schema installation (relocatable)
-- ----------------------------------------------------------------------

-- ----------------------------------------------------------------------
-- v1 API (unchanged)
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_launch(
    sql pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 0
)
RETURNS pg_catalog.int4
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_result(
    pid pg_catalog.int4
)
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_detach(
    pid pg_catalog.int4
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

-- ----------------------------------------------------------------------
-- v2 handle type
-- ----------------------------------------------------------------------

CREATE TYPE pg_background_handle AS (
  pid    pg_catalog.int4,
  cookie pg_catalog.int8
);

-- ----------------------------------------------------------------------
-- v2 API
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_launch_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 0
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_launch_v2'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_submit_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 0
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_submit_v2'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_result_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME', 'pg_background_result_v2'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_detach_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_detach_v2'
LANGUAGE C STRICT;

-- cancel (no overload ambiguity)
CREATE FUNCTION pg_background_cancel_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_cancel_v2'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_cancel_v2_grace(
    pid pg_catalog.int4,
    cookie pg_catalog.int8,
    grace_ms pg_catalog.int4
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_cancel_v2_grace'
LANGUAGE C STRICT;

-- wait
CREATE FUNCTION pg_background_wait_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_wait_v2'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_wait_v2_timeout(
    pid pg_catalog.int4,
    cookie pg_catalog.int8,
    timeout_ms pg_catalog.int4
)
RETURNS pg_catalog.bool
AS 'MODULE_PATHNAME', 'pg_background_wait_v2_timeout'
LANGUAGE C STRICT;

-- list (record; call with column definition list)
CREATE FUNCTION pg_background_list_v2()
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME', 'pg_background_list_v2'
LANGUAGE C;

-- ----------------------------------------------------------------------
-- v2 statistics and progress types
-- ----------------------------------------------------------------------

CREATE TYPE pg_background_stats AS (
    workers_launched   pg_catalog.int8,
    workers_completed  pg_catalog.int8,
    workers_failed     pg_catalog.int8,
    workers_canceled   pg_catalog.int8,
    workers_active     pg_catalog.int4,
    avg_execution_ms   pg_catalog.float8,
    max_workers        pg_catalog.int4
);

CREATE TYPE pg_background_progress AS (
    progress_pct  pg_catalog.int4,
    progress_msg  pg_catalog.text
);

-- ----------------------------------------------------------------------
-- v2 statistics and progress functions
-- ----------------------------------------------------------------------

-- Statistics function
CREATE FUNCTION pg_background_stats_v2()
RETURNS pg_background_stats
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
RETURNS pg_background_progress
AS 'MODULE_PATHNAME', 'pg_background_get_progress_v2'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_get_progress_v2(pg_catalog.int4, pg_catalog.int8) IS
'Get the current progress of a background worker. Returns NULL if progress not yet reported.';

-- ----------------------------------------------------------------------
-- Role: NOLOGIN executor role for clean privilege assignment
--   - not named pg_*
--   - can be granted to users/roles by admins
-- ----------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbackground_role') THEN
    CREATE ROLE pgbackground_role NOLOGIN INHERIT;
  END IF;
END
$$;

-- ----------------------------------------------------------------------
-- Hardened privilege helpers
--   - SECURITY DEFINER
--   - pinned search_path (prevents hijacking)
--   - only grants/revokes extension objects, not all of public
--   - dynamically determines schema from pg_extension catalog
-- ----------------------------------------------------------------------

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

    -- v2 stats and progress first (new in 1.8)
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

-- by default, grant privileges to the executor role
SELECT grant_pg_background_privileges('pgbackground_role', false);

-- ----------------------------------------------------------------------
-- Lock down PUBLIC on extension objects (no ambient capabilities)
-- ----------------------------------------------------------------------

REVOKE ALL ON FUNCTION grant_pg_background_privileges(pg_catalog.text, boolean)
  FROM public;
REVOKE ALL ON FUNCTION revoke_pg_background_privileges(pg_catalog.text, boolean)
  FROM public;

REVOKE ALL ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_result(pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_detach(pg_catalog.int4) FROM public;

REVOKE ALL ON TYPE pg_background_handle FROM public;

REVOKE ALL ON FUNCTION pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_list_v2() FROM public;

REVOKE ALL ON TYPE pg_background_stats FROM public;
REVOKE ALL ON TYPE pg_background_progress FROM public;
REVOKE ALL ON FUNCTION pg_background_stats_v2() FROM public;
REVOKE ALL ON FUNCTION pg_background_progress(pg_catalog.int4, pg_catalog.text) FROM public;
REVOKE ALL ON FUNCTION pg_background_get_progress_v2(pg_catalog.int4, pg_catalog.int8) FROM public;

-- ----------------------------------------------------------------------
-- Optional: helper to drop role explicitly (because DROP EXTENSION won't)
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_background_drop_executor_role()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  -- best effort: revoke from all members is admin's responsibility if needed
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbackground_role') THEN
    EXECUTE 'DROP ROLE pgbackground_role';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION pg_background_drop_executor_role() FROM public;
