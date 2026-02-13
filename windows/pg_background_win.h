/*--------------------------------------------------------------------------
 *
 * pg_background_win.h
 *     Windows-specific declarations for pg_background extension.
 *
 * This file provides PGDLLEXPORT declarations required for Windows DLL
 * symbol export. On Unix systems, symbol visibility is handled differently.
 *
 * -------------------------------------------------------------------------
 */
#ifndef PG_BACKGROUND_WIN_H
#define PG_BACKGROUND_WIN_H

#include "postgres.h"
#include "fmgr.h"

/* v1 API */
PGDLLEXPORT Datum pg_background_launch(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_result(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_detach(PG_FUNCTION_ARGS);

/* v2 API */
PGDLLEXPORT Datum pg_background_launch_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_submit_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_result_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_detach_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_cancel_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_cancel_v2_grace(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_wait_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_wait_v2_timeout(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_list_v2(PG_FUNCTION_ARGS);

/* Statistics and progress */
PGDLLEXPORT Datum pg_background_stats_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_progress(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_get_progress_v2(PG_FUNCTION_ARGS);

/* Worker entry point */
PGDLLEXPORT void pg_background_worker_main(Datum);

#endif /* PG_BACKGROUND_WIN_H */
