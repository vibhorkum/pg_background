-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_background UPDATE TO '1.1'" to load this file. \quit


CREATE FUNCTION pg_background_discard_result(pid pg_catalog.int4)
    RETURNS void STRICT
	AS 'MODULE_PATHNAME' LANGUAGE C;
