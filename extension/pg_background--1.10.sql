-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_background" to load this file. \quit

-- ----------------------------------------------------------------------
-- pg_background 1.10
--   - v1 API (unchanged)
--   - v2 API (handle + submit/cancel/wait/list)
--   - hardened privilege model via a NOLOGIN role
--   - GUCs: max_workers, worker_timeout, default_queue_size
--   - pg_background_stats_v2() - session statistics
--   - pg_background_progress() - worker progress reporting
--   - pg_background_get_progress_v2() - get worker progress
--   - Worker labels for operational clarity (1.9)
--   - Structured error returns (pg_background_error type) (1.9)
--   - Result metadata (pg_background_result_info_v2) (1.9)
--   - Batch operations (detach_all_v2, cancel_all_v2) (1.9)
--   - NEW (1.10): pg_background_list view (no column-definition list)
--   - NEW (1.10): pg_background_activity view (joins pg_stat_activity)
--   - NEW (1.10): pg_background_outcome composite type
--   - NEW (1.10): pg_background_outcome_v2() never-raises status helper
--   - NEW (1.10): pg_background_run_result composite type
--   - NEW (1.10): pg_background_run_v2() synchronous one-shot helper
--   - Internal: cryptographically secure cookies (pg_strong_random)
--   - Internal: dedicated memory context (prevents session bloat)
--   - Internal: exponential backoff polling (reduces CPU usage)
--   - Internal: max workers limit enforcement
--   - Internal: UTF-8 aware truncation
--   - Relocatable: supports CREATE EXTENSION ... WITH SCHEMA
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

-- 2-arg overload (backward compatible with 1.8, STRICT for NULL safety)
CREATE FUNCTION pg_background_launch_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 0
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_launch_v2'
LANGUAGE C STRICT;

-- 3-arg overload with label parameter (v1.9+, not STRICT to allow NULL label)
CREATE FUNCTION pg_background_launch_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4,
    label pg_catalog.text
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_launch_v2'
LANGUAGE C;

-- 2-arg overload (backward compatible with 1.8, STRICT for NULL safety)
CREATE FUNCTION pg_background_submit_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 0
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_submit_v2'
LANGUAGE C STRICT;

-- 3-arg overload with label parameter (v1.9+, not STRICT to allow NULL label)
CREATE FUNCTION pg_background_submit_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4,
    label pg_catalog.text
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_submit_v2'
LANGUAGE C;

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
-- v1.9: Result info and error types
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
-- v1.9: Observability functions
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
-- v1.9: Batch operations
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
-- v1.10: Convenience view over pg_background_list_v2()
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
-- v1.10: Joined view (worker registry + pg_stat_activity)
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
-- v1.10: Combined outcome snapshot type and never-raises helper
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

    BEGIN
        SELECT l.state, l.consumed, l.label, l.launched_at
          INTO out.state, out.consumed, out.label, out.launched_at
          FROM pg_background_list l
         WHERE l.pid = p_pid AND l.cookie = p_cookie;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

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
-- v1.10: Synchronous one-shot run helper
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
-- v1.10: Tier A loop killers
--
-- Six convenience helpers built on top of the v2 primitives. Each removes
-- a PL/pgSQL pattern users keep hand-rolling.
-- ----------------------------------------------------------------------

-- A1: synchronous one-shot returning rows
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
        finished := pg_background_wait_v2_timeout(h.pid, h.cookie, timeout_ms);
        IF NOT finished THEN
            BEGIN PERFORM pg_background_cancel_v2_grace(h.pid, h.cookie, 1000);
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
'Synchronous launch+wait+result+detach with rows. col_def must match the AS clause at the call site, e.g. '
'SELECT * FROM pg_background_run_query_v2(''SELECT 1'', col_def => ''x int'') AS r(x int).';

-- A2: drain — wait for all handles, return one outcome each
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
                /* deadline blown: emit minimal outcome and skip wait/detach */
                o := pg_background_outcome_v2(h.pid, h.cookie);
                RETURN NEXT o;
                CONTINUE;
            END IF;
            PERFORM pg_background_wait_v2_timeout(h.pid, h.cookie, remaining_ms::pg_catalog.int4);
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

-- A3: wait_any — return the first handle to finish, NULL on timeout
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
                IF pg_background_wait_v2_timeout(h.pid, h.cookie, 0) THEN
                    RETURN h;
                END IF;
            EXCEPTION WHEN OTHERS THEN
                /* handle stale or invalid; treat as not-finished */
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
'Returns NULL on timeout. Caller decides what to do with the still-running handles.';

-- A4: cancel_by_label — pattern-based cancel
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
            IF grace_ms > 0 THEN
                PERFORM pg_background_cancel_v2_grace(r.pid, r.cookie, grace_ms);
            ELSE
                PERFORM pg_background_cancel_v2(r.pid, r.cookie);
            END IF;
            cnt := cnt + 1;
        EXCEPTION WHEN OTHERS THEN
            /* worker may have been cleaned up between list and cancel */
            NULL;
        END;
    END LOOP;
    RETURN cnt;
END;
$function$;

COMMENT ON FUNCTION pg_background_cancel_by_label_v2(pg_catalog.text, pg_catalog.int4) IS
'Cancel every worker whose label matches the SQL LIKE pattern. Returns count canceled.';

-- A5: status_v2 — jsonb wrapper of outcome (driver-friendly)
CREATE FUNCTION pg_background_status_v2(
    p_pid    pg_catalog.int4,
    p_cookie pg_catalog.int8
)
RETURNS pg_catalog.jsonb
LANGUAGE sql
AS $function$
    SELECT pg_catalog.to_jsonb(pg_background_outcome_v2($1, $2));
$function$;

COMMENT ON FUNCTION pg_background_status_v2(pg_catalog.int4, pg_catalog.int8) IS
'jsonb-shaped outcome snapshot. Easier to consume from drivers that decode JSON natively.';

-- A6: purge — detach only stopped/done workers (vs detach_all_v2 which is non-discriminating)
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
            IF pg_background_wait_v2_timeout(r.pid, r.cookie, 0) THEN
                PERFORM pg_background_detach_v2(r.pid, r.cookie);
                cnt := cnt + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            /* worker raced cleanup; ignore */
            NULL;
        END;
    END LOOP;
    RETURN cnt;
END;
$function$;

COMMENT ON FUNCTION pg_background_purge_v2() IS
'Detach only workers that have already stopped (success/error/cancel). '
'Returns count purged. Use detach_all_v2() to detach all workers regardless of state.';

-- ----------------------------------------------------------------------
-- v1.10 (B3): full SQL accessor — beyond the 120-char preview
-- ----------------------------------------------------------------------
CREATE FUNCTION pg_background_full_sql_v2(
    pid    pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_catalog.text
AS 'MODULE_PATHNAME', 'pg_background_full_sql_v2'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pg_background_full_sql_v2(pg_catalog.int4, pg_catalog.int8) IS
'Return the full SQL the worker is running, capped at 64 KiB with a [...] '
'sentinel for longer queries. NULL if not stored. Use list_v2.sql_preview '
'for monitoring; this function is for debugging.';

-- ----------------------------------------------------------------------
-- Role: NOLOGIN executor role for clean privilege assignment
--   - not named pg_*
--   - can be granted to users/roles by admins
-- ----------------------------------------------------------------------

DO $$
DECLARE
  _saved_search_path pg_catalog.text := pg_catalog.current_setting('search_path');
BEGIN
  PERFORM pg_catalog.set_config('search_path', 'pg_catalog, pg_temp', true);
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'pgbackground_role') THEN
    CREATE ROLE pgbackground_role NOLOGIN INHERIT;
  END IF;
  PERFORM pg_catalog.set_config('search_path', _saved_search_path, true);
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
SET search_path = pg_catalog, pg_temp
AS $function$
/*
 * Grant the standard set of pg_background privileges to a role.
 *
 * The function discovers extension-owned objects via pg_depend rather
 * than maintaining an explicit list. This keeps the helper correct as
 * new functions, types, or views are added: anything CREATE EXTENSION
 * (or ALTER EXTENSION ... UPDATE) registers with deptype = 'e' is
 * picked up automatically.
 */
DECLARE
    _ext_oid pg_catalog.oid;
    _sql     pg_catalog.text;
    _r       pg_catalog.record;
BEGIN
    SELECT oid INTO _ext_oid
      FROM pg_catalog.pg_extension
     WHERE extname = 'pg_background';

    IF _ext_oid IS NULL THEN
        RAISE EXCEPTION 'pg_background extension not found';
    END IF;

    -- Functions: GRANT EXECUTE on every extension-owned procedure,
    -- EXCEPT SECURITY DEFINER privilege helpers (the grant/revoke/drop
    -- helpers themselves). Granting EXECUTE on those to the executor
    -- role would let any member of the role re-grant pg_background to
    -- arbitrary roles (including PUBLIC), bypassing admin control.
    -- Privilege helpers must stay admin-only.
    FOR _r IN
        SELECT p.oid::pg_catalog.regprocedure AS sig
          FROM pg_catalog.pg_depend d
          JOIN pg_catalog.pg_proc   p ON p.oid = d.objid
         WHERE d.classid    = 'pg_catalog.pg_proc'::pg_catalog.regclass
           AND d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
           AND d.refobjid   = _ext_oid
           AND d.deptype    = 'e'
           AND NOT p.prosecdef
    LOOP
        _sql := pg_catalog.format('GRANT EXECUTE ON FUNCTION %s TO %I', _r.sig, role_name);
        EXECUTE _sql;
        IF print_commands THEN RAISE INFO '%', _sql; END IF;
    END LOOP;

    -- Composite types created via CREATE TYPE: GRANT USAGE.
    -- Filter to typtype='c' AND the underlying relkind='c' (the auto-
    -- generated rowtypes for views/tables/array element types are excluded).
    FOR _r IN
        SELECT t.oid::pg_catalog.regtype AS typname
          FROM pg_catalog.pg_depend d
          JOIN pg_catalog.pg_type   t ON t.oid = d.objid
          JOIN pg_catalog.pg_class  c ON c.oid = t.typrelid
         WHERE d.classid    = 'pg_catalog.pg_type'::pg_catalog.regclass
           AND d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
           AND d.refobjid   = _ext_oid
           AND d.deptype    = 'e'
           AND t.typtype    = 'c'
           AND c.relkind    = 'c'
    LOOP
        _sql := pg_catalog.format('GRANT USAGE ON TYPE %s TO %I', _r.typname, role_name);
        EXECUTE _sql;
        IF print_commands THEN RAISE INFO '%', _sql; END IF;
    END LOOP;

    -- Relations (views, tables, materialized views): GRANT SELECT.
    FOR _r IN
        SELECT c.oid::pg_catalog.regclass AS relname
          FROM pg_catalog.pg_depend d
          JOIN pg_catalog.pg_class  c ON c.oid = d.objid
         WHERE d.classid    = 'pg_catalog.pg_class'::pg_catalog.regclass
           AND d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
           AND d.refobjid   = _ext_oid
           AND d.deptype    = 'e'
           AND c.relkind    IN ('v', 'r', 'm')
    LOOP
        _sql := pg_catalog.format('GRANT SELECT ON TABLE %s TO %I', _r.relname, role_name);
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
SET search_path = pg_catalog, pg_temp
AS $function$
/*
 * Revoke the standard set of pg_background privileges from a role.
 *
 * Mirror of grant_pg_background_privileges: discovers extension-owned
 * objects via pg_depend rather than maintaining an explicit list.
 */
DECLARE
    _ext_oid pg_catalog.oid;
    _sql     pg_catalog.text;
    _r       pg_catalog.record;
BEGIN
    SELECT oid INTO _ext_oid
      FROM pg_catalog.pg_extension
     WHERE extname = 'pg_background';

    IF _ext_oid IS NULL THEN
        RAISE EXCEPTION 'pg_background extension not found';
    END IF;

    -- Relations: REVOKE SELECT.
    FOR _r IN
        SELECT c.oid::pg_catalog.regclass AS relname
          FROM pg_catalog.pg_depend d
          JOIN pg_catalog.pg_class  c ON c.oid = d.objid
         WHERE d.classid    = 'pg_catalog.pg_class'::pg_catalog.regclass
           AND d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
           AND d.refobjid   = _ext_oid
           AND d.deptype    = 'e'
           AND c.relkind    IN ('v', 'r', 'm')
    LOOP
        _sql := pg_catalog.format('REVOKE SELECT ON TABLE %s FROM %I', _r.relname, role_name);
        EXECUTE _sql;
        IF print_commands THEN RAISE INFO '%', _sql; END IF;
    END LOOP;

    -- Composite types: REVOKE USAGE.
    FOR _r IN
        SELECT t.oid::pg_catalog.regtype AS typname
          FROM pg_catalog.pg_depend d
          JOIN pg_catalog.pg_type   t ON t.oid = d.objid
          JOIN pg_catalog.pg_class  c ON c.oid = t.typrelid
         WHERE d.classid    = 'pg_catalog.pg_type'::pg_catalog.regclass
           AND d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
           AND d.refobjid   = _ext_oid
           AND d.deptype    = 'e'
           AND t.typtype    = 'c'
           AND c.relkind    = 'c'
    LOOP
        _sql := pg_catalog.format('REVOKE USAGE ON TYPE %s FROM %I', _r.typname, role_name);
        EXECUTE _sql;
        IF print_commands THEN RAISE INFO '%', _sql; END IF;
    END LOOP;

    -- Functions: REVOKE EXECUTE.
    FOR _r IN
        SELECT p.oid::pg_catalog.regprocedure AS sig
          FROM pg_catalog.pg_depend d
          JOIN pg_catalog.pg_proc   p ON p.oid = d.objid
         WHERE d.classid    = 'pg_catalog.pg_proc'::pg_catalog.regclass
           AND d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
           AND d.refobjid   = _ext_oid
           AND d.deptype    = 'e'
    LOOP
        _sql := pg_catalog.format('REVOKE EXECUTE ON FUNCTION %s FROM %I', _r.sig, role_name);
        EXECUTE _sql;
        IF print_commands THEN RAISE INFO '%', _sql; END IF;
    END LOOP;
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

-- Belt-and-braces: even though the bulk grant helper above skips
-- SECURITY DEFINER functions, explicitly revoke EXECUTE on the
-- privilege helpers from pgbackground_role. This keeps the admin-only
-- contract intact even if the bulk grant is replayed by an admin in
-- the future, and protects against accidental grants.
REVOKE ALL ON FUNCTION grant_pg_background_privileges(pg_catalog.text, boolean)
  FROM pgbackground_role;
REVOKE ALL ON FUNCTION revoke_pg_background_privileges(pg_catalog.text, boolean)
  FROM pgbackground_role;

REVOKE ALL ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_result(pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_detach(pg_catalog.int4) FROM public;

REVOKE ALL ON TYPE pg_background_handle FROM public;

REVOKE ALL ON FUNCTION pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_launch_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.text) FROM public;
REVOKE ALL ON FUNCTION pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_submit_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.text) FROM public;
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

-- v1.9 new objects
REVOKE ALL ON TYPE pg_background_result_info FROM public;
REVOKE ALL ON TYPE pg_background_error FROM public;
REVOKE ALL ON FUNCTION pg_background_result_info_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_error_info_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_detach_all_v2() FROM public;
REVOKE ALL ON FUNCTION pg_background_cancel_all_v2() FROM public;

-- v1.10 new objects
REVOKE ALL ON TYPE pg_background_outcome FROM public;
REVOKE ALL ON TYPE pg_background_run_result FROM public;
REVOKE ALL ON FUNCTION pg_background_outcome_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_run_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text) FROM public;
REVOKE ALL ON TABLE pg_background_list FROM public;
REVOKE ALL ON TABLE pg_background_activity FROM public;

-- v1.10 Tier A new objects
REVOKE ALL ON FUNCTION pg_background_run_query_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text, pg_catalog.text) FROM public;
REVOKE ALL ON FUNCTION pg_background_drain_v2(pg_background_handle[], pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_wait_any_v2(pg_background_handle[], pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_cancel_by_label_v2(pg_catalog.text, pg_catalog.int4) FROM public;
REVOKE ALL ON FUNCTION pg_background_status_v2(pg_catalog.int4, pg_catalog.int8) FROM public;
REVOKE ALL ON FUNCTION pg_background_purge_v2() FROM public;
REVOKE ALL ON FUNCTION pg_background_full_sql_v2(pg_catalog.int4, pg_catalog.int8) FROM public;

-- ----------------------------------------------------------------------
-- Optional: helper to drop role explicitly (because DROP EXTENSION won't)
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_background_drop_executor_role()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  -- best effort: revoke from all members is admin's responsibility if needed
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'pgbackground_role') THEN
    EXECUTE 'DROP ROLE pgbackground_role';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION pg_background_drop_executor_role() FROM public;
-- Admin-only: must never be exposed via pgbackground_role.
REVOKE ALL ON FUNCTION pg_background_drop_executor_role()
  FROM pgbackground_role;
