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
 * cancel / wait are now single entrypoints; the separate _grace
 * and _timeout exports are gone.
 */

/* v2 API */
PGDLLEXPORT Datum pg_background_launch(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_submit(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_result(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_detach(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_cancel(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_wait(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_list(PG_FUNCTION_ARGS);

/* Statistics and progress */
PGDLLEXPORT Datum pg_background_stats(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_report_progress(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_get_progress(PG_FUNCTION_ARGS);

/* v1.9: Observability and batch operations */
PGDLLEXPORT Datum pg_background_result_info(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_error_info(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_detach_all(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_cancel_all(PG_FUNCTION_ARGS);

/* v1.10: Full SQL accessor */
PGDLLEXPORT Datum pg_background_full_sql(PG_FUNCTION_ARGS);

/* v2.0 (B5a): private bumper for run timeout accounting */
PGDLLEXPORT Datum pg_background_record_timeout(PG_FUNCTION_ARGS);

/* Worker entry point */
PGDLLEXPORT void pg_background_worker_main(Datum);

#endif /* PG_BACKGROUND_WIN_H */
