/*--------------------------------------------------------------------------
 *
 * pg_background_win.h
 *     Windows-specific declarations for pg_background extension.
 *
 * This file provides PGDLLEXPORT declarations required for Windows DLL
 * symbol export. On Unix systems, symbol visibility is handled differently.
 *
 * Copyright (c) 2014-2026, Vibhor Kumar and contributors
 *
 * Licensed under the PostgreSQL License. See LICENSE file for details.
 *
 * -------------------------------------------------------------------------
 */
#ifndef PG_BACKGROUND_WIN_H
#define PG_BACKGROUND_WIN_H

#include "postgres.h"
#include "fmgr.h"

/*
 * v2.0: the v1 (no-suffix) API has been dropped.
 * cancel_v2 / wait_v2 are now single entrypoints; the separate _grace
 * and _timeout exports are gone.
 */

/* v2 API */
PGDLLEXPORT Datum pg_background_launch_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_submit_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_result_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_detach_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_cancel_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_wait_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_list_v2(PG_FUNCTION_ARGS);

/* Statistics and progress */
PGDLLEXPORT Datum pg_background_stats_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_report_progress_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_get_progress_v2(PG_FUNCTION_ARGS);

/* v1.9: Observability and batch operations */
PGDLLEXPORT Datum pg_background_result_info_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_error_info_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_detach_all_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_cancel_all_v2(PG_FUNCTION_ARGS);

/* v1.10: Full SQL accessor */
PGDLLEXPORT Datum pg_background_full_sql_v2(PG_FUNCTION_ARGS);

/* v2.0 (B5a): private bumper for run_v2 timeout accounting */
PGDLLEXPORT Datum pg_background_record_timeout_v2(PG_FUNCTION_ARGS);

/* Worker entry point */
PGDLLEXPORT void pg_background_worker_main(Datum);

#endif /* PG_BACKGROUND_WIN_H */
