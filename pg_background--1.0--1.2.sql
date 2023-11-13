
-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_background" to load this file. \quit

REVOKE ALL ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4)
	FROM public;
REVOKE ALL ON FUNCTION pg_background_result(pg_catalog.int4)
	FROM public;
REVOKE ALL ON FUNCTION pg_background_detach(pg_catalog.int4)
	FROM public;
