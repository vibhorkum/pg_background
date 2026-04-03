/*--------------------------------------------------------------------------
 *
 * pg_background_win.h
 *     Windows-specific declarations for pg_background extension.
 *
 * This file provides PGDLLEXPORT declarations required for Windows DLL
 * symbol export. On Unix systems, symbol visibility is handled differently.
 *
 * Copyright (c) 2014-2026, Vibhor Kumar
 *
 * Permission to use, copy, modify, and distribute this software and its
 * documentation for any purpose, without fee, and without a written agreement
 * is hereby granted, provided that the above copyright notice and this
 * paragraph and the following two paragraphs appear in all copies.
 *
 * IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE TO ANY PARTY FOR DIRECT,
 * INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, INCLUDING LOST
 * PROFITS, ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION,
 * EVEN IF THE COPYRIGHT HOLDER HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 *
 * THE COPYRIGHT HOLDER SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT
 * NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS,
 * AND THE COPYRIGHT HOLDER HAS NO OBLIGATIONS TO PROVIDE MAINTENANCE, SUPPORT,
 * UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
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

/* v1.9: Observability and batch operations */
PGDLLEXPORT Datum pg_background_result_info_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_error_info_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_detach_all_v2(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_cancel_all_v2(PG_FUNCTION_ARGS);

/* Worker entry point */
PGDLLEXPORT void pg_background_worker_main(Datum);

#endif /* PG_BACKGROUND_WIN_H */
