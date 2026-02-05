/*--------------------------------------------------------------------------
 *
 * pg_background.c
 *    Run SQL commands using a background worker.
 *
 *
 * Copyright (C) 2014, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *             contrib/pg_background/pg_background.c
 * This version targets supported PostgreSQL versions: 12, 13, 14, 15, 16, 17, 18.
 * (PG_VERSION_NUM >= 120000 && < 190000)
 *
 * Key behavior:
 *  - v1 API preserved: launch/result/detach (fire-and-forget detach is NOT cancel)
 *  - v2 API adds: cookie-validated handle, submit (fire-and-forget), cancel, wait, list
 *  - Fixes NOTIFY race: shm_mq_wait_for_attach() before returning to SQL
 *  - Avoids past crashes: never pfree() BGW handle; deterministic hash cleanup
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
#include "utils/timeout.h"
#include "utils/timestamp.h"

#include <signal.h>
#include <unistd.h>

#ifdef WIN32
#include "windows/pg_background_win.h"
#endif /* WIN32 */

#include "pg_background.h"

/*
 * Supported versions only (per your request).
 * If you want older PGs, we can re-expand the compat macros, but for 1.6:
 */
#if PG_VERSION_NUM < 120000 || PG_VERSION_NUM >= 190000
#error "pg_background 1.6 supports PostgreSQL 12-18 only"
#endif

/* ---- constants ---- */
#define SQL_TERMINATOR_LEN 1

#define PG_BACKGROUND_MAGIC             0x50674267
#define PG_BACKGROUND_KEY_FIXED_DATA    0
#define PG_BACKGROUND_KEY_SQL           1
#define PG_BACKGROUND_KEY_GUC           2
#define PG_BACKGROUND_KEY_QUEUE         3
#define PG_BACKGROUND_NKEYS             4

#define PGBG_SQL_PREVIEW_LEN 120

/* Fixed-size data passed via our dynamic shared memory segment. */
typedef struct pg_background_fixed_data
{
    Oid         database_id;
    Oid         authenticated_user_id;
    Oid         current_user_id;
    int         sec_context;
    NameData    database;
    NameData    authenticated_user;

    /* v2 identity */
    uint64      cookie;

    /* v2 cancel: 0 = no, 1 = requested */
    uint32      cancel_requested;
} pg_background_fixed_data;

/* Private state maintained by the launching backend for IPC. */
typedef struct pg_background_worker_info
{
    pid_t       pid;
    Oid         current_user_id;

    uint64      cookie;

    dsm_segment *seg;
    BackgroundWorkerHandle *handle;
    shm_mq_handle *responseq;

    bool        consumed;
    bool        mapping_pinned;

    /* submit_v2 = true means caller opted out of results */
    bool        result_disabled;

    /* metadata for list_v2 */
    TimestampTz launched_at;
    int32       queue_size;
    char        sql_preview[PGBG_SQL_PREVIEW_LEN + 1];
    char       *last_error; /* TopMemoryContext; may be NULL */
} pg_background_worker_info;

/* Private state maintained across calls to pg_background_result. */
typedef struct pg_background_result_state
{
    pg_background_worker_info *info;
    FmgrInfo   *receive_functions;
    Oid        *typioparams;
    bool        has_row_description;
    List       *command_tags;
    bool        complete;
} pg_background_result_state;

static HTAB *worker_hash = NULL;

/* ---- forward decls ---- */
static void cleanup_worker_info(dsm_segment *seg, Datum pid_datum);
static pg_background_worker_info *find_worker_info(pid_t pid);
static void check_rights(pg_background_worker_info *info);

static void save_worker_info(pid_t pid, uint64 cookie, dsm_segment *seg,
                             BackgroundWorkerHandle *handle,
                             shm_mq_handle *responseq,
                             bool result_disabled,
                             int32 queue_size,
                             const char *sql_preview);

static void pg_background_error_callback(void *arg);

static HeapTuple form_result_tuple(pg_background_result_state *state,
                                   TupleDesc tupdesc, StringInfo msg);

static void handle_sigterm(SIGNAL_ARGS);
static void execute_sql_string(const char *sql);
static bool exists_binary_recv_fn(Oid type);

static void throw_untranslated_error(ErrorData translated_edata);

/* shared internal launcher used by v1 + v2 */
static void launch_internal(text *sql, int32 queue_size, uint64 cookie,
                            bool result_disabled,
                            pid_t *out_pid);

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
                               CommandTag commandTag,
                               List *stmts,
                               CachedPlan *cplan)
{
#if PG_VERSION_NUM >= 180000
    /* PG18+: PortalDefineQuery(portal, prepStmtName, sourceText, commandTag, stmts, cplan) */
    PortalDefineQuery(portal, prepStmtName, sourceText, commandTag, stmts, cplan);
#else
    /* PG12–17: same call form for your supported range */
    PortalDefineQuery(portal, prepStmtName, sourceText, commandTag, stmts, cplan);
#endif
}

static inline bool
pgbg_portal_run_compat(Portal portal,
                       long count,
                       bool isTopLevel,
                       bool run_once,
                       DestReceiver *dest,
                       DestReceiver *altdest,
                       QueryCompletion *qc)
{
#if PG_VERSION_NUM >= 180000
    (void) run_once;
    return PortalRun(portal, count, isTopLevel, dest, altdest, qc);
#else
    return PortalRun(portal, count, isTopLevel,
                     run_once, dest, altdest, qc);
#endif
}
/* v2 helpers */
static inline uint64 pg_background_make_cookie(void);
static inline long pgbg_timestamp_diff_ms(TimestampTz start, TimestampTz stop);
static void pgbg_request_cancel(pg_background_worker_info *info);
static void pgbg_send_cancel_signals(pg_background_worker_info *info, int32 grace_ms);
static const char *pgbg_state_from_handle(pg_background_worker_info *info);

/* exported worker entrypoint */
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

PGDLLEXPORT void pg_background_worker_main(Datum);

/* -------------------------------------------------------------------------
 * Cookie helper (not cryptographic; disambiguation only)
 * ------------------------------------------------------------------------- */
static inline uint64
pg_background_make_cookie(void)
{
    uint64 t = (uint64) GetCurrentTimestamp();
    uint64 c = (t << 17) ^ (t >> 13) ^ (uint64) MyProcPid ^ (uint64) (uintptr_t) MyProc;
    if (c == 0)
        c = 0x9e3779b97f4a7c15ULL ^ (uint64) MyProcPid;
    return c;
}

/* TimestampTz is int64 microseconds since PG epoch; safe for ms diff. */
static inline long
pgbg_timestamp_diff_ms(TimestampTz start, TimestampTz stop)
{
    int64 diff_us = (int64) stop - (int64) start;
    if (diff_us < 0)
        diff_us = 0;
    return (long) (diff_us / 1000);
}

/* -------------------------------------------------------------------------
 * Internal launcher (NOTIFY race fixed via shm_mq_wait_for_attach)
 * ------------------------------------------------------------------------- */
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

    if (queue_size < 0 || ((uint64) queue_size) < shm_mq_minimum_size)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("queue size must be at least %zu bytes",
                        shm_mq_minimum_size)));

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

    oldcontext = MemoryContextSwitchTo(TopMemoryContext);
    responseq = shm_mq_attach(mq, seg, NULL);
    MemoryContextSwitchTo(oldcontext);

    /* Worker config */
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

    oldcontext = MemoryContextSwitchTo(TopMemoryContext);
    if (!RegisterDynamicBackgroundWorker(&worker, &worker_handle))
        ereport(ERROR,
                (errcode(ERRCODE_INSUFFICIENT_RESOURCES),
                 errmsg("could not register background process"),
                 errhint("You may need to increase max_worker_processes.")));
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

    /* Prepare preview */
    preview_len = Min(sql_len, PGBG_SQL_PREVIEW_LEN);
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

    *out_pid = pid;
}

/* -------------------------------------------------------------------------
 * v1: launch
 * ------------------------------------------------------------------------- */
Datum
pg_background_launch(PG_FUNCTION_ARGS)
{
    text   *sql = PG_GETARG_TEXT_PP(0);
    int32   queue_size = PG_GETARG_INT32(1);
    pid_t   pid;

    launch_internal(sql, queue_size, 0 /* cookie unused */, false, &pid);
    PG_RETURN_INT32((int32) pid);
}

/* -------------------------------------------------------------------------
 * v2: launch (results enabled)
 * Returns public.pg_background_handle (pid int4, cookie int8)
 * ------------------------------------------------------------------------- */
Datum
pg_background_launch_v2(PG_FUNCTION_ARGS)
{
    text   *sql = PG_GETARG_TEXT_PP(0);
    int32   queue_size = PG_GETARG_INT32(1);
    pid_t   pid;
    uint64  cookie = pg_background_make_cookie();

    Datum       values[2];
    bool        isnulls[2] = {false, false};
    TupleDesc   tupdesc;
    HeapTuple   tuple;

    launch_internal(sql, queue_size, cookie, false, &pid);

    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("function returning composite called in context that cannot accept it")));
    tupdesc = BlessTupleDesc(tupdesc);

    values[0] = Int32GetDatum((int32) pid);
    values[1] = Int64GetDatum((int64) cookie);

    tuple = heap_form_tuple(tupdesc, values, isnulls);
    PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/* -------------------------------------------------------------------------
 * v2: submit (fire-and-forget, results disabled)
 * ------------------------------------------------------------------------- */
Datum
pg_background_submit_v2(PG_FUNCTION_ARGS)
{
    text   *sql = PG_GETARG_TEXT_PP(0);
    int32   queue_size = PG_GETARG_INT32(1);
    pid_t   pid;
    uint64  cookie = pg_background_make_cookie();

    Datum       values[2];
    bool        isnulls[2] = {false, false};
    TupleDesc   tupdesc;
    HeapTuple   tuple;

    launch_internal(sql, queue_size, cookie, true, &pid);

    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("function returning composite called in context that cannot accept it")));
    tupdesc = BlessTupleDesc(tupdesc);

    values[0] = Int32GetDatum((int32) pid);
    values[1] = Int64GetDatum((int64) cookie);

    tuple = heap_form_tuple(tupdesc, values, isnulls);
    PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/* -------------------------------------------------------------------------
 * Error translation helper
 * ------------------------------------------------------------------------- */
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

/* -------------------------------------------------------------------------
 * v1: result
 * ------------------------------------------------------------------------- */
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

                /* remember last_error for list_v2 (best-effort) */
                if (state->info != NULL)
                {
                    MemoryContext oldcxt = MemoryContextSwitchTo(TopMemoryContext);
                    if (state->info->last_error != NULL)
                        pfree(state->info->last_error);
                    state->info->last_error = (edata.message != NULL)
                        ? pstrdup(edata.message)
                        : pstrdup("unknown error");
                    MemoryContextSwitchTo(oldcxt);
                }

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

/* -------------------------------------------------------------------------
 * v2: result (cookie validate, then delegate to v1 path)
 * ------------------------------------------------------------------------- */
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

/* -------------------------------------------------------------------------
 * v1: detach (fire-and-forget; NOT cancel)
 * ------------------------------------------------------------------------- */
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

/* -------------------------------------------------------------------------
 * v2: detach (cookie validated; still NOT cancel)
 * ------------------------------------------------------------------------- */
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

/* -------------------------------------------------------------------------
 * v2: cancel (no overload ambiguity in 1.6 SQL)
 * ------------------------------------------------------------------------- */
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

    pgbg_request_cancel(info);
    pgbg_send_cancel_signals(info, 0);
    PG_RETURN_VOID();
}

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

    if (grace_ms < 0)
        grace_ms = 0;

    pgbg_request_cancel(info);
    pgbg_send_cancel_signals(info, grace_ms);
    PG_RETURN_VOID();
}

/* -------------------------------------------------------------------------
 * v2: wait (block until shutdown)
 * ------------------------------------------------------------------------- */
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

/* timeout_ms version: returns true if stopped */
Datum
pg_background_wait_v2_timeout(PG_FUNCTION_ARGS)
{
    int32 pid = PG_GETARG_INT32(0);
    int64 cookie_in = PG_GETARG_INT64(1);
    int32 timeout_ms = PG_GETARG_INT32(2);
    pg_background_worker_info *info = find_worker_info(pid);
    TimestampTz start;

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

    if (timeout_ms < 0)
        timeout_ms = 0;

    start = GetCurrentTimestamp();

    for (;;)
    {
        pid_t wpid = 0;
        BgwHandleStatus hs;

        if (info->handle == NULL)
            PG_RETURN_BOOL(true);

        hs = GetBackgroundWorkerPid(info->handle, &wpid);
        if (hs == BGWH_STOPPED)
            PG_RETURN_BOOL(true);

        if (pgbg_timestamp_diff_ms(start, GetCurrentTimestamp()) >= timeout_ms)
            PG_RETURN_BOOL(false);

        pg_usleep(10 * 1000L);
        CHECK_FOR_INTERRUPTS();
    }
}

/* -------------------------------------------------------------------------
 * v2: list (record; caller supplies column definition list)
 * ------------------------------------------------------------------------- */
Datum
pg_background_list_v2(PG_FUNCTION_ARGS)
{
    FuncCallContext *funcctx;

    if (SRF_IS_FIRSTCALL())
    {
        MemoryContext oldcontext;
        HASH_SEQ_STATUS *hstat;

        funcctx = SRF_FIRSTCALL_INIT();
        oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

        hstat = palloc(sizeof(HASH_SEQ_STATUS));
        if (worker_hash != NULL)
            hash_seq_init(hstat, worker_hash);
        else
            MemSet(hstat, 0, sizeof(*hstat));

        funcctx->user_fctx = hstat;

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

    if (worker_hash == NULL)
        SRF_RETURN_DONE(funcctx);

    for (;;)
    {
        HASH_SEQ_STATUS *hstat = (HASH_SEQ_STATUS *) funcctx->user_fctx;
        pg_background_worker_info *info;
        Datum values[9];
        bool nulls[9];
        HeapTuple tuple;

        info = (pg_background_worker_info *) hash_seq_search(hstat);
        if (info == NULL)
            SRF_RETURN_DONE(funcctx);

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
}

/* -------------------------------------------------------------------------
 * Cancel helpers
 * ------------------------------------------------------------------------- */
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

static void
pgbg_send_cancel_signals(pg_background_worker_info *info, int32 grace_ms)
{
    TimestampTz start;
    pid_t wpid = 0;
    BgwHandleStatus hs;

    if (info == NULL)
        return;

#ifndef WIN32
    if (info->pid > 0)
        (void) kill(info->pid, SIGTERM);
#endif

    if (grace_ms <= 0 || info->handle == NULL)
        return;

    start = GetCurrentTimestamp();

    for (;;)
    {
        hs = GetBackgroundWorkerPid(info->handle, &wpid);
        if (hs == BGWH_STOPPED)
            return;

        if (pgbg_timestamp_diff_ms(start, GetCurrentTimestamp()) >= grace_ms)
            break;

        pg_usleep(10 * 1000L);
        CHECK_FOR_INTERRUPTS();
    }

#ifndef WIN32
    if (info->pid > 0)
        (void) kill(info->pid, SIGKILL);
#endif
}

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

/* -------------------------------------------------------------------------
 * DSM detach cleanup: remove hash entry; free our allocations only
 * ------------------------------------------------------------------------- */
static void
cleanup_worker_info(dsm_segment *seg, Datum pid_datum)
{
    pid_t pid = (pid_t) DatumGetInt32(pid_datum);
    bool found;

    (void) seg;

    if (worker_hash == NULL)
        return;

    /* Find entry, free last_error if any, then remove */
    {
        pg_background_worker_info *info = hash_search(worker_hash, (void *) &pid, HASH_FIND, &found);
        if (found && info != NULL)
        {
            if (info->last_error != NULL)
            {
                pfree(info->last_error);
                info->last_error = NULL;
            }
        }
    }

    hash_search(worker_hash, (void *) &pid, HASH_REMOVE, &found);
    /*
     * Don't ERROR if not found - may be concurrent cleanup or already removed.
     * This can happen during normal operation with concurrent detach/result.
     */
    if (!found)
        elog(DEBUG1, "pg_background worker_hash entry for PID %d already removed", (int) pid);
}

/* Find worker info by pid */
static pg_background_worker_info *
find_worker_info(pid_t pid)
{
    if (worker_hash == NULL)
        return NULL;
    return (pg_background_worker_info *) hash_search(worker_hash, (void *) &pid, HASH_FIND, NULL);
}

/* Permission check */
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

/* Save worker info */
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

    if (worker_hash == NULL)
    {
        HASHCTL ctl;
        MemSet(&ctl, 0, sizeof(ctl));
        ctl.keysize = sizeof(pid_t);
        ctl.entrysize = sizeof(pg_background_worker_info);

        /* allocate hash in TopMemoryContext to outlive transactions safely */
        worker_hash = hash_create("pg_background worker_hash", 16, &ctl,
                                  HASH_BLOBS | HASH_ELEM);
    }

    GetUserIdAndSecContext(&current_user_id, &sec_context);

    /* If stale entry exists (rare PID reuse inside same session), detach it */
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

    info->launched_at = GetCurrentTimestamp();
    info->queue_size = queue_size;
    strlcpy(info->sql_preview, sql_preview ? sql_preview : "", sizeof(info->sql_preview));

    info->last_error = NULL;
}

/* Error context */
static void
pg_background_error_callback(void *arg)
{
    pid_t pid = *(pid_t *) arg;
    errcontext("background worker, pid %d", (int) pid);
}

/* -------------------------------------------------------------------------
 * Background worker main
 * ------------------------------------------------------------------------- */
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
    if (fdata->cancel_requested != 0)
        proc_exit(0);

    SetCurrentStatementStartTimestamp();
    debug_query_string = sql;
    pgstat_report_activity(STATE_RUNNING, sql);

    StartTransactionCommand();

    if (StatementTimeout > 0)
        enable_timeout_after(STATEMENT_TIMEOUT, StatementTimeout);
    else
        disable_timeout(STATEMENT_TIMEOUT, false);

    SetUserIdAndSecContext(fdata->current_user_id, fdata->sec_context);

    execute_sql_string(sql);

    disable_timeout(STATEMENT_TIMEOUT, false);
    CommitTransactionCommand();

    /* In PG15+, notifies are handled differently; keep legacy call only < 15 */
#if PG_VERSION_NUM < 150000
    ProcessCompletedNotifies();
#endif

    pgstat_report_activity(STATE_IDLE, sql);
    pgstat_report_stat(true);

    ReadyForQuery(DestRemote);
}

/* Type binary recv check */
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

/* Execute SQL string */
static void
execute_sql_string(const char *sql)
{
    List       *raw_parsetree_list;
    ListCell   *lc1;
    bool        isTopLevel;
    int         commands_remaining;
    MemoryContext parsecontext;
    MemoryContext oldcontext;

    parsecontext = AllocSetContextCreate(TopMemoryContext,
                                         "pg_background parse/plan",
                                         ALLOCSET_DEFAULT_MINSIZE,
                                         ALLOCSET_DEFAULT_INITSIZE,
                                         ALLOCSET_DEFAULT_MAXSIZE);

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
            CommandTag  commandTag;
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

            BeginCommand(commandTag, DestNone);

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

            EndCommand(&qc, DestRemote, false);

            PortalDrop(portal, false);
        }

        CommandCounterIncrement();
    }
    PG_CATCH();
    {
        /* Clean up memory context before re-throwing */
        MemoryContextDelete(parsecontext);
        PG_RE_THROW();
    }
    PG_END_TRY();

    /* Normal path: clean up memory context */
    MemoryContextDelete(parsecontext);
}

/* SIGTERM handling */
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
