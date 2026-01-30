\echo Use "CREATE EXTENSION pg_background" to load this file. \quit

-- v1 API (unchanged)
CREATE FUNCTION pg_background_launch(sql pg_catalog.text,
                                    queue_size pg_catalog.int4 DEFAULT 65536)
RETURNS pg_catalog.int4
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_result(pid pg_catalog.int4)
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_detach(pid pg_catalog.int4)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

-- v2 handle
CREATE TYPE public.pg_background_handle AS (
  pid    pg_catalog.int4,
  cookie pg_catalog.int8
);

-- v2 launch + submit
CREATE FUNCTION pg_background_launch_v2(sql pg_catalog.text,
                                       queue_size pg_catalog.int4 DEFAULT 65536)
RETURNS public.pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_launch_v2'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_submit_v2(sql pg_catalog.text,
                                       queue_size pg_catalog.int4 DEFAULT 65536)
RETURNS public.pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_submit_v2'
LANGUAGE C STRICT;

-- v2 result + detach
CREATE FUNCTION pg_background_result_v2(pid pg_catalog.int4, cookie pg_catalog.int8)
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME', 'pg_background_result_v2'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_detach_v2(pid pg_catalog.int4, cookie pg_catalog.int8)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_detach_v2'
LANGUAGE C STRICT;

-- v2 cancel (no overload ambiguity)
CREATE FUNCTION pg_background_cancel_v2(pid pg_catalog.int4, cookie pg_catalog.int8)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_cancel_v2'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_cancel_v2_grace(pid pg_catalog.int4, cookie pg_catalog.int8, grace_ms pg_catalog.int4)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_cancel_v2_grace'
LANGUAGE C STRICT;

-- v2 wait
CREATE FUNCTION pg_background_wait_v2(pid pg_catalog.int4, cookie pg_catalog.int8)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_wait_v2'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_wait_v2_timeout(pid pg_catalog.int4, cookie pg_catalog.int8, timeout_ms pg_catalog.int4)
RETURNS pg_catalog.bool
AS 'MODULE_PATHNAME', 'pg_background_wait_v2_timeout'
LANGUAGE C STRICT;

-- v2 list (record; call with column definition list)
CREATE FUNCTION pg_background_list_v2()
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME', 'pg_background_list_v2'
LANGUAGE C;

-- -------------------------------------------------------------------------
-- Ops-grade helpers (additive; does not change core API)
-- -------------------------------------------------------------------------

/*
 * Active-only view: reduces operator panic.
 * Shows only handles that still matter (not yet stopped).
 */
CREATE OR REPLACE VIEW public.pg_background_active_vw AS
SELECT *
FROM pg_background_list_v2()
  AS (pid int4, cookie int8, launched_at timestamptz, user_id oid,
      queue_size int4, state text, sql_preview text, last_error text, consumed bool)
WHERE state IS DISTINCT FROM 'stopped';


/*
 * Ops view: adds derived operational columns without changing list_v2().
 *
 * reapable: safe to detach now (i.e., it’s not running/starting).
 * age_ms: how long since launch (NULL if launched_at NULL).
 * sql_preview_short: compact preview for dashboards.
 */
CREATE OR REPLACE VIEW public.pg_background_ops_vw AS
SELECT
  pid,
  cookie,
  launched_at,
  user_id,
  queue_size,
  state,
  sql_preview,
  last_error,
  consumed,

  CASE
    WHEN state IN ('stopped', 'canceled', 'error', 'failed', 'done') THEN true
    WHEN state IS NULL THEN false
    ELSE false
  END AS reapable,

  CASE
    WHEN launched_at IS NULL THEN NULL::bigint
    ELSE (extract(epoch from (clock_timestamp() - launched_at)) * 1000)::bigint
  END AS age_ms,

  CASE
    WHEN sql_preview IS NULL THEN NULL
    WHEN length(sql_preview) <= 96 THEN sql_preview
    ELSE left(sql_preview, 93) || '...'
  END AS sql_preview_short

FROM pg_background_list_v2()
  AS (pid int4, cookie int8, launched_at timestamptz, user_id oid,
      queue_size int4, state text, sql_preview text, last_error text, consumed bool);


/*
 * Reap stopped handles for the current session.
 * Returns number of handles detached.
 *
 * NOTE: Uses list_v2 + detach_v2; safe because detach_v2 enforces cookie.
 */
CREATE OR REPLACE FUNCTION public.pg_background_reap_stopped_v2()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  r record;
  n int := 0;
BEGIN
  FOR r IN
    SELECT *
    FROM pg_background_list_v2()
      AS (pid int4, cookie int8, launched_at timestamptz, user_id oid,
          queue_size int4, state text, sql_preview text, last_error text, consumed bool)
    WHERE state = 'stopped'
  LOOP
    PERFORM pg_background_detach_v2(r.pid, r.cookie);
    n := n + 1;
  END LOOP;

  RETURN n;
END $$;


/*
 * Optional: reap everything that is reapable (stopped/canceled/error/etc).
 * If your state machine only ever returns 'starting'/'running'/'stopped',
 * this still works (it will effectively behave like reap_stopped_v2()).
 */
CREATE OR REPLACE FUNCTION public.pg_background_reap_reapable_v2()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  r record;
  n int := 0;
BEGIN
  FOR r IN
    SELECT pid, cookie
    FROM public.pg_background_ops_vw
    WHERE reapable
  LOOP
    PERFORM pg_background_detach_v2(r.pid, r.cookie);
    n := n + 1;
  END LOOP;

  RETURN n;
END $$;

-- privilege helpers (hardened)
CREATE OR REPLACE FUNCTION grant_pg_background_privileges(
    user_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  -- v1
  EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4) TO %I', user_name);
  EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_result(pg_catalog.int4) TO %I', user_name);
  EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_detach(pg_catalog.int4) TO %I', user_name);

  -- v2
  EXECUTE format('GRANT USAGE ON TYPE public.pg_background_handle TO %I', user_name);
  EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) TO %I', user_name);
  EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) TO %I', user_name);
  EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) TO %I', user_name);
  EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) TO %I', user_name);
  EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8) TO %I', user_name);
  EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) TO %I', user_name);
  EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8) TO %I', user_name);
  EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) TO %I', user_name);
  EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_list_v2() TO %I', user_name);

  RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Error granting pg_background privileges to %: %', user_name, SQLERRM;
  RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION revoke_pg_background_privileges(
    user_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  -- v2
  EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_list_v2() FROM %I', user_name);
  EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM %I', user_name);
  EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', user_name);
  EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM %I', user_name);
  EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', user_name);
  EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', user_name);
  EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) FROM %I', user_name);
  EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) FROM %I', user_name);
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
$$;

-- public lockdown
REVOKE ALL ON FUNCTION revoke_pg_background_privileges(pg_catalog.text, boolean) FROM public;
REVOKE ALL ON FUNCTION grant_pg_background_privileges(pg_catalog.text, boolean) FROM public;

REVOKE ALL ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_result(pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_detach(pg_catalog.int4) FROM public;

REVOKE ALL ON FUNCTION pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) FROM public;

REVOKE ALL ON FUNCTION pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM public;

REVOKE ALL ON FUNCTION pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM public;

REVOKE ALL ON FUNCTION pg_background_list_v2() FROM public;

REVOKE ALL ON TYPE public.pg_background_handle FROM public;
