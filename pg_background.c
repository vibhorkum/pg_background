/*--------------------------------------------------------------------------
 *
 * pg_background.c
 *     Run SQL commands using a background worker.
 *
 * Copyright (C) 2014, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *     contrib/pg_background/pg_background.c
 *
 * SUPPORTED VERSIONS
 *     PostgreSQL 14, 15, 16, 17, 18 (PG_VERSION_NUM >= 140000 && < 190000)
 *
 * DESCRIPTION
 *     This extension provides the ability to launch SQL commands in
 *     background worker processes. Workers execute autonomously and
 *     communicate results back via shared memory queues.
 *
 * KEY BEHAVIORS
 *     - v1 API preserved: launch/result/detach (fire-and-forget detach is NOT cancel)
 *     - v2 API adds: cookie-validated handle, submit (fire-and-forget), cancel, wait, list
 *     - Fixes NOTIFY race: shm_mq_wait_for_attach() before returning to SQL
 *     - Avoids past crashes: never pfree() BGW handle; deterministic hash cleanup
 *
 * VERSION 1.8 IMPROVEMENTS
 *     - Cryptographically secure cookie generation using pg_strong_random()
 *     - Dedicated memory context for worker info (prevents session memory bloat)
 *     - Exponential backoff in polling loops (reduces CPU usage)
 *     - Refactored code to eliminate duplication
 *     - Enhanced documentation and error messages
 *     - GUCs: pg_background.max_workers, worker_timeout, default_queue_size
 *     - Session statistics: pg_background_stats_v2()
 *     - Progress reporting: pg_background_progress(), pg_background_get_progress_v2()
 *     - Bounds checking: queue size max, timeout max, timestamp overflow protection
 *     - UTF-8 aware string truncation
 *     - Race condition fix in list_v2() hash iteration
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
#include "storage/dsm.h"
#include "storage/ipc.h"
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
#include "windows/pg_background_win.h"
#endif /* WIN32 */

#include "pg_background.h"

/*
 * Supported versions only (per your request).
 * If you want older PGs, we can re-expand the compat macros, but for 1.8:
 */
#if PG_VERSION_NUM < 140000 || PG_VERSION_NUM >= 190000
#error "pg_background 1.8 supports PostgreSQL 14-18 only"
#endif

/* ============================================================================
 * CONSTANTS
 * ============================================================================
 */

/* SQL terminator length for null byte */
#define SQL_TERMINATOR_LEN 1

/* Magic number for DSM segment verification */
#define PG_BACKGROUND_MAGIC             0x50674267

/* DSM Table of Contents keys */
#define PG_BACKGROUND_KEY_FIXED_DATA    0
#define PG_BACKGROUND_KEY_SQL           1
#define PG_BACKGROUND_KEY_GUC           2
#define PG_BACKGROUND_KEY_QUEUE         3
#define PG_BACKGROUND_NKEYS             4

/* SQL preview length for list_v2() monitoring */
#define PGBG_SQL_PREVIEW_LEN 120

/* Maximum error message length stored in worker info (prevents memory bloat) */
#define PGBG_MAX_ERROR_MSG_LEN 512

/* Initial hash table size for worker tracking */
#define PGBG_WORKER_HASH_INIT_SIZE 32

/* Polling interval bounds for exponential backoff (microseconds) */
#define PGBG_POLL_INTERVAL_MIN_US   1000    /* 1ms minimum */
#define PGBG_POLL_INTERVAL_MAX_US   100000  /* 100ms maximum */
#define PGBG_POLL_BACKOFF_FACTOR    2       /* Double each iteration */

/* Grace period bounds (milliseconds) */
#define PGBG_GRACE_MS_MAX           3600000 /* 1 hour maximum */

/* Queue size bounds (bytes) */
#define PGBG_QUEUE_SIZE_MAX         (256 * 1024 * 1024) /* 256 MB maximum */

/* Timeout bounds (milliseconds) */
#define PGBG_TIMEOUT_MS_MAX         86400000 /* 24 hours maximum */

/* ============================================================================
 * DATA STRUCTURES
 * ============================================================================
 */

/*
 * pg_background_fixed_data
 *     Fixed-size metadata passed via dynamic shared memory segment.
 *
 * This structure is allocated in shared memory and accessed by both
 * the launcher process and the background worker. Fields marked as
 * [W] are written by the worker, [L] by the launcher, [B] by both.
 */
typedef struct pg_background_fixed_data
{
    Oid         database_id;            /* [L] Database OID */
    Oid         authenticated_user_id;  /* [L] Authenticated user OID */
    Oid         current_user_id;        /* [L] Current user OID (may differ from auth) */
    int         sec_context;            /* [L] Security context flags */
    NameData    database;               /* [L] Database name */
    NameData    authenticated_user;     /* [L] Authenticated user name */
    uint64      cookie;                 /* [L] v2 identity cookie (cryptographically random) */
    uint32      cancel_requested;       /* [B] v2 cancel flag: 0=no, 1=requested */
    int32       progress_pct;           /* [W] Progress percentage (0-100, -1 = not reported) */
    char        progress_msg[64];       /* [W] Progress message (brief status) */
} pg_background_fixed_data;

/*
 * pg_background_worker_info
 *     Per-worker tracking state maintained by the launching backend.
 *
 * Stored in a session-local hash table keyed by worker PID.
 * Memory is managed in WorkerInfoMemoryContext to enable bulk cleanup.
 *
 * NOTE ON PID TYPES:
 * - SQL layer uses int32 (PostgreSQL's int4 type for function arguments)
 * - Internal code uses pid_t (POSIX process ID type)
 * - These are compatible on all supported platforms (pid_t is int or similar)
 * - Explicit casts are used at SQL/C boundaries for clarity
 */
typedef struct pg_background_worker_info
{
    pid_t       pid;                    /* Worker process ID (hash key) */
    Oid         current_user_id;        /* User who launched this worker */
    uint64      cookie;                 /* v2 identity cookie for validation */
    dsm_segment *seg;                   /* DSM segment handle */
    BackgroundWorkerHandle *handle;     /* BGW handle (owned by PostgreSQL, do NOT pfree) */
    shm_mq_handle *responseq;           /* Response queue handle */
    bool        consumed;               /* True if results have been read */
    bool        mapping_pinned;         /* True if DSM mapping is pinned */
    bool        result_disabled;        /* True if launched via submit_v2 (fire-and-forget) */
    bool        canceled;               /* True if cancel_v2 was called on this worker */
    TimestampTz launched_at;            /* Launch timestamp for monitoring */
    int32       queue_size;             /* Queue size used for this worker */
    char        sql_preview[PGBG_SQL_PREVIEW_LEN + 1];  /* SQL preview for list_v2 */
    char       *last_error;             /* Last error message (in WorkerInfoMemoryContext) */
} pg_background_worker_info;

/*
 * pg_background_result_state
 *     State maintained across SRF calls to pg_background_result.
 *
 * Allocated in the SRF multi_call_memory_ctx for automatic cleanup.
 */
typedef struct pg_background_result_state
{
    pg_background_worker_info *info;    /* Associated worker info */
    FmgrInfo   *receive_functions;      /* Binary receive functions per column */
    Oid        *typioparams;            /* Type I/O parameters per column */
    bool        has_row_description;    /* True if RowDescription received */
    List       *command_tags;           /* List of command completion tags */
    bool        complete;               /* True if ReadyForQuery received */
} pg_background_result_state;

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
static int pgbg_worker_timeout = 0;

/* ============================================================================
 * STATISTICS
 * ============================================================================
 */

/*
 * Session-local statistics for monitoring and debugging.
 * These are reset when the session ends.
 */
typedef struct pgbg_stats
{
    int64       workers_launched;       /* Total workers launched */
    int64       workers_completed;      /* Workers that completed successfully */
    int64       workers_failed;         /* Workers that failed with error */
    int64       workers_canceled;       /* Workers that were canceled */
    int64       total_execution_us;     /* Total execution time in microseconds */
} pgbg_stats;

static pgbg_stats session_stats = {0};

/*
 * Worker-side: pointer to current DSM segment for progress reporting.
 * Only valid within a worker process, NULL in launcher process.
 */
static dsm_segment *worker_dsm_seg = NULL;

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
                             const char *sql_preview);

/* Error handling */
static void pg_background_error_callback(void *arg);
static void throw_untranslated_error(ErrorData translated_edata);
static void store_worker_error(pg_background_worker_info *info, const char *message);

/* Result processing */
static HeapTuple form_result_tuple(pg_background_result_state *state,
                                   TupleDesc tupdesc, StringInfo msg);

/* Worker execution */
static void handle_sigterm(SIGNAL_ARGS);
static void execute_sql_string(const char *sql);
static bool exists_binary_recv_fn(Oid type);

/* Internal launcher (shared by v1 and v2 APIs) */
static void launch_internal(text *sql, int32 queue_size, uint64 cookie,
                            bool result_disabled,
                            pid_t *out_pid);

/* Helper to build handle tuple (eliminates duplication) */
static Datum build_handle_tuple(FunctionCallInfo fcinfo, pid_t pid, uint64 cookie);

/* Ensure WorkerInfoMemoryContext exists */
static void ensure_worker_info_memory_context(void);

/* Polling with exponential backoff */
static void pgbg_sleep_with_backoff(long *interval_us, long remaining_us);

/*
 * PostgreSQL 18 changed portal APIs:
 * - PortalDefineQuery now takes 7 args (adds CachedPlanSource *)
 * - PortalRun now takes 6 args (removes run_once boolean)
 *
 * See similar extension breakages against v18.  [oai_citation:1‡GitHub](https://github.com/citusdata/pg_cron/issues/396)
 */
static inline void
pgbg_portal_define_query_compat(Portal portal,
                               const char *prepStmtName,
                               const char *sourceText,
                               CommandTag_compat commandTag,
                               List *stmts,
                               CachedPlan *cplan)
{
    /* PortalDefineQuery accepts same parameters in PG14-18 */
    PortalDefineQuery(portal, prepStmtName, sourceText, commandTag, stmts, cplan);
}

static inline bool
pgbg_portal_run_compat(Portal portal,
                       long count,
                       bool isTopLevel,
                       bool run_once,
                       DestReceiver *dest,
                       DestReceiver *altdest,
                       QueryCompletion *qc
                       )
{
#if PG_VERSION_NUM >= 180000
    (void) run_once;
    return PortalRun(portal, count, isTopLevel, dest, altdest, qc);
#else
    return PortalRun(portal, count, isTopLevel,
                     run_once, dest, altdest, qc);
#endif
}
/* v2 API helpers */
static uint64 pg_background_make_cookie(void);
static inline long pgbg_timestamp_diff_ms(TimestampTz start, TimestampTz stop);
static void pgbg_request_cancel(pg_background_worker_info *info);
static void pgbg_send_cancel_signals(pg_background_worker_info *info, int32 grace_ms);
static const char *pgbg_state_from_handle(pg_background_worker_info *info);

/* ============================================================================
 * MODULE MAGIC AND FUNCTION DECLARATIONS
 * ============================================================================
 */

PG_MODULE_MAGIC;

/* v1 API */
PG_FUNCTION_INFO_V1(pg_background_launch);
PG_FUNCTION_INFO_V1(pg_background_result);
PG_FUNCTION_INFO_V1(pg_background_detach);

/* v2 API */
PG_FUNCTION_INFO_V1(pg_background_launch_v2);
PG_FUNCTION_INFO_V1(pg_background_submit_v2);
PG_FUNCTION_INFO_V1(pg_background_result_v2);
PG_FUNCTION_INFO_V1(pg_background_detach_v2);
PG_FUNCTION_INFO_V1(pg_background_cancel_v2);
PG_FUNCTION_INFO_V1(pg_background_cancel_v2_grace);
PG_FUNCTION_INFO_V1(pg_background_wait_v2);
PG_FUNCTION_INFO_V1(pg_background_wait_v2_timeout);
PG_FUNCTION_INFO_V1(pg_background_list_v2);

/* Worker entry point (called by PostgreSQL background worker infrastructure) */
PGDLLEXPORT void pg_background_worker_main(Datum);

/* Module initialization */
PGDLLEXPORT void _PG_init(void);

/* Statistics retrieval function */
PG_FUNCTION_INFO_V1(pg_background_stats_v2);

/* Progress reporting function (called from worker) */
PG_FUNCTION_INFO_V1(pg_background_progress);

/* Progress retrieval function */
PG_FUNCTION_INFO_V1(pg_background_get_progress_v2);

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
 * The cookie is used in v2 API to prevent PID reuse attacks. Even if a PID
 * is recycled by the OS, the cookie will differ, preventing operations on
 * the wrong worker.
 *
 * SECURITY: Uses pg_strong_random() which is backed by the OS CSPRNG
 * (e.g., /dev/urandom on Unix, CryptGenRandom on Windows).
 *
 * FALLBACK: If pg_strong_random() fails (extremely rare), we fall back to
 * a time-based approach with process entropy. This is less secure but
 * still provides reasonable disambiguation.
 *
 * Returns: 64-bit random cookie (never returns 0)
 */
static uint64
pg_background_make_cookie(void)
{
    uint64 cookie;

    /*
     * Use cryptographically secure random number generator.
     * pg_strong_random() returns true on success.
     */
    if (!pg_strong_random(&cookie, sizeof(cookie)))
    {
        /*
         * Fallback if CSPRNG fails (should be extremely rare).
         * Use time-based entropy with process info.
         */
        uint64 t = (uint64) GetCurrentTimestamp();
        elog(DEBUG1, "pg_strong_random failed, using fallback cookie generation");
        cookie = (t << 17) ^ (t >> 13) ^ (uint64) MyProcPid ^ (uint64) (uintptr_t) MyProc;
    }

    /*
     * Ensure cookie is never zero (zero is used as "no cookie" in v1 API).
     * Use golden ratio fractional part (2^64 / phi) as fallback.
     * This constant (0x9e3779b97f4a7c15) is widely used in hash functions
     * (e.g., Knuth's multiplicative hash) for good bit distribution.
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

    /* Overflow protection: cap at LONG_MAX milliseconds (~24 days on 32-bit) */
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
}

/* ============================================================================
 * HANDLE TUPLE BUILDER (eliminates code duplication)
 * ============================================================================
 */

/*
 * build_handle_tuple
 *     Construct a pg_background_handle composite type value.
 *
 * Used by pg_background_launch_v2 and pg_background_submit_v2 to build
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
 *     result_disabled - True if results should be discarded (submit_v2)
 *     out_pid         - Output: worker process ID
 */
static void
launch_internal(text *sql, int32 queue_size, uint64 cookie,
                bool result_disabled,
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
    pg_background_fixed_data *fdata;
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

    /* Ensure worker info memory context exists */
    ensure_worker_info_memory_context();

    /* Estimate / allocate DSM */
    shm_toc_initialize_estimator(&e);
    shm_toc_estimate_chunk(&e, sizeof(pg_background_fixed_data));
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

    /* Fixed data */
    fdata = shm_toc_allocate(toc, sizeof(pg_background_fixed_data));
    fdata->database_id = MyDatabaseId;
    fdata->authenticated_user_id = GetAuthenticatedUserId();
    GetUserIdAndSecContext(&fdata->current_user_id, &fdata->sec_context);
    namestrcpy(&fdata->database, get_database_name(MyDatabaseId));
    namestrcpy(&fdata->authenticated_user,
               GetUserNameFromId(fdata->authenticated_user_id, false));
    fdata->cookie = cookie;
    fdata->cancel_requested = 0;
    fdata->progress_pct = -1;           /* -1 = not reported yet */
    fdata->progress_msg[0] = '\0';
    shm_toc_insert(toc, PG_BACKGROUND_KEY_FIXED_DATA, fdata);

    /* SQL text */
    sqlp = shm_toc_allocate(toc, sql_len + SQL_TERMINATOR_LEN);
    memcpy(sqlp, VARDATA(sql), sql_len);
    sqlp[sql_len] = '\0';
    shm_toc_insert(toc, PG_BACKGROUND_KEY_SQL, sqlp);

    /* GUC state */
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
                 errhint("You may need to increase max_worker_processes.")));
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

    /* Save info */
    save_worker_info(pid, cookie, seg, worker_handle, responseq,
                     result_disabled, queue_size, preview);

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
 * V1 API FUNCTIONS
 * ============================================================================
 */

/*
 * pg_background_launch
 *     Launch a background worker to execute SQL (v1 API).
 *
 * Parameters:
 *     sql        - SQL command(s) to execute (text)
 *     queue_size - Shared memory queue size in bytes (default: uses
 *                  pg_background.default_queue_size GUC, typically 64KB)
 *
 * Returns: Worker process ID (int4)
 *
 * Notes:
 *     - Results must be retrieved with pg_background_result()
 *     - Use pg_background_detach() for fire-and-forget (does NOT cancel)
 *     - v2 API is recommended for new code (provides cookie validation)
 */
Datum
pg_background_launch(PG_FUNCTION_ARGS)
{
    text   *sql = PG_GETARG_TEXT_PP(0);
    int32   queue_size = PG_GETARG_INT32(1);
    pid_t   pid;

    launch_internal(sql, queue_size, 0 /* cookie=0 for v1 */, false, &pid);
    PG_RETURN_INT32((int32) pid);
}

/* ============================================================================
 * V2 API FUNCTIONS
 * ============================================================================
 */

/*
 * pg_background_launch_v2
 *     Launch a background worker with cookie validation (v2 API).
 *
 * Parameters:
 *     sql        - SQL command(s) to execute (text)
 *     queue_size - Shared memory queue size in bytes (default: uses
 *                  pg_background.default_queue_size GUC, typically 64KB)
 *
 * Returns: pg_background_handle composite (pid int4, cookie int8)
 *
 * Notes:
 *     - Cookie provides protection against PID reuse attacks
 *     - Results retrieved with pg_background_result_v2(pid, cookie)
 *     - Use pg_background_cancel_v2() to cancel (unlike v1 detach)
 */
Datum
pg_background_launch_v2(PG_FUNCTION_ARGS)
{
    text   *sql = PG_GETARG_TEXT_PP(0);
    int32   queue_size = PG_GETARG_INT32(1);
    pid_t   pid;
    uint64  cookie = pg_background_make_cookie();

    launch_internal(sql, queue_size, cookie, false, &pid);
    PG_RETURN_DATUM(build_handle_tuple(fcinfo, pid, cookie));
}

/*
 * pg_background_submit_v2
 *     Launch a fire-and-forget background worker (v2 API).
 *
 * Similar to launch_v2 but results are discarded. The worker runs
 * autonomously and cannot be queried for results.
 *
 * Parameters:
 *     sql        - SQL command(s) to execute (text)
 *     queue_size - Shared memory queue size in bytes (default: uses
 *                  pg_background.default_queue_size GUC, typically 64KB)
 *
 * Returns: pg_background_handle composite (pid int4, cookie int8)
 *
 * Notes:
 *     - Calling result_v2() on a submitted worker raises an error
 *     - Worker can still be canceled with cancel_v2()
 *     - Use for side-effect-only operations (logging, notifications)
 */
Datum
pg_background_submit_v2(PG_FUNCTION_ARGS)
{
    text   *sql = PG_GETARG_TEXT_PP(0);
    int32   queue_size = PG_GETARG_INT32(1);
    pid_t   pid;
    uint64  cookie = pg_background_make_cookie();

    launch_internal(sql, queue_size, cookie, true, &pid);
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
 *     Store an error message in the worker info for list_v2() visibility.
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
 *     Retrieve results from a background worker (v1 API).
 *
 * This is a set-returning function that streams results from the
 * worker's shared memory queue. Results can only be consumed once.
 *
 * Parameters:
 *     pid - Worker process ID
 *
 * Returns: SETOF record (caller must provide column definition list)
 *
 * Errors:
 *     - UNDEFINED_OBJECT: PID not attached or results already consumed
 *     - FEATURE_NOT_SUPPORTED: Worker was launched via submit_v2
 *     - CONNECTION_FAILURE: Worker died before sending results
 */
Datum
pg_background_result(PG_FUNCTION_ARGS)
{
    int32        pid = PG_GETARG_INT32(0);
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

        if (info->result_disabled)
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("results are disabled for PID %d (submitted via submit_v2)", pid)));

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

        res = shm_mq_receive(state->info->responseq, &nbytes, &data, false);
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

                /* Store error for list_v2() visibility */
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
                HeapTuple result = form_result_tuple(state, tupdesc, &msg);
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
    if (state->info && state->info->seg)
    {
        dsm_detach(state->info->seg);
        state->info->seg = NULL;  /* Prevent double-detach */
    }

    SRF_RETURN_DONE(funcctx);
}

/*
 * pg_background_result_v2
 *     Retrieve results with cookie validation (v2 API).
 *
 * Validates the cookie before delegating to the v1 result function.
 * This prevents accessing results from a wrong worker if PID was reused.
 *
 * Parameters:
 *     pid    - Worker process ID
 *     cookie - Worker identity cookie from launch_v2
 *
 * Returns: SETOF record (same as pg_background_result)
 *
 * Errors:
 *     - UNDEFINED_OBJECT: Cookie mismatch or PID not attached
 */
Datum
pg_background_result_v2(PG_FUNCTION_ARGS)
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
                (errcode(ERRCODE_UNDEFINED_OBJECT),
                 errmsg("PID %d is not attached to this session (cookie mismatch)", pid)));

    return pg_background_result(fcinfo);
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
 *     Stop tracking a background worker (v1 API).
 *
 * IMPORTANT: This is fire-and-forget, NOT cancellation. The worker
 * continues running; we just stop tracking it.
 */
Datum
pg_background_detach(PG_FUNCTION_ARGS)
{
    int32 pid = PG_GETARG_INT32(0);
    pg_background_worker_info *info = find_worker_info(pid);

    if (info == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_UNDEFINED_OBJECT),
                 errmsg("PID %d is not attached to this session", pid)));
    check_rights(info);

    if (info->seg && info->mapping_pinned)
    {
        dsm_unpin_mapping(info->seg);
        info->mapping_pinned = false;
    }

    if (info->seg)
    {
        dsm_detach(info->seg);
        info->seg = NULL;  /* Prevent double-detach */
    }

    PG_RETURN_VOID();
}

/*
 * pg_background_detach_v2
 *     Stop tracking a background worker with cookie validation (v2 API).
 *
 * Same as v1 detach but validates the cookie first.
 * Use cancel_v2 if you want to actually stop the worker.
 */
Datum
pg_background_detach_v2(PG_FUNCTION_ARGS)
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

    if (info->seg && info->mapping_pinned)
    {
        dsm_unpin_mapping(info->seg);
        info->mapping_pinned = false;
    }

    if (info->seg)
    {
        dsm_detach(info->seg);
        info->seg = NULL;  /* Prevent double-detach */
    }

    PG_RETURN_VOID();
}

/* ============================================================================
 * CANCEL FUNCTIONS
 * ============================================================================
 */

/*
 * pg_background_cancel_v2
 *     Cancel a background worker immediately (v2 API).
 *
 * Sets the cancel flag and sends SIGTERM to the worker.
 * The worker will exit at its next CHECK_FOR_INTERRUPTS() point.
 */
Datum
pg_background_cancel_v2(PG_FUNCTION_ARGS)
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

    /* Mark as canceled for statistics tracking */
    info->canceled = true;

    pgbg_request_cancel(info);
    pgbg_send_cancel_signals(info, 0);
    PG_RETURN_VOID();
}

/*
 * pg_background_cancel_v2_grace
 *     Cancel a background worker with grace period (v2 API).
 *
 * Sends SIGTERM, waits up to grace_ms milliseconds for clean exit,
 * then sends SIGKILL if still running.
 *
 * Grace period is capped at PGBG_GRACE_MS_MAX (1 hour) to prevent
 * indefinite blocking.
 */
Datum
pg_background_cancel_v2_grace(PG_FUNCTION_ARGS)
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
 * pg_background_wait_v2
 *     Block until a background worker exits (v2 API).
 *
 * Uses PostgreSQL's WaitForBackgroundWorkerShutdown which is efficient
 * (uses latches, not polling).
 */
Datum
pg_background_wait_v2(PG_FUNCTION_ARGS)
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

    if (info->handle != NULL)
        (void) WaitForBackgroundWorkerShutdown(info->handle);

    PG_RETURN_VOID();
}

/*
 * pg_background_wait_v2_timeout
 *     Wait for worker exit with timeout (v2 API).
 *
 * Uses exponential backoff polling to reduce CPU usage while waiting.
 * Returns true if worker stopped, false if timeout expired.
 *
 * Parameters:
 *     timeout_ms - Maximum wait time in milliseconds
 *
 * Returns: true if worker stopped, false on timeout
 */
Datum
pg_background_wait_v2_timeout(PG_FUNCTION_ARGS)
{
    int32 pid = PG_GETARG_INT32(0);
    int64 cookie_in = PG_GETARG_INT64(1);
    int32 timeout_ms = PG_GETARG_INT32(2);
    pg_background_worker_info *info = find_worker_info(pid);
    TimestampTz start;
    long poll_interval_us = PGBG_POLL_INTERVAL_MIN_US;

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

    /* Clamp timeout to valid range */
    if (timeout_ms < 0)
        timeout_ms = 0;
    else if (timeout_ms > PGBG_TIMEOUT_MS_MAX)
        timeout_ms = PGBG_TIMEOUT_MS_MAX;

    start = GetCurrentTimestamp();

    for (;;)
    {
        pid_t wpid = 0;
        BgwHandleStatus hs;
        long elapsed_ms;
        long remaining_us;

        if (info->handle == NULL)
            PG_RETURN_BOOL(true);

        hs = GetBackgroundWorkerPid(info->handle, &wpid);
        if (hs == BGWH_STOPPED)
            PG_RETURN_BOOL(true);

        elapsed_ms = pgbg_timestamp_diff_ms(start, GetCurrentTimestamp());
        if (elapsed_ms >= timeout_ms)
            PG_RETURN_BOOL(false);

        /* Calculate remaining time to avoid overshooting timeout */
        remaining_us = (timeout_ms - elapsed_ms) * 1000L;

        /* Sleep with exponential backoff, capped to remaining time */
        pgbg_sleep_with_backoff(&poll_interval_us, remaining_us);
        CHECK_FOR_INTERRUPTS();
    }
}

/* ============================================================================
 * LIST FUNCTION
 * ============================================================================
 */

/*
 * pg_background_list_state
 *     State for list_v2 SRF iteration.
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
 * pg_background_list_v2
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
 *          sql_preview, last_error, consumed
 */
Datum
pg_background_list_v2(PG_FUNCTION_ARGS)
{
    FuncCallContext *funcctx;
    pg_background_list_state *state;

    if (SRF_IS_FIRSTCALL())
    {
        MemoryContext oldcontext;
        HASH_SEQ_STATUS hstat;
        pg_background_worker_info *info;
        int capacity;
        int count = 0;

        funcctx = SRF_FIRSTCALL_INIT();
        oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

        state = palloc0(sizeof(pg_background_list_state));

        /* Snapshot all PIDs to avoid race with cleanup callbacks */
        if (worker_hash != NULL)
        {
            capacity = hash_get_num_entries(worker_hash);
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

        /* Resolve tupledesc from coldeflist */
        {
            TupleDesc tupdesc;
            if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
                ereport(ERROR,
                        (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                         errmsg("function returning record called in context that cannot accept type record"),
                         errhint("Call it in FROM with a column definition list.")));
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
        Datum values[9];
        bool nulls[9];
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

        /* (pid, cookie, launched_at, user_id, queue_size, state, sql_preview, last_error, consumed) */
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
 * pgbg_request_cancel
 *     Set the cancel flag in shared memory.
 */
static void
pgbg_request_cancel(pg_background_worker_info *info)
{
    shm_toc *toc;
    pg_background_fixed_data *fdata;

    if (info == NULL || info->seg == NULL)
        return;

    toc = shm_toc_attach(PG_BACKGROUND_MAGIC, dsm_segment_address(info->seg));
    if (toc == NULL)
        return;

    fdata = shm_toc_lookup_compat(toc, PG_BACKGROUND_KEY_FIXED_DATA, true);
    if (fdata == NULL)
        return;

    fdata->cancel_requested = 1;
}

/*
 * pgbg_send_cancel_signals
 *     Send cancellation signals to worker.
 *
 * Sends SIGTERM for cooperative cancellation. If grace_ms > 0,
 * waits for worker to exit, then sends SIGKILL if still running.
 *
 * Uses exponential backoff polling during the grace period.
 */
static void
pgbg_send_cancel_signals(pg_background_worker_info *info, int32 grace_ms)
{
    TimestampTz start;
    pid_t wpid = 0;
    BgwHandleStatus hs;
    long poll_interval_us = PGBG_POLL_INTERVAL_MIN_US;

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
     * Workers still check fdata->cancel_requested flag before executing SQL.
     * This provides limited cancellation:
     * - WORKS: Cancel before worker starts SQL execution
     * - DOES NOT WORK: Cancel during long-running query (no mid-query interrupt)
     * 
     * PRODUCTION IMPACT:
     * On Windows, cancel_v2() may not interrupt long-running SQL. Use:
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

    start = GetCurrentTimestamp();

    for (;;)
    {
        long elapsed_ms;
        long remaining_us;

        hs = GetBackgroundWorkerPid(info->handle, &wpid);
        if (hs == BGWH_STOPPED)
            return;

        elapsed_ms = pgbg_timestamp_diff_ms(start, GetCurrentTimestamp());
        if (elapsed_ms >= grace_ms)
            break;

        /* Calculate remaining time to avoid overshooting grace period */
        remaining_us = (grace_ms - elapsed_ms) * 1000L;

        /* Sleep with exponential backoff, capped to remaining time */
        pgbg_sleep_with_backoff(&poll_interval_us, remaining_us);
        CHECK_FOR_INTERRUPTS();
    }

#ifndef WIN32
    if (info->pid > 0)
        (void) kill(info->pid, SIGKILL);
#endif
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

    (void) seg;

    if (worker_hash == NULL)
        return;

    /* Find entry, update stats, free last_error if any, then remove */
    {
        pg_background_worker_info *info = hash_search(worker_hash, (void *) &pid, HASH_FIND, &found);
        if (found && info != NULL)
        {
            /* Update session statistics based on worker state */
            TimestampTz now = GetCurrentTimestamp();
            int64 execution_us = now - info->launched_at;
            if (execution_us > 0)
                session_stats.total_execution_us += execution_us;

            /*
             * Categorize worker outcome:
             * 1. Canceled takes priority (explicit user action)
             * 2. Failed if there was an error
             * 3. Completed otherwise
             */
            if (info->canceled)
            {
                session_stats.workers_canceled++;
            }
            else if (info->last_error != NULL)
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
     * If hash table is now empty, destroy it and reset the memory context
     * to release memory back to the system. This prevents long-running
     * sessions from retaining high-water-mark memory after many workers
     * have been launched and cleaned up.
     */
    if (hash_get_num_entries(worker_hash) == 0)
    {
        hash_destroy(worker_hash);
        worker_hash = NULL;

        if (WorkerInfoMemoryContext != NULL)
        {
            MemoryContextReset(WorkerInfoMemoryContext);
            elog(DEBUG1, "pg_background: reset WorkerInfoMemoryContext after last worker cleanup");
        }
    }
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
                 const char *sql_preview)
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
     * SCENARIO: On systems with rapid process recycling (high load, small PID space),
     * a background worker PID could theoretically be reused within the same session
     * before the cleanup callback fires.
     * 
     * SAFETY MECHANISMS:
     * 1. Cookie validation (v2 API): Even if PID is reused, cookie mismatch
     *    will prevent operations on wrong worker
     * 2. User ID check: If PID is reused by different user, we FATAL to prevent
     *    security breach
     * 3. Proactive cleanup: Detach stale DSM segment before creating new entry
     * 
     * WHY FATAL vs ERROR: A PID collision with different user indicates either:
     *    a) Severe kernel PID space exhaustion, OR
     *    b) Potential security attack (impersonation)
     * Both warrant session termination rather than allowing continued operation.
     * 
     * OBSERVABILITY: Monitor for "background worker with PID X already exists"
     * in logs - this indicates PID space pressure and may require system tuning.
     */
    info = find_worker_info(pid);
    if (info != NULL)
    {
        if (current_user_id != info->current_user_id)
            ereport(FATAL,
                    (errcode(ERRCODE_DUPLICATE_OBJECT),
                     errmsg("background worker with PID \"%d\" already exists",
                            (int) pid)));

        if (info->seg && info->mapping_pinned)
        {
            dsm_unpin_mapping(info->seg);
            info->mapping_pinned = false;
        }
        if (info->seg)
            dsm_detach(info->seg);
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

    info->launched_at = GetCurrentTimestamp();
    info->queue_size = queue_size;
    strlcpy(info->sql_preview, sql_preview ? sql_preview : "", sizeof(info->sql_preview));

    info->last_error = NULL;
}

/*
 * pg_background_error_callback
 *     Error context callback to identify background worker errors.
 */
static void
pg_background_error_callback(void *arg)
{
    pid_t pid = *(pid_t *) arg;
    errcontext("background worker, pid %d", (int) pid);
}

/* ============================================================================
 * BACKGROUND WORKER MAIN
 * ============================================================================
 */

/*
 * pg_background_worker_main
 *     Entry point for background worker process.
 *
 * This function is called by PostgreSQL when the background worker starts.
 * It connects to the database, restores GUC state, executes the SQL,
 * and sends results back via the shared memory queue.
 */
void
pg_background_worker_main(Datum main_arg)
{
    dsm_segment *seg;
    shm_toc     *toc;
    pg_background_fixed_data *fdata;
    char        *sql;
    char        *gucstate;
    shm_mq      *mq;
    shm_mq_handle *responseq;

    pqsignal(SIGTERM, handle_sigterm);
    BackgroundWorkerUnblockSignals();

    Assert(CurrentResourceOwner == NULL);
    CurrentResourceOwner = ResourceOwnerCreate(NULL, "pg_background");
    CurrentMemoryContext = AllocSetContextCreate(TopMemoryContext,
                                                 "pg_background session",
                                                 ALLOCSET_DEFAULT_MINSIZE,
                                                 ALLOCSET_DEFAULT_INITSIZE,
                                                 ALLOCSET_DEFAULT_MAXSIZE);

    seg = dsm_attach(DatumGetInt32(main_arg));
    if (seg == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("unable to map dynamic shared memory segment")));

    /* Store for progress reporting */
    worker_dsm_seg = seg;

    toc = shm_toc_attach(PG_BACKGROUND_MAGIC, dsm_segment_address(seg));
    if (toc == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("bad magic number in dynamic shared memory segment")));

    fdata = shm_toc_lookup_compat(toc, PG_BACKGROUND_KEY_FIXED_DATA, false);
    sql = shm_toc_lookup_compat(toc, PG_BACKGROUND_KEY_SQL, false);
    gucstate = shm_toc_lookup_compat(toc, PG_BACKGROUND_KEY_GUC, false);
    mq = shm_toc_lookup_compat(toc, PG_BACKGROUND_KEY_QUEUE, false);

    if (fdata == NULL || sql == NULL || gucstate == NULL || mq == NULL)
        ereport(ERROR, (errmsg("failed to locate required data in shared memory")));

    shm_mq_set_sender(mq, MyProc);
    responseq = shm_mq_attach(mq, seg, NULL);

    pq_redirect_to_shm_mq(seg, responseq);

    BackgroundWorkerInitializeConnection(NameStr(fdata->database),
                                         NameStr(fdata->authenticated_user),
                                         BGWORKER_BYPASS_ALLOWCONN);

    if (fdata->database_id != MyDatabaseId ||
        fdata->authenticated_user_id != GetAuthenticatedUserId())
        ereport(ERROR,
                (errmsg("user or database renamed during pg_background startup")));

    StartTransactionCommand();
    RestoreGUCState(gucstate);
    CommitTransactionCommand();

    /* If cancel was requested before we began, exit quietly */
    /*
     * I5: Volatile access for cancel flag race protection
     * 
     * The cancel_requested field is shared memory accessed by:
     * 1. Launcher session (writes via pgbg_request_cancel)
     * 2. Worker process (reads here and potentially in signal handler)
     * 
     * Without volatile, compiler could cache the read and miss concurrent updates.
     * While PostgreSQL's CHECK_FOR_INTERRUPTS() handles most cancellation via
     * signals, this flag provides best-effort early exit before SQL execution.
     * 
     * NOTE: Full memory barrier semantics not required here - we only need to
     * prevent compiler optimization. Signal handler will set InterruptPending
     * which is already volatile in PostgreSQL core.
     */
    if (*(volatile uint32 *)&fdata->cancel_requested != 0)
    {
        /*
         * Explicitly delete the ResourceOwner before proc_exit to ensure
         * clean resource cleanup. This prevents warnings about leaked
         * resources in PostgreSQL debug builds.
         */
        ResourceOwnerDelete(CurrentResourceOwner);
        CurrentResourceOwner = NULL;
        proc_exit(0);
    }

    SetCurrentStatementStartTimestamp();
    debug_query_string = sql;
    pgstat_report_activity(STATE_RUNNING, sql);

    StartTransactionCommand();

    /*
     * Apply worker timeout. Priority:
     * 1. pg_background.worker_timeout if set (> 0)
     * 2. session's statement_timeout if set (> 0)
     * 3. no timeout
     */
    {
        int effective_timeout = 0;

        if (pgbg_worker_timeout > 0)
            effective_timeout = pgbg_worker_timeout;
        else if (StatementTimeout > 0)
            effective_timeout = StatementTimeout;

        if (effective_timeout > 0)
            enable_timeout_after(STATEMENT_TIMEOUT, effective_timeout);
        else
            disable_timeout(STATEMENT_TIMEOUT, false);
    }

    SetUserIdAndSecContext(fdata->current_user_id, fdata->sec_context);

    execute_sql_string(sql);

    disable_timeout(STATEMENT_TIMEOUT, false);
    CommitTransactionCommand();

    pgstat_report_activity(STATE_IDLE, sql);
    pgstat_report_stat(true);

    ReadyForQuery(DestRemote);

    /*
     * Explicit ResourceOwner cleanup on normal exit path.
     * While PostgreSQL will clean this up during proc_exit(), explicit
     * cleanup prevents warnings in debug builds and is cleaner practice.
     */
    if (CurrentResourceOwner != NULL)
    {
        ResourceOwnerRelease(CurrentResourceOwner,
                             RESOURCE_RELEASE_BEFORE_LOCKS,
                             false, true);
        ResourceOwnerRelease(CurrentResourceOwner,
                             RESOURCE_RELEASE_LOCKS,
                             false, true);
        ResourceOwnerRelease(CurrentResourceOwner,
                             RESOURCE_RELEASE_AFTER_LOCKS,
                             false, true);
        ResourceOwnerDelete(CurrentResourceOwner);
        CurrentResourceOwner = NULL;
    }
}

/*
 * exists_binary_recv_fn
 *     Check if a type has a binary receive function.
 */
static bool
exists_binary_recv_fn(Oid type)
{
    HeapTuple typeTuple;
    Form_pg_type pt;
    bool exists_recv_fn;

    typeTuple = SearchSysCache1(TYPEOID, ObjectIdGetDatum(type));
    if (!HeapTupleIsValid(typeTuple))
        elog(ERROR, "cache lookup failed for type %u", type);

    pt = (Form_pg_type) GETSTRUCT(typeTuple);
    exists_recv_fn = OidIsValid(pt->typreceive);
    ReleaseSysCache(typeTuple);

    return exists_recv_fn;
}

/*
 * execute_sql_string
 *     Parse and execute SQL commands in the worker.
 *
 * Supports multiple commands separated by semicolons.
 * Transaction control statements are not allowed.
 */
static void
execute_sql_string(const char *sql)
{
    List       *raw_parsetree_list;
    ListCell   *lc1;
    bool        isTopLevel;
    int         commands_remaining;
    MemoryContext parsecontext;
    MemoryContext oldcontext;
    /*
     * I4: Error context for worker
     * 
     * Provides diagnostic context for errors that occur during worker execution.
     * This helps distinguish worker errors from launcher errors in logs and
     * makes debugging production issues significantly easier.
     * 
     * The context callback will prepend "pg_background worker executing: <sql>"
     * to any error messages, making it clear which background job failed.
     */
    ErrorContextCallback sqlerrcontext;

    parsecontext = AllocSetContextCreate(TopMemoryContext,
                                         "pg_background parse/plan",
                                         ALLOCSET_DEFAULT_MINSIZE,
                                         ALLOCSET_DEFAULT_INITSIZE,
                                         ALLOCSET_DEFAULT_MAXSIZE);

    /* Set up error context */
    sqlerrcontext.callback = pg_background_error_callback;
    sqlerrcontext.arg = (void *) &MyProcPid;
    sqlerrcontext.previous = error_context_stack;
    error_context_stack = &sqlerrcontext;

    PG_TRY();
    {
        oldcontext = MemoryContextSwitchTo(parsecontext);
        raw_parsetree_list = pg_parse_query(sql);
        commands_remaining = list_length(raw_parsetree_list);
        isTopLevel = (commands_remaining == 1);
        MemoryContextSwitchTo(oldcontext);

        foreach(lc1, raw_parsetree_list)
        {
            RawStmt    *parsetree = (RawStmt *) lfirst(lc1);
            CommandTag_compat  commandTag;
            QueryCompletion qc;
            List       *querytree_list;
            List       *plantree_list;
            bool        snapshot_set = false;
            Portal      portal;
            DestReceiver *receiver;
            int16       format = 1;

            if (IsA(parsetree->stmt, TransactionStmt))
                ereport(ERROR,
                        (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                         errmsg("transaction control statements are not allowed in pg_background")));

            commandTag = CreateCommandTag_compat(parsetree);
            set_ps_display_compat(GetCommandTagName(commandTag));

            BeginCommand_compat(commandTag, DestNone);

            if (analyze_requires_snapshot(parsetree))
            {
                PushActiveSnapshot(GetTransactionSnapshot());
                snapshot_set = true;
            }

            oldcontext = MemoryContextSwitchTo(parsecontext);
            querytree_list = pg_analyze_and_rewrite_compat(parsetree, sql, NULL, 0, NULL);

            plantree_list = pg_plan_queries(querytree_list, sql, 0, NULL);

            if (snapshot_set)
                PopActiveSnapshot();

            CHECK_FOR_INTERRUPTS();

            portal = CreatePortal("", true, true);
            portal->visible = false;

            pgbg_portal_define_query_compat(portal, NULL, sql, commandTag, plantree_list, NULL);
            PortalStart(portal, NULL, 0, InvalidSnapshot);
            PortalSetResultFormat(portal, 1, &format);

            commands_remaining--;
            if (commands_remaining > 0)
                receiver = CreateDestReceiver(DestNone);
            else
            {
                receiver = CreateDestReceiver(DestRemote);
                SetRemoteDestReceiverParams(receiver, portal);
            }

            MemoryContextSwitchTo(oldcontext);

            (void) pgbg_portal_run_compat(portal, FETCH_ALL, isTopLevel, true, receiver, receiver, &qc);

            (*receiver->rDestroy)(receiver);

            EndCommand_compat(&qc, DestRemote);

            PortalDrop(portal, false);
        }

        CommandCounterIncrement();
    }
    PG_CATCH();
    {
        /* Clean up memory context before re-throwing */
        MemoryContextDelete(parsecontext);
        /* Restore error context stack */
        error_context_stack = sqlerrcontext.previous;
        PG_RE_THROW();
    }
    PG_END_TRY();

    /* Normal path: clean up memory context and restore error context */
    MemoryContextDelete(parsecontext);
    error_context_stack = sqlerrcontext.previous;
}

/*
 * handle_sigterm
 *     SIGTERM signal handler for background worker.
 *
 * Sets interrupt flags to trigger clean exit at next CHECK_FOR_INTERRUPTS().
 * Must be async-signal-safe.
 */
static void
handle_sigterm(SIGNAL_ARGS)
{
    int save_errno = errno;

    if (MyProc)
        SetLatch(&MyProc->procLatch);

    if (!proc_exit_inprogress)
    {
        InterruptPending = true;
        ProcDiePending = true;
    }

    errno = save_errno;
}

/* ============================================================================
 * STATISTICS FUNCTION
 * ============================================================================
 */

/*
 * pg_background_stats_v2
 *     Return session-local statistics about background workers.
 *
 * Returns a single row with:
 *   - workers_launched: total workers launched this session
 *   - workers_completed: workers that completed successfully
 *   - workers_failed: workers that failed with an error
 *   - workers_canceled: workers that were explicitly canceled
 *   - workers_active: currently active workers
 *   - avg_execution_ms: average execution time in milliseconds
 *   - max_workers: current pg_background.max_workers setting
 */
Datum
pg_background_stats_v2(PG_FUNCTION_ARGS)
{
    TupleDesc   tupdesc;
    Datum       values[7];
    bool        nulls[7];
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
    values[4] = Int32GetDatum(active_workers);
    values[5] = Float8GetDatum(avg_execution_ms);
    values[6] = Int32GetDatum(pgbg_max_workers);

    tuple = heap_form_tuple(tupdesc, values, nulls);
    PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/* ============================================================================
 * PROGRESS REPORTING FUNCTIONS
 * ============================================================================
 */

/*
 * pg_background_progress
 *     Report progress from within a background worker.
 *
 * This function is meant to be called by SQL running inside a background
 * worker to report execution progress back to the launcher.
 *
 * Parameters:
 *     pct     - Progress percentage (0-100)
 *     message - Brief status message (optional, max 63 chars)
 *
 * Usage in worker SQL:
 *     SELECT pg_background_progress(50, 'Halfway done');
 */
Datum
pg_background_progress(PG_FUNCTION_ARGS)
{
    int32       pct = PG_GETARG_INT32(0);
    text       *msg = PG_ARGISNULL(1) ? NULL : PG_GETARG_TEXT_PP(1);
    shm_toc    *toc;
    pg_background_fixed_data *fdata;

    /* Only valid in worker context */
    if (worker_dsm_seg == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("pg_background_progress can only be called from a background worker")));

    /* Clamp percentage */
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;

    /* Access shared memory */
    toc = shm_toc_attach(PG_BACKGROUND_MAGIC, dsm_segment_address(worker_dsm_seg));
    if (toc == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("cannot access shared memory for progress reporting")));

    fdata = shm_toc_lookup_compat(toc, PG_BACKGROUND_KEY_FIXED_DATA, false);
    if (fdata == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("cannot find fixed data in shared memory")));

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
        int max_len = (int) sizeof(fdata->progress_msg) - 1;
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

        memcpy(fdata->progress_msg, VARDATA_ANY(msg), copy_len);
        fdata->progress_msg[copy_len] = '\0';
    }
    else
    {
        fdata->progress_msg[0] = '\0';
    }

    /* Write barrier ensures msg is visible before pct update */
    pg_write_barrier();

    /* Update progress percentage (volatile for cross-process visibility) */
    *(volatile int32 *)&fdata->progress_pct = pct;

    PG_RETURN_VOID();
}

/*
 * pg_background_get_progress_v2
 *     Get progress of a specific background worker.
 *
 * Parameters:
 *     pid    - Worker process ID
 *     cookie - Worker identity cookie
 *
 * Returns: (progress_pct int, progress_msg text) or NULL if not available
 */
Datum
pg_background_get_progress_v2(PG_FUNCTION_ARGS)
{
    int32       pid = PG_GETARG_INT32(0);
    int64       cookie_in = PG_GETARG_INT64(1);
    pg_background_worker_info *info;
    shm_toc    *toc;
    pg_background_fixed_data *fdata;
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

    fdata = shm_toc_lookup_compat(toc, PG_BACKGROUND_KEY_FIXED_DATA, true);
    if (fdata == NULL)
        PG_RETURN_NULL();

    /*
     * Read progress with memory barrier for consistency.
     * The worker writes: progress_msg then progress_pct (with write barrier).
     * We read: progress_pct then progress_msg (with read barrier).
     * The barriers ensure we see the message that was written before
     * the percentage was updated.
     */
    progress_pct = *(volatile int32 *)&fdata->progress_pct;
    if (progress_pct < 0)
        PG_RETURN_NULL();  /* Progress not reported yet */

    pg_read_barrier();

    /*
     * After the read barrier, memory is synchronized. Copy the message
     * using memcpy to avoid volatile qualifier warnings with strlcpy.
     * The source is guaranteed to be null-terminated (max 63 chars + null).
     */
    memcpy(progress_msg, fdata->progress_msg, sizeof(progress_msg));
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
