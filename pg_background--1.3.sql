
-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_background" to load this file. \quit
CREATE FUNCTION pg_background_launch(sql pg_catalog.text,
					   queue_size pg_catalog.int4 DEFAULT 65536)
    RETURNS pg_catalog.int4 STRICT
	AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION pg_background_result(pid pg_catalog.int4)
    RETURNS SETOF pg_catalog.record STRICT
	AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION pg_background_detach(pid pg_catalog.int4)
    RETURNS pg_catalog.void STRICT
	AS 'MODULE_PATHNAME' LANGUAGE C;
REVOKE ALL ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4)
	FROM public;
REVOKE ALL ON FUNCTION pg_background_result(pg_catalog.int4)
	FROM public;
REVOKE ALL ON FUNCTION pg_background_detach(pg_catalog.int4)
	FROM public;
CREATE ROLE pgbackground_role;
GRANT EXECUTE ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4) TO pgbackground_role;
GRANT EXECUTE ON FUNCTION pg_background_result(pg_catalog.int4) TO pgbackground_role;
GRANT EXECUTE ON FUNCTION pg_background_detach(pg_catalog.int4) TO pgbackground_role;
