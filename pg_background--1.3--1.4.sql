
-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION pg_background UPDATE TO '1.4'" to load this file. \quit

CREATE OR REPLACE FUNCTION grant_pg_background_privileges(
    user_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
/*
 * Description: Grants the necessary privileges to a role for
 *              using the pg_background extension.
 *
 * Arguments:
 *     user_name: The name of the role to grant privileges to.
 *     print_commands: If TRUE, prints the executed SQL commands.
 *
 * Returns:
 *     TRUE if successful, FALSE otherwise.
 */
BEGIN
    -- Grant execute permissions on pg_background functions
    EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4) TO %I', user_name);
    IF print_commands THEN
      RAISE INFO 'Executed command: GRANT EXECUTE ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4) TO %', user_name;
    END IF;

    EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_result(pg_catalog.int4) TO %I', user_name);
    IF print_commands THEN
      RAISE INFO 'Executed command: GRANT EXECUTE ON FUNCTION pg_background_result(pg_catalog.int4) TO %', user_name;
    END IF;

    EXECUTE format('GRANT EXECUTE ON FUNCTION pg_background_detach(pg_catalog.int4) TO %I', user_name);
    IF print_commands THEN
      RAISE INFO 'Executed command: GRANT EXECUTE ON FUNCTION pg_background_detach(pg_catalog.int4) TO %', user_name;
    END IF;

    RETURN TRUE;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error granting pg_background privileges to %: %', user_name, SQLERRM;
    RETURN FALSE;
END;
$function$;

CREATE OR REPLACE FUNCTION revoke_pg_background_privileges(
    user_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
/*
 * Description: Revokes the privileges previously granted to a role for
 *              using the pg_background extension.
 *
 * Arguments:
 *     user_name: The name of the role to revoke privileges from.
 *     print_commands: If TRUE, prints the executed SQL commands.
 *
 * Returns:
 *     TRUE if successful, FALSE otherwise.
 */
BEGIN
  -- Enclose the main logic in a BEGIN block for exception handling
  BEGIN
    -- Revoke execute permissions on pg_background functions
    EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4) FROM %I', user_name);
    IF print_commands THEN
      RAISE INFO 'Executed command: REVOKE EXECUTE ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4) FROM %', user_name;
    END IF;

    EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_result(pg_catalog.int4) FROM %I', user_name);
    IF print_commands THEN
      RAISE INFO 'Executed command: REVOKE EXECUTE ON FUNCTION pg_background_result(pg_catalog.int4) FROM %', user_name;
    END IF;

    EXECUTE format('REVOKE EXECUTE ON FUNCTION pg_background_detach(pg_catalog.int4) FROM %I', user_name);
    IF print_commands THEN
      RAISE INFO 'Executed command: REVOKE EXECUTE ON FUNCTION pg_background_detach(pg_catalog.int4) FROM %', user_name;
    END IF;

    RETURN TRUE;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error revoking pg_background privileges from %: %', user_name, SQLERRM;
    RETURN FALSE;
  END;
END;
$function$;

REVOKE ALL ON FUNCTION revoke_pg_background_privileges(pg_catalog.text, boolean)
        FROM public;
REVOKE ALL ON FUNCTION grant_pg_background_privileges(pg_catalog.text, boolean)
        FROM public;
REVOKE ALL ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4)
	FROM public;
REVOKE ALL ON FUNCTION pg_background_result(pg_catalog.int4)
	FROM public;
REVOKE ALL ON FUNCTION pg_background_detach(pg_catalog.int4)
	FROM public;
