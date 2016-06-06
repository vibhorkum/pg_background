
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
