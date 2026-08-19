/*--------------------------------------------------------------------------
 *
 * pg_background_internal.h
 *     Private header shared between pg_background.c (launcher) and
 *     pg_background_worker.c (worker process).
 *
 * Contains shared struct definitions, constants, and cross-file helper
 * declarations. Not installed; used only inside the build tree.
 *
 * Copyright (c) 2014-2026, Vibhor Kumar and contributors
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * Licensed under the PostgreSQL License. See LICENSE file for details.
 *
 * -------------------------------------------------------------------------
 */
#ifndef PG_BACKGROUND_INTERNAL_H_
#define PG_BACKGROUND_INTERNAL_H_

#include "datatype/timestamp.h"
#include "lib/stringinfo.h"
#include "postmaster/bgworker.h"
#include "storage/dsm.h"
#include "storage/shm_mq.h"
#include "utils/hsearch.h"

/* ============================================================================
 * CONSTANTS
 * ============================================================================
 */

/* SQL terminator length for null byte */
#define SQL_TERMINATOR_LEN 1

/* Magic number for DSM segment verification */
#define PG_BACKGROUND_MAGIC             0x50674267

/*
 * DSM Table of Contents keys.
 *
 * v2.0 (C1) split the previous single PG_BACKGROUND_KEY_FIXED_DATA chunk
 * into two:
 *   - PG_BACKGROUND_KEY_INPUT:  launcher → worker, immutable after launch
 *                               except for cancel_requested (a mutable
 *                               control flag the launcher keeps writing).
 *   - PG_BACKGROUND_KEY_OUTPUT: worker → launcher, written by the worker
 *                               during execution and read by the launcher.
 * Splitting them clarifies barrier ordering and avoids cache-line bouncing
 * between the two roles.
 */
#define PG_BACKGROUND_KEY_INPUT         0
#define PG_BACKGROUND_KEY_SQL           1
#define PG_BACKGROUND_KEY_GUC           2
#define PG_BACKGROUND_KEY_QUEUE         3
#define PG_BACKGROUND_KEY_OUTPUT        4
#define PG_BACKGROUND_NKEYS             5

/* SQL preview length for list() monitoring */
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

/* Worker label maximum length */
#define PGBG_LABEL_MAX_LEN          64

/* Command tag buffer size (includes NUL terminator, so max 63 chars + NUL) */
#define PGBG_COMMAND_TAG_LEN        64

/* Structured error field lengths */
#define PGBG_ERROR_SQLSTATE_LEN     6
#define PGBG_ERROR_MESSAGE_LEN      256
#define PGBG_ERROR_DETAIL_LEN       256
#define PGBG_ERROR_HINT_LEN         256
#define PGBG_ERROR_CONTEXT_LEN      256

/* v2.0 (B5c): structured error context fields (NAMEDATALEN-sized) */
#define PGBG_ERROR_NAME_LEN         64

/* ============================================================================
 * DATA STRUCTURES
 * ============================================================================
 */

/*
 * pg_background_input
 *     Launcher-controlled metadata passed to the background worker.
 *
 * Written by the launcher at launch time and (with the single exception
 * of cancel_requested) treated as immutable thereafter. The worker only
 * reads these fields; it never writes them. cancel_requested is a mutable
 * control flag set by pgbg_request_cancel and polled by the worker via
 * CHECK_FOR_INTERRUPTS-time checks.
 *
 * Stored under PG_BACKGROUND_KEY_INPUT in the DSM table of contents.
 */
typedef struct pg_background_input
{
    Oid         database_id;            /* Database OID */
    Oid         authenticated_user_id;  /* Authenticated user OID */
    Oid         current_user_id;        /* Current user OID (may differ from auth) */
    int         sec_context;            /* Security context flags */
    NameData    database;               /* Database name */
    NameData    authenticated_user;     /* Authenticated user name */
    uint64      cookie;                 /* v2 identity cookie (cryptographically random) */
    uint32      cancel_requested;       /* [mutable] cancel flag: 0=no, 1=requested */
    char        label[PGBG_LABEL_MAX_LEN + 1];           /* Optional worker label */
} pg_background_input;

/*
 * pg_background_output
 *     Worker-produced state read by the launcher.
 *
 * Written by the worker during execution and read by the launcher via
 * pg_background_result_info / error_info / get_progress. The
 * launcher zero-initializes the struct at allocation time so partial
 * reads before the worker starts producing values still see sensible
 * defaults (empty strings, 0 timestamps, progress_pct = -1).
 *
 * Two publish-flag patterns live inside this struct:
 *
 *   - error_sqlstate is the publish flag for the entire error block.
 *     Worker writes message/detail/.../error_*_name fields, then a
 *     pg_write_barrier(), then strlcpy's error_sqlstate LAST. Launcher
 *     readers test error_sqlstate first; if non-empty, issue
 *     pg_read_barrier() before reading any other error_* field.
 *
 *   - result_published is the publish flag for the row_count + command_tag
 *     pair. Same idiom: write the pair, pg_write_barrier(), then set the
 *     flag. Reader tests the flag first, pg_read_barrier(), then reads
 *     the pair. Prevents a launcher from seeing a fresh row_count paired
 *     with a stale command_tag.
 *
 * Stored under PG_BACKGROUND_KEY_OUTPUT in the DSM table of contents.
 */
typedef struct pg_background_output
{
    /* Progress reporting */
    int32       progress_pct;           /* Progress percentage (0-100, -1 = not reported) */
    char        progress_msg[64];       /* Progress message (brief status) */

    /* Structured error info (written by worker on error) */
    char        error_sqlstate[PGBG_ERROR_SQLSTATE_LEN]; /* SQLSTATE; publish flag */
    char        error_message[PGBG_ERROR_MESSAGE_LEN];   /* Primary error message */
    char        error_detail[PGBG_ERROR_DETAIL_LEN];     /* Error detail */
    char        error_hint[PGBG_ERROR_HINT_LEN];         /* Error hint */
    char        error_context[PGBG_ERROR_CONTEXT_LEN];   /* Error context */

    /* v2.0 (B5c): error-source identifiers from edata (empty = not set) */
    char        error_schema_name[PGBG_ERROR_NAME_LEN];     /* Schema name */
    char        error_table_name[PGBG_ERROR_NAME_LEN];      /* Relation name */
    char        error_column_name[PGBG_ERROR_NAME_LEN];     /* Column name */
    char        error_constraint_name[PGBG_ERROR_NAME_LEN]; /* Constraint name */

    /* Result metadata (written by worker on completion) */
    int64       result_row_count;                        /* Rows returned/affected */
    char        command_tag[PGBG_COMMAND_TAG_LEN];       /* Command completion tag */
    uint8       result_published;                        /* 0 = not yet, 1 = pair valid */

    /*
     * v2.0 (B5b): execution timestamps. started_at is written by the worker
     * just before the SPI loop starts; finished_at is written when the
     * worker finishes (success or error). Both are TimestampTz (microseconds
     * since 2000-01-01 UTC) and zero means "not set".
     */
    TimestampTz started_at;             /* Execution start (0 = not set) */
    TimestampTz finished_at;            /* Execution end   (0 = not set) */
} pg_background_output;

/*
 * pg_background_worker_info
 *     Per-worker tracking state maintained by the launching backend.
 *
 * Stored in a session-local hash table keyed by worker PID.
 * Memory is managed in WorkerInfoMemoryContext to enable bulk cleanup.
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
    bool        result_disabled;        /* True if launched via submit (fire-and-forget) */
    bool        canceled;               /* True if cancel was called on this worker */
    bool        active;                 /* True while a result reader holds this segment */
    TimestampTz launched_at;            /* Launch timestamp for monitoring */
    int32       queue_size;             /* Queue size used for this worker */
    char        sql_preview[PGBG_SQL_PREVIEW_LEN + 1];  /* SQL preview for list */
    char       *last_error;             /* Last error message (in WorkerInfoMemoryContext) */

    /* v1.9: Worker label for operational clarity */
    char        label[PGBG_LABEL_MAX_LEN + 1];          /* Optional label (empty = none) */

    /*
     * v1.10 (B3): full SQL text, palloc'd in WorkerInfoMemoryContext.
     * Capped at PGBG_FULL_SQL_MAX_LEN bytes; longer queries are truncated
     * with a "[...]" marker. Survives DSM detach so pg_background_full_sql
     * works after the worker exits.
     */
    char       *full_sql;
} pg_background_worker_info;

/*
 * Maximum bytes of full SQL we cache in launcher memory per worker.
 * Beyond this, we store only a truncated copy. 64 KiB matches the
 * default queue_size and is large enough for >99% of real-world SQL
 * while bounding worst-case session memory usage.
 */
#define PGBG_FULL_SQL_MAX_LEN  65536

/*
 * pg_background_result_state
 *     State maintained across SRF calls to pg_background_result.
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

/*
 * pgbg_stats
 *     Session-local statistics. Defined here so multiple files can update
 *     counters; the storage itself lives in pg_background.c.
 */
typedef struct pgbg_stats
{
    int64       workers_launched;
    int64       workers_completed;
    int64       workers_failed;
    int64       workers_canceled;
    int64       workers_timed_out;      /* v2.0 (B5a): timeouts from run */
    int64       total_execution_us;
} pgbg_stats;

/* ============================================================================
 * SHARED MODULE STATE (defined in pg_background.c)
 * ============================================================================
 */

extern pgbg_stats     session_stats;
extern dsm_segment   *worker_dsm_seg;     /* worker-side: current DSM segment */
extern int            pgbg_worker_timeout;

/* ============================================================================
 * CROSS-FILE HELPERS
 * ============================================================================
 */

/*
 * Worker process entry point. Invoked by the PostgreSQL background-worker
 * infrastructure via the bgw_function_name configured at launch time.
 */
extern PGDLLEXPORT void pg_background_worker_main(Datum main_arg);

/*
 * Shared error-context callback. Used by both the worker (in
 * execute_sql_string) and the launcher (in pg_background_result) to label
 * errors with the worker's PID.
 *
 * Argument is `pid_t *`.
 */
extern void pg_background_error_callback(void *arg);

/*
 * exists_binary_recv_fn
 *     Whether a type has a binary receive function. Lives in
 *     pg_background_worker.c; the launcher's result reader calls it when
 *     deciding how to consume a tuple field.
 */
extern bool exists_binary_recv_fn(Oid type);

#endif  /* PG_BACKGROUND_INTERNAL_H_ */
