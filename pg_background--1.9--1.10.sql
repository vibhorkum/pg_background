-- pg_background upgrade script: 1.9 -> 1.10
-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_background UPDATE TO '1.10'" to load this file. \quit

-- ----------------------------------------------------------------------
-- pg_background 1.10 (ergonomics release)
--   - NEW: pg_background_list view (no column-definition list required)
--   - NEW: pg_background_activity view (joins pg_stat_activity)
--   - NEW: pg_background_outcome composite type
--   - NEW: pg_background_outcome_v2() never-raises status helper
--   - NEW: pg_background_run_result composite type
--   - NEW: pg_background_run_v2() synchronous one-shot helper
--   - All additions are PL/pgSQL or views; no worker/C-level behavior changes.
-- ----------------------------------------------------------------------

-- ----------------------------------------------------------------------
-- View: pg_background_list
--   Hides the column-definition list users have to repeat for list_v2().
--   Same column order/shape as pg_background_list_v2().
-- ----------------------------------------------------------------------

CREATE VIEW pg_background_list AS
  SELECT pid, cookie, launched_at, user_id, queue_size,
         state, sql_preview, last_error, consumed, label
    FROM pg_background_list_v2()
      AS l(pid pg_catalog.int4, cookie pg_catalog.int8,
           launched_at pg_catalog.timestamptz, user_id pg_catalog.oid,
           queue_size pg_catalog.int4, state pg_catalog.text,
           sql_preview pg_catalog.text, last_error pg_catalog.text,
           consumed pg_catalog.bool, label pg_catalog.text);

COMMENT ON VIEW pg_background_list IS
'Session-local list of background workers tracked by this session. '
'Wraps pg_background_list_v2() so callers do not have to repeat a column-definition list.';

-- ----------------------------------------------------------------------
-- View: pg_background_activity
--   Joins pg_background_list with pg_stat_activity by pid for unified
--   observability. Non-privileged users see NULL for restricted columns.
-- ----------------------------------------------------------------------

CREATE VIEW pg_background_activity AS
  SELECT l.pid,
         l.cookie,
         l.launched_at,
         l.user_id,
         l.queue_size,
         l.state            AS pgbg_state,
         l.sql_preview,
         l.last_error,
         l.consumed,
         l.label,
         s.state            AS backend_state,
         s.wait_event_type,
         s.wait_event,
         s.xact_start,
         s.query_start,
         s.backend_start,
         s.query
    FROM pg_background_list l
    LEFT JOIN pg_catalog.pg_stat_activity s ON s.pid = l.pid;

COMMENT ON VIEW pg_background_activity IS
'pg_background_list joined with pg_stat_activity for combined worker + backend visibility.';

-- ----------------------------------------------------------------------
-- Type: pg_background_outcome
--   Combined snapshot of a worker handle (state + result_info + error_info).
-- ----------------------------------------------------------------------

CREATE TYPE pg_background_outcome AS (
    pid             pg_catalog.int4,
    cookie          pg_catalog.int8,
    state           pg_catalog.text,
    consumed        pg_catalog.bool,
    completed       pg_catalog.bool,
    has_error       pg_catalog.bool,
    row_count       pg_catalog.int8,
    command_tag     pg_catalog.text,
    sqlstate        pg_catalog.text,
    error_message   pg_catalog.text,
    label           pg_catalog.text,
    launched_at     pg_catalog.timestamptz
);

-- ----------------------------------------------------------------------
-- Function: pg_background_outcome_v2
--   Never-raises status snapshot. Returns NULL fields when the handle is
--   gone, results are already consumed, or the worker has no error info.
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_outcome_v2(
    p_pid pg_catalog.int4,
    p_cookie pg_catalog.int8
)
RETURNS pg_background_outcome
LANGUAGE plpgsql
AS $function$
DECLARE
    out pg_background_outcome;
    ri  pg_background_result_info;
    er  pg_background_error;
BEGIN
    out.pid    := p_pid;
    out.cookie := p_cookie;

    -- list_v2: state, consumed, label, launched_at (silent if not in this session)
    BEGIN
        SELECT l.state, l.consumed, l.label, l.launched_at
          INTO out.state, out.consumed, out.label, out.launched_at
          FROM pg_background_list l
         WHERE l.pid = p_pid AND l.cookie = p_cookie;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    -- result_info_v2: completed, has_error, row_count, command_tag
    BEGIN
        ri := pg_background_result_info_v2(p_pid, p_cookie);
        out.completed   := ri.completed;
        out.has_error   := ri.has_error;
        out.row_count   := ri.row_count;
        out.command_tag := ri.command_tag;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    -- error_info_v2: sqlstate + message
    BEGIN
        er := pg_background_error_info_v2(p_pid, p_cookie);
        out.sqlstate      := er.sqlstate;
        out.error_message := er.message;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    RETURN out;
END;
$function$;

COMMENT ON FUNCTION pg_background_outcome_v2(pg_catalog.int4, pg_catalog.int8) IS
'Combined status snapshot (state + result_info + error_info) for a worker handle. '
'Never raises; returns NULL fields when information is unavailable.';

-- ----------------------------------------------------------------------
-- Type: pg_background_run_result
--   Return type for the synchronous run helper.
-- ----------------------------------------------------------------------

CREATE TYPE pg_background_run_result AS (
    pid             pg_catalog.int4,
    completed       pg_catalog.bool,
    timed_out       pg_catalog.bool,
    has_error       pg_catalog.bool,
    row_count       pg_catalog.int8,
    command_tag     pg_catalog.text,
    sqlstate        pg_catalog.text,
    error_message   pg_catalog.text,
    elapsed_ms      pg_catalog.int8
);

-- ----------------------------------------------------------------------
-- Function: pg_background_run_v2
--   Synchronous one-shot: launch + wait + outcome + detach in one call.
--   - timeout_ms = 0 means wait indefinitely.
--   - On timeout, the worker is canceled (1s grace) and detached.
--   - Returns metadata only (row_count, command_tag, error). Result rows
--     are not returned; use launch_v2 + result_v2 if you need rows.
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_run_v2(
    sql        pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 0,
    timeout_ms pg_catalog.int4 DEFAULT 0,
    label      pg_catalog.text DEFAULT NULL
)
RETURNS pg_background_run_result
LANGUAGE plpgsql
AS $function$
DECLARE
    h        pg_background_handle;
    out      pg_background_run_result;
    o        pg_background_outcome;
    start_ts pg_catalog.timestamptz;
    finished pg_catalog.bool;
BEGIN
    start_ts := pg_catalog.clock_timestamp();

    IF label IS NULL THEN
        h := pg_background_launch_v2(sql, queue_size);
    ELSE
        h := pg_background_launch_v2(sql, queue_size, label);
    END IF;
    out.pid := h.pid;

    IF timeout_ms > 0 THEN
        finished := pg_background_wait_v2_timeout(h.pid, h.cookie, timeout_ms);
        IF NOT finished THEN
            BEGIN
                PERFORM pg_background_cancel_v2_grace(h.pid, h.cookie, 1000);
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END IF;
    ELSE
        PERFORM pg_background_wait_v2(h.pid, h.cookie);
        finished := true;
    END IF;
    out.timed_out := NOT finished;

    o := pg_background_outcome_v2(h.pid, h.cookie);
    out.completed     := COALESCE(o.completed, false);
    out.has_error     := COALESCE(o.has_error, false);
    out.row_count     := o.row_count;
    out.command_tag   := o.command_tag;
    out.sqlstate      := o.sqlstate;
    out.error_message := o.error_message;

    BEGIN
        PERFORM pg_background_detach_v2(h.pid, h.cookie);
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    out.elapsed_ms := (pg_catalog.date_part('epoch', pg_catalog.clock_timestamp() - start_ts) * 1000)::pg_catalog.int8;
    RETURN out;
END;
$function$;

COMMENT ON FUNCTION pg_background_run_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text) IS
'Run a SQL command in a background worker and wait for completion. '
'Returns (pid, completed, timed_out, has_error, row_count, command_tag, sqlstate, error_message, elapsed_ms). '
'On timeout the worker is canceled with 1s grace. Returns metadata only; use launch_v2+result_v2 for result rows.';

-- ----------------------------------------------------------------------
-- Privileges for new objects
-- ----------------------------------------------------------------------

REVOKE ALL ON TYPE pg_background_outcome FROM public;
REVOKE ALL ON TYPE pg_background_run_result FROM public;
REVOKE ALL ON FUNCTION pg_background_outcome_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_run_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text) FROM public;
REVOKE ALL ON TABLE pg_background_list FROM public;
REVOKE ALL ON TABLE pg_background_activity FROM public;

-- Grant new objects to the executor role.
DO $do$
DECLARE
    _schema text;
BEGIN
    SELECT n.nspname INTO _schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
     WHERE e.extname = 'pg_background';

    IF _schema IS NOT NULL THEN
        EXECUTE format('GRANT USAGE ON TYPE %I.pg_background_outcome TO pgbackground_role', _schema);
        EXECUTE format('GRANT USAGE ON TYPE %I.pg_background_run_result TO pgbackground_role', _schema);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %I.pg_background_outcome_v2(pg_catalog.int4, pg_catalog.int8) TO pgbackground_role', _schema);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %I.pg_background_run_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text) TO pgbackground_role', _schema);
        EXECUTE format('GRANT SELECT ON TABLE %I.pg_background_list TO pgbackground_role', _schema);
        EXECUTE format('GRANT SELECT ON TABLE %I.pg_background_activity TO pgbackground_role', _schema);
    END IF;
END
$do$;

-- ----------------------------------------------------------------------
-- Refresh grant/revoke helpers using metadata-driven loops over
-- pg_depend so they cover all current and future extension-owned
-- objects without an explicit list.
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
    _ext_oid oid;
    _sql     text;
    _r       record;
BEGIN
    SELECT oid INTO _ext_oid
      FROM pg_extension
     WHERE extname = 'pg_background';

    IF _ext_oid IS NULL THEN
        RAISE EXCEPTION 'pg_background extension not found';
    END IF;

    FOR _r IN
        SELECT p.oid::regprocedure AS sig
          FROM pg_depend d
          JOIN pg_proc   p ON p.oid = d.objid
         WHERE d.classid    = 'pg_proc'::regclass
           AND d.refclassid = 'pg_extension'::regclass
           AND d.refobjid   = _ext_oid
           AND d.deptype    = 'e'
    LOOP
        _sql := format('GRANT EXECUTE ON FUNCTION %s TO %I', _r.sig, role_name);
        EXECUTE _sql;
        IF print_commands THEN RAISE INFO '%', _sql; END IF;
    END LOOP;

    FOR _r IN
        SELECT t.oid::regtype AS typname
          FROM pg_depend d
          JOIN pg_type   t ON t.oid = d.objid
          JOIN pg_class  c ON c.oid = t.typrelid
         WHERE d.classid    = 'pg_type'::regclass
           AND d.refclassid = 'pg_extension'::regclass
           AND d.refobjid   = _ext_oid
           AND d.deptype    = 'e'
           AND t.typtype    = 'c'
           AND c.relkind    = 'c'
    LOOP
        _sql := format('GRANT USAGE ON TYPE %s TO %I', _r.typname, role_name);
        EXECUTE _sql;
        IF print_commands THEN RAISE INFO '%', _sql; END IF;
    END LOOP;

    FOR _r IN
        SELECT c.oid::regclass AS relname
          FROM pg_depend d
          JOIN pg_class  c ON c.oid = d.objid
         WHERE d.classid    = 'pg_class'::regclass
           AND d.refclassid = 'pg_extension'::regclass
           AND d.refobjid   = _ext_oid
           AND d.deptype    = 'e'
           AND c.relkind    IN ('v', 'r', 'm')
    LOOP
        _sql := format('GRANT SELECT ON TABLE %s TO %I', _r.relname, role_name);
        EXECUTE _sql;
        IF print_commands THEN RAISE INFO '%', _sql; END IF;
    END LOOP;

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
    _ext_oid oid;
    _sql     text;
    _r       record;
BEGIN
    SELECT oid INTO _ext_oid
      FROM pg_extension
     WHERE extname = 'pg_background';

    IF _ext_oid IS NULL THEN
        RAISE EXCEPTION 'pg_background extension not found';
    END IF;

    FOR _r IN
        SELECT c.oid::regclass AS relname
          FROM pg_depend d
          JOIN pg_class  c ON c.oid = d.objid
         WHERE d.classid    = 'pg_class'::regclass
           AND d.refclassid = 'pg_extension'::regclass
           AND d.refobjid   = _ext_oid
           AND d.deptype    = 'e'
           AND c.relkind    IN ('v', 'r', 'm')
    LOOP
        _sql := format('REVOKE SELECT ON TABLE %s FROM %I', _r.relname, role_name);
        EXECUTE _sql;
        IF print_commands THEN RAISE INFO '%', _sql; END IF;
    END LOOP;

    FOR _r IN
        SELECT t.oid::regtype AS typname
          FROM pg_depend d
          JOIN pg_type   t ON t.oid = d.objid
          JOIN pg_class  c ON c.oid = t.typrelid
         WHERE d.classid    = 'pg_type'::regclass
           AND d.refclassid = 'pg_extension'::regclass
           AND d.refobjid   = _ext_oid
           AND d.deptype    = 'e'
           AND t.typtype    = 'c'
           AND c.relkind    = 'c'
    LOOP
        _sql := format('REVOKE USAGE ON TYPE %s FROM %I', _r.typname, role_name);
        EXECUTE _sql;
        IF print_commands THEN RAISE INFO '%', _sql; END IF;
    END LOOP;

    FOR _r IN
        SELECT p.oid::regprocedure AS sig
          FROM pg_depend d
          JOIN pg_proc   p ON p.oid = d.objid
         WHERE d.classid    = 'pg_proc'::regclass
           AND d.refclassid = 'pg_extension'::regclass
           AND d.refobjid   = _ext_oid
           AND d.deptype    = 'e'
    LOOP
        _sql := format('REVOKE EXECUTE ON FUNCTION %s FROM %I', _r.sig, role_name);
        EXECUTE _sql;
        IF print_commands THEN RAISE INFO '%', _sql; END IF;
    END LOOP;

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error revoking pg_background privileges from %: %', role_name, SQLERRM;
    RETURN FALSE;
END;
$function$;
