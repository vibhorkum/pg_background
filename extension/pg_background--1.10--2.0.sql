-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_background UPDATE TO '2.0'" to load this file. \quit

-- ----------------------------------------------------------------------
-- pg_background 1.10 -> 2.0 upgrade.
--
-- This is a major release. The script:
--
--   1. drops the v1 entrypoints (pg_background_launch / _result / _detach);
--   2. collapses pg_background_cancel_v2 + cancel_v2_grace into one
--      function with grace_ms DEFAULT 0;
--   3. collapses pg_background_wait_v2 + wait_v2_timeout into one
--      function returning bool, with timeout_ms DEFAULT 0 = block forever;
--   4. drops pg_background_status_v2 (drivers can call
--      to_jsonb(pg_background_outcome_v2(...)) themselves);
--   5. renames pg_background_progress to pg_background_report_progress_v2
--      and pg_background_progress (type) to pg_background_progress_info;
--   6. renames the privilege helpers to pg_background_grant_privileges_v2
--      and pg_background_revoke_privileges_v2;
--   7. extends pg_background_stats / result_info / error / run_result
--      composite types with forward-compatibility columns;
--   8. adds pg_background_record_timeout_v2 (internal counter bumper).
--
-- Anything an existing user-written script references that this upgrade
-- removes (v1 functions, the _grace / _timeout suffixed variants,
-- status_v2, the unprefixed grant helpers) needs to be ported. See
-- docs/MIGRATION.md.
-- ----------------------------------------------------------------------

-- ----------------------------------------------------------------------
-- Step 1: drop dependent SQL/PL helpers so we can reshape the types.
-- ----------------------------------------------------------------------

DROP FUNCTION IF EXISTS pg_background_status_v2(pg_catalog.int4, pg_catalog.int8);
DROP FUNCTION IF EXISTS pg_background_run_query_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text, pg_catalog.text);
DROP FUNCTION IF EXISTS pg_background_drain_v2(pg_background_handle[], pg_catalog.int4);
DROP FUNCTION IF EXISTS pg_background_wait_any_v2(pg_background_handle[], pg_catalog.int4);
DROP FUNCTION IF EXISTS pg_background_cancel_by_label_v2(pg_catalog.text, pg_catalog.int4);
DROP FUNCTION IF EXISTS pg_background_purge_v2();
DROP FUNCTION IF EXISTS pg_background_run_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text);
DROP FUNCTION IF EXISTS pg_background_outcome_v2(pg_catalog.int4, pg_catalog.int8);

-- ----------------------------------------------------------------------
-- Step 2: drop readers whose return types are about to change.
-- ----------------------------------------------------------------------

DROP FUNCTION IF EXISTS pg_background_stats_v2();
DROP FUNCTION IF EXISTS pg_background_result_info_v2(pg_catalog.int4, pg_catalog.int8);
DROP FUNCTION IF EXISTS pg_background_error_info_v2(pg_catalog.int4, pg_catalog.int8);
DROP FUNCTION IF EXISTS pg_background_get_progress_v2(pg_catalog.int4, pg_catalog.int8);

-- ----------------------------------------------------------------------
-- Step 3: drop the changing composite types.
-- ----------------------------------------------------------------------

DROP TYPE IF EXISTS pg_background_stats;
DROP TYPE IF EXISTS pg_background_progress;
DROP TYPE IF EXISTS pg_background_result_info;
DROP TYPE IF EXISTS pg_background_error;
DROP TYPE IF EXISTS pg_background_run_result;

-- ----------------------------------------------------------------------
-- Step 4: drop the v1 API and the collapsed/renamed primitives.
-- ----------------------------------------------------------------------

DROP FUNCTION IF EXISTS pg_background_launch(pg_catalog.text, pg_catalog.int4);
DROP FUNCTION IF EXISTS pg_background_result(pg_catalog.int4);
DROP FUNCTION IF EXISTS pg_background_detach(pg_catalog.int4);

DROP FUNCTION IF EXISTS pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8);
DROP FUNCTION IF EXISTS pg_background_cancel_v2_grace(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4);
DROP FUNCTION IF EXISTS pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8);
DROP FUNCTION IF EXISTS pg_background_wait_v2_timeout(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4);
DROP FUNCTION IF EXISTS pg_background_progress(pg_catalog.int4, pg_catalog.text);

DROP FUNCTION IF EXISTS grant_pg_background_privileges(pg_catalog.text, pg_catalog.bool);
DROP FUNCTION IF EXISTS revoke_pg_background_privileges(pg_catalog.text, pg_catalog.bool);

-- ----------------------------------------------------------------------
-- Step 5: recreate types with the new shape.
-- ----------------------------------------------------------------------

CREATE TYPE pg_background_stats AS (
    workers_launched   pg_catalog.int8,
    workers_completed  pg_catalog.int8,
    workers_failed     pg_catalog.int8,
    workers_canceled   pg_catalog.int8,
    workers_timed_out  pg_catalog.int8,
    workers_active     pg_catalog.int4,
    avg_execution_ms   pg_catalog.float8,
    max_workers        pg_catalog.int4
);

CREATE TYPE pg_background_progress_info AS (
    progress_pct  pg_catalog.int4,
    progress_msg  pg_catalog.text
);

CREATE TYPE pg_background_result_info AS (
    row_count       pg_catalog.int8,
    command_tag     pg_catalog.text,
    completed       pg_catalog.bool,
    has_error       pg_catalog.bool,
    started_at      pg_catalog.timestamptz,
    finished_at     pg_catalog.timestamptz
);

CREATE TYPE pg_background_error AS (
    sqlstate         pg_catalog.text,
    message          pg_catalog.text,
    detail           pg_catalog.text,
    hint             pg_catalog.text,
    context          pg_catalog.text,
    schema_name      pg_catalog.text,
    table_name       pg_catalog.text,
    column_name      pg_catalog.text,
    constraint_name  pg_catalog.text
);

CREATE TYPE pg_background_run_result AS (
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
    launched_at     pg_catalog.timestamptz,
    timed_out       pg_catalog.bool,
    elapsed_ms      pg_catalog.int8
);

-- ----------------------------------------------------------------------
-- Step 6: collapsed cancel_v2 / wait_v2 entrypoints.
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_cancel_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8,
    grace_ms pg_catalog.int4 DEFAULT 0
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_cancel_v2'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) IS
'Cancel a worker. grace_ms = 0 sends SIGTERM only; grace_ms > 0 waits that '
'many ms for clean exit before SIGKILL (capped at 1 hour).';

CREATE FUNCTION pg_background_wait_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8,
    timeout_ms pg_catalog.int4 DEFAULT 0
)
RETURNS pg_catalog.bool
AS 'MODULE_PATHNAME', 'pg_background_wait_v2'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) IS
'Wait for a worker to exit. timeout_ms <= 0 blocks indefinitely (latch-based, '
'no polling) and always returns true; timeout_ms > 0 waits up to N ms and '
'returns true if the worker stopped, false on timeout.';

-- ----------------------------------------------------------------------
-- Step 7: readers (return types are the new ones).
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_stats_v2()
RETURNS pg_background_stats
AS 'MODULE_PATHNAME', 'pg_background_stats_v2'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_stats_v2() IS
'Returns session-local statistics about background workers: launched, completed, '
'failed, canceled, timed_out, active count, average execution time, max workers.';

CREATE FUNCTION pg_background_record_timeout_v2()
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_record_timeout_v2'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_record_timeout_v2() IS
'Internal: increment session_stats.workers_timed_out. Called from '
'pg_background_run_v2 when a launched worker exceeds its timeout.';

CREATE FUNCTION pg_background_report_progress_v2(
    pct pg_catalog.int4,
    msg pg_catalog.text DEFAULT NULL
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_report_progress_v2'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_report_progress_v2(pg_catalog.int4, pg_catalog.text) IS
'Report progress from within a background worker. Call from your SQL: '
'SELECT pg_background_report_progress_v2(50, ''Halfway done'');';

CREATE FUNCTION pg_background_get_progress_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_background_progress_info
AS 'MODULE_PATHNAME', 'pg_background_get_progress_v2'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_get_progress_v2(pg_catalog.int4, pg_catalog.int8) IS
'Get the current progress of a background worker. Returns NULL if progress not yet reported.';

CREATE FUNCTION pg_background_result_info_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_background_result_info
AS 'MODULE_PATHNAME', 'pg_background_result_info_v2'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pg_background_result_info_v2(pg_catalog.int4, pg_catalog.int8) IS
'Get result metadata (row_count, command_tag, completed, has_error, started_at, finished_at) without consuming results.';

CREATE FUNCTION pg_background_error_info_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_background_error
AS 'MODULE_PATHNAME', 'pg_background_error_info_v2'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pg_background_error_info_v2(pg_catalog.int4, pg_catalog.int8) IS
'Get structured error information (sqlstate, message, detail, hint, context, '
'schema_name, table_name, column_name, constraint_name) from a worker. '
'Returns NULL if no error.';

-- ----------------------------------------------------------------------
-- Step 8: outcome helper (body unchanged but recreated for hygiene).
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

    /* Reading from pg_background_list cannot raise — see fresh-install notes. */
    SELECT l.state, l.consumed, l.label, l.launched_at
      INTO out.state, out.consumed, out.label, out.launched_at
      FROM pg_background_list l
     WHERE l.pid = p_pid AND l.cookie = p_cookie;

    BEGIN
        ri := pg_background_result_info_v2(p_pid, p_cookie);
        out.completed   := ri.completed;
        out.has_error   := ri.has_error;
        out.row_count   := ri.row_count;
        out.command_tag := ri.command_tag;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

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
-- Step 9: run_v2 with extended run_result and timeout-counter bump.
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

    IF timeout_ms > 0 THEN
        finished := pg_background_wait_v2(h.pid, h.cookie, timeout_ms);
        IF NOT finished THEN
            BEGIN
                PERFORM pg_background_cancel_v2(h.pid, h.cookie, 1000);
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
            BEGIN
                PERFORM pg_background_record_timeout_v2();
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END IF;
    ELSE
        PERFORM pg_background_wait_v2(h.pid, h.cookie);
        finished := true;
    END IF;

    o := pg_background_outcome_v2(h.pid, h.cookie);
    out.pid           := o.pid;
    out.cookie        := o.cookie;
    out.state         := o.state;
    out.consumed      := o.consumed;
    out.completed     := COALESCE(o.completed, false);
    out.has_error     := COALESCE(o.has_error, false);
    out.row_count     := o.row_count;
    out.command_tag   := o.command_tag;
    out.sqlstate      := o.sqlstate;
    out.error_message := o.error_message;
    out.label         := o.label;
    out.launched_at   := o.launched_at;
    out.timed_out     := NOT finished;

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
'Run a SQL command in a background worker and wait for completion. Returns '
'the full outcome snapshot plus timed_out and elapsed_ms. On timeout the '
'worker is canceled with 1s grace and the timeout is recorded in stats.';

-- ----------------------------------------------------------------------
-- Step 10: Tier A helpers (rewired to use new wait_v2 / cancel_v2).
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_run_query_v2(
    sql        pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 0,
    timeout_ms pg_catalog.int4 DEFAULT 0,
    label      pg_catalog.text DEFAULT NULL,
    col_def    pg_catalog.text DEFAULT NULL
)
RETURNS SETOF pg_catalog.record
LANGUAGE plpgsql
AS $function$
DECLARE
    h        pg_background_handle;
    o        pg_background_outcome;
    finished pg_catalog.bool;
BEGIN
    IF label IS NULL THEN
        h := pg_background_launch_v2(sql, queue_size);
    ELSE
        h := pg_background_launch_v2(sql, queue_size, label);
    END IF;

    IF timeout_ms > 0 THEN
        finished := pg_background_wait_v2(h.pid, h.cookie, timeout_ms);
        IF NOT finished THEN
            BEGIN PERFORM pg_background_cancel_v2(h.pid, h.cookie, 1000);
            EXCEPTION WHEN OTHERS THEN NULL; END;
            BEGIN PERFORM pg_background_record_timeout_v2();
            EXCEPTION WHEN OTHERS THEN NULL; END;
            BEGIN PERFORM pg_background_detach_v2(h.pid, h.cookie);
            EXCEPTION WHEN OTHERS THEN NULL; END;
            RAISE EXCEPTION 'pg_background_run_query_v2: worker did not complete within % ms', timeout_ms
                USING ERRCODE = '57014';
        END IF;
    ELSE
        PERFORM pg_background_wait_v2(h.pid, h.cookie);
    END IF;

    o := pg_background_outcome_v2(h.pid, h.cookie);
    IF o.has_error THEN
        BEGIN PERFORM pg_background_detach_v2(h.pid, h.cookie);
        EXCEPTION WHEN OTHERS THEN NULL; END;
        RAISE EXCEPTION '%', COALESCE(o.error_message, 'worker error')
            USING ERRCODE = COALESCE(o.sqlstate, 'XX000');
    END IF;

    IF col_def IS NULL THEN
        BEGIN PERFORM pg_background_detach_v2(h.pid, h.cookie);
        EXCEPTION WHEN OTHERS THEN NULL; END;
        RETURN;
    END IF;

    RETURN QUERY EXECUTE pg_catalog.format(
        'SELECT * FROM pg_background_result_v2($1, $2) AS r(%s)', col_def
    ) USING h.pid, h.cookie;

    BEGIN PERFORM pg_background_detach_v2(h.pid, h.cookie);
    EXCEPTION WHEN OTHERS THEN NULL; END;
    RETURN;
END;
$function$;

COMMENT ON FUNCTION pg_background_run_query_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text, pg_catalog.text) IS
'Synchronous launch+wait+result+detach with rows. col_def must match the AS clause at the call site.';

CREATE FUNCTION pg_background_drain_v2(
    handles    pg_background_handle[],
    timeout_ms pg_catalog.int4 DEFAULT 0
)
RETURNS SETOF pg_background_outcome
LANGUAGE plpgsql
AS $function$
DECLARE
    start_ts pg_catalog.timestamptz := pg_catalog.clock_timestamp();
    h        pg_background_handle;
    o        pg_background_outcome;
    elapsed_ms pg_catalog.int8;
    remaining_ms pg_catalog.int8;
BEGIN
    IF handles IS NULL THEN RETURN; END IF;

    FOREACH h IN ARRAY handles LOOP
        IF h IS NULL THEN CONTINUE; END IF;

        IF timeout_ms > 0 THEN
            elapsed_ms := (pg_catalog.date_part('epoch', pg_catalog.clock_timestamp() - start_ts) * 1000)::pg_catalog.int8;
            remaining_ms := timeout_ms - elapsed_ms;
            IF remaining_ms <= 0 THEN
                o := pg_background_outcome_v2(h.pid, h.cookie);
                RETURN NEXT o;
                CONTINUE;
            END IF;
            PERFORM pg_background_wait_v2(h.pid, h.cookie, remaining_ms::pg_catalog.int4);
        ELSE
            BEGIN PERFORM pg_background_wait_v2(h.pid, h.cookie);
            EXCEPTION WHEN OTHERS THEN NULL; END;
        END IF;

        o := pg_background_outcome_v2(h.pid, h.cookie);
        RETURN NEXT o;

        BEGIN PERFORM pg_background_detach_v2(h.pid, h.cookie);
        EXCEPTION WHEN OTHERS THEN NULL; END;
    END LOOP;
    RETURN;
END;
$function$;

COMMENT ON FUNCTION pg_background_drain_v2(pg_background_handle[], pg_catalog.int4) IS
'Wait for every handle (wall-clock total timeout shared across handles), '
'collect outcomes, and detach. Returns one row per input handle in input order.';

CREATE FUNCTION pg_background_wait_any_v2(
    handles    pg_background_handle[],
    timeout_ms pg_catalog.int4 DEFAULT 0
)
RETURNS pg_background_handle
LANGUAGE plpgsql
AS $function$
DECLARE
    start_ts   pg_catalog.timestamptz := pg_catalog.clock_timestamp();
    poll_ms    pg_catalog.int4 := 50;
    h          pg_background_handle;
    elapsed_ms pg_catalog.int8;
BEGIN
    IF handles IS NULL OR pg_catalog.array_length(handles, 1) IS NULL THEN
        RETURN NULL;
    END IF;

    LOOP
        FOREACH h IN ARRAY handles LOOP
            IF h IS NULL THEN CONTINUE; END IF;
            BEGIN
                IF pg_background_wait_v2(h.pid, h.cookie, 1) THEN
                    RETURN h;
                END IF;
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END LOOP;

        IF timeout_ms > 0 THEN
            elapsed_ms := (pg_catalog.date_part('epoch', pg_catalog.clock_timestamp() - start_ts) * 1000)::pg_catalog.int8;
            IF elapsed_ms >= timeout_ms THEN
                RETURN NULL;
            END IF;
        END IF;

        PERFORM pg_catalog.pg_sleep(poll_ms / 1000.0);
        IF poll_ms < 500 THEN poll_ms := poll_ms * 2; END IF;
    END LOOP;
END;
$function$;

COMMENT ON FUNCTION pg_background_wait_any_v2(pg_background_handle[], pg_catalog.int4) IS
'Return the first handle whose worker has finished. Adaptive polling 50ms..500ms. '
'Returns NULL on timeout.';

CREATE FUNCTION pg_background_cancel_by_label_v2(
    pattern  pg_catalog.text,
    grace_ms pg_catalog.int4 DEFAULT 0
)
RETURNS pg_catalog.int4
LANGUAGE plpgsql
AS $function$
DECLARE
    r   pg_catalog.record;
    cnt pg_catalog.int4 := 0;
BEGIN
    IF pattern IS NULL THEN RETURN 0; END IF;
    FOR r IN
        SELECT pid, cookie FROM pg_background_list WHERE label LIKE pattern
    LOOP
        BEGIN
            PERFORM pg_background_cancel_v2(r.pid, r.cookie, grace_ms);
            cnt := cnt + 1;
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END LOOP;
    RETURN cnt;
END;
$function$;

COMMENT ON FUNCTION pg_background_cancel_by_label_v2(pg_catalog.text, pg_catalog.int4) IS
'Cancel every worker whose label matches the SQL LIKE pattern. Returns count canceled.';

CREATE FUNCTION pg_background_purge_v2()
RETURNS pg_catalog.int4
LANGUAGE plpgsql
AS $function$
DECLARE
    r   pg_catalog.record;
    cnt pg_catalog.int4 := 0;
BEGIN
    FOR r IN SELECT pid, cookie FROM pg_background_list LOOP
        BEGIN
            IF pg_background_wait_v2(r.pid, r.cookie, 1) THEN
                PERFORM pg_background_detach_v2(r.pid, r.cookie);
                cnt := cnt + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END LOOP;
    RETURN cnt;
END;
$function$;

COMMENT ON FUNCTION pg_background_purge_v2() IS
'Detach only workers that have already stopped. '
'Returns count purged. Use detach_all_v2() to detach all workers regardless of state.';

-- ----------------------------------------------------------------------
-- Step 11: renamed privilege helpers.
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_grant_privileges_v2(
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
           -- v2.0 security: never grant EXECUTE on the SECURITY DEFINER
           -- privilege helpers (grant/revoke/drop) to the executor role.
           -- They run as the extension owner, so granting them would let
           -- any pgbackground_role member re-grant the role's capabilities
           -- to arbitrary roles (privilege escalation).
           AND NOT p.prosecdef
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

CREATE FUNCTION pg_background_revoke_privileges_v2(
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

-- ----------------------------------------------------------------------
-- Step 12: re-grant + lock down PUBLIC on the new surface.
-- ----------------------------------------------------------------------

SELECT pg_background_grant_privileges_v2('pgbackground_role', false);

REVOKE ALL ON FUNCTION pg_background_grant_privileges_v2(pg_catalog.text, boolean) FROM public;
REVOKE ALL ON FUNCTION pg_background_revoke_privileges_v2(pg_catalog.text, boolean) FROM public;

-- Belt-and-braces: also revoke from pgbackground_role so the admin-only
-- contract on the SECURITY DEFINER privilege helpers holds even if the bulk
-- grant is replayed later (privilege-escalation guard).
REVOKE ALL ON FUNCTION pg_background_grant_privileges_v2(pg_catalog.text, boolean) FROM pgbackground_role;
REVOKE ALL ON FUNCTION pg_background_revoke_privileges_v2(pg_catalog.text, boolean) FROM pgbackground_role;

REVOKE ALL ON FUNCTION pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) FROM public;

REVOKE ALL ON TYPE pg_background_stats FROM public;
REVOKE ALL ON TYPE pg_background_progress_info FROM public;
REVOKE ALL ON FUNCTION pg_background_stats_v2() FROM public;
REVOKE ALL ON FUNCTION pg_background_record_timeout_v2() FROM public;
REVOKE ALL ON FUNCTION pg_background_report_progress_v2(pg_catalog.int4, pg_catalog.text) FROM public;
REVOKE ALL ON FUNCTION pg_background_get_progress_v2(pg_catalog.int4, pg_catalog.int8) FROM public;

REVOKE ALL ON TYPE pg_background_result_info FROM public;
REVOKE ALL ON TYPE pg_background_error FROM public;
REVOKE ALL ON FUNCTION pg_background_result_info_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_error_info_v2(pg_catalog.int4, pg_catalog.int8) FROM public;

REVOKE ALL ON TYPE pg_background_run_result FROM public;
REVOKE ALL ON FUNCTION pg_background_outcome_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_run_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text) FROM public;

REVOKE ALL ON FUNCTION pg_background_run_query_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text, pg_catalog.text) FROM public;
REVOKE ALL ON FUNCTION pg_background_drain_v2(pg_background_handle[], pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_wait_any_v2(pg_background_handle[], pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_cancel_by_label_v2(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_purge_v2() FROM public;
