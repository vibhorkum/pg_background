/*--------------------------------------------------------------------------
 *
 * pg_background.c
 *		Run SQL commands using a background worker.
 *
 * Copyright (C) 2014, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *		contrib/pg_background/pg_background.c
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
#include "storage/latch.h"
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
#include "utils/timestamp.h"
#include "utils/timeout.h"

#include <signal.h>

#ifdef WIN32
#include "windows/pg_background_win.h"
#endif	/* WIN32 */

#include "pg_background.h"

/* -------------------------------------------------------------------------
 * Guardrails (Recommendation #5)
 * ------------------------------------------------------------------------- */
#define PG_BACKGROUND_MAX_SQL_LEN    (4 * 1024 * 1024)   /* 4MB */
#define PG_BACKGROUND_MAX_QUEUE_SIZE (16 * 1024 * 1024)  /* 16MB */

/* Table-of-contents constants for our dynamic shared memory segment. */
#define PG_BACKGROUND_MAGIC				0x50674267
#define PG_BACKGROUND_KEY_FIXED_DATA	0
#define PG_BACKGROUND_KEY_SQL			1
#define PG_BACKGROUND_KEY_GUC			2
#define PG_BACKGROUND_KEY_QUEUE			3
#define PG_BACKGROUND_NKEYS				4

/* Fixed-size data passed via our dynamic shared memory segment. */
typedef struct pg_background_fixed_data
{
	Oid			database_id;
	Oid			authenticated_user_id;
	Oid			current_user_id;
	int			sec_context;
	NameData	database;
	NameData	authenticated_user;

	/* v2 identity token (cookie) */
	uint64		cookie;
} pg_background_fixed_data;

/* Private state maintained by the launching backend for IPC. */
typedef struct pg_background_worker_info
{
	pid_t		pid;
	Oid			current_user_id;
	uint64		cookie;

	dsm_segment *seg;
	BackgroundWorkerHandle *handle;
	shm_mq_handle *responseq;

	bool		consumed;

	/* bookkeeping for pin/unpin safety */
	bool		mapping_pinned;

	/* Recommendation #2 (status) */
	TimestampTz	started_at;
	TimestampTz	last_msg_at;

	/* local view of lifecycle */
	bool		detached;
} pg_background_worker_info;

/* Private state maintained across calls to pg_background_result. */
typedef struct pg_background_result_state
{
	pg_background_worker_info *info;
	FmgrInfo   *receive_functions;
	Oid		   *typioparams;
	bool		has_row_description;
	List	   *command_tags;
	bool		complete;
} pg_background_result_state;

static HTAB *worker_hash;

/* --- internal helpers --- */
static void cleanup_worker_info(dsm_segment *seg, Datum pid_datum);
static pg_background_worker_info *find_worker_info(pid_t pid);
static void check_rights(pg_background_worker_info *info);
static void save_worker_info(pid_t pid, uint64 cookie, dsm_segment *seg,
							 BackgroundWorkerHandle *handle,
							 shm_mq_handle *responseq);
static void pg_background_error_callback(void *arg);

static HeapTuple form_result_tuple(pg_background_result_state *state,
								   TupleDesc tupdesc, StringInfo msg);

static void handle_sigterm(SIGNAL_ARGS);
static void execute_sql_string(const char *sql);
static bool exists_binary_recv_fn(Oid type);

static void throw_untranslated_error(ErrorData translated_edata);

/* shared internal launcher */
static void launch_internal(text *sql, int32 queue_size, uint64 cookie,
							pid_t *out_pid);

/* v2 cookie helper */
static inline uint64 pg_background_make_cookie(void);

/* Recommendation #3: cleanup on backend exit */
static void pg_background_on_exit(int code, Datum arg);

/* Recommendation #1 / #4 / #2: wait/status/cancel helpers */
static void pgbg_validate_v2(pg_background_worker_info *info, int32 pid, int64 cookie_in);
static int pgbg_worker_state(pg_background_worker_info *info); /* 0 running, 1 complete, -1 unknown */
static void pgbg_send_cancel_signals(pg_background_worker_info *info, int32 grace_ms);

/* -------------------------------------------------------------------------
 * Module magic / init
 * ------------------------------------------------------------------------- */
PG_MODULE_MAGIC;

void _PG_init(void);
void
_PG_init(void)
{
	/* On backend exit, best-effort cleanup of any still-attached workers */
	before_shmem_exit(pg_background_on_exit, 0);
}

/* -------------------------------------------------------------------------
 * SQL-callable function declarations
 * ------------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(pg_background_launch);
PG_FUNCTION_INFO_V1(pg_background_result);
PG_FUNCTION_INFO_V1(pg_background_detach);

PG_FUNCTION_INFO_V1(pg_background_launch_v2);
PG_FUNCTION_INFO_V1(pg_background_result_v2);
PG_FUNCTION_INFO_V1(pg_background_detach_v2);

PG_FUNCTION_INFO_V1(pg_background_wait_v2);
PG_FUNCTION_INFO_V1(pg_background_status_v2);

PG_FUNCTION_INFO_V1(pg_background_cancel);
PG_FUNCTION_INFO_V1(pg_background_cancel_v2);

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

/* -------------------------------------------------------------------------
 * Internal launcher (includes NOTIFY race fix: shm_mq_wait_for_attach)
 * ------------------------------------------------------------------------- */
static void
launch_internal(text *sql, int32 queue_size, uint64 cookie, pid_t *out_pid)
{
	int32		sql_len = VARSIZE_ANY_EXHDR(sql);
	Size		guc_len;
	Size		segsize;
	dsm_segment *seg;
	shm_toc_estimator e;
	shm_toc    *toc;
	char	   *sqlp;
	char	   *gucstate;
	shm_mq	   *mq;
	BackgroundWorker worker;
	BackgroundWorkerHandle *worker_handle;
	pg_background_fixed_data *fdata;
	pid_t		pid;
	shm_mq_handle *responseq;
	MemoryContext oldcontext;

	/* Guardrails */
	if (sql_len <= 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("SQL must not be empty")));
	if (sql_len > PG_BACKGROUND_MAX_SQL_LEN)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("SQL is too large (%d bytes), max is %d bytes",
						sql_len, (int) PG_BACKGROUND_MAX_SQL_LEN)));

	if (queue_size < 0 || ((uint64) queue_size) < shm_mq_minimum_size)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("queue size must be at least %zu bytes",
						shm_mq_minimum_size)));
	if ((uint64) queue_size > (uint64) PG_BACKGROUND_MAX_QUEUE_SIZE)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("queue size is too large (%d bytes), max is %d bytes",
						queue_size, (int) PG_BACKGROUND_MAX_QUEUE_SIZE)));

	/* Create DSM + TOC */
	shm_toc_initialize_estimator(&e);
	shm_toc_estimate_chunk(&e, sizeof(pg_background_fixed_data));
	shm_toc_estimate_chunk(&e, (Size) sql_len + 1);
	guc_len = EstimateGUCStateSpace();
	shm_toc_estimate_chunk(&e, guc_len);
	shm_toc_estimate_chunk(&e, (Size) queue_size);
	shm_toc_estimate_keys(&e, PG_BACKGROUND_NKEYS);
	segsize = shm_toc_estimate(&e);

	seg = dsm_create(segsize, 0);
	toc = shm_toc_create(PG_BACKGROUND_MAGIC, dsm_segment_address(seg), segsize);

	/* fixed data */
	fdata = shm_toc_allocate(toc, sizeof(pg_background_fixed_data));
	fdata->database_id = MyDatabaseId;
	fdata->authenticated_user_id = GetAuthenticatedUserId();
	GetUserIdAndSecContext(&fdata->current_user_id, &fdata->sec_context);
	namestrcpy(&fdata->database, get_database_name(MyDatabaseId));
	namestrcpy(&fdata->authenticated_user,
			   GetUserNameFromId(fdata->authenticated_user_id, false));
	fdata->cookie = cookie;
	shm_toc_insert(toc, PG_BACKGROUND_KEY_FIXED_DATA, fdata);

	/* SQL */
	sqlp = shm_toc_allocate(toc, (Size) sql_len + 1);
	memcpy(sqlp, VARDATA(sql), sql_len);
	sqlp[sql_len] = '\0';
	shm_toc_insert(toc, PG_BACKGROUND_KEY_SQL, sqlp);

	/* GUC */
	gucstate = shm_toc_allocate(toc, guc_len);
	SerializeGUCState(guc_len, gucstate);
	shm_toc_insert(toc, PG_BACKGROUND_KEY_GUC, gucstate);

	/* MQ */
	mq = shm_mq_create(shm_toc_allocate(toc, (Size) queue_size),
					   (Size) queue_size);
	shm_toc_insert(toc, PG_BACKGROUND_KEY_QUEUE, mq);
	shm_mq_set_receiver(mq, MyProc);

	/* Attach MQ before launch */
	oldcontext = MemoryContextSwitchTo(TopMemoryContext);
	responseq = shm_mq_attach(mq, seg, NULL);
	MemoryContextSwitchTo(oldcontext);

	/* Configure worker */
	worker.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	worker.bgw_start_time = BgWorkerStart_ConsistentState;
	worker.bgw_restart_time = BGW_NEVER_RESTART;
#if PG_VERSION_NUM < 100000
	worker.bgw_main = NULL;
#endif
	snprintf(worker.bgw_library_name, BGW_MAXLEN, "pg_background");
	snprintf(worker.bgw_function_name, BGW_MAXLEN, "pg_background_worker_main");
	snprintf(worker.bgw_name, BGW_MAXLEN, "pg_background by PID %d", MyProcPid);
#if (PG_VERSION_NUM >= 110000)
	snprintf(worker.bgw_type, BGW_MAXLEN, "pg_background");
#endif
	worker.bgw_main_arg = UInt32GetDatum(dsm_segment_handle(seg));
	worker.bgw_notify_pid = MyProcPid;

	/* Register worker (handle must outlive xact) */
	oldcontext = MemoryContextSwitchTo(TopMemoryContext);
	if (!RegisterDynamicBackgroundWorker(&worker, &worker_handle))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_RESOURCES),
				 errmsg("could not register background process"),
				 errhint("You may need to increase max_worker_processes.")));
	MemoryContextSwitchTo(oldcontext);

	shm_mq_set_handle(responseq, worker_handle);

	/* Wait for startup */
	switch (WaitForBackgroundWorkerStartup(worker_handle, &pid))
	{
		case BGWH_STARTED:
		case BGWH_STOPPED:
			break;
		case BGWH_POSTMASTER_DIED:
			pfree(worker_handle);
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_RESOURCES),
					 errmsg("cannot start background processes without postmaster"),
					 errhint("Kill all remaining database processes and restart the database.")));
			break;
		default:
			elog(ERROR, "unexpected bgworker handle status");
	}

	/*
	 * Critical race fix:
	 * Wait until worker has attached as sender before returning to SQL,
	 * so an immediate DETACH can't make the worker miss DSM/MQ.
	 */
	shm_mq_wait_for_attach(responseq);

	/* Save worker info */
	save_worker_info(pid, cookie, seg, worker_handle, responseq);

	/*
	 * Pin mapping so DSM survives transaction boundaries until result/detach.
	 * We'll unpin exactly once later.
	 */
	dsm_pin_mapping(seg);
	{
		pg_background_worker_info *info = find_worker_info(pid);
		if (info)
			info->mapping_pinned = true;
	}

	*out_pid = pid;
}

/* -------------------------------------------------------------------------
 * v1 API
 * ------------------------------------------------------------------------- */
Datum
pg_background_launch(PG_FUNCTION_ARGS)
{
	text   *sql = PG_GETARG_TEXT_PP(0);
	int32   queue_size = PG_GETARG_INT32(1);
	pid_t   pid;

	launch_internal(sql, queue_size, 0 /* cookie unused for v1 */, &pid);
	PG_RETURN_INT32((int32) pid);
}

Datum
pg_background_detach(PG_FUNCTION_ARGS)
{
	int32 pid = PG_GETARG_INT32(0);
	pg_background_worker_info *info = find_worker_info((pid_t) pid);

	if (info == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("PID %d is not attached to this session", pid)));
	check_rights(info);

	info->detached = true;

	/* Unpin if we pinned */
	if (info->seg != NULL && info->mapping_pinned)
	{
		dsm_unpin_mapping(info->seg);
		info->mapping_pinned = false;
	}

	/* Detach DSM (triggers cleanup callback) */
	if (info->seg != NULL)
		dsm_detach(info->seg);

	PG_RETURN_VOID();
}

/* -------------------------------------------------------------------------
 * v2 API (handle + cookie)
 * ------------------------------------------------------------------------- */
Datum
pg_background_launch_v2(PG_FUNCTION_ARGS)
{
	text   *sql = PG_GETARG_TEXT_PP(0);
	int32   queue_size = PG_GETARG_INT32(1);
	pid_t   pid;
	uint64  cookie = pg_background_make_cookie();

	Datum		values[2];
	bool		isnulls[2] = {false, false};
	TupleDesc	tupdesc;
	HeapTuple	tuple;

	launch_internal(sql, queue_size, cookie, &pid);

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

Datum
pg_background_detach_v2(PG_FUNCTION_ARGS)
{
	int32 pid = PG_GETARG_INT32(0);
	int64 cookie_in = PG_GETARG_INT64(1);
	pg_background_worker_info *info = find_worker_info((pid_t) pid);

	if (info == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("PID %d is not attached to this session", pid)));
	check_rights(info);

	pgbg_validate_v2(info, pid, cookie_in);

	/* Detach is fire-and-forget (no cancel). */
	info->detached = true;

	if (info->seg != NULL && info->mapping_pinned)
	{
		dsm_unpin_mapping(info->seg);
		info->mapping_pinned = false;
	}

	if (info->seg != NULL)
		dsm_detach(info->seg);

	PG_RETURN_VOID();
}

/* -------------------------------------------------------------------------
 * Error translation helper
 * ------------------------------------------------------------------------- */
static void
throw_untranslated_error(ErrorData translated_edata)
{
	ErrorData untranslated_edata = translated_edata;

#define UNTRANSLATE(field) \
	if (translated_edata.field != NULL) \
		untranslated_edata.field = pg_client_to_server(translated_edata.field, strlen(translated_edata.field))

#define FREE_UNTRANSLATED(field) \
	if (untranslated_edata.field != NULL && untranslated_edata.field != translated_edata.field) \
		pfree(untranslated_edata.field)

	UNTRANSLATE(message);
	UNTRANSLATE(detail);
	UNTRANSLATE(detail_log);
	UNTRANSLATE(hint);
	UNTRANSLATE(context);

	ThrowErrorData(&untranslated_edata);

	FREE_UNTRANSLATED(message);
	FREE_UNTRANSLATED(detail);
	FREE_UNTRANSLATED(detail_log);
	FREE_UNTRANSLATED(hint);
	FREE_UNTRANSLATED(context);
}

/* -------------------------------------------------------------------------
 * pg_background_result (v1)  + updates last_msg_at
 * ------------------------------------------------------------------------- */
Datum
pg_background_result(PG_FUNCTION_ARGS)
{
	int32		pid = PG_GETARG_INT32(0);
	shm_mq_result res;
	FuncCallContext *funcctx;
	TupleDesc	tupdesc;
	StringInfoData msg;
	pg_background_result_state *state;

	if (SRF_IS_FIRSTCALL())
	{
		MemoryContext oldcontext;
		pg_background_worker_info *info;
		dsm_segment *seg;

		funcctx = SRF_FIRSTCALL_INIT();
		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

		if ((info = find_worker_info((pid_t) pid)) == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_OBJECT),
					 errmsg("PID %d is not attached to this session", pid)));
		check_rights(info);

		if (info->consumed)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_OBJECT),
					 errmsg("results for PID %d have already been consumed", pid)));
		info->consumed = true;

		seg = info->seg;

		/* unpin exactly once */
		if (info->mapping_pinned)
		{
			dsm_unpin_mapping(seg);
			info->mapping_pinned = false;
		}

		if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("function returning record called in context that cannot accept type record"),
					 errhint("Try calling the function in the FROM clause using a column definition list.")));

		funcctx->tuple_desc = BlessTupleDesc(tupdesc);

		state = palloc0(sizeof(pg_background_result_state));
		state->info = info;

		if (funcctx->tuple_desc->natts > 0)
		{
			int natts = funcctx->tuple_desc->natts;
			int i;

			state->receive_functions = palloc(sizeof(FmgrInfo) * natts);
			state->typioparams = palloc(sizeof(Oid) * natts);

			for (i = 0; i < natts; ++i)
			{
				Oid receive_function_id;
				getTypeBinaryInputInfo(TupleDescAttr(funcctx->tuple_desc, i)->atttypid,
									   &receive_function_id,
									   &state->typioparams[i]);
				fmgr_info(receive_function_id, &state->receive_functions[i]);
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
		char		msgtype;
		Size		nbytes;
		void	   *data;

		res = shm_mq_receive(state->info->responseq, &nbytes, &data, false);
		if (res != SHM_MQ_SUCCESS)
			break;

		state->info->last_msg_at = GetCurrentTimestamp();

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

				for (i = 0; i < natts; ++i)
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
				elog(WARNING, "unknown message type: %c (%zu bytes)",
					 msg.data[0], nbytes);
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
			char	   *tag = linitial(state->command_tags);
			Datum		value;
			bool		isnull = false;
			HeapTuple	result;

			state->command_tags = list_delete_first(state->command_tags);
			value = PointerGetDatum(cstring_to_text(tag));
			result = heap_form_tuple(tupdesc, &value, &isnull);
			SRF_RETURN_NEXT(funcctx, HeapTupleGetDatum(result));
		}
	}

	/* done; detach DSM (fires cleanup callback) */
	if (state->info->seg != NULL)
		dsm_detach(state->info->seg);

	SRF_RETURN_DONE(funcctx);
}

/* v2 result: cookie-check then reuse v1 result */
Datum
pg_background_result_v2(PG_FUNCTION_ARGS)
{
	int32 pid = PG_GETARG_INT32(0);
	int64 cookie_in = PG_GETARG_INT64(1);
	pg_background_worker_info *info = find_worker_info((pid_t) pid);

	if (info == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("PID %d is not attached to this session", pid)));
	check_rights(info);
	pgbg_validate_v2(info, pid, cookie_in);

	return pg_background_result(fcinfo);
}

/* -------------------------------------------------------------------------
 * Wait (Recommendation #1)
 *   - does NOT consume result queue
 *   - uses BGW handle state
 * ------------------------------------------------------------------------- */
Datum
pg_background_wait_v2(PG_FUNCTION_ARGS)
{
	int32 pid = PG_GETARG_INT32(0);
	int64 cookie_in = PG_GETARG_INT64(1);
	bool timeout_isnull = PG_ARGISNULL(2);
	int32 timeout_ms = timeout_isnull ? -1 : PG_GETARG_INT32(2);

	pg_background_worker_info *info = find_worker_info((pid_t) pid);
	TimestampTz start_ts;

	if (info == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("PID %d is not attached to this session", pid)));
	check_rights(info);
	pgbg_validate_v2(info, pid, cookie_in);

	start_ts = GetCurrentTimestamp();
	for (;;)
	{
		int st = pgbg_worker_state(info);
		if (st == 1)
			PG_RETURN_BOOL(true);
		if (st < 0)
			PG_RETURN_BOOL(false);

		if (timeout_ms >= 0)
		{
			long elapsed = pgbg_timestamp_diff_ms(start_ts, GetCurrentTimestamp());
			if (elapsed >= (long) timeout_ms)
				PG_RETURN_BOOL(false);
		}

		/* Wait briefly without busy looping */
#ifndef PG_WAIT_EXTENSION
#define PG_WAIT_EXTENSION 0
#endif
		(void) WaitLatch(MyLatch,
						 WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
						 50L /* ms */,
						 PG_WAIT_EXTENSION);
		ResetLatch(MyLatch);
		CHECK_FOR_INTERRUPTS();
	}
}

/* -------------------------------------------------------------------------
 * Status (Recommendation #2)
 * Returns: (pid, state, started_at, last_msg_at)
 * state: running | complete | detached
 * ------------------------------------------------------------------------- */
Datum
pg_background_status_v2(PG_FUNCTION_ARGS)
{
	int32 pid = PG_GETARG_INT32(0);
	int64 cookie_in = PG_GETARG_INT64(1);

	pg_background_worker_info *info = find_worker_info((pid_t) pid);
	Datum values[4];
	bool isnull[4] = {false,false,false,false};
	TupleDesc tupdesc;
	HeapTuple tuple;

	if (info == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("PID %d is not attached to this session", pid)));
	check_rights(info);
	pgbg_validate_v2(info, pid, cookie_in);

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function returning composite called in context that cannot accept it")));

	tupdesc = BlessTupleDesc(tupdesc);

	values[0] = Int32GetDatum(pid);

	if (info->detached)
		values[1] = CStringGetTextDatum("detached");
	else
	{
		int st = pgbg_worker_state(info);
		values[1] = CStringGetTextDatum(st == 1 ? "complete" : "running");
	}

	values[2] = TimestampTzGetDatum(info->started_at);
	values[3] = TimestampTzGetDatum(info->last_msg_at);

	tuple = heap_form_tuple(tupdesc, values, isnull);
	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/* -------------------------------------------------------------------------
 * Cancel (Recommendation #4)
 * - explicit API (detach never cancels)
 * - Unix: SIGINT then SIGTERM if still running after grace_ms
 * ------------------------------------------------------------------------- */
Datum
pg_background_cancel(PG_FUNCTION_ARGS)
{
	int32 pid = PG_GETARG_INT32(0);
	int32 grace_ms = PG_GETARG_INT32(1);

	pg_background_worker_info *info = find_worker_info((pid_t) pid);
	if (info == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("PID %d is not attached to this session", pid)));
	check_rights(info);

	pgbg_send_cancel_signals(info, grace_ms);

	PG_RETURN_VOID();
}

Datum
pg_background_cancel_v2(PG_FUNCTION_ARGS)
{
	int32 pid = PG_GETARG_INT32(0);
	int64 cookie_in = PG_GETARG_INT64(1);
	int32 grace_ms = PG_GETARG_INT32(2);

	pg_background_worker_info *info = find_worker_info((pid_t) pid);
	if (info == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("PID %d is not attached to this session", pid)));
	check_rights(info);
	pgbg_validate_v2(info, pid, cookie_in);

	pgbg_send_cancel_signals(info, grace_ms);

	PG_RETURN_VOID();
}

/* -------------------------------------------------------------------------
 * Tuple builder
 * ------------------------------------------------------------------------- */
static HeapTuple
form_result_tuple(pg_background_result_state *state, TupleDesc tupdesc,
				  StringInfo msg)
{
	int16		natts = pq_getmsgint(msg, 2);
	int16		i;
	Datum	   *values = NULL;
	bool	   *isnull = NULL;
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

	for (i = 0; i < natts; ++i)
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
 * Worker hash / bookkeeping
 * ------------------------------------------------------------------------- */
static void
cleanup_worker_info(dsm_segment *seg, Datum pid_datum)
{
	pid_t pid = DatumGetInt32(pid_datum);
	bool found;
	pg_background_worker_info *info;

	(void) seg;

	if (worker_hash == NULL)
		return;

	info = hash_search(worker_hash, (void *) &pid, HASH_FIND, &found);
	if (!found || info == NULL)
		return;

	if (info->handle != NULL)
		pfree(info->handle);

	hash_search(worker_hash, (void *) &pid, HASH_REMOVE, &found);
}

static pg_background_worker_info *
find_worker_info(pid_t pid)
{
	if (worker_hash == NULL)
		return NULL;
	return hash_search(worker_hash, (void *) &pid, HASH_FIND, NULL);
}

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

static void
save_worker_info(pid_t pid, uint64 cookie, dsm_segment *seg,
				 BackgroundWorkerHandle *handle,
				 shm_mq_handle *responseq)
{
	pg_background_worker_info *info;
	Oid current_user_id;
	int sec_context;

	if (worker_hash == NULL)
	{
		HASHCTL ctl;
		ctl.keysize = sizeof(pid_t);
		ctl.entrysize = sizeof(pg_background_worker_info);
		worker_hash = hash_create("pg_background worker_hash", 8, &ctl,
								  HASH_BLOBS | HASH_ELEM);
	}

	GetUserIdAndSecContext(&current_user_id, &sec_context);

	/* If PID collision in this session (very unlikely), detach old one safely */
	if ((info = find_worker_info(pid)) != NULL)
	{
		if (current_user_id != info->current_user_id)
			ereport(FATAL,
					(errcode(ERRCODE_DUPLICATE_OBJECT),
					 errmsg("background worker with PID \"%d\" already exists", (int) pid)));

		if (info->seg && info->mapping_pinned)
		{
			dsm_unpin_mapping(info->seg);
			info->mapping_pinned = false;
		}
		if (info->seg)
			dsm_detach(info->seg);
	}

	on_dsm_detach(seg, cleanup_worker_info, Int32GetDatum((int32) pid));

	info = hash_search(worker_hash, (void *) &pid, HASH_ENTER, NULL);
	info->pid = pid;
	info->cookie = cookie;
	info->seg = seg;
	info->handle = handle;
	info->current_user_id = current_user_id;
	info->responseq = responseq;
	info->consumed = false;
	info->mapping_pinned = false; /* set true after dsm_pin_mapping */
	info->started_at = GetCurrentTimestamp();
	info->last_msg_at = info->started_at;
	info->detached = false;
}

static void
pg_background_error_callback(void *arg)
{
	pid_t pid = *(pid_t *) arg;
	errcontext("background worker, pid %d", (int) pid);
}

/* -------------------------------------------------------------------------
 * Recommendation #3: cleanup on backend exit
 * ------------------------------------------------------------------------- */
static void
pg_background_on_exit(int code, Datum arg)
{
	HASH_SEQ_STATUS seq;
	pid_t *pids = NULL;
	int count = 0;
	int cap = 0;

	(void) code;
	(void) arg;

	if (worker_hash == NULL)
		return;

	/* First pass: collect pids (avoid modifying hash during scan) */
	hash_seq_init(&seq, worker_hash);
	for (;;)
	{
		pg_background_worker_info *info = hash_seq_search(&seq);
		if (info == NULL)
			break;

		if (cap == count)
		{
			cap = (cap == 0) ? 16 : cap * 2;
			pids = (pid_t *) repalloc(pids, cap * sizeof(pid_t));
		}
		pids[count++] = info->pid;
	}

	/* Second pass: detach each safely */
	for (int i = 0; i < count; i++)
	{
		pg_background_worker_info *info = find_worker_info(pids[i]);
		if (info == NULL)
			continue;

		if (info->seg && info->mapping_pinned)
		{
			dsm_unpin_mapping(info->seg);
			info->mapping_pinned = false;
		}
		if (info->seg)
			dsm_detach(info->seg); /* triggers cleanup_worker_info */
	}

	if (pids)
		pfree(pids);
}

/* -------------------------------------------------------------------------
 * v2 validators / state helpers
 * ------------------------------------------------------------------------- */
static void
pgbg_validate_v2(pg_background_worker_info *info, int32 pid, int64 cookie_in)
{
	if (info->cookie != (uint64) cookie_in)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("PID %d is not attached to this session (cookie mismatch)", pid)));
}

static int
pgbg_worker_state(pg_background_worker_info *info)
{
	pid_t tmp;

	if (info == NULL || info->handle == NULL)
		return -1;

	switch (GetBackgroundWorkerPid(info->handle, &tmp))
	{
		case BGWH_STARTED:
			return 0;
		case BGWH_STOPPED:
			return 1;
		case BGWH_POSTMASTER_DIED:
			return -1;
		default:
			return -1;
	}
}

static void
pgbg_send_cancel_signals(pg_background_worker_info *info, int32 grace_ms)
{
    	pid_t           wpid;
    	BgwHandleStatus hs;
    	TimestampTz     start_ts;
    	long            elapsed_ms;

	/* clamp */
	if (grace_ms < 0)
		grace_ms = 0;
	if (grace_ms > 60000)
		grace_ms = 60000;

	/* best effort: get OS pid */
	// pid_t wpid;
	// BgwHandleStatus hs = GetBackgroundWorkerPid(info->handle, &wpid);
	hs = GetBackgroundWorkerPid(info->handle, &wpid);

	if (hs != BGWH_STARTED || wpid <= 0)
		return;

#ifdef WIN32
	/*
	 * On Windows, use TerminateBackgroundWorker as best effort.
	 * (No SIGINT equivalent.)
	 */
	TerminateBackgroundWorker(info->handle);
	return;
#else
	/* First: query-cancel-ish */
	(void) kill(wpid, SIGINT);

	/* Wait up to grace_ms for stop */
	//TimestampTz start = GetCurrentTimestamp();
	start_ts = GetCurrentTimestamp();
	for (;;)
	{
		if (GetBackgroundWorkerPid(info->handle, &wpid) != BGWH_STARTED)
			return;

		//long elapsed = pgbg_timestamp_diff_ms(start, GetCurrentTimestamp());
		//if (elapsed >= (long) grace_ms)
               elapsed_ms = pgbg_timestamp_diff_ms(start_ts, GetCurrentTimestamp());
               if (elapsed_ms >= (long) grace_ms)
			break;

		pg_usleep(10 * 1000L); /* 10ms */
		CHECK_FOR_INTERRUPTS();
	}

	/* Escalate */
	(void) kill(wpid, SIGTERM);
#endif
}

/* -------------------------------------------------------------------------
 * Worker entrypoint
 * ------------------------------------------------------------------------- */
void
pg_background_worker_main(Datum main_arg)
{
	dsm_segment *seg;
	shm_toc    *toc;
	pg_background_fixed_data *fdata;
	char	   *sql;
	char	   *gucstate;
	shm_mq	   *mq;
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

	shm_mq_set_sender(mq, MyProc);
	responseq = shm_mq_attach(mq, seg, NULL);

	/* Redirect protocol messages to responseq. */
	pq_redirect_to_shm_mq(seg, responseq);

	BackgroundWorkerInitializeConnection(NameStr(fdata->database),
										 NameStr(fdata->authenticated_user)
#if PG_VERSION_NUM >= 110000
										 , BGWORKER_BYPASS_ALLOWCONN
#endif
										);

	if (fdata->database_id != MyDatabaseId ||
		fdata->authenticated_user_id != GetAuthenticatedUserId())
		ereport(ERROR,
				(errmsg("user or database renamed during pg_background startup")));

	StartTransactionCommand();
	RestoreGUCState(gucstate);
	CommitTransactionCommand();

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

#if PG_VERSION_NUM < 150000
	ProcessCompletedNotifies();
#endif

	pgstat_report_activity(STATE_IDLE, sql);
	pgstat_report_stat(true);

	ReadyForQuery(DestRemote);
}

/* -------------------------------------------------------------------------
 * Minor helpers
 * ------------------------------------------------------------------------- */
static bool
exists_binary_recv_fn(Oid type)
{
	HeapTuple	typeTuple;
	Form_pg_type pt;
	bool		exists_rev_fn;

	typeTuple = SearchSysCache1(TYPEOID, ObjectIdGetDatum(type));
	if (!HeapTupleIsValid(typeTuple))
		elog(ERROR, "cache lookup failed for type %u", type);

	pt = (Form_pg_type) GETSTRUCT(typeTuple);
	exists_rev_fn = OidIsValid(pt->typreceive);
	ReleaseSysCache(typeTuple);

	return exists_rev_fn;
}

static void
execute_sql_string(const char *sql)
{
	List	   *raw_parsetree_list;
	ListCell   *lc1;
	bool		isTopLevel;
	int			commands_remaining;
	MemoryContext parsecontext;
	MemoryContext oldcontext;

	parsecontext = AllocSetContextCreate(TopMemoryContext,
										 "pg_background parse/plan",
										 ALLOCSET_DEFAULT_MINSIZE,
										 ALLOCSET_DEFAULT_INITSIZE,
										 ALLOCSET_DEFAULT_MAXSIZE);
	oldcontext = MemoryContextSwitchTo(parsecontext);
	raw_parsetree_list = pg_parse_query(sql);
	commands_remaining = list_length(raw_parsetree_list);
	isTopLevel = commands_remaining == 1;
	MemoryContextSwitchTo(oldcontext);

	foreach(lc1, raw_parsetree_list)
	{
#if PG_VERSION_NUM < 100000
		Node	   *parsetree = (Node *) lfirst(lc1);
#else
		RawStmt    *parsetree = (RawStmt *) lfirst(lc1);
#endif
#if PG_VERSION_NUM >= 130000
		CommandTag	commandTag;
#else
		const char *commandTag;
#endif
#if PG_VERSION_NUM < 130000
		char		completionTag[COMPLETION_TAG_BUFSIZE];
#else
		QueryCompletion qc;
#endif
		List	   *querytree_list,
				   *plantree_list;
		bool		snapshot_set = false;
		Portal		portal;
		DestReceiver *receiver;
		int16		format = 1;

		if (IsA(parsetree, TransactionStmt))
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

		plantree_list = pg_plan_queries(querytree_list,
#if PG_VERSION_NUM >= 130000
										sql,
#endif
										0, NULL);

		if (snapshot_set)
			PopActiveSnapshot();

		CHECK_FOR_INTERRUPTS();

		portal = CreatePortal("", true, true);
		portal->visible = false;
		PortalDefineQuery(portal, NULL, sql, commandTag, plantree_list, NULL);
		PortalStart(portal, NULL, 0, InvalidSnapshot);
		PortalSetResultFormat(portal, 1, &format);

		--commands_remaining;
		if (commands_remaining > 0)
			receiver = CreateDestReceiver(DestNone);
		else
		{
			receiver = CreateDestReceiver(DestRemote);
			SetRemoteDestReceiverParams(receiver, portal);
		}

		MemoryContextSwitchTo(oldcontext);

#if PG_VERSION_NUM < 100000
		(void) PortalRun(portal, FETCH_ALL, isTopLevel, receiver, receiver, completionTag);
#elif PG_VERSION_NUM < 130000
		(void) PortalRun(portal, FETCH_ALL, isTopLevel, true, receiver, receiver, completionTag);
#elif PG_VERSION_NUM < 180000
		(void) PortalRun(portal, FETCH_ALL, isTopLevel, true, receiver, receiver, &qc);
#else
		(void) PortalRun(portal, FETCH_ALL, isTopLevel, receiver, receiver, &qc);
#endif

		(*receiver->rDestroy) (receiver);

#if PG_VERSION_NUM < 130000
		EndCommand(completionTag, DestRemote);
#else
		EndCommand(&qc, DestRemote, false);
#endif

		PortalDrop(portal, false);
	}

	CommandCounterIncrement();
}

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
