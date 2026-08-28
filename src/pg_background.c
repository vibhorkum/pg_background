/*--------------------------------------------------------------------------
 *
 * pg_background.c
 *     Run SQL commands using a background worker.
 *
 * Copyright (c) 2014-2026, Vibhor Kumar and contributors
 *
 * Licensed under the PostgreSQL License. See LICENSE file for details.
 *
 * IDENTIFICATION
 *     contrib/pg_background/pg_background.c
 *
 * SUPPORTED VERSIONS
 *     PostgreSQL 14, 15, 16, 17, 18, 19 (PG_VERSION_NUM >= 140000 && < 200000)
 *
 * DESCRIPTION
 *     This extension provides the ability to launch SQL commands in
 *     background worker processes. Workers execute autonomously and
 *     communicate results back via shared memory queues.
 *
 * KEY BEHAVIORS
 *     - Cookie-validated v2 API: launch/submit, result, detach, cancel, wait, list.
 *     - submit is fire-and-forget; detach is NOT cancel.
 *     - NOTIFY race fix: shm_mq_wait_for_attach() before returning to SQL.
 *     - Crash hygiene: never pfree() BGW handle; deterministic hash cleanup.
 *     - Cryptographically secure cookies (pg_strong_random); session-local
 *       statistics + progress reporting; bounded GUC + queue / timeout knobs.
 *
 * Per-release improvements are tracked in docs/MIGRATION.md and the README's
 * "What's new in v2.0 / earlier milestones" section, not in this file.
 *
 * -------------------------------------------------------------------------
 */

#include "postgres.h"

#include "fmgr.h"

#include "access/htup_details.h"
#include "access/printtup.h"
#include "access/xact.h"
#include "catalog/pg_type.h"
#include "commands/async.h"
#include "commands/dbcommands.h"
#include "funcapi.h"
#include "libpq/libpq.h"
#include "libpq/pqformat.h"
#include "libpq/pqmq.h"
#include "miscadmin.h"
#include "parser/analyze.h"
#include "pgstat.h"
/*
 * PG_WAIT_EXTENSION moved to utils/wait_event.h when wait events were split
 * out of pgstat.h (PG 16). PostgreSQL 19 no longer re-exports it from
 * pgstat.h, so include the dedicated header explicitly where it exists.
 */
#if PG_VERSION_NUM >= 160000
#include "utils/wait_event.h"
#endif
#include "storage/dsm.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/proc.h"
#include "storage/shm_mq.h"
#include "storage/shm_toc.h"
#include "tcop/pquery.h"
#include "tcop/utility.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/ps_status.h"
#include "utils/snapmgr.h"
#include "utils/syscache.h"
#include "utils/guc.h"
#include "utils/timeout.h"
#include "utils/timestamp.h"
#include "mb/pg_wchar.h"
#include "port.h"

#include <limits.h>
#include <signal.h>
#include <unistd.h>

#ifdef WIN32
#include "pg_background_win.h"
#endif /* WIN32 */

#include "pg_background.h"
#include "pg_background_internal.h"

/*
 * Supported PostgreSQL versions for pg_background 2.0: 14, 15, 16, 17, 18, 19.
 * Older versions would require resurrecting compat shims that have already
 * been pruned; newer majors need re-validation of background-worker and
 * shm_mq APIs. PostgreSQL 19 is currently a beta target.
 */
#if PG_VERSION_NUM < 140000 || PG_VERSION_NUM >= 200000
#error "pg_background 2.0 supports PostgreSQL 14-19 only"
#endif

/* ============================================================================
 * MODULE STATE
 * ============================================================================
 */

/* Hash table for tracking workers (session-local) */
static HTAB *worker_hash = NULL;

/*
 * Dedicated memory context for worker info allocations.
 * This prevents TopMemoryContext bloat and enables bulk cleanup.
 */
static MemoryContext WorkerInfoMemoryContext = NULL;

/* ============================================================================
 * GUC VARIABLES
 * ============================================================================
 */

/*
 * pg_background.max_workers
 *     Maximum number of concurrent background workers per session.
 *
 * This limit prevents resource exhaustion from runaway worker creation.
 * Default: 16 workers (reasonable for most workloads)
 * Range: 1-1000
 */
static int pgbg_max_workers = 16;

/*
 * pg_background.default_queue_size
 *     Default shared memory queue size for new workers.
 *
 * Can be overridden per-worker via function parameter.
 * Default: 65536 bytes (64KB)
 */
static int pgbg_default_queue_size = 65536;

/*
 * pg_background.worker_timeout
 *     Maximum execution time for background workers in milliseconds.
 *
 * Workers that exceed this timeout will be terminated. This overrides
 * the inherited statement_timeout for worker processes.
 * Default: 0 (no timeout - uses session's statement_timeout)
 */
/*
 * pgbg_worker_timeout is non-static so pg_background_worker.c can read it
 * when applying the worker-side timeout policy. Declared extern in
 * pg_background_internal.h.
 */
int pgbg_worker_timeout = 0;

/* ============================================================================
 * STATISTICS / SHARED STATE
 * ============================================================================
 */

/*
 * Session-local statistics for monitoring and debugging.
 * Type defined in pg_background_internal.h so the worker side can update
 * counters in future splits.
 */
pgbg_stats session_stats = {0};

/*
 * Worker-side: pointer to current DSM segment for progress reporting.
 * Set by pg_background_worker_main; consulted by pg_background_report_progress.
 * Non-static so pg_background_worker.c can write it. NULL in launcher.
 */
dsm_segment *worker_dsm_seg = NULL;

/* ============================================================================
 * FORWARD DECLARATIONS
 * ============================================================================
 */

/* Cleanup and lookup functions */
static void cleanup_worker_info(dsm_segment *seg, Datum pid_datum);
static pg_background_worker_info *find_worker_info(pid_t pid);
static void check_rights(pg_background_worker_info *info);
static void save_worker_info(pid_t pid, uint64 cookie, dsm_segment *seg,
                             BackgroundWorkerHandle *handle,
                             shm_mq_handle *responseq,
                             bool result_disabled,
                             int32 queue_size,
                             const char *sql_preview,
                             const char *label,
                             const char *full_sql);

/*
 * pg_background_error_context callback is defined in this file and exposed
 * to the worker via pg_background_internal.h, so no static prototype is
 * needed here.
 */

/* Error handling helpers used only on the launcher side. */
static void throw_untranslated_error(ErrorData translated_edata);
static void store_worker_error(pg_background_worker_info *info, const char *message);

/* Result processing */
static HeapTuple form_result_tuple(pg_background_result_state *state,
                                   TupleDesc tupdesc, StringInfo msg);

/* Internal launcher (shared by v1 and v2 APIs) */
static void launch_internal(text *sql, int32 queue_size, uint64 cookie,
                            bool result_disabled,
                            const char *label,
                            pid_t *out_pid);

/* Helper to build handle tuple (eliminates duplication) */
static Datum build_handle_tuple(FunctionCallInfo fcinfo, pid_t pid, uint64 cookie);

/* Ensure WorkerInfoMemoryContext exists */
static void ensure_worker_info_memory_context(void);

/* Polling with exponential backoff */
static void pgbg_sleep_with_backoff(long *interval_us, long remaining_us);
static bool pgbg_wait_for_stop(pg_background_worker_info *info, int32 timeout_ms);

/* v2 API helpers */
static uint64 pg_background_make_cookie(void);
static void pgbg_request_cancel(pg_background_worker_info *info);
static void pgbg_send_cancel_signals(pg_background_worker_info *info, int32 grace_ms);
static const char *pgbg_state_from_handle(pg_background_worker_info *info);
static bool detach_worker_seg(pg_background_worker_info *info);

/* ============================================================================
 * MODULE MAGIC AND FUNCTION DECLARATIONS
 * ============================================================================
 */

PG_MODULE_MAGIC;

/*
 * v2.0: the v1 (no-suffix) API is gone. cancel / wait are now single
 * entrypoints that take (pid, cookie, grace_ms) and (pid, cookie, timeout_ms);
 * the separate _grace / _timeout exports were removed.
 */

/* v2 API */
PG_FUNCTION_INFO_V1(pg_background_launch);
PG_FUNCTION_INFO_V1(pg_background_submit);
PG_FUNCTION_INFO_V1(pg_background_result);
PG_FUNCTION_INFO_V1(pg_background_detach);
PG_FUNCTION_INFO_V1(pg_background_cancel);
PG_FUNCTION_INFO_V1(pg_background_wait);
PG_FUNCTION_INFO_V1(pg_background_list);

/* Worker entry point lives in pg_background_worker.c.
 * Declaration is in pg_background_internal.h.
 */

/* Module initialization */
PGDLLEXPORT void _PG_init(void);

/* Statistics retrieval function */
PG_FUNCTION_INFO_V1(pg_background_stats);

/* v2.0 (B3d): progress reporting renamed for naming coherence */
PG_FUNCTION_INFO_V1(pg_background_report_progress);

/* Progress retrieval function */
PG_FUNCTION_INFO_V1(pg_background_get_progress);

/* v1.9: New observability functions */
PG_FUNCTION_INFO_V1(pg_background_result_info);
PG_FUNCTION_INFO_V1(pg_background_error_info);
PG_FUNCTION_INFO_V1(pg_background_detach_all);
PG_FUNCTION_INFO_V1(pg_background_cancel_all);

/* v1.10 (B3): full SQL accessor */
PG_FUNCTION_INFO_V1(pg_background_full_sql);

/* v2.0 (B5a): private bumper called by run PL/pgSQL on timeout */
PG_FUNCTION_INFO_V1(pg_background_record_timeout);

/* ============================================================================
 * MODULE INITIALIZATION
 * ============================================================================
 */

/*
 * _PG_init
 *     Extension initialization - called when the shared library is loaded.
 *
 * Registers custom GUC variables for configuration.
 */
void
_PG_init(void)
{
    /* Define pg_background.max_workers */
    DefineCustomIntVariable("pg_background.max_workers",
                            "Maximum number of concurrent background workers per session.",
                            "Prevents resource exhaustion from excessive worker creation.",
                            &pgbg_max_workers,
                            16,         /* default */
                            1,          /* min */
                            1000,       /* max */
                            PGC_USERSET,
                            0,
                            NULL,
                            NULL,
                            NULL);

    /* Define pg_background.default_queue_size */
    /* Runtime check: ensure shm_mq_minimum_size fits in int for GUC */
    Assert(shm_mq_minimum_size <= PG_INT32_MAX);
    DefineCustomIntVariable("pg_background.default_queue_size",
                            "Default shared memory queue size for workers.",
                            "Can be overridden per-worker. Larger sizes support bigger result sets.",
                            &pgbg_default_queue_size,
                            65536,                  /* default: 64KB */
                            (int) shm_mq_minimum_size,  /* min */
                            PGBG_QUEUE_SIZE_MAX,    /* max */
                            PGC_USERSET,
                            GUC_UNIT_BYTE,
                            NULL,
                            NULL,
                            NULL);

    /* Define pg_background.worker_timeout */
    DefineCustomIntVariable("pg_background.worker_timeout",
                            "Maximum execution time for background workers.",
                            "Workers exceeding this timeout are terminated. 0 means no limit.",
                            &pgbg_worker_timeout,
                            0,          /* default: no timeout */
                            0,          /* min */
                            INT_MAX,    /* max */
                            PGC_USERSET,
                            GUC_UNIT_MS,
                            NULL,
                            NULL,
                            NULL);

    /*
     * MarkGUCPrefixReserved was added in PostgreSQL 15.
     * In earlier versions, GUC prefix reservation is not available.
     */
#if PG_VERSION_NUM >= 150000
    MarkGUCPrefixReserved("pg_background");
#endif
}

/* ============================================================================
 * MEMORY CONTEXT MANAGEMENT
 * ============================================================================
 */

/*
 * ensure_worker_info_memory_context
 *     Create the dedicated memory context for worker info if not exists.
 *
 * This context is a child of TopMemoryContext and is used for:
 * - Worker hash table entries
 * - Error message strings
 * - Other per-worker allocations
 *
 * Using a dedicated context prevents TopMemoryContext bloat and enables
 * efficient bulk cleanup when needed.
 */
static void
ensure_worker_info_memory_context(void)
{
    if (WorkerInfoMemoryContext == NULL)
    {
        WorkerInfoMemoryContext = AllocSetContextCreate(TopMemoryContext,
                                                        "pg_background worker info",
                                                        ALLOCSET_DEFAULT_SIZES);
    }
}

/* ============================================================================
 * COOKIE GENERATION
 * ============================================================================
 */

/*
 * pg_background_make_cookie
 *     Generate a cryptographically secure 64-bit cookie for worker identity.
 *
 * The cookie is used in the v2 API to prevent PID reuse attacks. Even if
 * a PID is recycled by the OS, the cookie will differ, preventing
 * operations on the wrong worker.
 *
 * SECURITY: Uses pg_strong_random(), which is backed by the OS CSPRNG
 * (e.g., /dev/urandom on Unix, CryptGenRandom on Windows). On a configured
 * backend pg_strong_random does not fail in any path that's been observed
 * in the wild, so v2.0 simply raises ERROR on the impossible case rather
 * than falling back to a weaker generator. If you ever see this error you
 * have a fundamentally broken CSPRNG and worker cookies are the least of
 * your problems.
 *
 * The cookie is forced non-zero so that callers cannot accidentally pass
 * the literal 0 from a stale handle and silently match.
 *
 * Returns: 64-bit random cookie (never returns 0)
 */
static uint64
pg_background_make_cookie(void)
{
    uint64 cookie;

    if (!pg_strong_random(&cookie, sizeof(cookie)))
        ereport(ERROR,
                (errcode(ERRCODE_INTERNAL_ERROR),
                 errmsg("pg_background: pg_strong_random failed to generate a worker cookie"),
                 errhint("This indicates a broken OS CSPRNG and is not normally recoverable.")));

    /*
     * Ensure cookie is never zero so a stale handle initialised to 0 cannot
     * accidentally match a live worker. 0x9e3779b97f4a7c15 is the golden-
     * ratio constant used widely as a hash seed for good bit distribution.
     */
    if (cookie == 0)
        cookie = 0x9e3779b97f4a7c15ULL;

    return cookie;
}

/* ============================================================================
 * UTILITY FUNCTIONS
 * ============================================================================
 */

/*
 * pgbg_timestamp_diff_ms
 *     Calculate milliseconds elapsed between two timestamps.
 *
 * TimestampTz is int64 microseconds since PostgreSQL epoch.
 * Returns 0 for negative differences (clock skew protection).
 * Caps result at LONG_MAX to prevent overflow on very long durations.
 */
static inline long
pgbg_timestamp_diff_ms(TimestampTz start, TimestampTz stop)
{
    int64 diff_us = (int64) stop - (int64) start;

    /* Clock skew protection */
    if (diff_us < 0)
        return 0;

    /*
     * Overflow protection: cap at LONG_MAX milliseconds (~24 days on 32-bit).
     * Division cannot overflow; comparing result against LONG_MAX works because
     * LONG_MAX is promoted to int64 for comparison on 32-bit systems.
     */
    if (diff_us / 1000 > LONG_MAX)
        return LONG_MAX;

    return (long) (diff_us / 1000);
}

/*
 * pgbg_sleep_with_backoff
 *     Sleep for the current interval and increase it exponentially.
 *
 * This reduces CPU usage when polling for worker state changes.
 * The interval doubles each call up to PGBG_POLL_INTERVAL_MAX_US.
 *
 * Parameters:
 *     interval_us   - Pointer to current interval in microseconds.
 *                     Updated to next interval after sleeping.
 *     remaining_us  - Maximum time to sleep (0 = use interval_us).
 *                     Prevents overshooting timeouts/grace periods.
 */
static void
pgbg_sleep_with_backoff(long *interval_us, long remaining_us)
{
    long sleep_time = *interval_us;

    /* Cap sleep time to remaining time if specified */
    if (remaining_us > 0 && sleep_time > remaining_us)
        sleep_time = remaining_us;

    if (sleep_time > 0)
        pg_usleep(sleep_time);

    /* Exponential backoff with cap */
    *interval_us *= PGBG_POLL_BACKOFF_FACTOR;
    if (*interval_us > PGBG_POLL_INTERVAL_MAX_US)
        *interval_us = PGBG_POLL_INTERVAL_MAX_US;

    /*
     * Add a small (~12.5%) random jitter so concurrent sessions polling the
     * same workers do not converge to identical wake-up times (thundering
     * herd). random() is fine here — we are not doing cryptographic work,
     * just decorrelating timing across sessions.
     */
    if (*interval_us > 8)
        *interval_us += (long) (random() % (*interval_us / 8));
}

/*
 * pgbg_wait_for_stop
 *     Block until the worker stops, or timeout_ms elapses.
 *
 * Returns:
 *   true  - worker is BGWH_STOPPED (or info/handle was NULL: nothing to wait for)
 *   false - timeout expired and the worker is still running
 *
 * Shared by pg_background_wait and pgbg_send_cancel_signals'
 * grace period; keeping the loop in one place makes the
 * CHECK_FOR_INTERRUPTS / backoff / remaining-time accounting consistent.
 */
static bool
pgbg_wait_for_stop(pg_background_worker_info *info, int32 timeout_ms)
{
    TimestampTz start;
    long        poll_interval_us = PGBG_POLL_INTERVAL_MIN_US;
    bool        infinite = (timeout_ms <= 0);

    if (info == NULL || info->handle == NULL)
        return true;

    start = GetCurrentTimestamp();

    for (;;)
    {
        pid_t            wpid = 0;
        BgwHandleStatus  hs;
        long             remaining_us;

        hs = GetBackgroundWorkerPid(info->handle, &wpid);
        if (hs == BGWH_STOPPED)
            return true;

        if (!infinite)
        {
            long             elapsed_ms = pgbg_timestamp_diff_ms(start, GetCurrentTimestamp());
            if (elapsed_ms >= timeout_ms)
                return false;
            remaining_us = (timeout_ms - elapsed_ms) * 1000L;
        }
        else
        {
            remaining_us = PGBG_POLL_INTERVAL_MAX_US;
        }
        pgbg_sleep_with_backoff(&poll_interval_us, remaining_us);
        CHECK_FOR_INTERRUPTS();
    }
}

/* ============================================================================
 * HANDLE TUPLE BUILDER (eliminates code duplication)
 * ============================================================================
 */

/*
 * build_handle_tuple
 *     Construct a pg_background_handle composite type value.
 *
 * Used by pg_background_launch and pg_background_submit to build
 * the return value. Eliminates code duplication between these functions.
 *
 * Parameters:
 *     fcinfo - Function call info (for tuple descriptor)
 *     pid    - Worker process ID
 *     cookie - Worker identity cookie
 *
 * Returns: HeapTuple datum for (pid, cookie) composite
 */
static Datum
build_handle_tuple(FunctionCallInfo fcinfo, pid_t pid, uint64 cookie)
{
    Datum       values[2];
    bool        isnulls[2] = {false, false};
    TupleDesc   tupdesc;
    HeapTuple   tuple;

    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("function returning composite called in context that cannot accept it")));
    tupdesc = BlessTupleDesc(tupdesc);

    values[0] = Int32GetDatum((int32) pid);
    values[1] = Int64GetDatum((int64) cookie);

    tuple = heap_form_tuple(tupdesc, values, isnulls);
    return HeapTupleGetDatum(tuple);
}

/* ============================================================================
 * INTERNAL LAUNCHER
 * ============================================================================
 */

/*
 * launch_internal
 *     Core implementation for launching a background worker.
 *
 * This function is shared by both v1 and v2 launch APIs. It handles:
 * - DSM segment creation and initialization
 * - Background worker registration
 * - Shared memory queue setup
 * - Worker startup synchronization
 *
 * The NOTIFY race condition is fixed by calling shm_mq_wait_for_attach()
 * before returning, ensuring the worker has attached to the queue.
 *
 * Parameters:
 *     sql             - SQL command(s) to execute
 *     queue_size      - Shared memory queue size in bytes
 *     cookie          - Worker identity cookie (0 for v1 API)
 *     result_disabled - True if results should be discarded (submit)
 *     out_pid         - Output: worker process ID
 */
static void
launch_internal(text *sql, int32 queue_size, uint64 cookie,
                bool result_disabled,
                const char *label,
                pid_t *out_pid)
{
    int32        sql_len = VARSIZE_ANY_EXHDR(sql);
    Size         guc_len;
    Size         segsize;
    dsm_segment *seg;
    shm_toc_estimator e;
    shm_toc     *toc;
    char        *sqlp;
    char        *gucstate;
    shm_mq      *mq;
    BackgroundWorker worker;
    BackgroundWorkerHandle *worker_handle;
    pg_background_input  *input;
    pg_background_output *output;
    pid_t        pid;
    shm_mq_handle *responseq;
    MemoryContext oldcontext;
    char preview[PGBG_SQL_PREVIEW_LEN + 1];
    int preview_len;

    /*
     * Apply default queue size from GUC if not specified (0 or negative).
     * This allows users to control the default via pg_background.default_queue_size
     * without having to specify it on every function call.
     */
    if (queue_size <= 0)
        queue_size = pgbg_default_queue_size;

    if (((uint64) queue_size) < shm_mq_minimum_size)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("queue size must be at least %zu bytes",
                        shm_mq_minimum_size)));

    if (queue_size > PGBG_QUEUE_SIZE_MAX)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("queue size must not exceed %d bytes",
                        PGBG_QUEUE_SIZE_MAX),
                 errhint("Large result sets should be written to a table instead.")));

    /* Check max_workers limit */
    if (worker_hash != NULL &&
        hash_get_num_entries(worker_hash) >= pgbg_max_workers)
        ereport(ERROR,
                (errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
                 errmsg("too many background workers"),
                 errdetail("Current limit is %d concurrent workers per session.", pgbg_max_workers),
                 errhint("Wait for existing workers to complete, or increase pg_background.max_workers.")));

    /* Validate label length (v1.9) */
    if (label != NULL && strlen(label) > PGBG_LABEL_MAX_LEN)
        ereport(ERROR,
                (errcode(ERRCODE_STRING_DATA_RIGHT_TRUNCATION),
                 errmsg("label too long"),
                 errdetail("Label length %zu exceeds maximum of %d bytes.",
                           strlen(label), PGBG_LABEL_MAX_LEN)));

    /* Ensure worker info memory context exists */
    ensure_worker_info_memory_context();

    /* Estimate / allocate DSM (v2.0 (C1) split: input + output as separate keys) */
    shm_toc_initialize_estimator(&e);
    shm_toc_estimate_chunk(&e, sizeof(pg_background_input));
    shm_toc_estimate_chunk(&e, sizeof(pg_background_output));
    shm_toc_estimate_chunk(&e, sql_len + 1);
    guc_len = EstimateGUCStateSpace();
    shm_toc_estimate_chunk(&e, guc_len);
    shm_toc_estimate_chunk(&e, (Size) queue_size);
    shm_toc_estimate_keys(&e, PG_BACKGROUND_NKEYS);
    segsize = shm_toc_estimate(&e);

    seg = dsm_create(segsize, 0);
    if (seg == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_OUT_OF_MEMORY),
                 errmsg("could not create dynamic shared memory segment"),
                 errhint("You may need to increase dynamic_shared_memory_bytes or max_worker_processes.")));

    toc = shm_toc_create(PG_BACKGROUND_MAGIC, dsm_segment_address(seg), segsize);

    /* Input (launcher → worker, immutable post-launch except cancel_requested) */
    input = shm_toc_allocate(toc, sizeof(pg_background_input));
    input->database_id = MyDatabaseId;
    input->authenticated_user_id = GetAuthenticatedUserId();
    GetUserIdAndSecContext(&input->current_user_id, &input->sec_context);
    namestrcpy(&input->database, get_database_name(MyDatabaseId));
    namestrcpy(&input->authenticated_user,
               GetUserNameFromId(input->authenticated_user_id, false));
    input->cookie = cookie;
    input->cancel_requested = 0;
    if (label != NULL && label[0] != '\0')
        strlcpy(input->label, label, sizeof(input->label));
    else
        input->label[0] = '\0';
    shm_toc_insert(toc, PG_BACKGROUND_KEY_INPUT, input);

    /* Output (worker → launcher) — zero-init the whole struct, then patch the
     * one field that should not start at zero. */
    output = shm_toc_allocate(toc, sizeof(pg_background_output));
    memset(output, 0, sizeof(pg_background_output));
    output->progress_pct = -1;          /* -1 = not reported yet */
    shm_toc_insert(toc, PG_BACKGROUND_KEY_OUTPUT, output);

    /* SQL text */
    sqlp = shm_toc_allocate(toc, sql_len + SQL_TERMINATOR_LEN);
    memcpy(sqlp, VARDATA(sql), sql_len);
    sqlp[sql_len] = '\0';
    shm_toc_insert(toc, PG_BACKGROUND_KEY_SQL, sqlp);

    /*
     * GUC state.
     *
     * NOTE on GUC propagation: SerializeGUCState copies the launcher's full
     * GUC state — every variable the planner/executor cares about plus
     * session-local knobs the worker may not honour the same way (for
     * example, idle_in_transaction_session_timeout, lock_timeout,
     * search_path, role-based settings). The worker calls RestoreGUCState
     * at startup before executing the caller's SQL, so this is intentional
     * and matches how PostgreSQL parallel workers propagate GUCs. If you
     * need a worker to run with a tighter or different GUC profile, set the
     * GUC in the launching session before calling launch/submit.
     */
    gucstate = shm_toc_allocate(toc, guc_len);
    SerializeGUCState(guc_len, gucstate);
    shm_toc_insert(toc, PG_BACKGROUND_KEY_GUC, gucstate);

    /* MQ */
    mq = shm_mq_create(shm_toc_allocate(toc, (Size) queue_size),
                       (Size) queue_size);
    shm_toc_insert(toc, PG_BACKGROUND_KEY_QUEUE, mq);
    shm_mq_set_receiver(mq, MyProc);

    /* Worker config (no allocations needed) */
    MemSet(&worker, 0, sizeof(worker));
    worker.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
    worker.bgw_start_time = BgWorkerStart_ConsistentState;
    worker.bgw_restart_time = BGW_NEVER_RESTART;

    snprintf(worker.bgw_library_name, BGW_MAXLEN, "pg_background");
    snprintf(worker.bgw_function_name, BGW_MAXLEN, "pg_background_worker_main");
    snprintf(worker.bgw_name, BGW_MAXLEN, "pg_background by PID %d", MyProcPid);
    snprintf(worker.bgw_type, BGW_MAXLEN, "pg_background");

    worker.bgw_main_arg = UInt32GetDatum(dsm_segment_handle(seg));
    worker.bgw_notify_pid = MyProcPid;

    /*
     * Allocate MQ handle and register worker in WorkerInfoMemoryContext.
     * Consolidated context switch for efficiency.
     *
     * C1: BackgroundWorkerHandle lifetime is managed by PostgreSQL.
     * CRITICAL: Do NOT pfree(worker_handle). PostgreSQL owns this memory
     * and will clean it up internally. Calling pfree() on this handle
     * will cause use-after-free bugs and potential crashes.
     *
     * The handle remains valid until:
     * 1. The background worker process exits, OR
     * 2. The current session ends
     */
    oldcontext = MemoryContextSwitchTo(WorkerInfoMemoryContext);

    responseq = shm_mq_attach(mq, seg, NULL);

    if (!RegisterDynamicBackgroundWorker(&worker, &worker_handle))
    {
        MemoryContextSwitchTo(oldcontext);
        /* Clean up DSM segment to prevent resource leak */
        dsm_detach(seg);
        ereport(ERROR,
                (errcode(ERRCODE_INSUFFICIENT_RESOURCES),
                 errmsg("could not register background process"),
                 errhint("Background worker slots are exhausted. Check the cluster-wide "
                         "max_worker_processes setting and the per-session "
                         "pg_background.max_workers GUC, and inspect existing workers "
                         "with SELECT * FROM pg_background_list to identify candidates "
                         "to detach or cancel.")));
    }

    MemoryContextSwitchTo(oldcontext);

    shm_mq_set_handle(responseq, worker_handle);

    switch (WaitForBackgroundWorkerStartup(worker_handle, &pid))
    {
        case BGWH_STARTED:
        case BGWH_STOPPED:
            break;
        case BGWH_POSTMASTER_DIED:
            ereport(ERROR,
                    (errcode(ERRCODE_INSUFFICIENT_RESOURCES),
                     errmsg("cannot start background processes without postmaster"),
                     errhint("Kill all remaining database processes and restart the database.")));
            break;
        default:
            elog(ERROR, "unexpected bgworker handle status");
            break;
    }

    /*
     * Critical NOTIFY/DSM race fix:
     * Wait until worker attaches as sender before we return to SQL.
     */
    shm_mq_wait_for_attach(responseq);

    /*
     * Prepare preview with UTF-8 aware truncation.
     * pg_mbcliplen() ensures we don't cut multi-byte characters mid-sequence.
     */
    preview_len = pg_mbcliplen(VARDATA(sql), sql_len, PGBG_SQL_PREVIEW_LEN);
    memcpy(preview, VARDATA(sql), preview_len);
    preview[preview_len] = '\0';

    /*
     * Build a NUL-terminated full SQL cstring for save_worker_info to copy
     * into WorkerInfoMemoryContext. save_worker_info caps and copies; this
     * temporary buffer is freed with the current memory context.
     */
    {
        char *full_sql_cstr = palloc(sql_len + 1);
        memcpy(full_sql_cstr, VARDATA(sql), sql_len);
        full_sql_cstr[sql_len] = '\0';

        /* Save info */
        save_worker_info(pid, cookie, seg, worker_handle, responseq,
                         result_disabled, queue_size, preview, label,
                         full_sql_cstr);
    }

    /* Pin mapping so txn cleanup won't detach underneath us */
    dsm_pin_mapping(seg);

    /* Mark pinned */
    {
        pg_background_worker_info *info = find_worker_info(pid);
        if (info)
            info->mapping_pinned = true;
    }

    /* Update session statistics */
    session_stats.workers_launched++;

    *out_pid = pid;
}

/* ============================================================================
 * V2 API FUNCTIONS
 * ============================================================================
 */

/*
 * pg_background_launch
 *     Launch a background worker with cookie validation (v2 API).
 *
 * Parameters:
 *     sql        - SQL command(s) to execute (text)
 *     queue_size - Shared memory queue size in bytes (default: uses
 *                  pg_background.default_queue_size GUC, typically 64KB)
 *     label      - Optional worker label for operational clarity (v1.9+)
 *
 * Returns: pg_background_handle composite (pid int4, cookie int8)
 *
 * Notes:
 *     - Cookie provides protection against PID reuse attacks
 *     - Results retrieved with pg_background_result(pid, cookie)
 *     - Use pg_background_cancel() to cancel (unlike v1 detach)
 */
Datum
pg_background_launch(PG_FUNCTION_ARGS)
{
    text   *sql;
    int32   queue_size;
    const char *label = NULL;
    pid_t   pid;
    uint64  cookie = pg_background_make_cookie();

    /* Required: sql parameter cannot be NULL */
    if (PG_ARGISNULL(0))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("sql parameter cannot be NULL")));
    sql = PG_GETARG_TEXT_PP(0);

    /* Optional: queue_size defaults to 0 if NULL */
    queue_size = PG_ARGISNULL(1) ? 0 : PG_GETARG_INT32(1);

    /* v1.9: Optional label parameter */
    if (PG_NARGS() >= 3 && !PG_ARGISNULL(2))
    {
        text *label_text = PG_GETARG_TEXT_PP(2);
        label = text_to_cstring(label_text);
    }

    launch_internal(sql, queue_size, cookie, false, label, &pid);
    PG_RETURN_DATUM(build_handle_tuple(fcinfo, pid, cookie));
}

/*
 * pg_background_submit
 *     Launch a fire-and-forget background worker (v2 API).
 *
 * Similar to launch but results are discarded. The worker runs
 * autonomously and cannot be queried for results.
 *
 * Parameters:
 *     sql        - SQL command(s) to execute (text)
 *     queue_size - Shared memory queue size in bytes (default: uses
 *                  pg_background.default_queue_size GUC, typically 64KB)
 *     label      - Optional worker label for operational clarity (v1.9+)
 *
 * Returns: pg_background_handle composite (pid int4, cookie int8)
 *
 * Notes:
 *     - Calling result() on a submitted worker raises an error
 *     - Worker can still be canceled with cancel()
 *     - Use for side-effect-only operations (logging, notifications)
 */
Datum
pg_background_submit(PG_FUNCTION_ARGS)
{
    text   *sql;
    int32   queue_size;
    const char *label = NULL;
    pid_t   pid;
    uint64  cookie = pg_background_make_cookie();

    /* Required: sql parameter cannot be NULL */
    if (PG_ARGISNULL(0))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("sql parameter cannot be NULL")));
    sql = PG_GETARG_TEXT_PP(0);

    /* Optional: queue_size defaults to 0 if NULL */
    queue_size = PG_ARGISNULL(1) ? 0 : PG_GETARG_INT32(1);

    /* v1.9: Optional label parameter */
    if (PG_NARGS() >= 3 && !PG_ARGISNULL(2))
    {
        text *label_text = PG_GETARG_TEXT_PP(2);
        label = text_to_cstring(label_text);
    }

    launch_internal(sql, queue_size, cookie, true, label, &pid);
    PG_RETURN_DATUM(build_handle_tuple(fcinfo, pid, cookie));
}

/* ============================================================================
 * ERROR HANDLING
 * ============================================================================
 */

/*
 * throw_untranslated_error
 *     Re-throw an error with client-to-server encoding conversion.
 *
 * When errors are transmitted via the shared memory queue, they may
 * be in client encoding. This function converts them back to server
 * encoding before re-throwing.
 */
static void
throw_untranslated_error(ErrorData translated_edata)
{
    ErrorData untranslated_edata = translated_edata;

#define UNTRANSLATE(field) \
    do { \
        if (translated_edata.field != NULL) \
            untranslated_edata.field = pg_client_to_server(translated_edata.field, \
                                                          strlen(translated_edata.field)); \
    } while (0)

    UNTRANSLATE(message);
    UNTRANSLATE(detail);
    UNTRANSLATE(detail_log);
    UNTRANSLATE(hint);
    UNTRANSLATE(context);

    ThrowErrorData(&untranslated_edata);
}

/*
 * store_worker_error
 *     Store an error message in the worker info for list() visibility.
 *
 * Error messages are truncated to PGBG_MAX_ERROR_MSG_LEN to prevent
 * memory bloat from malicious or buggy workers sending huge errors.
 */
static void
store_worker_error(pg_background_worker_info *info, const char *message)
{
    MemoryContext oldcxt;

    if (info == NULL)
        return;

    ensure_worker_info_memory_context();
    oldcxt = MemoryContextSwitchTo(WorkerInfoMemoryContext);

    /* Free previous error if any */
    if (info->last_error != NULL)
    {
        pfree(info->last_error);
        info->last_error = NULL;
    }

    if (message != NULL)
    {
        size_t msg_len = strlen(message);
        if (msg_len > PGBG_MAX_ERROR_MSG_LEN)
        {
            /*
             * Truncate with ellipsis indicator, UTF-8 aware.
             * pg_mbcliplen() ensures we don't cut multi-byte characters.
             */
            int clip_len = pg_mbcliplen(message, msg_len, PGBG_MAX_ERROR_MSG_LEN - 3);
            char *truncated = palloc(clip_len + 4);  /* +4 for "..." and null */
            memcpy(truncated, message, clip_len);
            strcpy(truncated + clip_len, "...");
            info->last_error = truncated;
        }
        else
        {
            info->last_error = pstrdup(message);
        }
    }
    else
    {
        info->last_error = pstrdup("unknown error");
    }

    MemoryContextSwitchTo(oldcxt);
}

/* ============================================================================
 * RESULT RETRIEVAL
 * ============================================================================
 */

/*
 * pg_background_result
 *     Retrieve results from a background worker (v2 API).
 *
 * Set-returning function that streams results from the worker's shared
 * memory queue. Results can only be consumed once. The caller's cookie
 * is validated against the worker's identity to prevent PID-reuse hits.
 *
 * Parameters:
 *     pid    - Worker process ID
 *     cookie - Worker identity cookie from launch
 *
 * Returns: SETOF record (caller must provide column definition list)
 *
 * Errors:
 *     - UNDEFINED_OBJECT: PID not attached, cookie mismatch, or results
 *                         already consumed
 *     - FEATURE_NOT_SUPPORTED: Worker was launched via submit
 *     - CONNECTION_FAILURE: Worker died before sending results
 */
Datum
pg_background_result(PG_FUNCTION_ARGS)
{
    int32        pid = PG_GETARG_INT32(0);
    int64        cookie_in = PG_GETARG_INT64(1);
    shm_mq_result res;
    FuncCallContext *funcctx;
    TupleDesc    tupdesc;
    StringInfoData msg;
    pg_background_result_state *state;

    if (SRF_IS_FIRSTCALL())
    {
        MemoryContext oldcontext;
        pg_background_worker_info *info;
        dsm_segment *seg;

        funcctx = SRF_FIRSTCALL_INIT();
        oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

        info = find_worker_info(pid);
        if (info == NULL)
            ereport(ERROR,
                    (errcode(ERRCODE_UNDEFINED_OBJECT),
                     errmsg("PID %d is not attached to this session", pid)));
        check_rights(info);

        if (info->cookie != (uint64) cookie_in)
            ereport(ERROR,
                    (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                     errmsg("cookie mismatch for PID %d", pid),
                     errhint("The worker may have been restarted or the handle is stale.")));

        if (info->result_disabled)
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("results are disabled for PID %d (submitted via pg_background_submit)", pid)));

        if (info->consumed)
            ereport(ERROR,
                    (errcode(ERRCODE_UNDEFINED_OBJECT),
                     errmsg("results for PID %d have already been consumed", pid)));
        info->consumed = true;

        seg = info->seg;

        /* Unpin exactly once */
        if (info->mapping_pinned)
        {
            dsm_unpin_mapping(seg);
            info->mapping_pinned = false;
        }

        if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("function returning record called in context that cannot accept type record"),
                     errhint("Call it in FROM with a column definition list.")));

        funcctx->tuple_desc = BlessTupleDesc(tupdesc);

        state = palloc0(sizeof(pg_background_result_state));
        state->info = info;

        if (funcctx->tuple_desc->natts > 0)
        {
            int natts = funcctx->tuple_desc->natts;
            int i;

            state->receive_functions = palloc(sizeof(FmgrInfo) * natts);
            state->typioparams = palloc(sizeof(Oid) * natts);

            for (i = 0; i < natts; i++)
            {
                Oid recvfn;
                getTypeBinaryInputInfo(TupleDescAttr(funcctx->tuple_desc, i)->atttypid,
                                       &recvfn,
                                       &state->typioparams[i]);
                fmgr_info(recvfn, &state->receive_functions[i]);
            }
        }

        funcctx->user_fctx = state;
        MemoryContextSwitchTo(oldcontext);
    }

    funcctx = SRF_PERCALL_SETUP();
    tupdesc = funcctx->tuple_desc;
    state = funcctx->user_fctx;

    initStringInfo(&msg);

    for (;;)
    {
        char        msgtype;
        Size        nbytes;
        void       *data;

        /*
         * I3: CHECK_FOR_INTERRUPTS in result loop
         *
         * Allows cancellation of long-running result retrieval (e.g., large
         * result sets streaming from worker). Without this, Ctrl-C or
         * pg_terminate_backend() won't interrupt the launcher session while
         * it's blocked reading results.
         */
        CHECK_FOR_INTERRUPTS();

        /*
         * v2.0 (C3): non-blocking receive + WaitLatch instead of a blocking
         * shm_mq_receive(..., false). A worker that attaches the queue but
         * never sends and never exits would otherwise hang the launcher
         * session indefinitely (CHECK_FOR_INTERRUPTS lets the user Ctrl-C
         * out, but no automatic recovery).
         *
         * Loop pattern:
         *   1) try a non-blocking receive;
         *   2) on WOULD_BLOCK, check whether the BGW has stopped — if so,
         *      one final non-blocking receive picks up any in-flight data,
         *      then we treat the queue as detached;
         *   3) otherwise WaitLatch on MyLatch with a 250 ms timeout, so we
         *      re-check liveness periodically and react to incoming data
         *      via the latch shm_mq sets when bytes are available.
         */
        for (;;)
        {
            res = shm_mq_receive(state->info->responseq, &nbytes, &data, true);
            if (res != SHM_MQ_WOULD_BLOCK)
                break;

            if (state->info->handle != NULL)
            {
                pid_t              wpid = 0;
                BgwHandleStatus    hs   = GetBackgroundWorkerPid(state->info->handle, &wpid);

                if (hs == BGWH_STOPPED || hs == BGWH_POSTMASTER_DIED)
                {
                    /* Drain any final byte still in the queue, then exit. */
                    res = shm_mq_receive(state->info->responseq, &nbytes, &data, true);
                    if (res == SHM_MQ_WOULD_BLOCK)
                        res = SHM_MQ_DETACHED;
                    break;
                }
            }

            (void) WaitLatch(MyLatch,
                             WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
                             250L,
                             PG_WAIT_EXTENSION);
            ResetLatch(MyLatch);
            CHECK_FOR_INTERRUPTS();
        }
        if (res != SHM_MQ_SUCCESS)
            break;

        resetStringInfo(&msg);
        enlargeStringInfo(&msg, nbytes);
        msg.len = nbytes;
        memcpy(msg.data, data, nbytes);
        msg.data[nbytes] = '\0';

        msgtype = pq_getmsgbyte(&msg);

        switch (msgtype)
        {
            case 'E':
            case 'N':
            {
                ErrorData edata;
                ErrorContextCallback context;

                pq_parse_errornotice(&msg, &edata);

                /* Store error for list() visibility */
                store_worker_error(state->info, edata.message);

                if (edata.elevel > ERROR)
                    edata.elevel = ERROR;

                context.callback = pg_background_error_callback;
                context.arg = (void *) &pid;
                context.previous = error_context_stack;
                error_context_stack = &context;
                throw_untranslated_error(edata);
                error_context_stack = context.previous;
                break;
            }
            case 'A':
                /*
                 * NOTIFY ('A') frames from the worker are forwarded to the
                 * launcher's protocol output here. This only happens while
                 * the launcher is *parked inside* pg_background_result —
                 * i.e., it works for launch + result callers that
                 * actually consume the result. NOTIFY frames emitted by
                 * workers launched via submit (fire-and-forget; results
                 * disabled) are written into the shm_mq but never read by
                 * anyone, so any NOTIFY they raise is effectively dropped.
                 * Document this in the README's submit section if you
                 * change anything here.
                 */
                pq_putmessage(msg.data[0], &msg.data[1], nbytes - 1);
                break;

            case 'T':
            {
                int16 natts = pq_getmsgint(&msg, 2);
                int16 i;

                if (state->has_row_description)
                    elog(ERROR, "multiple RowDescription messages");
                state->has_row_description = true;

                /*
                 * Bounds checking for natts to prevent allocation attacks
                 * 
                 * Malicious or corrupted worker could send huge natts value,
                 * causing excessive memory allocation or integer overflow.
                 * PostgreSQL's MaxTupleAttributeNumber is typically 1664.
                 * Cap at a reasonable value to prevent DoS.
                 */
                if (natts < 0 || natts > MaxTupleAttributeNumber)
                    ereport(ERROR,
                            (errcode(ERRCODE_PROTOCOL_VIOLATION),
                             errmsg("invalid column count in RowDescription: %d", natts),
                             errhint("Column count must be between 0 and %d.", MaxTupleAttributeNumber)));

                if (natts != tupdesc->natts)
                    ereport(ERROR,
                            (errcode(ERRCODE_DATATYPE_MISMATCH),
                             errmsg("remote query result rowtype does not match the specified FROM clause rowtype")));

                for (i = 0; i < natts; i++)
                {
                    Oid type_id;

                    (void) pq_getmsgstring(&msg);
                    (void) pq_getmsgint(&msg, 4);
                    (void) pq_getmsgint(&msg, 2);
                    type_id = pq_getmsgint(&msg, 4);
                    (void) pq_getmsgint(&msg, 2);
                    (void) pq_getmsgint(&msg, 4);
                    (void) pq_getmsgint(&msg, 2);

                    if (exists_binary_recv_fn(type_id))
                    {
                        if (type_id != TupleDescAttr(tupdesc, i)->atttypid)
                            ereport(ERROR,
                                    (errcode(ERRCODE_DATATYPE_MISMATCH),
                                     errmsg("remote query result rowtype does not match the specified FROM clause rowtype")));
                    }
                    else if (TupleDescAttr(tupdesc, i)->atttypid != TEXTOID)
                    {
                        ereport(ERROR,
                                (errcode(ERRCODE_DATATYPE_MISMATCH),
                                 errmsg("remote query result rowtype does not match the specified FROM clause rowtype"),
                                 errhint("use text type instead")));
                    }
                }
                pq_getmsgend(&msg);
                break;
            }

            case 'D':
            {
                HeapTuple result;

                /*
                 * Mark the worker in-use across tuple decode. A column type
                 * whose receive function runs user SQL (e.g. a domain CHECK)
                 * can re-enter a sibling entrypoint such as
                 * pg_background_detach_all(); detach_worker_seg() refuses to
                 * free a segment whose reader is active, preventing a
                 * use-after-free of this queue. Cleared on both the normal
                 * and error paths so a failed decode cannot pin the worker.
                 */
                state->info->active = true;
                PG_TRY();
                {
                    result = form_result_tuple(state, tupdesc, &msg);
                }
                PG_CATCH();
                {
                    state->info->active = false;
                    PG_RE_THROW();
                }
                PG_END_TRY();
                state->info->active = false;

                SRF_RETURN_NEXT(funcctx, HeapTupleGetDatum(result));
            }

            case 'C':
            {
                MemoryContext oldcontext;
                const char *tag = pq_getmsgstring(&msg);

                oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
                state->command_tags = lappend(state->command_tags, pstrdup(tag));
                MemoryContextSwitchTo(oldcontext);
                break;
            }

            case 'G':
            case 'H':
            case 'W':
                ereport(ERROR,
                        (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                         errmsg("COPY protocol not allowed in pg_background")));
                break;

            case 'Z':
                state->complete = true;
                break;

            default:
                elog(WARNING, "unknown message type: %c (%zu bytes)", msg.data[0], nbytes);
                break;
        }
    }

    if (!state->complete)
        ereport(ERROR,
                (errcode(ERRCODE_CONNECTION_FAILURE),
                 errmsg("lost connection to worker process with PID %d", pid)));

    if (!state->has_row_description)
    {
        if (tupdesc->natts != 1 || TupleDescAttr(tupdesc, 0)->atttypid != TEXTOID)
            ereport(ERROR,
                    (errcode(ERRCODE_DATATYPE_MISMATCH),
                     errmsg("remote query did not return a result set, but result rowtype is not a single text column")));

        if (state->command_tags != NIL)
        {
            char *tag = linitial(state->command_tags);
            Datum value = PointerGetDatum(cstring_to_text(tag));
            bool isnull = false;
            HeapTuple result;

            state->command_tags = list_delete_first(state->command_tags);
            result = heap_form_tuple(tupdesc, &value, &isnull);
            SRF_RETURN_NEXT(funcctx, HeapTupleGetDatum(result));
        }
    }

    /* Done: detach DSM (triggers cleanup callback) */
    detach_worker_seg(state->info);

    SRF_RETURN_DONE(funcctx);
}

/* -------------------------------------------------------------------------
 * Parse DataRow into tuple
 * ------------------------------------------------------------------------- */
static HeapTuple
form_result_tuple(pg_background_result_state *state, TupleDesc tupdesc, StringInfo msg)
{
    int16 natts = pq_getmsgint(msg, 2);
    int16 i;
    Datum *values = NULL;
    bool *isnull = NULL;
    StringInfoData buf;

    if (!state->has_row_description)
        elog(ERROR, "DataRow not preceded by RowDescription");

    /*
     * Bounds-check natts before any allocation. Mirrors the validation in the
     * 'T' (RowDescription) branch and defends against a malicious or
     * corrupted worker sending a bogus column count, even though the
     * subsequent equality check against tupdesc->natts already excludes
     * out-of-range values when tupdesc itself is well-formed.
     */
    if (natts < 0 || natts > MaxTupleAttributeNumber)
        ereport(ERROR,
                (errcode(ERRCODE_PROTOCOL_VIOLATION),
                 errmsg("invalid column count in DataRow: %d", natts),
                 errhint("Column count must be between 0 and %d.", MaxTupleAttributeNumber)));

    if (natts != tupdesc->natts)
        elog(ERROR, "malformed DataRow");

    if (natts > 0)
    {
        values = palloc(natts * sizeof(Datum));
        isnull = palloc(natts * sizeof(bool));
    }

    initStringInfo(&buf);

    for (i = 0; i < natts; i++)
    {
        int32 bytes = pq_getmsgint(msg, 4);

        if (bytes < 0)
        {
            values[i] = ReceiveFunctionCall(&state->receive_functions[i],
                                            NULL,
                                            state->typioparams[i],
                                            TupleDescAttr(tupdesc, i)->atttypmod);
            isnull[i] = true;
        }
        else
        {
            resetStringInfo(&buf);
            appendBinaryStringInfo(&buf, pq_getmsgbytes(msg, bytes), bytes);
            values[i] = ReceiveFunctionCall(&state->receive_functions[i],
                                            &buf,
                                            state->typioparams[i],
                                            TupleDescAttr(tupdesc, i)->atttypmod);
            isnull[i] = false;
        }
    }

    pq_getmsgend(msg);
    return heap_form_tuple(tupdesc, values, isnull);
}

/* ============================================================================
 * DETACH FUNCTIONS
 * ============================================================================
 */

/*
 * pg_background_detach
 *     Stop tracking a background worker with cookie validation (v2 API).
 *
 * Same as v1 detach but validates the cookie first.
 * Use cancel if you want to actually stop the worker.
 */
Datum
pg_background_detach(PG_FUNCTION_ARGS)
{
    int32 pid = PG_GETARG_INT32(0);
    int64 cookie_in = PG_GETARG_INT64(1);
    pg_background_worker_info *info = find_worker_info(pid);

    if (info == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_UNDEFINED_OBJECT),
                 errmsg("PID %d is not attached to this session", pid)));
    check_rights(info);

    if (info->cookie != (uint64) cookie_in)
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("cookie mismatch for PID %d", pid),
                 errhint("The worker may have been restarted or the handle is stale.")));

    detach_worker_seg(info);

    PG_RETURN_VOID();
}

/* ============================================================================
 * CANCEL FUNCTIONS
 * ============================================================================
 */

/*
 * pg_background_cancel
 *     Cancel a background worker (v2 API).
 *
 * v2.0: Single entrypoint with optional grace_ms (defaulted in SQL to 0).
 * Sets the cancel flag and sends SIGTERM (cooperative cancellation). If
 * grace_ms > 0, additionally waits up to grace_ms milliseconds for the
 * worker to stop, so the caller can observe whether it actually exited.
 * Grace period is clamped to PGBG_GRACE_MS_MAX (1 hour).
 *
 * Cancellation is cooperative: we never SIGKILL the worker, because a
 * bgworker killed by a signal forces a postmaster crash-recovery restart of
 * the entire cluster (see pgbg_send_cancel_signals). An unresponsive worker
 * is therefore not force-stopped; bound runaway SQL with statement_timeout
 * or pg_background.worker_timeout instead.
 *
 * Parameters:
 *     pid      - Worker process ID
 *     cookie   - Worker identity cookie from launch
 *     grace_ms - Time to wait for cooperative exit (0 = send SIGTERM and
 *                return immediately, without waiting)
 */
Datum
pg_background_cancel(PG_FUNCTION_ARGS)
{
    int32 pid = PG_GETARG_INT32(0);
    int64 cookie_in = PG_GETARG_INT64(1);
    int32 grace_ms = PG_GETARG_INT32(2);
    pg_background_worker_info *info = find_worker_info(pid);

    if (info == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_UNDEFINED_OBJECT),
                 errmsg("PID %d is not attached to this session", pid)));
    check_rights(info);

    if (info->cookie != (uint64) cookie_in)
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("cookie mismatch for PID %d", pid),
                 errhint("The worker may have been restarted or the handle is stale.")));

    /* Clamp grace period to valid range */
    if (grace_ms < 0)
        grace_ms = 0;
    else if (grace_ms > PGBG_GRACE_MS_MAX)
        grace_ms = PGBG_GRACE_MS_MAX;

    /* Mark as canceled for statistics tracking */
    info->canceled = true;

    pgbg_request_cancel(info);
    pgbg_send_cancel_signals(info, grace_ms);
    PG_RETURN_VOID();
}

/* ============================================================================
 * WAIT FUNCTIONS
 * ============================================================================
 */

/*
 * pg_background_wait
 *     Wait for a background worker to exit (v2 API).
 *
 * v2.0: Single entrypoint with optional timeout_ms (defaulted in SQL to 0).
 *
 *   - timeout_ms <= 0  -> block until the worker exits (uses
 *                         WaitForBackgroundWorkerShutdown — latch-based,
 *                         no busy loop). Returns true.
 *   - timeout_ms >  0  -> wait up to timeout_ms ms via pgbg_wait_for_stop.
 *                         Returns true if the worker stopped, false on
 *                         timeout. Capped at PGBG_TIMEOUT_MS_MAX (24 h).
 *
 * Returns: bool — true if the worker has stopped, false on timeout.
 */
Datum
pg_background_wait(PG_FUNCTION_ARGS)
{
    int32 pid = PG_GETARG_INT32(0);
    int64 cookie_in = PG_GETARG_INT64(1);
    int32 timeout_ms = PG_GETARG_INT32(2);
    pg_background_worker_info *info = find_worker_info(pid);

    if (info == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_UNDEFINED_OBJECT),
                 errmsg("PID %d is not attached to this session", pid)));
    check_rights(info);

    if (info->cookie != (uint64) cookie_in)
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("cookie mismatch for PID %d", pid),
                 errhint("The worker may have been restarted or the handle is stale.")));

    if (timeout_ms <= 0)
    {
        /* Infinite wait: latch-based, no polling. */
        if (info->handle != NULL)
            (void) WaitForBackgroundWorkerShutdown(info->handle);
        PG_RETURN_BOOL(true);
    }

    /* Bounded wait: clamp and poll with backoff. */
    if (timeout_ms > PGBG_TIMEOUT_MS_MAX)
        timeout_ms = PGBG_TIMEOUT_MS_MAX;

    PG_RETURN_BOOL(pgbg_wait_for_stop(info, timeout_ms));
}

/* ============================================================================
 * LIST FUNCTION
 * ============================================================================
 */

/*
 * pg_background_list_state
 *     State for list SRF iteration.
 *
 * We snapshot PIDs at first call to avoid race conditions where
 * cleanup callbacks could modify the hash during iteration.
 */
typedef struct pg_background_list_state
{
    pid_t  *pids;           /* Array of PIDs to iterate */
    int     count;          /* Total number of PIDs */
    int     current;        /* Current index in iteration */
} pg_background_list_state;

/*
 * pg_background_list
 *     List all background workers for the current session (v2 API).
 *
 * Returns information about tracked workers including state, SQL preview,
 * and last error. Only workers that the current user can manage are listed.
 *
 * RACE CONDITION FIX: We snapshot all PIDs at first call to prevent
 * issues where cleanup callbacks could modify the hash during iteration.
 * Each returned row re-looks up the PID, handling cases where the worker
 * was cleaned up between snapshot and access.
 *
 * Columns: pid, cookie, launched_at, user_id, queue_size, state,
 *          sql_preview, last_error, consumed, label
 */
Datum
pg_background_list(PG_FUNCTION_ARGS)
{
    FuncCallContext *funcctx;
    pg_background_list_state *state;

    if (SRF_IS_FIRSTCALL())
    {
        MemoryContext oldcontext;
        HASH_SEQ_STATUS hstat;
        const pg_background_worker_info *info;
        int count = 0;

        funcctx = SRF_FIRSTCALL_INIT();
        oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

        state = palloc0(sizeof(pg_background_list_state));

        /* Snapshot all PIDs to avoid race with cleanup callbacks */
        if (worker_hash != NULL)
        {
            int capacity = hash_get_num_entries(worker_hash);
            if (capacity > 0)
            {
                state->pids = palloc(sizeof(pid_t) * capacity);
                hash_seq_init(&hstat, worker_hash);
                while ((info = hash_seq_search(&hstat)) != NULL)
                {
                    if (count < capacity)
                        state->pids[count++] = info->pid;
                }
            }
        }
        state->count = count;
        state->current = 0;

        funcctx->user_fctx = state;

        /*
         * Resolve tupledesc from the caller's column-definition list and
         * validate it before use. The label column (v1.9) is the trailing
         * column, so both the historical 9-column shape and the current
         * 10-column shape are accepted; a 9-column caller simply omits it and
         * heap_form_tuple() forms only the columns the descriptor declares.
         * Any other arity, or a by-reference type where a by-value type is
         * expected (or vice versa), would otherwise make heap_form_tuple()
         * dereference a scalar as a pointer and crash the backend, so reject
         * it with a clean error. Prefer the pg_background_list view, which
         * always supplies the correct rowtype.
         */
        {
            TupleDesc tupdesc;
            int       i;
            static const Oid expected[10] = {
                INT4OID,        /* pid */
                INT8OID,        /* cookie */
                TIMESTAMPTZOID, /* launched_at */
                OIDOID,         /* user_id */
                INT4OID,        /* queue_size */
                TEXTOID,        /* state */
                TEXTOID,        /* sql_preview */
                TEXTOID,        /* last_error */
                BOOLOID,        /* consumed */
                TEXTOID         /* label */
            };

            if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
                ereport(ERROR,
                        (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                         errmsg("function returning record called in context that cannot accept type record"),
                         errhint("Call it in FROM with a column definition list.")));

            if (tupdesc->natts != 9 && tupdesc->natts != 10)
                ereport(ERROR,
                        (errcode(ERRCODE_DATATYPE_MISMATCH),
                         errmsg("pg_background_list() requires a 9- or 10-column definition list"),
                         errdetail("Got %d columns; expected 9 or 10.", tupdesc->natts),
                         errhint("Use the pg_background_list view instead of a custom column list.")));

            for (i = 0; i < tupdesc->natts; i++)
            {
                Oid att = TupleDescAttr(tupdesc, i)->atttypid;

                if (att != expected[i])
                    ereport(ERROR,
                            (errcode(ERRCODE_DATATYPE_MISMATCH),
                             errmsg("pg_background_list() column %d has the wrong type", i + 1),
                             errdetail("Column %d has type OID %u; expected %u.",
                                       i + 1, att, expected[i]),
                             errhint("Use the pg_background_list view instead of a custom column list.")));
            }

            funcctx->tuple_desc = BlessTupleDesc(tupdesc);
        }

        MemoryContextSwitchTo(oldcontext);
    }

    funcctx = SRF_PERCALL_SETUP();
    state = (pg_background_list_state *) funcctx->user_fctx;

    /* Iterate over snapshotted PIDs */
    while (state->current < state->count)
    {
        pid_t pid = state->pids[state->current++];
        pg_background_worker_info *info;
        Datum values[10];
        bool nulls[10];
        HeapTuple tuple;

        /* Re-lookup: worker may have been cleaned up since snapshot */
        info = find_worker_info(pid);
        if (info == NULL)
            continue;

        /* Per-row rights: only list workers you can manage */
        if (info->current_user_id != InvalidOid)
        {
            Oid cur;
            int sec;
            GetUserIdAndSecContext(&cur, &sec);
            if (!has_privs_of_role(cur, info->current_user_id))
                continue;
        }

        MemSet(nulls, true, sizeof(nulls));

        /* (pid, cookie, launched_at, user_id, queue_size, state, sql_preview, last_error, consumed, label) */
        values[0] = Int32GetDatum((int32) info->pid);              nulls[0] = false;
        values[1] = Int64GetDatum((int64) info->cookie);           nulls[1] = false;
        values[2] = TimestampTzGetDatum(info->launched_at);        nulls[2] = false;
        values[3] = ObjectIdGetDatum(info->current_user_id);       nulls[3] = false;
        values[4] = Int32GetDatum(info->queue_size);               nulls[4] = false;

        values[5] = CStringGetTextDatum(pgbg_state_from_handle(info)); nulls[5] = false;

        values[6] = CStringGetTextDatum(info->sql_preview);        nulls[6] = false;

        if (info->last_error != NULL)
        {
            values[7] = CStringGetTextDatum(info->last_error);
            nulls[7] = false;
        }

        values[8] = BoolGetDatum(info->consumed);                  nulls[8] = false;

        /* v1.9: Add label column */
        if (info->label[0] != '\0')
        {
            values[9] = CStringGetTextDatum(info->label);
            nulls[9] = false;
        }

        tuple = heap_form_tuple(funcctx->tuple_desc, values, nulls);
        SRF_RETURN_NEXT(funcctx, HeapTupleGetDatum(tuple));
    }

    SRF_RETURN_DONE(funcctx);
}

/* ============================================================================
 * CANCEL HELPERS
 * ============================================================================
 */

/*
 * detach_worker_seg
 *     Detach a worker's DSM segment safely, used by every "we are done with
 *     this worker" cleanup path.
 *
 * Clears info->seg and info->mapping_pinned BEFORE calling dsm_detach so
 * the cleanup_worker_info on_dsm_detach callback (which fires from inside
 * dsm_detach) does not see a still-mapped pointer and try to detach again.
 * If the mapping was pinned at launch, we unpin first.
 *
 * Replaces three nearly-identical inline blocks in the result-streaming SRF
 * tail, pg_background_detach, and pg_background_detach_all.
 */
static bool
detach_worker_seg(pg_background_worker_info *info)
{
    dsm_segment *seg;
    bool         was_pinned;

    if (info == NULL || info->seg == NULL)
        return false;

    /*
     * Refuse to free a segment whose result reader is still streaming. A
     * type input/receive function can run user SQL (e.g. a domain CHECK)
     * that re-enters a sibling detach path (pg_background_detach_all, etc.);
     * freeing here would leave the reader's shm_mq handle dangling. The
     * reader clears info->active before its own final detach, so this only
     * defers reentrant frees, never the legitimate one.
     */
    if (info->active)
        return false;

    seg        = info->seg;
    was_pinned = info->mapping_pinned;

    info->seg            = NULL;
    info->mapping_pinned = false;

    if (was_pinned)
        dsm_unpin_mapping(seg);
    dsm_detach(seg);
    return true;
}

/*
 * pgbg_request_cancel
 *     Set the cancel flag in shared memory.
 */
static void
pgbg_request_cancel(pg_background_worker_info *info)
{
    shm_toc *toc;
    pg_background_input *input;

    if (info == NULL || info->seg == NULL)
        return;

    toc = shm_toc_attach(PG_BACKGROUND_MAGIC, dsm_segment_address(info->seg));
    if (toc == NULL)
        return;

    input = shm_toc_lookup(toc, PG_BACKGROUND_KEY_INPUT, true);
    if (input == NULL)
        return;

    input->cancel_requested = 1;
}

/*
 * pgbg_send_cancel_signals
 *     Send cancellation signal to worker.
 *
 * Sends SIGTERM for cooperative cancellation. If grace_ms > 0, waits up to
 * grace_ms for the worker to stop cooperatively (exponential-backoff poll),
 * purely so the caller can observe whether the worker actually exited.
 *
 * We deliberately do NOT escalate to SIGKILL. The postmaster treats any
 * child that dies from an uncaught signal (SIGKILL included) as a crash and
 * responds by terminating every other backend and reinitializing shared
 * memory -- a cluster-wide restart that drops all sessions. A direct
 * SIGKILL of a background worker therefore turns a single cancel into a
 * server crash. There is no signal that force-stops a bgworker without
 * tripping crash recovery, so cancellation is cooperative only. This
 * matches the documented contract (cancel requests termination; it does not
 * guarantee an immediate stop) and the worker's own SIGTERM handler, which
 * converts the signal into a catchable query cancel and exits via
 * proc_exit(1) -- an exit code the postmaster accepts without crash
 * recovery.
 */
static void
pgbg_send_cancel_signals(pg_background_worker_info *info, int32 grace_ms)
{
    if (info == NULL)
        return;

#ifndef WIN32
    /*
     * Windows Cancel Limitations
     *
     * On Unix systems, we use SIGTERM for cooperative cancellation.
     * Worker checks InterruptPending via CHECK_FOR_INTERRUPTS() in query
     * execution and can cleanly abort.
     *
     * WINDOWS LIMITATION:
     * PostgreSQL on Windows does not support signal-based cancellation for
     * background workers. The kill() call is not available, and Windows uses
     * events/threads for IPC instead of signals.
     *
     * WORKAROUND:
     * Workers still check input->cancel_requested flag before executing SQL.
     * This provides limited cancellation:
     * - WORKS: Cancel before worker starts SQL execution
     * - DOES NOT WORK: Cancel during long-running query (no mid-query interrupt)
     *
     * PRODUCTION IMPACT:
     * On Windows, cancel() may not interrupt long-running SQL. Use:
     * 1. statement_timeout to bound query execution time
     * 2. Application-level timeouts
     * 3. Connection pooler limits
     *
     * SEE ALSO: windows/ReadMe.md for Windows-specific build notes
     */
    if (info->pid > 0)
        (void) kill(info->pid, SIGTERM);
#endif

    if (grace_ms <= 0 || info->handle == NULL)
        return;

    /*
     * Best-effort: wait up to grace_ms for the worker to stop after the
     * cooperative SIGTERM above. If it has not stopped by then we simply
     * return -- the worker keeps running and will still honor the pending
     * cancel at its next interrupt check. We never force-kill (see the
     * function header for why SIGKILL would crash the whole cluster).
     */
    (void) pgbg_wait_for_stop(info, grace_ms);
}

/*
 * pgbg_state_from_handle
 *     Get human-readable state string for a worker.
 */
static const char *
pgbg_state_from_handle(pg_background_worker_info *info)
{
    if (info == NULL)
        return "unknown";

    if (info->handle == NULL)
        return "starting";

    {
        pid_t wpid = 0;
        BgwHandleStatus hs = GetBackgroundWorkerPid(info->handle, &wpid);

        if (hs == BGWH_STOPPED)
            return "stopped";
        if (hs == BGWH_STARTED)
            return "running";
        if (hs == BGWH_POSTMASTER_DIED)
            return "postmaster_died";
        return "starting";
    }
}

/* ============================================================================
 * CLEANUP AND LOOKUP
 * ============================================================================
 */

/*
 * cleanup_worker_info
 *     DSM detach callback to remove worker from tracking hash.
 */
static void
cleanup_worker_info(dsm_segment *seg, Datum pid_datum)
{
    pid_t pid = (pid_t) DatumGetInt32(pid_datum);
    bool found;
    bool has_dsm_error = false;

    if (worker_hash == NULL)
        return;

    /*
     * Check DSM for structured error before segment is unmapped.
     * This catches errors even when results were never consumed.
     * The seg argument is still accessible in this callback.
     */
    if (seg != NULL)
    {
        shm_toc *toc = shm_toc_attach(PG_BACKGROUND_MAGIC, dsm_segment_address(seg));
        if (toc != NULL)
        {
            const pg_background_output *output =
                shm_toc_lookup(toc, PG_BACKGROUND_KEY_OUTPUT, true);
            if (output != NULL && output->error_sqlstate[0] != '\0')
                has_dsm_error = true;
        }
    }

    /* Find entry, update stats, free last_error if any, then remove */
    {
        pg_background_worker_info *info = hash_search(worker_hash, (void *) &pid, HASH_FIND, &found);
        if (found && info != NULL)
        {
            /* Update session statistics based on worker state */
            TimestampTz now = GetCurrentTimestamp();
            int64 execution_us = now - info->launched_at;
            /* Add execution time with overflow protection */
            if (execution_us > 0 &&
                session_stats.total_execution_us <= PG_INT64_MAX - execution_us)
                session_stats.total_execution_us += execution_us;

            /*
             * Categorize worker outcome:
             * 1. Canceled takes priority (explicit user action)
             * 2. Failed if there was an error (from result consumption OR DSM)
             * 3. Completed otherwise
             *
             * Check both info->last_error (set when results consumed) and
             * has_dsm_error (from structured error in DSM) to correctly
             * classify workers that were waited/detached without consuming.
             */
            if (info->canceled)
            {
                session_stats.workers_canceled++;
            }
            else if (info->last_error != NULL || has_dsm_error)
            {
                session_stats.workers_failed++;
            }
            else
            {
                session_stats.workers_completed++;
            }

            /* Free error message if allocated */
            if (info->last_error != NULL)
            {
                pfree(info->last_error);
                info->last_error = NULL;
            }
        }
    }

    hash_search(worker_hash, (void *) &pid, HASH_REMOVE, &found);
    if (!found)
        elog(DEBUG1, "pg_background worker_hash entry for PID %d already removed", (int) pid);

    /*
     * v2.0 (C2): Do NOT destroy the hash table or reset the memory context
     * from this dsm-detach callback. Public C entrypoints can be holding a
     * pg_background_worker_info * across the dsm_detach that triggers this
     * callback (e.g., the result-streaming SRF freeing its DSM at end of
     * iteration). Resetting the context underneath them would invalidate
     * those pointers — exactly the use-after-free trap we used to mitigate
     * with "clear seg before detach".
     *
     * The hash and the WorkerInfoMemoryContext live for the duration of the
     * session and are released by PostgreSQL when the backend exits. Per-
     * worker memory inside the context is bounded by total launches *
     * sizeof(pg_background_worker_info) (typically ~200 bytes), so the
     * high-water mark is small even for sessions that launch thousands of
     * workers. If a future workload demands aggressive reclamation, defer
     * the reset to a top-level point (end of public C entrypoint, or a
     * before_shmem_exit hook) rather than from inside this callback.
     */
}

/*
 * find_worker_info
 *     Look up worker info by PID in the session hash table.
 */
static pg_background_worker_info *
find_worker_info(pid_t pid)
{
    if (worker_hash == NULL)
        return NULL;
    return (pg_background_worker_info *) hash_search(worker_hash, (void *) &pid, HASH_FIND, NULL);
}

/*
 * check_rights
 *     Verify current user has permission to manage the worker.
 */
static void
check_rights(pg_background_worker_info *info)
{
    Oid current_user_id;
    int sec_context;

    GetUserIdAndSecContext(&current_user_id, &sec_context);
    if (!has_privs_of_role(current_user_id, info->current_user_id))
        ereport(ERROR,
                (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
                 errmsg("permission denied for background worker with PID \"%d\"",
                        (int) info->pid)));
}

/*
 * save_worker_info
 *     Store worker info in the session hash table.
 */
static void
save_worker_info(pid_t pid, uint64 cookie, dsm_segment *seg,
                 BackgroundWorkerHandle *handle,
                 shm_mq_handle *responseq,
                 bool result_disabled,
                 int32 queue_size,
                 const char *sql_preview,
                 const char *label,
                 const char *full_sql)
{
    pg_background_worker_info *info;
    Oid current_user_id;
    int sec_context;

    /* Ensure memory context exists */
    ensure_worker_info_memory_context();

    if (worker_hash == NULL)
    {
        HASHCTL ctl;
        MemSet(&ctl, 0, sizeof(ctl));
        ctl.keysize = sizeof(pid_t);
        ctl.entrysize = sizeof(pg_background_worker_info);
        ctl.hcxt = WorkerInfoMemoryContext;

        worker_hash = hash_create("pg_background worker_hash",
                                  PGBG_WORKER_HASH_INIT_SIZE,
                                  &ctl,
                                  HASH_BLOBS | HASH_ELEM | HASH_CONTEXT);
    }

    GetUserIdAndSecContext(&current_user_id, &sec_context);

    /*
     * C2: PID Reuse Edge Case Protection
     *
     * SCENARIO: On systems with rapid process recycling (high load, small PID
     * space), a background worker PID could theoretically be reused within the
     * same session before the cleanup callback fires.
     *
     * SAFETY MECHANISMS:
     * 1. Cookie validation (v2 API): Even if PID is reused, cookie mismatch
     *    will prevent operations on the wrong worker.
     * 2. User ID check: If PID is reused by a different user we abort the
     *    just-launched worker and raise an ERROR so the caller learns.
     * 3. Proactive cleanup: Detach stale DSM segment before creating new
     *    entry.
     *
     * Why ERROR (not FATAL): a stale tracking-table entry must not be a
     * remote DoS vector. We tear down the worker we just launched (terminate
     * its BGW and detach its DSM) and raise ERROR so the launcher session
     * survives. The pre-existing entry's owner check still prevents the
     * caller from operating on the unrelated worker.
     *
     * OBSERVABILITY: Monitor for "background worker with PID X already
     * exists" in logs - this indicates PID space pressure and may require
     * system tuning.
     */
    info = find_worker_info(pid);
    if (info != NULL)
    {
        if (current_user_id != info->current_user_id)
        {
            /*
             * Tear down the worker we just launched before raising. The
             * cleanup callback has not been registered yet (on_dsm_detach
             * happens below), so PostgreSQL would otherwise leave the BGW
             * and its DSM behind.
             */
            if (handle != NULL)
                TerminateBackgroundWorker(handle);
            if (seg != NULL)
                dsm_detach(seg);

            ereport(ERROR,
                    (errcode(ERRCODE_DUPLICATE_OBJECT),
                     errmsg("background worker with PID \"%d\" already exists",
                            (int) pid),
                     errhint("A stale tracking entry for this PID exists from a different user; the just-launched worker has been terminated.")));
        }

        /*
         * A result reader may still hold this entry, marking it active while a
         * receive function runs user SQL. detach_worker_seg() refuses to free
         * an active entry, and overwriting it in place would corrupt the
         * reader's tracked identity and result state. Reject the reuse: tear
         * down the just-launched worker and raise, leaving the reader's entry
         * intact.
         */
        if (info->active)
        {
            if (handle != NULL)
                TerminateBackgroundWorker(handle);
            if (seg != NULL)
                dsm_detach(seg);

            ereport(ERROR,
                    (errcode(ERRCODE_OBJECT_IN_USE),
                     errmsg("background worker with PID \"%d\" is currently reading results",
                            (int) pid),
                     errhint("Consume or detach the existing result for this PID before reusing it.")));
        }

        detach_worker_seg(info);
    }

    on_dsm_detach(seg, cleanup_worker_info, Int32GetDatum((int32) pid));

    info = (pg_background_worker_info *) hash_search(worker_hash, (void *) &pid, HASH_ENTER, NULL);

    info->pid = pid;
    info->cookie = cookie;
    info->seg = seg;
    info->handle = handle;
    info->responseq = responseq;

    info->current_user_id = current_user_id;
    info->consumed = false;
    info->mapping_pinned = false;
    info->result_disabled = result_disabled;
    info->canceled = false;
    info->active = false;

    info->launched_at = GetCurrentTimestamp();
    info->queue_size = queue_size;
    strlcpy(info->sql_preview, sql_preview ? sql_preview : "", sizeof(info->sql_preview));

    info->last_error = NULL;

    /* v1.9: Initialize label */
    if (label != NULL && label[0] != '\0')
        strlcpy(info->label, label, sizeof(info->label));
    else
        info->label[0] = '\0';

    /* v1.10 (B3): cache full SQL in launcher memory so it survives DSM detach. */
    info->full_sql = NULL;
    if (full_sql != NULL && full_sql[0] != '\0')
    {
        MemoryContext oldcontext = MemoryContextSwitchTo(WorkerInfoMemoryContext);
        size_t       sql_len = strlen(full_sql);

        if (sql_len <= PGBG_FULL_SQL_MAX_LEN)
        {
            info->full_sql = pstrdup(full_sql);
        }
        else
        {
            /* Truncate; mark with a sentinel so callers see the cap was hit. */
            char *buf = palloc(PGBG_FULL_SQL_MAX_LEN + 8);
            memcpy(buf, full_sql, PGBG_FULL_SQL_MAX_LEN);
            memcpy(buf + PGBG_FULL_SQL_MAX_LEN, "[...]\0", 6);
            info->full_sql = buf;
        }
        MemoryContextSwitchTo(oldcontext);
    }

    /* v1.9 metadata (timing, result info, errors) stored in DSM, not cached here */
}

/*
 * pg_background_error_callback
 *     Error context callback to identify background worker errors.
 *
 * Non-static so pg_background_worker.c can also install it. Declared
 * extern in pg_background_internal.h.
 */
void
pg_background_error_callback(void *arg)
{
    pid_t pid = *(pid_t *) arg;
    errcontext("background worker, pid %d", (int) pid);
}


/* ============================================================================
 * STATISTICS FUNCTION
 * ============================================================================
 */

/*
 * pg_background_stats
 *     Return session-local statistics about background workers.
 *
 * Returns a single row with:
 *   - workers_launched: total workers launched this session
 *   - workers_completed: workers that completed successfully
 *   - workers_failed: workers that failed with an error
 *   - workers_canceled: workers that were explicitly canceled
 *   - workers_timed_out: workers that hit run timeout (subset of canceled)
 *   - workers_active: currently active workers
 *   - avg_execution_ms: average execution time in milliseconds
 *   - max_workers: current pg_background.max_workers setting
 */
Datum
pg_background_stats(PG_FUNCTION_ARGS)
{
    TupleDesc   tupdesc;
    Datum       values[8];
    bool        nulls[8];
    HeapTuple   tuple;
    int         active_workers;
    float8      avg_execution_ms;
    int64       finished_total;

    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("function returning composite called in context that cannot accept it")));
    tupdesc = BlessTupleDesc(tupdesc);

    /* Calculate active workers */
    active_workers = (worker_hash != NULL) ? hash_get_num_entries(worker_hash) : 0;

    /* Calculate average execution time (includes all finished workers) */
    finished_total = session_stats.workers_completed +
                     session_stats.workers_failed +
                     session_stats.workers_canceled;
    if (finished_total > 0)
        avg_execution_ms = (float8) session_stats.total_execution_us / finished_total / 1000.0;
    else
        avg_execution_ms = 0.0;

    MemSet(nulls, false, sizeof(nulls));

    values[0] = Int64GetDatum(session_stats.workers_launched);
    values[1] = Int64GetDatum(session_stats.workers_completed);
    values[2] = Int64GetDatum(session_stats.workers_failed);
    values[3] = Int64GetDatum(session_stats.workers_canceled);
    values[4] = Int64GetDatum(session_stats.workers_timed_out);
    values[5] = Int32GetDatum(active_workers);
    values[6] = Float8GetDatum(avg_execution_ms);
    values[7] = Int32GetDatum(pgbg_max_workers);

    tuple = heap_form_tuple(tupdesc, values, nulls);
    PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/*
 * pg_background_record_timeout (v2.0, B5a)
 *     Increment the session-local workers_timed_out counter.
 *
 * Called by pg_background_run (PL/pgSQL) when a launched worker
 * exceeds its timeout and is canceled. We track timeouts as a separate
 * counter from explicit user-driven cancels so the stats view is
 * actionable. SQL declares this with VOLATILE; not granted to PUBLIC.
 */
Datum
pg_background_record_timeout(PG_FUNCTION_ARGS)
{
    /*
     * Saturate rather than overflow: workers_timed_out is int64, but we
     * still guard against the (essentially impossible) wrap-around.
     */
    if (session_stats.workers_timed_out < PG_INT64_MAX)
        session_stats.workers_timed_out++;
    PG_RETURN_VOID();
}

/* ============================================================================
 * PROGRESS REPORTING FUNCTIONS
 * ============================================================================
 */

/*
 * pg_background_report_progress (v2.0)
 *     Report progress from within a background worker.
 *
 * Renamed from pg_background_progress in 2.0 to align with v2 naming and
 * to avoid the function/type name collision (the type is now
 * pg_background_progress_info).
 *
 * Called by SQL running inside a background worker; updates the progress
 * fields in the launcher-visible DSM segment.
 *
 * Parameters:
 *     pct     - Progress percentage (0-100)
 *     message - Brief status message (optional, max 63 chars)
 *
 * Usage in worker SQL:
 *     SELECT pg_background_report_progress(50, 'Halfway done');
 */
Datum
pg_background_report_progress(PG_FUNCTION_ARGS)
{
    int32       pct;
    text       *msg;
    shm_toc    *toc;
    pg_background_output *output;

    /*
     * SQL declaration is non-STRICT so we may receive NULL for either
     * argument. Reject NULL pct rather than reading garbage from
     * PG_GETARG_INT32(0) (CLAUDE.md §4 SQL/C alignment).
     */
    if (PG_ARGISNULL(0))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("pct must not be NULL")));

    pct = PG_GETARG_INT32(0);
    msg = PG_ARGISNULL(1) ? NULL : PG_GETARG_TEXT_PP(1);

    /* Only valid in worker context */
    if (worker_dsm_seg == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("pg_background_report_progress can only be called from a background worker")));

    /* Clamp percentage */
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;

    /* Access shared memory */
    toc = shm_toc_attach(PG_BACKGROUND_MAGIC, dsm_segment_address(worker_dsm_seg));
    if (toc == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("cannot access shared memory for progress reporting")));

    output = shm_toc_lookup(toc, PG_BACKGROUND_KEY_OUTPUT, false);
    if (output == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("cannot find output data in shared memory")));

    /*
     * Write progress_msg first, then progress_pct with a write barrier.
     * This ensures the reader (using read barrier) sees consistent data:
     * - Writer: msg -> write_barrier -> pct
     * - Reader: pct -> read_barrier -> msg
     * When reader sees updated pct, msg is guaranteed to be visible.
     */
    if (msg != NULL)
    {
        int msg_len = VARSIZE_ANY_EXHDR(msg);
        int max_len = (int) sizeof(output->progress_msg) - 1;
        int copy_len;

        /*
         * UTF-8 aware truncation: pg_mbcliplen() ensures we don't cut
         * multi-byte characters in the middle, which would produce
         * invalid UTF-8 sequences.
         */
        if (msg_len > max_len)
            copy_len = pg_mbcliplen(VARDATA_ANY(msg), msg_len, max_len);
        else
            copy_len = msg_len;

        memcpy(output->progress_msg, VARDATA_ANY(msg), copy_len);
        output->progress_msg[copy_len] = '\0';
    }
    else
    {
        output->progress_msg[0] = '\0';
    }

    /* Write barrier ensures msg is visible before pct update */
    pg_write_barrier();

    /* Update progress percentage (volatile for cross-process visibility) */
    *(volatile int32 *)&output->progress_pct = pct;

    PG_RETURN_VOID();
}

/*
 * pg_background_get_progress
 *     Get progress of a specific background worker.
 *
 * Parameters:
 *     pid    - Worker process ID
 *     cookie - Worker identity cookie
 *
 * Returns: (progress_pct int, progress_msg text) or NULL if not available
 */
Datum
pg_background_get_progress(PG_FUNCTION_ARGS)
{
    int32       pid = PG_GETARG_INT32(0);
    int64       cookie_in = PG_GETARG_INT64(1);
    pg_background_worker_info *info;
    shm_toc    *toc;
    pg_background_output *output;
    TupleDesc   tupdesc;
    Datum       values[2];
    bool        nulls[2];
    HeapTuple   tuple;
    int32       progress_pct;
    char        progress_msg[64];

    info = find_worker_info(pid);
    if (info == NULL)
        PG_RETURN_NULL();

    check_rights(info);

    if (info->cookie != (uint64) cookie_in)
        PG_RETURN_NULL();

    if (info->seg == NULL)
        PG_RETURN_NULL();

    /* Access shared memory */
    toc = shm_toc_attach(PG_BACKGROUND_MAGIC, dsm_segment_address(info->seg));
    if (toc == NULL)
        PG_RETURN_NULL();

    output = shm_toc_lookup(toc, PG_BACKGROUND_KEY_OUTPUT, true);
    if (output == NULL)
        PG_RETURN_NULL();

    /*
     * Read progress with memory barrier for consistency.
     * The worker writes: progress_msg then progress_pct (with write barrier).
     * We read: progress_pct then progress_msg (with read barrier).
     * The barriers ensure we see the message that was written before
     * the percentage was updated.
     */
    progress_pct = *(volatile int32 *)&output->progress_pct;
    if (progress_pct < 0)
        PG_RETURN_NULL();  /* Progress not reported yet */

    pg_read_barrier();

    /*
     * After the read barrier, memory is synchronized. Copy the message
     * using memcpy to avoid volatile qualifier warnings with strlcpy.
     * The source is guaranteed to be null-terminated (max 63 chars + null).
     */
    memcpy(progress_msg, output->progress_msg, sizeof(progress_msg));
    progress_msg[sizeof(progress_msg) - 1] = '\0';  /* Ensure null termination */

    /* Build result tuple */
    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("function returning composite called in context that cannot accept it")));
    tupdesc = BlessTupleDesc(tupdesc);

    MemSet(nulls, false, sizeof(nulls));
    values[0] = Int32GetDatum(progress_pct);
    values[1] = CStringGetTextDatum(progress_msg);

    tuple = heap_form_tuple(tupdesc, values, nulls);
    PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/* ============================================================================
 * V1.9 OBSERVABILITY FUNCTIONS
 * ============================================================================
 */

/*
 * pg_background_result_info
 *     Get result metadata without consuming results.
 *
 * Returns: pg_background_result_info composite type
 *     (row_count int8, command_tag text, completed bool, has_error bool)
 *
 * This allows callers to check worker status without consuming results.
 *
 * IMPORTANT: The row_count, command_tag, and has_error fields are only
 * reliable when completed=true. If called while the worker is still running,
 * these fields may show partial or stale values. Always check completed
 * before relying on the other fields.
 */
Datum
pg_background_result_info(PG_FUNCTION_ARGS)
{
    int32       pid = PG_GETARG_INT32(0);
    int64       cookie = PG_GETARG_INT64(1);
    pg_background_worker_info *info;
    pg_background_output *output;
    TupleDesc   tupdesc;
    Datum       values[6];
    bool        nulls[6];
    HeapTuple   tuple;
    bool        completed = false;
    bool        has_error = false;
    int64       row_count = 0;
    char        command_tag[PGBG_COMMAND_TAG_LEN];
    TimestampTz started_at = 0;
    TimestampTz finished_at = 0;

    command_tag[0] = '\0';

    /* Look up worker */
    info = find_worker_info((pid_t) pid);
    if (info == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_UNDEFINED_OBJECT),
                 errmsg("PID %d is not attached to this session", pid)));

    check_rights(info);

    if (info->cookie != (uint64) cookie)
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("cookie mismatch for PID %d", pid),
                 errhint("The worker may have been restarted or the handle is stale.")));

    /* Check if worker has completed */
    if (info->handle != NULL)
    {
        pid_t wpid = 0;
        BgwHandleStatus hs = GetBackgroundWorkerPid(info->handle, &wpid);
        completed = (hs == BGWH_STOPPED);
    }

    /* Read metadata from shared memory */
    if (info->seg != NULL)
    {
        shm_toc    *toc = shm_toc_attach(PG_BACKGROUND_MAGIC, dsm_segment_address(info->seg));
        if (toc != NULL)
        {
            output = shm_toc_lookup(toc, PG_BACKGROUND_KEY_OUTPUT, true);
            if (output != NULL)
            {
                /*
                 * Read the publish flag first; only treat the row_count /
                 * command_tag pair as valid if the worker has fully written
                 * them. The pg_read_barrier() pairs with the worker's
                 * pg_write_barrier() in execute_sql_string so we cannot see
                 * a fresh row_count paired with a stale command_tag.
                 */
                if (output->result_published)
                {
                    pg_read_barrier();
                    row_count = output->result_row_count;
                    strlcpy(command_tag, output->command_tag, sizeof(command_tag));
                }
                has_error = (output->error_sqlstate[0] != '\0');

                /*
                 * v2.0 (B5b): execution timestamps. Zero means "not set yet"
                 * (worker hasn't reached the SPI loop / hasn't finished).
                 */
                started_at = output->started_at;
                finished_at = output->finished_at;
            }
        }
    }

    /* Build result tuple */
    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("function returning composite called in context that cannot accept it")));
    tupdesc = BlessTupleDesc(tupdesc);

    MemSet(nulls, false, sizeof(nulls));
    values[0] = Int64GetDatum(row_count);
    values[1] = CStringGetTextDatum(command_tag);
    values[2] = BoolGetDatum(completed);
    values[3] = BoolGetDatum(has_error);

    if (started_at != 0)
        values[4] = TimestampTzGetDatum(started_at);
    else
        nulls[4] = true;

    if (finished_at != 0)
        values[5] = TimestampTzGetDatum(finished_at);
    else
        nulls[5] = true;

    tuple = heap_form_tuple(tupdesc, values, nulls);
    PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/*
 * pg_background_error_info
 *     Get structured error information from a worker.
 *
 * Returns: pg_background_error composite type
 *     (sqlstate, message, detail, hint, context, schema_name, table_name,
 *      column_name, constraint_name) — each text, NULL if not populated.
 *
 * The four trailing identifiers (schema_name, table_name, column_name,
 * constraint_name) are surfaced from PostgreSQL's edata for errors raised
 * by the heap/access layer (constraint violations, missing relations, etc.)
 * and are NULL for errors that don't carry source-object information.
 *
 * Returns NULL if no error occurred.
 */
Datum
pg_background_error_info(PG_FUNCTION_ARGS)
{
    int32       pid = PG_GETARG_INT32(0);
    int64       cookie = PG_GETARG_INT64(1);
    pg_background_worker_info *info;
    shm_toc    *toc;
    pg_background_output *output;
    TupleDesc   tupdesc;
    Datum       values[9];
    bool        nulls[9];
    HeapTuple   tuple;

    /* Look up worker */
    info = find_worker_info((pid_t) pid);
    if (info == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_UNDEFINED_OBJECT),
                 errmsg("PID %d is not attached to this session", pid)));

    check_rights(info);

    if (info->cookie != (uint64) cookie)
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("cookie mismatch for PID %d", pid),
                 errhint("The worker may have been restarted or the handle is stale.")));

    /* Read error info from shared memory */
    if (info->seg == NULL)
        PG_RETURN_NULL();

    toc = shm_toc_attach(PG_BACKGROUND_MAGIC, dsm_segment_address(info->seg));
    if (toc == NULL)
        PG_RETURN_NULL();

    output = shm_toc_lookup(toc, PG_BACKGROUND_KEY_OUTPUT, true);
    if (output == NULL || output->error_sqlstate[0] == '\0')
        PG_RETURN_NULL();  /* No error */

    /*
     * Read barrier: error_sqlstate is set LAST by the worker (after a write
     * barrier), so if we see it non-empty, all other error fields are valid.
     */
    pg_read_barrier();

    /* Build result tuple */
    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("function returning composite called in context that cannot accept it")));
    tupdesc = BlessTupleDesc(tupdesc);

    MemSet(nulls, false, sizeof(nulls));
    values[0] = CStringGetTextDatum(output->error_sqlstate);
    values[1] = CStringGetTextDatum(output->error_message);

    if (output->error_detail[0] != '\0')
        values[2] = CStringGetTextDatum(output->error_detail);
    else
        nulls[2] = true;

    if (output->error_hint[0] != '\0')
        values[3] = CStringGetTextDatum(output->error_hint);
    else
        nulls[3] = true;

    if (output->error_context[0] != '\0')
        values[4] = CStringGetTextDatum(output->error_context);
    else
        nulls[4] = true;

    /* v2.0 (B5c): error-source identifiers — NULL when not populated */
    if (output->error_schema_name[0] != '\0')
        values[5] = CStringGetTextDatum(output->error_schema_name);
    else
        nulls[5] = true;

    if (output->error_table_name[0] != '\0')
        values[6] = CStringGetTextDatum(output->error_table_name);
    else
        nulls[6] = true;

    if (output->error_column_name[0] != '\0')
        values[7] = CStringGetTextDatum(output->error_column_name);
    else
        nulls[7] = true;

    if (output->error_constraint_name[0] != '\0')
        values[8] = CStringGetTextDatum(output->error_constraint_name);
    else
        nulls[8] = true;

    tuple = heap_form_tuple(tupdesc, values, nulls);
    PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/*
 * pg_background_full_sql
 *     Return the full SQL the worker is/was running.
 *
 * The 120-char preview shown by pg_background_list is good for monitoring;
 * for debugging, callers want the complete query. Stored in worker_info
 * (palloc'd in WorkerInfoMemoryContext) so it survives DSM detach. Capped
 * at PGBG_FULL_SQL_MAX_LEN with a "[...]" sentinel; longer queries should
 * be debugged from the application's own logs.
 *
 * Subject to the same per-row authorization check as list: only the
 * owner (or a role with the worker's role privileges) can read the SQL.
 */
Datum
pg_background_full_sql(PG_FUNCTION_ARGS)
{
    int32 pid = PG_GETARG_INT32(0);
    int64 cookie_in = PG_GETARG_INT64(1);
    pg_background_worker_info *info = find_worker_info(pid);

    if (info == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_UNDEFINED_OBJECT),
                 errmsg("PID %d is not attached to this session", pid)));
    check_rights(info);

    if (info->cookie != (uint64) cookie_in)
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("cookie mismatch for PID %d", pid),
                 errhint("The worker may have been restarted or the handle is stale.")));

    if (info->full_sql == NULL)
        PG_RETURN_NULL();

    PG_RETURN_TEXT_P(cstring_to_text(info->full_sql));
}

/*
 * pg_background_detach_all
 *     Detach all tracked workers in the current session.
 *
 * Returns: int4 - number of workers actually detached
 */
Datum
pg_background_detach_all(PG_FUNCTION_ARGS)
{
    HASH_SEQ_STATUS hstat;
    pg_background_worker_info *info;
    pid_t      *pids_to_detach;
    int         count = 0;
    int         detached = 0;
    int         capacity;
    int         i;

    if (worker_hash == NULL)
        PG_RETURN_INT32(0);

    capacity = hash_get_num_entries(worker_hash);
    if (capacity == 0)
        PG_RETURN_INT32(0);

    /* Snapshot PIDs to avoid modifying hash during iteration */
    pids_to_detach = palloc(sizeof(pid_t) * capacity);

    hash_seq_init(&hstat, worker_hash);
    while ((info = hash_seq_search(&hstat)) != NULL)
    {
        /* Only detach workers we have rights to */
        Oid cur;
        int sec;
        GetUserIdAndSecContext(&cur, &sec);
        if (has_privs_of_role(cur, info->current_user_id))
        {
            if (count < capacity)
                pids_to_detach[count++] = info->pid;
        }
    }

    /* Now detach each one */
    for (i = 0; i < count; i++)
    {
        info = find_worker_info(pids_to_detach[i]);
        if (info != NULL && info->seg != NULL)
        {
            /*
             * Count only detaches that actually tore down the segment.
             * detach_worker_seg() returns false when a result reader is
             * still active; that worker is detached later by the reader's
             * own cleanup, so counting it here would over-report.
             */
            if (detach_worker_seg(info))
                detached++;
        }
    }

    pfree(pids_to_detach);
    PG_RETURN_INT32(detached);
}

/*
 * pg_background_cancel_all
 *     Cancel all tracked workers in the current session.
 *
 * Consistent with cancel(): sets the cancel flag in shared memory for all
 * workers (including not-yet-started), so they will see it when they start.
 * Signals are only sent to workers that have actually started.
 *
 * Returns: int4 - number of workers for which cancel was requested
 */
Datum
pg_background_cancel_all(PG_FUNCTION_ARGS)
{
    HASH_SEQ_STATUS hstat;
    pg_background_worker_info *info;
    pid_t      *pids_to_cancel;
    int         count = 0;
    int         capacity;
    int         i;
    int         canceled = 0;

    if (worker_hash == NULL)
        PG_RETURN_INT32(0);

    capacity = hash_get_num_entries(worker_hash);
    if (capacity == 0)
        PG_RETURN_INT32(0);

    /* Snapshot PIDs to avoid modifying hash during iteration */
    pids_to_cancel = palloc(sizeof(pid_t) * capacity);

    hash_seq_init(&hstat, worker_hash);
    while ((info = hash_seq_search(&hstat)) != NULL)
    {
        /* Only cancel workers we have rights to */
        Oid cur;
        int sec;
        GetUserIdAndSecContext(&cur, &sec);
        if (has_privs_of_role(cur, info->current_user_id))
        {
            /*
             * Include all non-canceled workers, regardless of started state.
             * This matches cancel() semantics: set the cancel flag for
             * not-yet-started workers (they'll see it on startup), and send
             * signals only to started workers (handled by pgbg_send_cancel_signals).
             */
            if (!info->canceled)
            {
                if (count < capacity)
                    pids_to_cancel[count++] = info->pid;
            }
        }
    }

    /* Now cancel each one */
    for (i = 0; i < count; i++)
    {
        info = find_worker_info(pids_to_cancel[i]);
        if (info != NULL && !info->canceled)
        {
            pgbg_request_cancel(info);
            pgbg_send_cancel_signals(info, 0);
            info->canceled = true;
            /* Note: stats increment happens in cleanup_worker_info(), not here,
             * to maintain consistency with pg_background_cancel() */
            canceled++;
        }
    }

    pfree(pids_to_cancel);
    PG_RETURN_INT32(canceled);
}
