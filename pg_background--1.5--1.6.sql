-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION pg_background UPDATE" to load this file. \quit

-- ----------------------------------------------------------------------
-- 1.5 -> 1.6 upgrade
-- ----------------------------------------------------------------------

-- v2 handle type (create if missing)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public'
      AND t.typname = 'pg_background_handle'
  ) THEN
    CREATE TYPE public.pg_background_handle AS (
      pid    pg_catalog.int4,
      cookie pg_catalog.int8
    );
  END IF;
END
$$;

-- v2 functions
CREATE OR REPLACE FUNCTION pg_background_launch_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 65536
)
RETURNS public.pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_launch_v2'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION pg_background_submit_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 65536
)
RETURNS public.pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_submit_v2'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION pg_background_result_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME', 'pg_background_result_v2'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION pg_background_detach_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_detach_v2'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION pg_background_cancel_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_cancel_v2'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION pg_background_cancel_v2_grace(
    pid pg_catalog.int4,
    cookie pg_catalog.int8,
    grace_ms pg_catalog.int4
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_cancel_v2_grace'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION pg_background_wait_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_wait_v2'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION pg_background_wait_v2_timeout(
    pid pg_catalog.int4,
    cookie pg_catalog.int8,
    timeout_ms pg_catalog.int4
)
RETURNS pg_catalog.bool
AS 'MODULE_PATHNAME', 'pg_background_wait_v2_timeout'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION pg_background_list_v2()
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME', 'pg_background_list_v2'
LANGUAGE C;

-- role (NOLOGIN)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbackground_role') THEN
    CREATE ROLE pgbackground_role NOLOGIN INHERIT;
  END IF;
END
$$;

-- replace helpers (same as 1.6)
CREATE OR REPLACE FUNCTION grant_pg_background_privileges(
    role_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE _sql text;
BEGIN
    _sql := format('GRANT EXECUTE ON FUNCTION public.pg_background_launch(pg_catalog.text, pg_catalog.int4) TO %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION public.pg_background_result(pg_catalog.int4) TO %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION public.pg_background_detach(pg_catalog.int4) TO %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT USAGE ON TYPE public.pg_background_handle TO %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION public.pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) TO %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION public.pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) TO %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION public.pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) TO %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION public.pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) TO %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION public.pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8) TO %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION public.pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) TO %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION public.pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8) TO %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION public.pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) TO %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('GRANT EXECUTE ON FUNCTION public.pg_background_list_v2() TO %I', role_name);
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
DECLARE _sql text;
BEGIN
    _sql := format('REVOKE EXECUTE ON FUNCTION public.pg_background_list_v2() FROM %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION public.pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION public.pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION public.pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION public.pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION public.pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION public.pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION public.pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) FROM %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION public.pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) FROM %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE USAGE ON TYPE public.pg_background_handle FROM %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION public.pg_background_detach(pg_catalog.int4) FROM %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION public.pg_background_result(pg_catalog.int4) FROM %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format('REVOKE EXECUTE ON FUNCTION public.pg_background_launch(pg_catalog.text, pg_catalog.int4) FROM %I', role_name);
    EXECUTE _sql; IF print_commands THEN RAISE INFO '%', _sql; END IF;

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error revoking pg_background privileges from %: %', role_name, SQLERRM;
    RETURN FALSE;
END;
$function$;

-- grant executor role privileges
SELECT public.grant_pg_background_privileges('pgbackground_role', false);

-- lock down helpers
REVOKE ALL ON FUNCTION public.grant_pg_background_privileges(pg_catalog.text, boolean) FROM public;
REVOKE ALL ON FUNCTION public.revoke_pg_background_privileges(pg_catalog.text, boolean) FROM public;

-- lock down extension objects from PUBLIC
REVOKE ALL ON FUNCTION public.pg_background_launch(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION public.pg_background_result(pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION public.pg_background_detach(pg_catalog.int4) FROM public;

REVOKE ALL ON TYPE public.pg_background_handle FROM public;

REVOKE ALL ON FUNCTION public.pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION public.pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION public.pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION public.pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION public.pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION public.pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION public.pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION public.pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION public.pg_background_list_v2() FROM public;

-- optional helper (same as 1.6)
CREATE OR REPLACE FUNCTION pg_background_drop_executor_role()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbackground_role') THEN
    EXECUTE 'DROP ROLE pgbackground_role';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.pg_background_drop_executor_role() FROM public;
