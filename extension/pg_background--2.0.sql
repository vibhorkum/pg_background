-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_background" to load this file. \quit

-- ----------------------------------------------------------------------
-- pg_background 2.0 — major release.
--
-- Breaking changes vs 1.10:
--   * v1 API (pg_background_launch / _result / _detach) removed.
--   * pg_background_cancel_v2_grace folded into a single
--       cancel function with grace_ms int4 DEFAULT 0.
--   * pg_background_wait_v2_timeout folded into a single wait function
--       returning bool. timeout_ms <= 0 blocks indefinitely (matches
--       1.10 wait default), timeout_ms > 0 waits up to N ms.
--   * pg_background_status_v2 removed (drivers can call
--       to_jsonb(pg_background_outcome(...))).
--   * pg_background_progress(pct,msg) renamed to
--       pg_background_report_progress (collision with the type resolved by
--       also renaming the type to pg_background_progress_info).
--   * grant_pg_background_privileges / revoke_pg_background_privileges
--       renamed to pg_background_grant_privileges /
--       pg_background_revoke_privileges.
--
-- The _v2 suffix is retired
-- ----------------------------------------------------------------------
--   With the v1 API gone, the _v2 suffix no longer distinguishes anything.
--   2.0 makes the unsuffixed names (pg_background_launch, _result, _wait,
--   ...) the canonical API. Every _v2 name is kept as a thin DEPRECATED
--   alias so existing 1.x/2.0 callers keep working unchanged; the aliases
--   are slated for removal in 3.0. New code should use the unsuffixed
--   names.
--
--   The unsuffixed names coexist with same-named objects of a different
--   kind, which PostgreSQL resolves by call syntax:
--     * pg_background_list      -> view  (preferred for monitoring)
--       pg_background_list()    -> set-returning function (raw, needs a
--                                  column-definition list)
--     * pg_background_stats     -> composite type
--       pg_background_stats()   -> function returning that type
--     * pg_background_outcome   -> composite type
--       pg_background_outcome() -> function returning that type
--
-- Forward-compatible additions:
--   * pg_background_stats: workers_timed_out int8.
--   * pg_background_result_info: started_at, finished_at timestamptz.
--   * pg_background_error: schema_name, table_name, column_name,
--       constraint_name (sourced from edata for heap/access errors).
--   * pg_background_run_result extends pg_background_outcome with
--       timed_out + elapsed_ms, eliminating duplicate column shape.
--
-- Internal:
--   * pg_background_record_timeout() bumps the workers_timed_out counter;
--     called from pg_background_run on timeout.
-- ----------------------------------------------------------------------

-- ----------------------------------------------------------------------
-- handle type
-- ----------------------------------------------------------------------

CREATE TYPE pg_background_handle AS (
  pid    pg_catalog.int4,
  cookie pg_catalog.int8
);

-- ======================================================================
-- Canonical API (unsuffixed). The _v2 aliases live in a dedicated block
-- near the end of this file.
-- ======================================================================

-- 2-arg overload (STRICT for NULL safety)
CREATE FUNCTION pg_background_launch(
    sql pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 0
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_launch'
LANGUAGE C STRICT;

-- 3-arg overload with label parameter (not STRICT to allow NULL label)
CREATE FUNCTION pg_background_launch(
    sql pg_catalog.text,
    queue_size pg_catalog.int4,
    label pg_catalog.text
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_launch'
LANGUAGE C;

-- 2-arg submit
CREATE FUNCTION pg_background_submit(
    sql pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 0
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_submit'
LANGUAGE C STRICT;

-- 3-arg submit with label
CREATE FUNCTION pg_background_submit(
    sql pg_catalog.text,
    queue_size pg_catalog.int4,
    label pg_catalog.text
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_submit'
LANGUAGE C;

CREATE FUNCTION pg_background_result(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME', 'pg_background_result'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_detach(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_detach'
LANGUAGE C STRICT;

-- single cancel entrypoint with optional grace_ms (0 = immediate).
CREATE FUNCTION pg_background_cancel(
    pid pg_catalog.int4,
    cookie pg_catalog.int8,
    grace_ms pg_catalog.int4 DEFAULT 0
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_cancel'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pg_background_cancel(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) IS
'Cancel a worker. grace_ms = 0 sends SIGTERM only; grace_ms > 0 waits that '
'many ms for clean exit before SIGKILL (capped at 1 hour).';

-- single wait entrypoint with optional timeout_ms (<=0 blocks forever).
CREATE FUNCTION pg_background_wait(
    pid pg_catalog.int4,
    cookie pg_catalog.int8,
    timeout_ms pg_catalog.int4 DEFAULT 0
)
RETURNS pg_catalog.bool
AS 'MODULE_PATHNAME', 'pg_background_wait'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pg_background_wait(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) IS
'Wait for a worker to exit. timeout_ms <= 0 blocks indefinitely (latch-based, '
'no polling) and always returns true; timeout_ms > 0 waits up to N ms and '
'returns true if the worker stopped, false on timeout.';

-- list (record; call with column definition list, or use pg_background_list view)
CREATE FUNCTION pg_background_list()
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME', 'pg_background_list'
LANGUAGE C;

-- ----------------------------------------------------------------------
-- statistics and progress types
-- ----------------------------------------------------------------------

-- workers_timed_out is a separate counter from canceled.
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

-- renamed from pg_background_progress to free that name for the
-- worker-side report function.
CREATE TYPE pg_background_progress_info AS (
    progress_pct  pg_catalog.int4,
    progress_msg  pg_catalog.text
);

-- ----------------------------------------------------------------------
-- statistics and progress functions
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_stats()
RETURNS pg_background_stats
AS 'MODULE_PATHNAME', 'pg_background_stats'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_stats() IS
'Returns session-local statistics about background workers: launched, completed, '
'failed, canceled, timed_out, active count, average execution time, max workers.';

-- internal: called by pg_background_run on timeout.
CREATE FUNCTION pg_background_record_timeout()
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_record_timeout'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_record_timeout() IS
'Internal: increment session_stats.workers_timed_out. Called from '
'pg_background_run when a launched worker exceeds its timeout.';

-- renamed from pg_background_progress to avoid clashing with the type now
-- named pg_background_progress_info.
CREATE FUNCTION pg_background_report_progress(
    pct pg_catalog.int4,
    msg pg_catalog.text DEFAULT NULL
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_report_progress'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_report_progress(pg_catalog.int4, pg_catalog.text) IS
'Report progress from within a background worker. Call from your SQL: '
'SELECT pg_background_report_progress(50, ''Halfway done'');';

-- Progress retrieval (returns the renamed type)
CREATE FUNCTION pg_background_get_progress(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_background_progress_info
AS 'MODULE_PATHNAME', 'pg_background_get_progress'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_get_progress(pg_catalog.int4, pg_catalog.int8) IS
'Get the current progress of a background worker. Returns NULL if progress not yet reported.';

-- ----------------------------------------------------------------------
-- result info and error types
-- ----------------------------------------------------------------------

-- added started_at + finished_at.
CREATE TYPE pg_background_result_info AS (
    row_count       pg_catalog.int8,
    command_tag     pg_catalog.text,
    completed       pg_catalog.bool,
    has_error       pg_catalog.bool,
    started_at      pg_catalog.timestamptz,
    finished_at     pg_catalog.timestamptz
);

-- added schema_name, table_name, column_name, constraint_name.
-- These are populated for heap/access errors that PG already exposes via
-- edata and are NULL for errors that don't carry source-object info.
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

-- ----------------------------------------------------------------------
-- Observability functions
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_result_info(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_background_result_info
AS 'MODULE_PATHNAME', 'pg_background_result_info'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pg_background_result_info(pg_catalog.int4, pg_catalog.int8) IS
'Get result metadata (row_count, command_tag, completed, has_error, started_at, finished_at) without consuming results.';

CREATE FUNCTION pg_background_error_info(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_background_error
AS 'MODULE_PATHNAME', 'pg_background_error_info'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pg_background_error_info(pg_catalog.int4, pg_catalog.int8) IS
'Get structured error information (sqlstate, message, detail, hint, context, '
'schema_name, table_name, column_name, constraint_name) from a worker. '
'Returns NULL if no error.';

-- ----------------------------------------------------------------------
-- Batch operations
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_detach_all()
RETURNS pg_catalog.int4
AS 'MODULE_PATHNAME', 'pg_background_detach_all'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_detach_all() IS
'Detach all tracked workers in the current session. Returns number of workers detached.';

CREATE FUNCTION pg_background_cancel_all()
RETURNS pg_catalog.int4
AS 'MODULE_PATHNAME', 'pg_background_cancel_all'
LANGUAGE C;

COMMENT ON FUNCTION pg_background_cancel_all() IS
'Cancel all running workers in the current session. Returns number of workers for which cancel was requested.';

-- ----------------------------------------------------------------------
-- Convenience view over pg_background_list()
-- ----------------------------------------------------------------------

CREATE VIEW pg_background_list AS
  SELECT pid, cookie, launched_at, user_id, queue_size,
         state, sql_preview, last_error, consumed, label
    FROM pg_background_list()
      AS l(pid pg_catalog.int4, cookie pg_catalog.int8,
           launched_at pg_catalog.timestamptz, user_id pg_catalog.oid,
           queue_size pg_catalog.int4, state pg_catalog.text,
           sql_preview pg_catalog.text, last_error pg_catalog.text,
           consumed pg_catalog.bool, label pg_catalog.text);

COMMENT ON VIEW pg_background_list IS
'Session-local list of background workers tracked by this session. '
'Wraps pg_background_list() so callers do not have to repeat a column-definition list.';

-- ----------------------------------------------------------------------
-- Joined view (worker registry + pg_stat_activity)
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
-- Combined outcome snapshot type and never-raises helper
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

CREATE FUNCTION pg_background_outcome(
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

    /*
     * Reading from pg_background_list cannot raise — the list function
     * returns a snapshot of the session-local hash, never errors on a
     * missing PID, and the SELECT INTO simply leaves the targets NULL
     * when no row matches. No EXCEPTION wrapper needed.
     */
    SELECT l.state, l.consumed, l.label, l.launched_at
      INTO out.state, out.consumed, out.label, out.launched_at
      FROM pg_background_list l
     WHERE l.pid = p_pid AND l.cookie = p_cookie;

    BEGIN
        ri := pg_background_result_info(p_pid, p_cookie);
        out.completed   := ri.completed;
        out.has_error   := ri.has_error;
        out.row_count   := ri.row_count;
        out.command_tag := ri.command_tag;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    BEGIN
        er := pg_background_error_info(p_pid, p_cookie);
        out.sqlstate      := er.sqlstate;
        out.error_message := er.message;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    RETURN out;
END;
$function$;

COMMENT ON FUNCTION pg_background_outcome(pg_catalog.int4, pg_catalog.int8) IS
'Combined status snapshot (state + result_info + error_info) for a worker handle. '
'Never raises; returns NULL fields when information is unavailable.';

-- ----------------------------------------------------------------------
-- pg_background_run_result extends pg_background_outcome with run-specific
-- fields (timed_out, elapsed_ms).
-- ----------------------------------------------------------------------

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

CREATE FUNCTION pg_background_run(
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
        h := pg_background_launch(sql, queue_size);
    ELSE
        h := pg_background_launch(sql, queue_size, label);
    END IF;

    IF timeout_ms > 0 THEN
        finished := pg_background_wait(h.pid, h.cookie, timeout_ms);
        IF NOT finished THEN
            BEGIN
                PERFORM pg_background_cancel(h.pid, h.cookie, 1000);
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
            /* Account for run-driven timeout separately from explicit cancels. */
            BEGIN
                PERFORM pg_background_record_timeout();
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END IF;
    ELSE
        PERFORM pg_background_wait(h.pid, h.cookie);
        finished := true;
    END IF;

    o := pg_background_outcome(h.pid, h.cookie);
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
        PERFORM pg_background_detach(h.pid, h.cookie);
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    out.elapsed_ms := (pg_catalog.date_part('epoch', pg_catalog.clock_timestamp() - start_ts) * 1000)::pg_catalog.int8;
    RETURN out;
END;
$function$;

COMMENT ON FUNCTION pg_background_run(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text) IS
'Run a SQL command in a background worker and wait for completion. Returns '
'the full outcome snapshot plus timed_out and elapsed_ms. On timeout the '
'worker is canceled with 1s grace and the timeout is recorded in stats. '
'Returns metadata only; use launch+result for result rows.';

-- ----------------------------------------------------------------------
-- Tier A loop killers
-- ----------------------------------------------------------------------

-- A1: synchronous one-shot returning rows
CREATE FUNCTION pg_background_run_query(
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
        h := pg_background_launch(sql, queue_size);
    ELSE
        h := pg_background_launch(sql, queue_size, label);
    END IF;

    IF timeout_ms > 0 THEN
        finished := pg_background_wait(h.pid, h.cookie, timeout_ms);
        IF NOT finished THEN
            BEGIN PERFORM pg_background_cancel(h.pid, h.cookie, 1000);
            EXCEPTION WHEN OTHERS THEN NULL; END;
            BEGIN PERFORM pg_background_record_timeout();
            EXCEPTION WHEN OTHERS THEN NULL; END;
            BEGIN PERFORM pg_background_detach(h.pid, h.cookie);
            EXCEPTION WHEN OTHERS THEN NULL; END;
            RAISE EXCEPTION 'pg_background_run_query: worker did not complete within % ms', timeout_ms
                USING ERRCODE = '57014';
        END IF;
    ELSE
        PERFORM pg_background_wait(h.pid, h.cookie);
    END IF;

    o := pg_background_outcome(h.pid, h.cookie);
    IF o.has_error THEN
        BEGIN PERFORM pg_background_detach(h.pid, h.cookie);
        EXCEPTION WHEN OTHERS THEN NULL; END;
        RAISE EXCEPTION '%', COALESCE(o.error_message, 'worker error')
            USING ERRCODE = COALESCE(o.sqlstate, 'XX000');
    END IF;

    IF col_def IS NULL THEN
        BEGIN PERFORM pg_background_detach(h.pid, h.cookie);
        EXCEPTION WHEN OTHERS THEN NULL; END;
        RETURN;
    END IF;

    RETURN QUERY EXECUTE pg_catalog.format(
        'SELECT * FROM pg_background_result($1, $2) AS r(%s)', col_def
    ) USING h.pid, h.cookie;

    BEGIN PERFORM pg_background_detach(h.pid, h.cookie);
    EXCEPTION WHEN OTHERS THEN NULL; END;
    RETURN;
END;
$function$;

COMMENT ON FUNCTION pg_background_run_query(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text, pg_catalog.text) IS
'Synchronous launch+wait+result+detach with rows. col_def must match the AS clause at the call site, e.g. '
'SELECT * FROM pg_background_run_query(''SELECT 1'', col_def => ''x int'') AS r(x int).';

-- A2: drain — wait for all handles, return one outcome each
CREATE FUNCTION pg_background_drain(
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
                o := pg_background_outcome(h.pid, h.cookie);
                RETURN NEXT o;
                CONTINUE;
            END IF;
            PERFORM pg_background_wait(h.pid, h.cookie, remaining_ms::pg_catalog.int4);
        ELSE
            BEGIN PERFORM pg_background_wait(h.pid, h.cookie);
            EXCEPTION WHEN OTHERS THEN NULL; END;
        END IF;

        o := pg_background_outcome(h.pid, h.cookie);
        RETURN NEXT o;

        BEGIN PERFORM pg_background_detach(h.pid, h.cookie);
        EXCEPTION WHEN OTHERS THEN NULL; END;
    END LOOP;
    RETURN;
END;
$function$;

COMMENT ON FUNCTION pg_background_drain(pg_background_handle[], pg_catalog.int4) IS
'Wait for every handle (wall-clock total timeout shared across handles), '
'collect outcomes, and detach. Returns one row per input handle in input order.';

-- A3: wait_any — return the first handle to finish, NULL on timeout
CREATE FUNCTION pg_background_wait_any(
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
                /*
                 * pg_background_wait with timeout_ms=1 polls (timeout_ms<=0
                 * now means "block forever").
                 */
                IF pg_background_wait(h.pid, h.cookie, 1) THEN
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

COMMENT ON FUNCTION pg_background_wait_any(pg_background_handle[], pg_catalog.int4) IS
'Return the first handle whose worker has finished. Adaptive polling 50ms..500ms. '
'Returns NULL on timeout. Caller decides what to do with the still-running handles.';

-- A4: cancel_by_label — pattern-based cancel
CREATE FUNCTION pg_background_cancel_by_label(
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
            PERFORM pg_background_cancel(r.pid, r.cookie, grace_ms);
            cnt := cnt + 1;
        EXCEPTION WHEN OTHERS THEN
            /* worker may have been cleaned up between list and cancel */
            NULL;
        END;
    END LOOP;
    RETURN cnt;
END;
$function$;

COMMENT ON FUNCTION pg_background_cancel_by_label(pg_catalog.text, pg_catalog.int4) IS
'Cancel every worker whose label matches the SQL LIKE pattern. Returns count canceled.';

-- A6: purge — detach only stopped/done workers (vs detach_all which is non-discriminating).
CREATE FUNCTION pg_background_purge()
RETURNS pg_catalog.int4
LANGUAGE plpgsql
AS $function$
DECLARE
    r   pg_catalog.record;
    cnt pg_catalog.int4 := 0;
BEGIN
    FOR r IN SELECT pid, cookie FROM pg_background_list LOOP
        BEGIN
            IF pg_background_wait(r.pid, r.cookie, 1) THEN
                PERFORM pg_background_detach(r.pid, r.cookie);
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

COMMENT ON FUNCTION pg_background_purge() IS
'Detach only workers that have already stopped (success/error/cancel). '
'Returns count purged. Use detach_all() to detach all workers regardless of state.';

-- ----------------------------------------------------------------------
-- full SQL accessor — beyond the 120-char preview
-- ----------------------------------------------------------------------
CREATE FUNCTION pg_background_full_sql(
    pid    pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_catalog.text
AS 'MODULE_PATHNAME', 'pg_background_full_sql'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pg_background_full_sql(pg_catalog.int4, pg_catalog.int8) IS
'Return the full SQL the worker is running, capped at 64 KiB with a [...] '
'sentinel for longer queries. NULL if not stored. Use the list view''s '
'sql_preview for monitoring; this function is for debugging.';

-- ----------------------------------------------------------------------
-- Role: NOLOGIN executor role for clean privilege assignment
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
-- ----------------------------------------------------------------------

CREATE FUNCTION pg_background_grant_privileges(
    role_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
/*
 * Grant the standard set of pg_background privileges to a role.
 *
 * Discovers extension-owned objects via pg_depend rather than maintaining
 * an explicit list. New functions/types/views registered by ALTER EXTENSION
 * UPDATE are picked up automatically.
 */
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
           -- security: never grant EXECUTE on the SECURITY DEFINER
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

CREATE FUNCTION pg_background_revoke_privileges(
    role_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
/*
 * Revoke the standard set of pg_background privileges from a role.
 * Mirror of pg_background_grant_privileges.
 */
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

-- ======================================================================
-- DEPRECATED _v2 ALIASES
-- ----------------------------------------------------------------------
-- These exist only so callers written against the 1.x / pre-2.0 _v2 API
-- keep working unchanged. They are thin shims over the canonical
-- unsuffixed functions above and are slated for removal in 3.0. Do not
-- add new aliases here; new functions ship under their unsuffixed name.
--
-- C-backed aliases point at the same C symbol as their canonical twin
-- (no extra indirection). plpgsql aliases delegate to the canonical
-- function; pg_background_run_query is duplicated because a SQL/plpgsql
-- wrapper cannot forward a SETOF record shape without the caller's
-- column-definition list.
-- ======================================================================

CREATE FUNCTION pg_background_launch_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 0
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_launch'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_launch_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4,
    label pg_catalog.text
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_launch'
LANGUAGE C;

CREATE FUNCTION pg_background_submit_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 0
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_submit'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_submit_v2(
    sql pg_catalog.text,
    queue_size pg_catalog.int4,
    label pg_catalog.text
)
RETURNS pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_submit'
LANGUAGE C;

CREATE FUNCTION pg_background_result_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME', 'pg_background_result'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_detach_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_detach'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_cancel_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8,
    grace_ms pg_catalog.int4 DEFAULT 0
)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_cancel'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_wait_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8,
    timeout_ms pg_catalog.int4 DEFAULT 0
)
RETURNS pg_catalog.bool
AS 'MODULE_PATHNAME', 'pg_background_wait'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_list_v2()
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME', 'pg_background_list'
LANGUAGE C;

CREATE FUNCTION pg_background_stats_v2()
RETURNS pg_background_stats
AS 'MODULE_PATHNAME', 'pg_background_stats'
LANGUAGE C;

-- Note: pg_background_record_timeout / _report_progress have no _v2 alias.
-- They are new in 2.0 (record_timeout is internal; the worker-side progress
-- writer shipped through 1.10 as pg_background_progress, intentionally
-- renamed+broken in 2.0 — see docs/MIGRATION.md), so no released _v2 name
-- ever existed to preserve.

CREATE FUNCTION pg_background_get_progress_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_background_progress_info
AS 'MODULE_PATHNAME', 'pg_background_get_progress'
LANGUAGE C;

CREATE FUNCTION pg_background_result_info_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_background_result_info
AS 'MODULE_PATHNAME', 'pg_background_result_info'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_error_info_v2(
    pid pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_background_error
AS 'MODULE_PATHNAME', 'pg_background_error_info'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_detach_all_v2()
RETURNS pg_catalog.int4
AS 'MODULE_PATHNAME', 'pg_background_detach_all'
LANGUAGE C;

CREATE FUNCTION pg_background_cancel_all_v2()
RETURNS pg_catalog.int4
AS 'MODULE_PATHNAME', 'pg_background_cancel_all'
LANGUAGE C;

CREATE FUNCTION pg_background_full_sql_v2(
    pid    pg_catalog.int4,
    cookie pg_catalog.int8
)
RETURNS pg_catalog.text
AS 'MODULE_PATHNAME', 'pg_background_full_sql'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_outcome_v2(
    p_pid pg_catalog.int4,
    p_cookie pg_catalog.int8
)
RETURNS pg_background_outcome
LANGUAGE sql
AS $function$ SELECT pg_background_outcome($1, $2); $function$;

CREATE FUNCTION pg_background_run_v2(
    sql        pg_catalog.text,
    queue_size pg_catalog.int4 DEFAULT 0,
    timeout_ms pg_catalog.int4 DEFAULT 0,
    label      pg_catalog.text DEFAULT NULL
)
RETURNS pg_background_run_result
LANGUAGE sql
AS $function$ SELECT pg_background_run($1, $2, $3, $4); $function$;

-- run_query is duplicated (not delegated): a SQL/plpgsql wrapper cannot
-- forward a SETOF record shape without the caller's column-definition list.
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
        h := pg_background_launch(sql, queue_size);
    ELSE
        h := pg_background_launch(sql, queue_size, label);
    END IF;

    IF timeout_ms > 0 THEN
        finished := pg_background_wait(h.pid, h.cookie, timeout_ms);
        IF NOT finished THEN
            BEGIN PERFORM pg_background_cancel(h.pid, h.cookie, 1000);
            EXCEPTION WHEN OTHERS THEN NULL; END;
            BEGIN PERFORM pg_background_record_timeout();
            EXCEPTION WHEN OTHERS THEN NULL; END;
            BEGIN PERFORM pg_background_detach(h.pid, h.cookie);
            EXCEPTION WHEN OTHERS THEN NULL; END;
            RAISE EXCEPTION 'pg_background_run_query_v2: worker did not complete within % ms', timeout_ms
                USING ERRCODE = '57014';
        END IF;
    ELSE
        PERFORM pg_background_wait(h.pid, h.cookie);
    END IF;

    o := pg_background_outcome(h.pid, h.cookie);
    IF o.has_error THEN
        BEGIN PERFORM pg_background_detach(h.pid, h.cookie);
        EXCEPTION WHEN OTHERS THEN NULL; END;
        RAISE EXCEPTION '%', COALESCE(o.error_message, 'worker error')
            USING ERRCODE = COALESCE(o.sqlstate, 'XX000');
    END IF;

    IF col_def IS NULL THEN
        BEGIN PERFORM pg_background_detach(h.pid, h.cookie);
        EXCEPTION WHEN OTHERS THEN NULL; END;
        RETURN;
    END IF;

    RETURN QUERY EXECUTE pg_catalog.format(
        'SELECT * FROM pg_background_result($1, $2) AS r(%s)', col_def
    ) USING h.pid, h.cookie;

    BEGIN PERFORM pg_background_detach(h.pid, h.cookie);
    EXCEPTION WHEN OTHERS THEN NULL; END;
    RETURN;
END;
$function$;

CREATE FUNCTION pg_background_drain_v2(
    handles    pg_background_handle[],
    timeout_ms pg_catalog.int4 DEFAULT 0
)
RETURNS SETOF pg_background_outcome
LANGUAGE sql
AS $function$ SELECT * FROM pg_background_drain($1, $2); $function$;

CREATE FUNCTION pg_background_wait_any_v2(
    handles    pg_background_handle[],
    timeout_ms pg_catalog.int4 DEFAULT 0
)
RETURNS pg_background_handle
LANGUAGE sql
AS $function$ SELECT pg_background_wait_any($1, $2); $function$;

CREATE FUNCTION pg_background_cancel_by_label_v2(
    pattern  pg_catalog.text,
    grace_ms pg_catalog.int4 DEFAULT 0
)
RETURNS pg_catalog.int4
LANGUAGE sql
AS $function$ SELECT pg_background_cancel_by_label($1, $2); $function$;

CREATE FUNCTION pg_background_purge_v2()
RETURNS pg_catalog.int4
LANGUAGE sql
AS $function$ SELECT pg_background_purge(); $function$;

-- Note: the privilege helpers have no _v2 alias. They are new in 2.0; the
-- helpers that shipped through 1.10 were named grant_pg_background_privileges
-- / revoke_pg_background_privileges and are renamed (not _v2-aliased) in 2.0.
-- See docs/MIGRATION.md.

-- Deprecation markers (canonical replacements in parentheses).
COMMENT ON FUNCTION pg_background_launch_v2(pg_catalog.text, pg_catalog.int4) IS 'DEPRECATED in 2.0: use pg_background_launch. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_launch_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.text) IS 'DEPRECATED in 2.0: use pg_background_launch. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_submit_v2(pg_catalog.text, pg_catalog.int4) IS 'DEPRECATED in 2.0: use pg_background_submit. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_submit_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.text) IS 'DEPRECATED in 2.0: use pg_background_submit. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_result_v2(pg_catalog.int4, pg_catalog.int8) IS 'DEPRECATED in 2.0: use pg_background_result. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_detach_v2(pg_catalog.int4, pg_catalog.int8) IS 'DEPRECATED in 2.0: use pg_background_detach. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_cancel_v2(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) IS 'DEPRECATED in 2.0: use pg_background_cancel. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_wait_v2(pg_catalog.int4, pg_catalog.int8, pg_catalog.int4) IS 'DEPRECATED in 2.0: use pg_background_wait. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_list_v2() IS 'DEPRECATED in 2.0: use pg_background_list() / the pg_background_list view. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_stats_v2() IS 'DEPRECATED in 2.0: use pg_background_stats(). Removed in 3.0.';
COMMENT ON FUNCTION pg_background_get_progress_v2(pg_catalog.int4, pg_catalog.int8) IS 'DEPRECATED in 2.0: use pg_background_get_progress. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_result_info_v2(pg_catalog.int4, pg_catalog.int8) IS 'DEPRECATED in 2.0: use pg_background_result_info. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_error_info_v2(pg_catalog.int4, pg_catalog.int8) IS 'DEPRECATED in 2.0: use pg_background_error_info. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_detach_all_v2() IS 'DEPRECATED in 2.0: use pg_background_detach_all(). Removed in 3.0.';
COMMENT ON FUNCTION pg_background_cancel_all_v2() IS 'DEPRECATED in 2.0: use pg_background_cancel_all(). Removed in 3.0.';
COMMENT ON FUNCTION pg_background_full_sql_v2(pg_catalog.int4, pg_catalog.int8) IS 'DEPRECATED in 2.0: use pg_background_full_sql. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_outcome_v2(pg_catalog.int4, pg_catalog.int8) IS 'DEPRECATED in 2.0: use pg_background_outcome(). Removed in 3.0.';
COMMENT ON FUNCTION pg_background_run_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text) IS 'DEPRECATED in 2.0: use pg_background_run. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_run_query_v2(pg_catalog.text, pg_catalog.int4, pg_catalog.int4, pg_catalog.text, pg_catalog.text) IS 'DEPRECATED in 2.0: use pg_background_run_query. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_drain_v2(pg_background_handle[], pg_catalog.int4) IS 'DEPRECATED in 2.0: use pg_background_drain. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_wait_any_v2(pg_background_handle[], pg_catalog.int4) IS 'DEPRECATED in 2.0: use pg_background_wait_any. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_cancel_by_label_v2(pg_catalog.text, pg_catalog.int4) IS 'DEPRECATED in 2.0: use pg_background_cancel_by_label. Removed in 3.0.';
COMMENT ON FUNCTION pg_background_purge_v2() IS 'DEPRECATED in 2.0: use pg_background_purge(). Removed in 3.0.';

-- ----------------------------------------------------------------------
-- by default, grant privileges to the executor role.
-- Order matters: we grant BEFORE creating pg_background_drop_executor_role
-- so the helper does not end up in pgbackground_role's grant set
-- (drop is admin-only). The grant walker covers both the canonical and the
-- deprecated _v2 functions automatically (metadata-driven).
-- ----------------------------------------------------------------------
SELECT pg_background_grant_privileges('pgbackground_role', false);

-- Belt-and-braces: the grant loop above already skips SECURITY DEFINER
-- functions, but explicitly revoke EXECUTE on the privilege helpers from
-- pgbackground_role so the admin-only contract holds even if an admin
-- replays the bulk grant later.
REVOKE ALL ON FUNCTION pg_background_grant_privileges(text, boolean)  FROM pgbackground_role;
REVOKE ALL ON FUNCTION pg_background_revoke_privileges(text, boolean) FROM pgbackground_role;

-- ----------------------------------------------------------------------
-- Optional: helper to drop role explicitly (DROP EXTENSION won't).
-- Created after the grant call above so it is NOT granted to
-- pgbackground_role; the lockdown block below still revokes it from public.
-- ----------------------------------------------------------------------
CREATE FUNCTION pg_background_drop_executor_role()
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

-- ----------------------------------------------------------------------
-- Lock down PUBLIC on extension objects (no ambient capabilities).
--
-- Metadata-driven mirror of pg_background_grant_privileges: walk pg_depend
-- for everything CREATE EXTENSION just registered (deptype 'e') and REVOKE
-- ALL FROM public on each. Avoids a long, drift-prone explicit list and
-- stays correct as the surface evolves. Runs LAST so it sweeps every
-- function/type/view the install has registered, including
-- pg_background_drop_executor_role above and the _v2 aliases.
-- ----------------------------------------------------------------------

DO $lockdown$
DECLARE
    _ext_oid oid;
    _r       record;
BEGIN
    SELECT oid INTO _ext_oid FROM pg_extension WHERE extname = 'pg_background';
    IF _ext_oid IS NULL THEN
        RAISE EXCEPTION 'pg_background extension not found during lockdown';
    END IF;

    FOR _r IN
        SELECT p.oid::regprocedure AS sig
          FROM pg_depend d JOIN pg_proc p ON p.oid = d.objid
         WHERE d.classid = 'pg_proc'::regclass
           AND d.refclassid = 'pg_extension'::regclass
           AND d.refobjid = _ext_oid
           AND d.deptype = 'e'
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM public', _r.sig);
    END LOOP;

    FOR _r IN
        SELECT t.oid::regtype AS typname
          FROM pg_depend d
          JOIN pg_type   t ON t.oid = d.objid
          JOIN pg_class  c ON c.oid = t.typrelid
         WHERE d.classid = 'pg_type'::regclass
           AND d.refclassid = 'pg_extension'::regclass
           AND d.refobjid = _ext_oid
           AND d.deptype = 'e'
           AND t.typtype = 'c'
           AND c.relkind = 'c'
    LOOP
        EXECUTE format('REVOKE ALL ON TYPE %s FROM public', _r.typname);
    END LOOP;

    FOR _r IN
        SELECT c.oid::regclass AS relname
          FROM pg_depend d JOIN pg_class c ON c.oid = d.objid
         WHERE d.classid = 'pg_class'::regclass
           AND d.refclassid = 'pg_extension'::regclass
           AND d.refobjid = _ext_oid
           AND d.deptype = 'e'
           AND c.relkind IN ('v', 'r', 'm')
    LOOP
        EXECUTE format('REVOKE ALL ON TABLE %s FROM public', _r.relname);
    END LOOP;
END
$lockdown$;
