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
#include "storage/shm_mq.h"
#include "storage/shm_toc.h"
#include "tcop/pquery.h"
#include "tcop/utility.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/ps_status.h"
#include "utils/snapmgr.h"
#include "utils/timeout.h"
#include "utils/syscache.h"
#include "utils/acl.h"
#ifdef WIN32
#include "windows/pg_background_win.h"
#endif	/* // WIN32 */

#include "pg_background.h"

/*  Define constants for magic numbers */
#define SQL_TERMINATOR_LEN 1

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
}			pg_background_fixed_data;

/* Private state maintained by the launching backend for IPC. */
typedef struct pg_background_worker_info
{
	pid_t		pid;
	Oid			current_user_id;
	dsm_segment *seg;
	BackgroundWorkerHandle *handle;
	shm_mq_handle *responseq;
	bool		consumed;
}			pg_background_worker_info;

/* Private state maintained across calls to pg_background_result. */
typedef struct pg_background_result_state
{
	pg_background_worker_info *info;
	FmgrInfo   *receive_functions;
	Oid		   *typioparams;
	bool		has_row_description;
	List	   *command_tags;
	bool		complete;
}			pg_background_result_state;

static HTAB *worker_hash;

static void cleanup_worker_info(dsm_segment *, Datum pid_datum);
static pg_background_worker_info * find_worker_info(pid_t pid);
static void check_rights(pg_background_worker_info * info);
static void save_worker_info(pid_t pid, dsm_segment *seg,
							 BackgroundWorkerHandle *handle,
							 shm_mq_handle *responseq);
static void pg_background_error_callback(void *arg);

static HeapTuple form_result_tuple(pg_background_result_state * state,
								   TupleDesc tupdesc, StringInfo msg);

static void handle_sigterm(SIGNAL_ARGS);
static void execute_sql_string(const char *sql);
static bool exists_binary_recv_fn(Oid type);

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(pg_background_launch);
PG_FUNCTION_INFO_V1(pg_background_result);
PG_FUNCTION_INFO_V1(pg_background_detach);

PGDLLEXPORT void pg_background_worker_main(Datum);

/*
 * Start a dynamic background worker to run a user-specified SQL command.
 */
Datum
pg_background_launch(PG_FUNCTION_ARGS)
{
	text	   *sql = PG_GETARG_TEXT_PP(0);
	int32		queue_size = PG_GETARG_INT32(1);
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

	/* Ensure a valid queue size. */
	if (queue_size < 0 || ((uint64) queue_size) < shm_mq_minimum_size)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("queue size must be at least %zu bytes",
						shm_mq_minimum_size)));

	/* Create dynamic shared memory and table of contents. */
	shm_toc_initialize_estimator(&e);
	shm_toc_estimate_chunk(&e, sizeof(pg_background_fixed_data));
	shm_toc_estimate_chunk(&e, sql_len + 1);
	guc_len = EstimateGUCStateSpace();
	shm_toc_estimate_chunk(&e, guc_len);
	shm_toc_estimate_chunk(&e, (Size) queue_size);
	shm_toc_estimate_keys(&e, PG_BACKGROUND_NKEYS);
	segsize = shm_toc_estimate(&e);
	seg = dsm_create(segsize, 0);
	toc = shm_toc_create(PG_BACKGROUND_MAGIC, dsm_segment_address(seg),
						 segsize);

	/* Store fixed-size data in dynamic shared memory. */
	fdata = shm_toc_allocate(toc, sizeof(pg_background_fixed_data));
	fdata->database_id = MyDatabaseId;
	fdata->authenticated_user_id = GetAuthenticatedUserId();
	GetUserIdAndSecContext(&fdata->current_user_id, &fdata->sec_context);
	namestrcpy(&fdata->database, get_database_name(MyDatabaseId));
	namestrcpy(&fdata->authenticated_user,
			   GetUserNameFromId(fdata->authenticated_user_id, false));
	shm_toc_insert(toc, PG_BACKGROUND_KEY_FIXED_DATA, fdata);

	/* Store SQL query in dynamic shared memory. */
	sqlp = shm_toc_allocate(toc, sql_len + SQL_TERMINATOR_LEN);
	if (sqlp == NULL)
//Line 171:Added error handling
			ereport(ERROR, (errmsg("Failed to allocate memory for SQL query")));
	memcpy(sqlp, VARDATA(sql), sql_len);
	sqlp[sql_len] = '\0';
	shm_toc_insert(toc, PG_BACKGROUND_KEY_SQL, sqlp);

	/* Store GUC state in dynamic shared memory. */
	gucstate = shm_toc_allocate(toc, guc_len);
	SerializeGUCState(guc_len, gucstate);
	shm_toc_insert(toc, PG_BACKGROUND_KEY_GUC, gucstate);

	/* Establish message queue in dynamic shared memory. */
	mq = shm_mq_create(shm_toc_allocate(toc, (Size) queue_size),
					   (Size) queue_size);
	shm_toc_insert(toc, PG_BACKGROUND_KEY_QUEUE, mq);
	shm_mq_set_receiver(mq, MyProc);

	/*
	 * Attach the queue before launching a worker, so that we'll automatically
	 * detach the queue if we error out.  (Otherwise, the worker might sit
	 * there trying to write the queue long after we've gone away.)
	 */
	oldcontext = MemoryContextSwitchTo(TopMemoryContext);
	responseq = shm_mq_attach(mq, seg, NULL);
	MemoryContextSwitchTo(oldcontext);

	/* Configure a worker. */
	worker.bgw_flags =
		BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	worker.bgw_start_time = BgWorkerStart_ConsistentState;
	worker.bgw_restart_time = BGW_NEVER_RESTART;
#if PG_VERSION_NUM < 100000
	worker.bgw_main = NULL;		/* new worker might not have library loaded */
#endif
	snprintf(worker.bgw_library_name, BGW_MAXLEN, "pg_background");
	snprintf(worker.bgw_function_name, BGW_MAXLEN, "pg_background_worker_main");
	snprintf(worker.bgw_name, BGW_MAXLEN,
			 "pg_background by PID %d", MyProcPid);
#if (PG_VERSION_NUM >= 110000)
	snprintf(worker.bgw_type, BGW_MAXLEN, "pg_background");
#endif
	worker.bgw_main_arg = UInt32GetDatum(dsm_segment_handle(seg));
	/* set bgw_notify_pid, so we can detect if the worker stops */
	worker.bgw_notify_pid = MyProcPid;

	/*
	 * Register the worker.
	 *
	 * We switch contexts so that the background worker handle can outlast
	 * this transaction.
	 */
	oldcontext = MemoryContextSwitchTo(TopMemoryContext);
	if (!RegisterDynamicBackgroundWorker(&worker, &worker_handle))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_RESOURCES),
				 errmsg("could not register background process"),
				 errhint("You may need to increase max_worker_processes.")));
	MemoryContextSwitchTo(oldcontext);
	shm_mq_set_handle(responseq, worker_handle);

	/* Wait for the worker to start. */
	switch (WaitForBackgroundWorkerStartup(worker_handle, &pid))
	{
		case BGWH_STARTED:
			/* Success. */
			break;
		case BGWH_STOPPED:
			/* Success and already done. */
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
			break;
	}

	/* Store the relevant details about this worker for future use. */
	save_worker_info(pid, seg, worker_handle, responseq);

	/*
	 * Now that the worker info is saved, we do not need to, and should not,
	 * automatically detach the segment at resource-owner cleanup time.
	 */
	dsm_pin_mapping(seg);

	/* Return the worker's PID. */
	PG_RETURN_INT32(pid);
}

/*
 * Parts of error messages received from the shared memory queue have already been translated to client encoding.
 * In order to rethrow the error/notice received, we have to translate them back to server encoding.
 * Not all fields are involved : have a look at EVALUATE_MESSAGE macro in elog.c, especially the translateit parameter.
 * It's not an issue to untranslate internal messages (see errdetail_internal in elog.c),
 * since they only use US-ASCII characters, which are common to all characters set : no translation/untranslation occurs in the end.
 */
static void
throw_untranslated_error(ErrorData translated_edata)
{
	ErrorData untranslated_edata = translated_edata;

#define UNTRANSLATE(field) if (translated_edata.field != NULL) { untranslated_edata.field = pg_client_to_server(translated_edata.field, strlen(translated_edata.field)); }
#define FREE_UNTRANSLATED(field) if (untranslated_edata.field != translated_edata.field) { pfree(untranslated_edata.field); }

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

/*
 * Retrieve the results of a background query previously launched in this
 * session.
 */
Datum
pg_background_result(PG_FUNCTION_ARGS)
{
	int32		pid = PG_GETARG_INT32(0);
	shm_mq_result res;
	FuncCallContext *funcctx;
	TupleDesc	tupdesc;
	StringInfoData msg;
	pg_background_result_state *state;

	/* First-time setup. */
	if (SRF_IS_FIRSTCALL())
	{
		MemoryContext oldcontext;
		pg_background_worker_info *info;
		dsm_segment *seg;

		funcctx = SRF_FIRSTCALL_INIT();
		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

		/* See if we have a connection to the specified PID. */
		if ((info = find_worker_info(pid)) == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_OBJECT),
					 errmsg("PID %d is not attached to this session", pid)));
		check_rights(info);

		/* Can't read results twice. */
		if (info->consumed)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_OBJECT),
					 errmsg("results for PID %d have already been consumed", pid)));
		info->consumed = true;

		/*
		 * Whether we succeed or fail, a future invocation of this function
		 * may not try to read from the DSM once we've begun to do so.
		 * Accordingly, make arrangements to clean things up at end of query.
		 */
		seg = info->seg;

		dsm_unpin_mapping(seg);

		/* Set up tuple-descriptor based on colum definition list. */
		if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("function returning record called in context "
							"that cannot accept type record"),
					 errhint("Try calling the function in the FROM clause "
							 "using a column definition list.")));
		funcctx->tuple_desc = BlessTupleDesc(tupdesc);

		/* Cache state that will be needed on every call. */
		state = palloc0(sizeof(pg_background_result_state));
		state->info = info;
		if (funcctx->tuple_desc->natts > 0)
		{
			int			natts = funcctx->tuple_desc->natts;
			int			i;

			state->receive_functions = palloc(sizeof(FmgrInfo) * natts);
			state->typioparams = palloc(sizeof(Oid) * natts);

			for (i = 0; i < natts; ++i)
			{
				Oid			receive_function_id;

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

	/* Initialize message buffer. */
	initStringInfo(&msg);

	/* Read and processes messages from the shared memory queue. */
	for (;;)
	{
		char		msgtype;
		Size		nbytes;
		void	   *data;

		/* Get next message. */
		res = shm_mq_receive(state->info->responseq, &nbytes, &data, false);
		if (res != SHM_MQ_SUCCESS)
			break;

		/*
		 * Message-parsing routines operate on a null-terminated StringInfo,
		 * so we must construct one.
		 */
		resetStringInfo(&msg);
		enlargeStringInfo(&msg, nbytes);
		msg.len = nbytes;
		memcpy(msg.data, data, nbytes);
		msg.data[nbytes] = '\0';
		msgtype = pq_getmsgbyte(&msg);

		/* Dispatch on message type. */
		switch (msgtype)
		{
			case 'E':
			case 'N':
				{
					ErrorData	edata;
					ErrorContextCallback context;

					/* Parse ErrorResponse or NoticeResponse. */
					pq_parse_errornotice(&msg, &edata);

					/*
					 * Limit the maximum error level to ERROR.  We don't want
					 * a FATAL inside the background worker to kill the user
					 * session.
					 */
					if (edata.elevel > ERROR)
						edata.elevel = ERROR;

					/*
					 * Rethrow the error with an appropriate context method.
					 */
					context.callback = pg_background_error_callback;
					context.arg = (void *) &pid;
					context.previous = error_context_stack;
					error_context_stack = &context;
					throw_untranslated_error(edata);
					error_context_stack = context.previous;

					break;
				}
			case 'A':
				{
					/* Propagate NotifyResponse. */
					pq_putmessage(msg.data[0], &msg.data[1], nbytes - 1);
					break;
				}
			case 'T':
				{
					int16		natts = pq_getmsgint(&msg, 2);
					int16		i;

					if (state->has_row_description)
						elog(ERROR, "multiple RowDescription messages");
					state->has_row_description = true;
					if (natts != tupdesc->natts)
						ereport(ERROR,
								(errcode(ERRCODE_DATATYPE_MISMATCH),
								 errmsg("remote query result rowtype does not match "
										"the specified FROM clause rowtype")));

					for (i = 0; i < natts; ++i)
					{
						Oid			type_id;

						(void) pq_getmsgstring(&msg);	/* name */
						(void) pq_getmsgint(&msg, 4);	/* table OID */
						(void) pq_getmsgint(&msg, 2);	/* table attnum */
						type_id = pq_getmsgint(&msg, 4);	/* type OID */
						(void) pq_getmsgint(&msg, 2);	/* type length */
						(void) pq_getmsgint(&msg, 4);	/* typmod */
						(void) pq_getmsgint(&msg, 2);	/* format code */

						if (exists_binary_recv_fn(type_id))
						{
							if (type_id != TupleDescAttr(tupdesc, i)->atttypid)
							{
								ereport(ERROR,
										(errcode(ERRCODE_DATATYPE_MISMATCH),
										 errmsg("remote query result rowtype does not match "
												"the specified FROM clause rowtype")));
							}
						}
						else if (TupleDescAttr(tupdesc, i)->atttypid != TEXTOID)
						{
							ereport(ERROR,
									(errcode(ERRCODE_DATATYPE_MISMATCH),
									 errmsg("remote query result rowtype does not match "
											"the specified FROM clause rowtype"),
									 errhint("use text type instead")));
						}
					}

					pq_getmsgend(&msg);

					break;
				}
			case 'D':
				{
					/* Handle DataRow message. */
					HeapTuple	result;

					result = form_result_tuple(state, tupdesc, &msg);
					SRF_RETURN_NEXT(funcctx, HeapTupleGetDatum(result));
				}
			case 'C':
				{
					/* Handle CommandComplete message. */
					MemoryContext oldcontext;
					const char *tag = pq_getmsgstring(&msg);

					oldcontext =
						MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
					state->command_tags = lappend(state->command_tags,
												  pstrdup(tag));
					MemoryContextSwitchTo(oldcontext);
					break;
				}
			case 'G':
			case 'H':
			case 'W':
				{
					ereport(ERROR,
							(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							 errmsg("COPY protocol not allowed in pg_background")));
					break;
				}
			case 'Z':
				{
					/* Handle ReadyForQuery message. */
					state->complete = true;
					break;
				}
			default:
				elog(WARNING, "unknown message type: %c (%zu bytes)",
					 msg.data[0], nbytes);
				break;
		}
	}

	/* Check whether the connection was broken prematurely. */
	if (!state->complete)
		ereport(ERROR,
				(errcode(ERRCODE_CONNECTION_FAILURE),
				 errmsg("lost connection to worker process with PID %d",
						pid)));

	/* If no data rows, return the command tags instead. */
	if (!state->has_row_description)
	{
		if (tupdesc->natts != 1 || TupleDescAttr(tupdesc, 0)->atttypid != TEXTOID)
		{
			ereport(ERROR,
					(errcode(ERRCODE_DATATYPE_MISMATCH),
					 errmsg("remote query did not return a result set, but "
							"result rowtype is not a single text column")));
		}
		if (state->command_tags != NIL)
		{
			char	   *tag = linitial(state->command_tags);
			Datum		value;
			bool		isnull;
			HeapTuple	result;

			state->command_tags = list_delete_first(state->command_tags);
			value = PointerGetDatum(cstring_to_text(tag));
			isnull = false;
			result = heap_form_tuple(tupdesc, &value, &isnull);
			SRF_RETURN_NEXT(funcctx, HeapTupleGetDatum(result));
		}
	}

	/* We're done! */
	dsm_detach(state->info->seg);
	SRF_RETURN_DONE(funcctx);
}

/*
 * Parse a DataRow message and form a result tuple.
 */
static HeapTuple
form_result_tuple(pg_background_result_state * state, TupleDesc tupdesc,
				  StringInfo msg)
{
	/* Handle DataRow message. */
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
		int32		bytes = pq_getmsgint(msg, 4);

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

/*
 * Detach from the dynamic shared memory segment used for communication with
 * a background worker.  This prevents the worker from stalling waiting for
 * us to read its results.
 */
Datum
pg_background_detach(PG_FUNCTION_ARGS)
{
	int32		pid = PG_GETARG_INT32(0);
	pg_background_worker_info *info;

	info = find_worker_info(pid);
	if (info == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("PID %d is not attached to this session", pid)));
	dsm_detach(info->seg);

	PG_RETURN_VOID();
}

/*
 * When the dynamic shared memory segment associated with a worker is
 * cleaned up, we need to clean up our associated private data structures.
 */
static void
cleanup_worker_info(dsm_segment *seg, Datum pid_datum)
{
	pid_t		pid = DatumGetInt32(pid_datum);
	bool		found;
	pg_background_worker_info *info;

	/* Find any worker info entry for this PID.  If none, we're done. */
	if ((info = find_worker_info(pid)) == NULL)
		return;

	/* Free memory used by the BackgroundWorkerHandle. */
	if (info->handle != NULL)
	{
		pfree(info->handle);
		info->handle = NULL;
	}

	/* Remove the hashtable entry. */
	hash_search(worker_hash, (void *) &pid, HASH_REMOVE, &found);
	if (!found)
		elog(ERROR, "pg_background worker_hash table corrupted");
}

/*
 * Find the background worker information for the worker with a given PID.
 */
static pg_background_worker_info *
find_worker_info(pid_t pid)
{
	pg_background_worker_info *info = NULL;

	if (worker_hash != NULL)
		info = hash_search(worker_hash, (void *) &pid, HASH_FIND, NULL);

	return info;
}

/*
 * Check whether the current user has rights to manipulate the background
 * worker with the given PID.
 */
static void
check_rights(pg_background_worker_info * info)
{
	Oid			current_user_id;
	int			sec_context;

	GetUserIdAndSecContext(&current_user_id, &sec_context);
	if (!has_privs_of_role(current_user_id, info->current_user_id))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("permission denied for background worker with PID \"%d\"",
						info->pid)));
}

/*
 * Save worker information for future IPC.
 */
static void
save_worker_info(pid_t pid, dsm_segment *seg, BackgroundWorkerHandle *handle,
				 shm_mq_handle *responseq)
{
	pg_background_worker_info *info;
	Oid			current_user_id;
	int			sec_context;

	/* If the hash table hasn't been set up yet, do that now. */
	if (worker_hash == NULL)
	{
		HASHCTL		ctl;

		ctl.keysize = sizeof(pid_t);
		ctl.entrysize = sizeof(pg_background_worker_info);
		worker_hash = hash_create("pg_background worker_hash", 8, &ctl,
								  HASH_BLOBS | HASH_ELEM);
	}

	/* Get current authentication information. */
	GetUserIdAndSecContext(&current_user_id, &sec_context);

	/*
	 * In the unlikely event that there's an older worker with this PID, just
	 * detach it - unless it has a different user ID than the currently-active
	 * one, in which case someone might be trying to pull a fast one.  Let's
	 * kill the backend to make sure we don't break anyone's expectations.
	 */
	if ((info = find_worker_info(pid)) != NULL)
	{
		if (current_user_id != info->current_user_id)
			ereport(FATAL,
					(errcode(ERRCODE_DUPLICATE_OBJECT),
					 errmsg("background worker with PID \"%d\" already exists",
							pid)));
		dsm_detach(info->seg);
	}

	/* When the DSM is unmapped, clean everything up. */
	on_dsm_detach(seg, cleanup_worker_info, Int32GetDatum(pid));

	/* Create a new entry for this worker. */
	info = hash_search(worker_hash, (void *) &pid, HASH_ENTER, NULL);
	info->seg = seg;
	info->handle = handle;
	info->current_user_id = current_user_id;
	info->responseq = responseq;
	info->consumed = false;
}

/*
 * Indicate that an error came from a particular background worker.
 */
static void
pg_background_error_callback(void *arg)
{
	pid_t		pid = *(pid_t *) arg;

	errcontext("background worker, pid %d", pid);
}

/*
 * Background worker entrypoint.
 */
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

	/* Establish signal handlers. */
	pqsignal(SIGTERM, handle_sigterm);
	BackgroundWorkerUnblockSignals();

	/* Set up a memory context and resource owner. */
	Assert(CurrentResourceOwner == NULL);
	CurrentResourceOwner = ResourceOwnerCreate(NULL, "pg_background");
	CurrentMemoryContext = AllocSetContextCreate(TopMemoryContext,
												 "pg_background session",
												 ALLOCSET_DEFAULT_MINSIZE,
												 ALLOCSET_DEFAULT_INITSIZE,
												 ALLOCSET_DEFAULT_MAXSIZE);


	/* Connect to the dynamic shared memory segment. */
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

	/* Find data structures in dynamic shared memory. */
	fdata = shm_toc_lookup_compat(toc, PG_BACKGROUND_KEY_FIXED_DATA, false);
	if (fdata == NULL)
//Line 159:Added error handling
			ereport(ERROR, (errmsg("Failed to allocate memory for fixed data")));
	sql = shm_toc_lookup_compat(toc, PG_BACKGROUND_KEY_SQL, false);
	gucstate = shm_toc_lookup_compat(toc, PG_BACKGROUND_KEY_GUC, false);
	mq = shm_toc_lookup_compat(toc, PG_BACKGROUND_KEY_QUEUE, false);

	shm_mq_set_sender(mq, MyProc);
	responseq = shm_mq_attach(mq, seg, NULL);

	/* Redirect protocol messages to responseq. */
	/* pq_redirect_to_shm_mq(mq, responseq); */
	pq_redirect_to_shm_mq(seg, responseq);

	/*
	 * Initialize our user and database ID based on the strings version of the
	 * data, and then go back and check that we actually got the database and
	 * user ID that we intended to get.  We do this because it's not
	 * impossible for the process that started us to die before we get here,
	 * and the user or database could be renamed in the meantime.  We don't
	 * want to latch on the wrong object by accident.  There should probably
	 * be a variant of BackgroundWorkerInitializeConnection that accepts OIDs
	 * rather than strings.
	 */
	BackgroundWorkerInitializeConnection(NameStr(fdata->database),
										 NameStr(fdata->authenticated_user)
#if PG_VERSION_NUM >= 110000
										 ,BGWORKER_BYPASS_ALLOWCONN
#endif
		);

	if (fdata->database_id != MyDatabaseId ||
		fdata->authenticated_user_id != GetAuthenticatedUserId())
		ereport(ERROR,
				(errmsg("user or database renamed during pg_background startup")));

	/* Restore GUC values from launching backend. */
	StartTransactionCommand();
	RestoreGUCState(gucstate);
	CommitTransactionCommand();

	/* Restore user ID and security context. */
	SetUserIdAndSecContext(fdata->current_user_id, fdata->sec_context);

	/* Prepare to execute the query. */
	SetCurrentStatementStartTimestamp();
	debug_query_string = sql;
	pgstat_report_activity(STATE_RUNNING, sql);
	StartTransactionCommand();
	if (StatementTimeout > 0)
		enable_timeout_after(STATEMENT_TIMEOUT, StatementTimeout);
	else
		disable_timeout(STATEMENT_TIMEOUT, false);

	/* Execute the query. */
	execute_sql_string(sql);

	/* Post-execution cleanup. */
	disable_timeout(STATEMENT_TIMEOUT, false);
	CommitTransactionCommand();
#if PG_VERSION_NUM < 150000
	ProcessCompletedNotifies();
#endif
	pgstat_report_activity(STATE_IDLE, sql);
	pgstat_report_stat(true);

	/* Signal that we are done. */
	ReadyForQuery(DestRemote);
}

/*
 * Check binary input function exists for the given type.
 */
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


/*
 * Execute given SQL string.
 *
 * Using SPI here would preclude backgrounding commands like VACUUM which one
 * might very well wish to launch in the background.  So we do this instead.
 */
static void
execute_sql_string(const char *sql)
{
	List	   *raw_parsetree_list;
	ListCell   *lc1;
	bool		isTopLevel;
	int			commands_remaining;
	MemoryContext parsecontext;
	MemoryContext oldcontext;

	/*
	 * Parse the SQL string into a list of raw parse trees.
	 *
	 * Because we allow statements that perform internal transaction control,
	 * we can't do this in TopTransactionContext; the parse trees might get
	 * blown away before we're done executing them.
	 */
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

	/*
	 * Do parse analysis, rule rewrite, planning, and execution for each raw
	 * parsetree.  We must fully execute each query before beginning parse
	 * analysis on the next one, since there may be interdependencies.
	 */
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

		/*
		 * We don't allow transaction-control commands like COMMIT and ABORT
		 * here.  The entire SQL statement is executed as a single transaction
		 * which commits if no errors are encountered.
		 */
		if (IsA(parsetree, TransactionStmt))
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("transaction control statements are not allowed in pg_background")));

		/*
		 * Get the command name for use in status display (it also becomes the
		 * default completion tag, down inside PortalRun).  Set ps_status and
		 * do any special start-of-SQL-command processing needed by the
		 * destination.
		 */
		commandTag = CreateCommandTag_compat(parsetree);
		set_ps_display_compat(GetCommandTagName(commandTag));

		BeginCommand(commandTag, DestNone);

		/* Set up a snapshot if parse analysis/planning will need one. */
		if (analyze_requires_snapshot(parsetree))
		{
			PushActiveSnapshot(GetTransactionSnapshot());
			snapshot_set = true;
		}

		/*
		 * OK to analyze, rewrite, and plan this query.
		 *
		 * As with parsing, we need to make sure this data outlives the
		 * transaction, because of the possibility that the statement might
		 * perform internal transaction control.
		 */
		oldcontext = MemoryContextSwitchTo(parsecontext);
		querytree_list = pg_analyze_and_rewrite_compat(parsetree, sql, NULL, 0,
													   NULL);

		plantree_list = pg_plan_queries(querytree_list,
#if PG_VERSION_NUM >= 130000
										sql,
#endif
										0, NULL);

		/* Done with the snapshot used for parsing/planning */
		if (snapshot_set)
			PopActiveSnapshot();

		/* If we got a cancel signal in analysis or planning, quit */
		CHECK_FOR_INTERRUPTS();

		/*
		 * Execute the query using the unnamed portal.
		 */
		portal = CreatePortal("", true, true);
		/* Don't display the portal in pg_cursors */
		portal->visible = false;
#if PG_VERSION_NUM < 180000
                PortalDefineQuery(portal, NULL, sql, commandTag, plantree_list, NULL);
#else
                PortalDefineQuery(portal, NULL, sql, commandTag, plantree_list, NULL, NULL);
#endif
		PortalStart(portal, NULL, 0, InvalidSnapshot);
		PortalSetResultFormat(portal, 1, &format);	/* binary format */

		/*
		 * Tuples returned by any command other than the last are simply
		 * discarded; but those returned by the last (or only) command are
		 * redirected to the shared memory queue we're using for communication
		 * with the launching backend. If the launching backend is gone or has
		 * detached us, these messages will just get dropped on the floor.
		 */
		--commands_remaining;
		if (commands_remaining > 0)
			receiver = CreateDestReceiver(DestNone);
		else
		{
			receiver = CreateDestReceiver(DestRemote);
			SetRemoteDestReceiverParams(receiver, portal);
		}

		/*
		 * Only once the portal and destreceiver have been established can we
		 * return to the transaction context.  All that stuff needs to survive
		 * an internal commit inside PortalRun!
		 */
		MemoryContextSwitchTo(oldcontext);

		/* Here's where we actually execute the command. */
#if PG_VERSION_NUM < 100000
		(void) PortalRun(portal, FETCH_ALL, isTopLevel, receiver, receiver,
						 completionTag);
#elif PG_VERSION_NUM < 130000
		(void) PortalRun(portal, FETCH_ALL, isTopLevel, true, receiver,
						 receiver, completionTag);
#elif PG_VERSION_NUM < 180000
		(void) PortalRun(portal, FETCH_ALL, isTopLevel, true, receiver,
						 receiver, &qc);
#else
		(void) PortalRun(portal, FETCH_ALL, isTopLevel, receiver,
						 receiver, &qc);

#endif

		/* Clean up the receiver. */
		(*receiver->rDestroy) (receiver);

		/*
		 * Send a CommandComplete message even if we suppressed the query
		 * results.  The user backend will report these in the absence of any
		 * true query results.
		 */
#if PG_VERSION_NUM < 130000
		EndCommand(completionTag, DestRemote);
#else
		EndCommand(&qc, DestRemote, false);
#endif

		/* Clean up the portal. */
		PortalDrop(portal, false);
	}

	/* Be sure to advance the command counter after the last script command */
	CommandCounterIncrement();
}

/*
 * When we receive a SIGTERM, we set InterruptPending and ProcDiePending just
 * like a normal backend.  The next CHECK_FOR_INTERRUPTS() will do the right
 * thing.
 */
static void
handle_sigterm(SIGNAL_ARGS)
{
	int			save_errno = errno;

	if (MyProc)
		SetLatch(&MyProc->procLatch);

	if (!proc_exit_inprogress)
	{
		InterruptPending = true;
		ProcDiePending = true;
	}

	errno = save_errno;
}
