/*--------------------------------------------------------------------------
 *
 * pg_background_worker.c
 *     Worker-process side of pg_background.
 *
 * The launcher-side machinery (hash table, lifecycle SQL functions,
 * observability) lives in pg_background.c. The code in this file runs in
 * the background worker process: SQL parsing/execution, the structured
 * error-exit path that writes results back to the launcher via DSM and
 * shm_mq, and signal handling. The two halves communicate only through the
 * DSM-backed pg_background_fixed_data and the response shm_mq, never via
 * direct function calls.
 *
 * Copyright (c) 2014-2026, Vibhor Kumar and contributors
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * Licensed under the PostgreSQL License. See LICENSE file for details.
 *
 * -------------------------------------------------------------------------
 */

#include "postgres.h"

#include "fmgr.h"

#include "access/htup_details.h"
#include "access/printtup.h"
#include "access/xact.h"
#include "catalog/pg_type.h"
#include "libpq/libpq.h"
#include "libpq/pqmq.h"
#include "miscadmin.h"
#include "parser/analyze.h"
#include "pgstat.h"
#include "postmaster/bgworker.h"
#include "storage/dsm.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/shm_mq.h"
#include "storage/shm_toc.h"
#include "tcop/pquery.h"
#include "tcop/tcopprot.h"
#include "tcop/utility.h"
#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/ps_status.h"
#include "utils/resowner.h"
#include "utils/snapmgr.h"
#include "utils/syscache.h"
#include "utils/timeout.h"

#include <signal.h>

#ifdef WIN32
#include "windows/pg_background_win.h"
#endif /* WIN32 */

#include "pg_background.h"
#include "pg_background_internal.h"

/* ============================================================================
 * PG VERSION COMPATIBILITY (worker-side query execution)
 * ============================================================================
 *
 * PostgreSQL 18 changed portal APIs:
 * - PortalDefineQuery now takes 7 args (adds CachedPlanSource *)
 * - PortalRun now takes 6 args (removes run_once boolean)
 *
 * These thin wrappers keep the worker body unchanged across PG 14-18.
 */
static inline void
pgbg_portal_define_query_compat(Portal portal,
                                const char *prepStmtName,
                                const char *sourceText,
                                CommandTag_compat commandTag,
                                List *stmts,
                                CachedPlan *cplan)
{
    PortalDefineQuery(portal, prepStmtName, sourceText, commandTag, stmts, cplan);
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

/* ============================================================================
 * FORWARD DECLARATIONS (file-local)
 * ============================================================================
 */

static void pg_background_worker_error_exit(pg_background_fixed_data *fdata);
static void execute_sql_string(const char *sql, pg_background_fixed_data *fdata);
static void handle_sigterm(SIGNAL_ARGS);
/* exists_binary_recv_fn is exported via pg_background_internal.h */

/* ============================================================================
 * BACKGROUND WORKER ERROR-EXIT PATH
 * ============================================================================
 */

/*
 * pg_background_worker_error_exit
 *
 * Common error-path exit shared by both worker PG_CATCH handlers
 * (pre-commit, commit-phase).  Must be called from inside
 * a PG_CATCH block with the current error still on the stack.
 *
 * Copies error data into the DSM fixed block for the launcher, emits the
 * real 'E' frame over shm_mq (so the launcher sees the actual SQLSTATE
 * instead of a synthesized 08006), sends ReadyForQuery, flushes the queue,
 * and calls proc_exit(1).  Never returns.
 *
 * HOLD_INTERRUPTS/RESUME_INTERRUPTS bracket the body so that SIGTERM cannot
 * interrupt pq_flush mid-frame, matching the ParallelWorkerMain pattern.
 */
static void
pg_background_worker_error_exit(pg_background_fixed_data *fdata)
{
    ErrorData  *edata;

    Assert(fdata != NULL);  /* callers guarantee this; crash loudly if violated */

    HOLD_INTERRUPTS();

    /*
     * Switch out of ErrorContext before CopyErrorData — PostgreSQL asserts
     * CurrentMemoryContext != ErrorContext to prevent use-after-free when
     * ErrorContext is reset on the next error.
     */
    MemoryContextSwitchTo(TopMemoryContext);
    edata = CopyErrorData();

    /* Clear result metadata: no rows produced when the worker errors out. */
    fdata->result_row_count = 0;
    fdata->command_tag[0] = '\0';

    if (edata->message != NULL)
        strlcpy(fdata->error_message, edata->message, sizeof(fdata->error_message));
    if (edata->detail != NULL)
        strlcpy(fdata->error_detail, edata->detail, sizeof(fdata->error_detail));
    if (edata->hint != NULL)
        strlcpy(fdata->error_hint, edata->hint, sizeof(fdata->error_hint));
    if (edata->context != NULL)
        strlcpy(fdata->error_context, edata->context, sizeof(fdata->error_context));

    /*
     * Write barrier: ensure all fields above are visible to concurrent
     * readers before we set the publish flag (error_sqlstate).
     */
    pg_write_barrier();
    /* unpack_sql_state() always returns 5 chars + NUL, fits in PGBG_ERROR_SQLSTATE_LEN */
    strlcpy(fdata->error_sqlstate, unpack_sql_state(edata->sqlerrcode),
            sizeof(fdata->error_sqlstate));

    /*
     * Emit the real 'E' frame over shm_mq so the launcher's result state
     * machine sees the actual SQLSTATE.  Nested PG_TRY guards against OOM
     * inside pq_sendstring recursing into this same error path — mirror the
     * ParallelWorkerMain swallow pattern: FlushErrorState and continue.
     * DSM already carries the SQLSTATE so the launcher still gets useful info.
     */
    PG_TRY();
    {
        EmitErrorReport();
    }
    PG_CATCH();
    {
        FlushErrorState();  /* flush any error raised by EmitErrorReport itself */
    }
    PG_END_TRY();

    FreeErrorData(edata);

    /*
     * Two FlushErrorState calls are both required:
     * - The PG_CATCH above flushed any secondary error raised by EmitErrorReport.
     * - This call flushes the *original* worker error, which CopyErrorData() copied
     *   but did not remove from the ErrorContext stack.  Without this, the caller's
     *   PG_END_TRY would observe stale error state.
     */
    FlushErrorState();

    if (IsTransactionState())
        AbortCurrentTransaction();

    /* Mark session idle, send 'Z' to flip state->complete, flush the queue. */
    pgstat_report_activity(STATE_IDLE, NULL);
    ReadyForQuery(DestRemote);
    pq_flush();

    RESUME_INTERRUPTS();

    proc_exit(1);
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

    /*
     * Combined init- and execute-phase PG_TRY.
     *
     * A single PG_TRY covers all pre-commit work: connection init, GUC restore,
     * user/database checks, and SQL execution.  Both init and execute errors
     * produce identical handling — pg_background_worker_error_exit writes the
     * DSM fields, emits the real 'E' frame, and calls proc_exit(1) — so a
     * nested PG_TRY is not needed.  Flattening also avoids
     * -Wshadow=compatible-local warnings that arise when nested PG_TRY blocks
     * expand to the same local variable names.
     *
     * Commit is wrapped in a separate sequential PG_TRY after PG_END_TRY so
     * that a single EmitErrorReport is produced per error with no overlap
     * between the pre-commit and commit catch handlers.
     *
     * PG_TRY starts AFTER pq_redirect_to_shm_mq() so EmitErrorReport can write
     * the 'E' frame into the hijacked pqmq destination. Failures before redirect
     * (dsm_attach, shm_toc_lookup) remain under the standard bgworker handler
     * and degrade the launcher to 08006 — documented acceptable limitation.
     */
    PG_TRY();
    {
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

        /*
         * v1.10 (B6): set a recognizable application_name so the worker is
         * easy to spot in pg_stat_activity and log lines. Format is
         * "pg_background:<label>:<pid>" (or just "pg_background:<pid>" when
         * the caller did not pass a label). RestoreGUCState above could
         * restore the launcher's application_name, so this overrides it.
         */
        {
            char appname[NAMEDATALEN];
            if (fdata->label[0] != '\0')
                snprintf(appname, sizeof(appname),
                         "pg_background:%s:%d", fdata->label, (int) MyProcPid);
            else
                snprintf(appname, sizeof(appname),
                         "pg_background:%d", (int) MyProcPid);
            (void) SetConfigOption("application_name", appname,
                                   PGC_USERSET, PGC_S_OVERRIDE);
        }

        /* If cancel was requested before we began, exit quietly */
        if (*(volatile uint32 *)&fdata->cancel_requested != 0)
        {
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

        execute_sql_string(sql, fdata);

        disable_timeout(STATEMENT_TIMEOUT, false);
    }
    PG_CATCH();
    {
        /*
         * Any pre-commit error — connection init, GUC restore, user/database
         * check, or SQL execution — lands here. All paths call proc_exit(1).
         */
        pg_background_worker_error_exit(fdata);
    }
    PG_END_TRY();

    /*
     * Commit-wrapper PG_TRY (SEQUENTIAL, NOT nested).
     *
     * CommitTransactionCommand() fires deferred constraint triggers and
     * AFTER-triggers, so commit-time errors (23503 deferred FK, 57014 cancel,
     * 23505 deferred unique) surface here. Wrapping commit in its own PG_TRY
     * keeps "exactly one EmitErrorReport per error" invariant — the pre-commit
     * PG_CATCH above already ran PG_END_TRY, so a commit failure here does
     * not double-report via the pre-commit catch.
     */
    PG_TRY();
    {
        CommitTransactionCommand();

        pgstat_report_activity(STATE_IDLE, NULL);
        pgstat_report_stat(true);

        ReadyForQuery(DestRemote);
        pq_flush();
    }
    PG_CATCH();
    {
        /*
         * Commit-phase error: deferred constraints, AFTER triggers, or
         * statement cancel during CommitTransactionCommand.
         */
        pg_background_worker_error_exit(fdata);
    }
    PG_END_TRY();

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

/* ============================================================================
 * SQL EXECUTION (inside the worker process)
 * ============================================================================
 */

/*
 * exists_binary_recv_fn
 *     Check if a type has a binary receive function.
 *
 * Non-static so the launcher's result reader (in pg_background.c) can
 * call it directly. Declared extern in pg_background_internal.h.
 */
bool
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
 *
 * v1.9: Populates fdata->result_row_count and fdata->command_tag
 * with metadata from the final command executed.
 */
static void
execute_sql_string(const char *sql, pg_background_fixed_data *fdata)
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

            /*
             * v1.9: Store result metadata from each command.
             * The final values reflect the last command executed.
             */
            if (fdata != NULL)
            {
                fdata->result_row_count = qc.nprocessed;
                strlcpy(fdata->command_tag, GetCommandTagName(commandTag),
                        sizeof(fdata->command_tag));
            }

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
 *
 * IMPORTANT: We use QueryCancelPending, NOT ProcDiePending.
 *
 * ProcDiePending causes a FATAL error which bypasses PG_CATCH handlers entirely,
 * going directly to proc_exit(). This can cause PostgreSQL's postmaster to
 * interpret the worker exit as a crash, potentially terminating all connections.
 *
 * QueryCancelPending causes an ERROR-level exception (query cancellation) which
 * IS caught by our PG_CATCH handler. The handler then captures error info and
 * calls proc_exit(1) cleanly, which PostgreSQL recognizes as a normal worker exit.
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
        QueryCancelPending = true;
    }

    errno = save_errno;
}
