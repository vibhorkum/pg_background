-- pg_background--1.4--1.5.sql

-- 1) Add handle type (idempotent)
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
END;
$$;

-- pg_background--1.5--1.6.sql

-- Add wait/status/cancel (additive)

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'pg_background_status'
  ) THEN
    CREATE TYPE public.pg_background_status AS (
      pid        pg_catalog.int4,
      state      pg_catalog.text,
      started_at pg_catalog.timestamptz,
      last_msg_at pg_catalog.timestamptz
    );
  END IF;
END;
$$;

CREATE FUNCTION pg_background_wait_v2(pid pg_catalog.int4,
                                     cookie pg_catalog.int8,
                                     timeout_ms pg_catalog.int4 DEFAULT NULL)
RETURNS pg_catalog.bool
AS 'MODULE_PATHNAME', 'pg_background_wait_v2'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_status_v2(pid pg_catalog.int4, cookie pg_catalog.int8)
RETURNS public.pg_background_status
AS 'MODULE_PATHNAME', 'pg_background_status_v2'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_cancel(pid pg_catalog.int4,
                                     grace_ms pg_catalog.int4 DEFAULT 1000)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_cancel'
LANGUAGE C STRICT;

-- explicit cancel (recommended)
CREATE FUNCTION pg_background_cancel_v2(pid pg_catalog.int4,
                                        cookie pg_catalog.int8,
                                        grace_ms pg_catalog.int4 DEFAULT 1000)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_cancel_v2'
LANGUAGE C STRICT;

-- 2) Add v2 functions (additive)
CREATE FUNCTION pg_background_launch_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 65536
)
RETURNS public.pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_launch_v2'
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


-- 3) Replace grant/revoke helper functions (include v2 + hardened search_path)
CREATE OR REPLACE FUNCTION grant_pg_background_privileges(
    user_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    -- v1
    EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4) TO %I', user_name);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_result(pg_catalog.int4) TO %I', user_name);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_detach(pg_catalog.int4) TO %I', user_name);

    -- v2
    EXECUTE format('GRANT USAGE ON TYPE public.pg_background_handle TO %I', user_name);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) TO %I', user_name);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) TO %I', user_name);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) TO %I', user_name);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) TO %I', user_name);

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
BEGIN
    -- v2 first
    EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM %I', user_name);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', user_name);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', user_name);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) FROM %I', user_name);
    EXECUTE format('REVOKE USAGE ON TYPE public.pg_background_handle FROM %I', user_name);

    -- v1
    EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_detach(pg_catalog.int4) FROM %I', user_name);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_result(pg_catalog.int4) FROM %I', user_name);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4) FROM %I', user_name);

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error revoking pg_background privileges from %: %', user_name, SQLERRM;
    RETURN FALSE;
END;
$function$;

-- 4) Lockdown
REVOKE ALL ON FUNCTION revoke_pg_background_privileges(pg_catalog.text, boolean) FROM public;
REVOKE ALL ON FUNCTION grant_pg_background_privileges(pg_catalog.text, boolean) FROM public;

REVOKE ALL ON FUNCTION pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM public;

REVOKE ALL ON TYPE public.pg_background_handle FROM public;
