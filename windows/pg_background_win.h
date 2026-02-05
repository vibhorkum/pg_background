#include "postgres.h"
#include "fmgr.h"

/* Add a prototype marked PGDLLEXPORT */
PGDLLEXPORT Datum pg_background_launch(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_result(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum pg_background_detach(PG_FUNCTION_ARGS);
PGDLLEXPORT void pg_background_worker_main(Datum);
