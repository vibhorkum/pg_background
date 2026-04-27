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

/* ============================================================================
 * DATA STRUCTURES
 * ============================================================================
 */

/*
 * pg_background_fixed_data
 *     Fixed-size metadata passed via dynamic shared memory segment.
 *
 * Allocated in shared memory and accessed by both the launcher process and
 * the background worker. Fields are marked [W] (worker writes), [L]
 * (launcher writes), or [B] (both).
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

    /* v1.9: Structured error info (written by worker on error) */
    char        error_sqlstate[PGBG_ERROR_SQLSTATE_LEN]; /* [W] SQLSTATE code (e.g., "42P01") */
    char        error_message[PGBG_ERROR_MESSAGE_LEN];   /* [W] Primary error message */
    char        error_detail[PGBG_ERROR_DETAIL_LEN];     /* [W] Error detail */
    char        error_hint[PGBG_ERROR_HINT_LEN];         /* [W] Error hint */
    char        error_context[PGBG_ERROR_CONTEXT_LEN];   /* [W] Error context */

    /* v1.9: Result metadata (written by worker on completion) */
    int64       result_row_count;       /* [W] Number of rows returned/affected */
    char        command_tag[PGBG_COMMAND_TAG_LEN];       /* [W] Command completion tag */

    /* v1.9: Worker label (written by launcher) */
    char        label[PGBG_LABEL_MAX_LEN + 1];           /* [L] Optional worker label */
} pg_background_fixed_data;

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
    bool        result_disabled;        /* True if launched via submit_v2 (fire-and-forget) */
    bool        canceled;               /* True if cancel_v2 was called on this worker */
    TimestampTz launched_at;            /* Launch timestamp for monitoring */
    int32       queue_size;             /* Queue size used for this worker */
    char        sql_preview[PGBG_SQL_PREVIEW_LEN + 1];  /* SQL preview for list_v2 */
    char       *last_error;             /* Last error message (in WorkerInfoMemoryContext) */

    /* v1.9: Worker label for operational clarity */
    char        label[PGBG_LABEL_MAX_LEN + 1];          /* Optional label (empty = none) */

    /*
     * v1.10 (B3): full SQL text, palloc'd in WorkerInfoMemoryContext.
     * Capped at PGBG_FULL_SQL_MAX_LEN bytes; longer queries are truncated
     * with a "[...]" marker. Survives DSM detach so pg_background_full_sql_v2
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
