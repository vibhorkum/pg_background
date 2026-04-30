-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION pg_background UPDATE" to load this file. \quit

-- ----------------------------------------------------------------------
-- 1.4 -> 1.6 upgrade
--   - Add v2 handle + v2 API functions
--   - Harden privilege helpers to grant only extension objects
--   - Lock down PUBLIC on all extension objects
-- ----------------------------------------------------------------------

-- 1) v2 handle type
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

-- 2) v2 functions (1.6 API surface)
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

-- cancel (no overload ambiguity in 1.6)
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

-- wait
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

-- list (record; caller supplies coldeflist)
CREATE OR REPLACE FUNCTION pg_background_list_v2()
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME', 'pg_background_list_v2'
LANGUAGE C;

-- 3) privilege helper functions
--    - SECURITY DEFINER, but pinned search_path to avoid hijacking
--    - Grants only extension objects (v1 + v2 + handle type)
CREATE OR REPLACE FUNCTION grant_pg_background_privileges(
    user_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    _sql text;
BEGIN
    -- v1
    _sql := format(
      'GRANT EXECUTE ON FUNCTION public.pg_background_launch(pg_catalog.text, pg_catalog.int4) TO %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'GRANT EXECUTE ON FUNCTION public.pg_background_result(pg_catalog.int4) TO %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'GRANT EXECUTE ON FUNCTION public.pg_background_detach(pg_catalog.int4) TO %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v2 type
    _sql := format(
      'GRANT USAGE ON TYPE public.pg_background_handle TO %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v2 functions
    _sql := format(
      'GRANT EXECUTE ON FUNCTION public.pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) TO %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'GRANT EXECUTE ON FUNCTION public.pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) TO %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'GRANT EXECUTE ON FUNCTION public.pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) TO %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'GRANT EXECUTE ON FUNCTION public.pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) TO %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'GRANT EXECUTE ON FUNCTION public.pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8) TO %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'GRANT EXECUTE ON FUNCTION public.pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) TO %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'GRANT EXECUTE ON FUNCTION public.pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8) TO %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'GRANT EXECUTE ON FUNCTION public.pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) TO %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'GRANT EXECUTE ON FUNCTION public.pg_background_list_v2() TO %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    RETURN TRUE;

EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error granting pg_background privileges to %: %', user_name, SQLERRM;
    RETURN FALSE;
END;
$function$;

CREATE OR REPLACE FUNCTION revoke_pg_background_privileges(
    user_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    _sql text;
BEGIN
    -- v2 first
    _sql := format(
      'REVOKE EXECUTE ON FUNCTION public.pg_background_list_v2() FROM %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'REVOKE EXECUTE ON FUNCTION public.pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'REVOKE EXECUTE ON FUNCTION public.pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8) FROM %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'REVOKE EXECUTE ON FUNCTION public.pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'REVOKE EXECUTE ON FUNCTION public.pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8) FROM %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'REVOKE EXECUTE ON FUNCTION public.pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) FROM %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'REVOKE EXECUTE ON FUNCTION public.pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) FROM %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'REVOKE EXECUTE ON FUNCTION public.pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) FROM %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'REVOKE EXECUTE ON FUNCTION public.pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) FROM %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'REVOKE USAGE ON TYPE public.pg_background_handle FROM %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    -- v1
    _sql := format(
      'REVOKE EXECUTE ON FUNCTION public.pg_background_detach(pg_catalog.int4) FROM %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'REVOKE EXECUTE ON FUNCTION public.pg_background_result(pg_catalog.int4) FROM %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    _sql := format(
      'REVOKE EXECUTE ON FUNCTION public.pg_background_launch(pg_catalog.text, pg_catalog.int4) FROM %I',
      user_name
    );
    EXECUTE _sql;
    IF print_commands THEN RAISE INFO '%', _sql; END IF;

    RETURN TRUE;

EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error revoking pg_background privileges from %: %', user_name, SQLERRM;
    RETURN FALSE;
END;
$function$;

-- 4) lock down helper functions + extension objects from PUBLIC
REVOKE ALL ON FUNCTION public.revoke_pg_background_privileges(pg_catalog.text, boolean)
  FROM public;
REVOKE ALL ON FUNCTION public.grant_pg_background_privileges(pg_catalog.text, boolean)
  FROM public;

REVOKE ALL ON FUNCTION public.pg_background_launch(pg_catalog.text, pg_catalog.int4)
  FROM public;
REVOKE ALL ON FUNCTION public.pg_background_result(pg_catalog.int4)
  FROM public;
REVOKE ALL ON FUNCTION public.pg_background_detach(pg_catalog.int4)
  FROM public;

REVOKE ALL ON TYPE public.pg_background_handle
  FROM public;

REVOKE ALL ON FUNCTION public.pg_background_launch_v2(pg_catalog.text, pg_catalog.int4)
  FROM public;
REVOKE ALL ON FUNCTION public.pg_background_submit_v2(pg_catalog.text, pg_catalog.int4)
  FROM public;
REVOKE ALL ON FUNCTION public.pg_background_result_v2(pg_catalog.int4, pg_catalog.int8)
  FROM public;
REVOKE ALL ON FUNCTION public.pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8)
  FROM public;
REVOKE ALL ON FUNCTION public.pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8)
  FROM public;
REVOKE ALL ON FUNCTION public.pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4)
  FROM public;
REVOKE ALL ON FUNCTION public.pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8)
  FROM public;
REVOKE ALL ON FUNCTION public.pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4)
  FROM public;
REVOKE ALL ON FUNCTION public.pg_background_list_v2()
  FROM public;
