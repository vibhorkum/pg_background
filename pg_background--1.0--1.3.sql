
-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION pg_background UPDATE TO '1.3'" to load this file. \quit
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
