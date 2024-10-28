# pg_background: Run PostgreSQL Commands in Background Workers

This extension allows you to execute arbitrary SQL commands in background worker processes within PostgreSQL (version >= 9.5). It provides a convenient way to offload long-running tasks, perform operations asynchronously, and implement autonomous transactions.

## Features

* Execute any SQL command in a background worker.
* Retrieve the result of the background command.
* Detach background workers to run independently.
* Enhanced error handling and command result reporting.
* Built-in functions for managing privileges.

## Installation

1. **Prerequisites:**
   * PostgreSQL version >= 9.5
   * Ensure `pg_config` is in your `PATH`

2. **Build and Install:**
   ```bash
   make
   sudo make install
   ```
3. **Enable the Extension:**
   ```bash
    psql -h your_server -p 5432 -d your_database -c "CREATE EXTENSION pg_background;"
   ```

## Usage
### SQL API:

****pg_background_launch(sql_command TEXT, queue_size INTEGER DEFAULT 65536):****

Executes `sql_command` in a background worker. `queue_size` determines the message queue size (default: 65536). Returns the background worker's process ID.

****pg_background_result(pid INTEGER):****
Retrieves the result of the command executed by the background worker with process ID `pid`.

****pg_background_detach(pid INTEGER):****
Detaches the background worker with process ID `pid`, allowing it to run independently.

## Examples
```sql
-- Run VACUUM in the background
SELECT pg_background_launch('VACUUM VERBOSE public.your_table');

-- Retrieve the result
SELECT pg_background_result(12345); -- Replace 12345 with the actual pid

-- Run a command and wait for the result
SELECT pg_background_result(pg_background_launch('SELECT count(*) FROM your_table'));
```

## Privilege Management
For security, grant privileges to a dedicated role:
```SQL
-- Create a role
CREATE ROLE pgbackground_role;

-- Grant privileges using the built-in function
SELECT grant_pg_background_privileges('pgbackground_role', TRUE);

-- Revoke privileges
SELECT revoke_pg_background_privileges('pgbackground_role', TRUE);
```

## Use Cases

***Background Tasks:*** Offload long-running tasks like VACUUM, ANALYZE, or CREATE INDEX CONCURRENTLY to background workers.

***Autonomous Transactions:*** Implement autonomous transactions more effectively than with dblink.

***Procedural Languages:*** Execute commands from procedural languages like PL/pgSQL without blocking.




## More examples:

```sql
SELECT pg_background_launch('vacuum verbose public.sales');
 pg_background_launch 
----------------------
                11088
(1 row)


SELECT * FROM pg_background_result(11088) as (result text);
INFO:  vacuuming "public.sales"
INFO:  index "sales_pkey" now contains 0 row versions in 1 pages
DETAIL:  0 index row versions were removed.
0 index pages have been deleted, 0 are currently reusable.
CPU 0.00s/0.00u sec elapsed 0.00 sec.
INFO:  "sales": found 0 removable, 0 nonremovable row versions in 0 out of 0 pages
DETAIL:  0 dead row versions cannot be removed yet.
There were 0 unused item pointers.
Skipped 0 pages due to buffer pins.
0 pages are entirely empty.
CPU 0.00s/0.00u sec elapsed 0.00 sec.
INFO:  vacuuming "pg_toast.pg_toast_1866942"
INFO:  index "pg_toast_1866942_index" now contains 0 row versions in 1 pages
DETAIL:  0 index row versions were removed.
0 index pages have been deleted, 0 are currently reusable.
CPU 0.00s/0.00u sec elapsed 0.00 sec.
INFO:  "pg_toast_1866942": found 0 removable, 0 nonremovable row versions in 0 out of 0 pages
DETAIL:  0 dead row versions cannot be removed yet.
There were 0 unused item pointers.
Skipped 0 pages due to buffer pins.
0 pages are entirely empty.
CPU 0.00s/0.00u sec elapsed 0.00 sec.
 result    
--------
 VACUUM
(1 row)

```

If user wants to execute the command wait for result, then they can use following example:
```sql
SELECT * FROM pg_background_result(pg_background_launch('vacuum verbose public.sales')) as (result TEXT);
INFO:  vacuuming "public.sales"
INFO:  index "sales_pkey" now contains 0 row versions in 1 pages
DETAIL:  0 index row versions were removed.
0 index pages have been deleted, 0 are currently reusable.
CPU 0.00s/0.00u sec elapsed 0.00 sec.
INFO:  "sales": found 0 removable, 0 nonremovable row versions in 0 out of 0 pages
DETAIL:  0 dead row versions cannot be removed yet.
There were 0 unused item pointers.
Skipped 0 pages due to buffer pins.
0 pages are entirely empty.
CPU 0.00s/0.00u sec elapsed 0.00 sec.
INFO:  vacuuming "pg_toast.pg_toast_1866942"
INFO:  index "pg_toast_1866942_index" now contains 0 row versions in 1 pages
DETAIL:  0 index row versions were removed.
0 index pages have been deleted, 0 are currently reusable.
CPU 0.00s/0.00u sec elapsed 0.00 sec.
INFO:  "pg_toast_1866942": found 0 removable, 0 nonremovable row versions in 0 out of 0 pages
DETAIL:  0 dead row versions cannot be removed yet.
There were 0 unused item pointers.
Skipped 0 pages due to buffer pins.
0 pages are entirely empty.
CPU 0.00s/0.00u sec elapsed 0.00 sec.
 result 
--------
 VACUUM
(1 row)
```

Granting/Revoking permissions
```sql
CREATE ROLE pgbackground_role;
CREATE ROLE

SELECT grant_pg_background_privileges(user_name => 'pgbackground_role', print_commands => true);
INFO:  Executed command: GRANT EXECUTE ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4) TO pgbackground_role
INFO:  Executed command: GRANT EXECUTE ON FUNCTION pg_background_result(pg_catalog.int4) TO pgbackground_role
INFO:  Executed command: GRANT EXECUTE ON FUNCTION pg_background_detach(pg_catalog.int4) TO pgbackground_role
┌────────────────────────────────┐
│ grant_pg_background_privileges │
├────────────────────────────────┤
│ t                              │
└────────────────────────────────┘
(1 row)
```

If you want to revoke permission from a specific role, the following function can be used:
```sql
SELECT revoke_pg_background_privileges(user_name => 'pgbackground_role', print_commands => true);
INFO:  Executed command: REVOKE EXECUTE ON FUNCTION pg_background_launch(pg_catalog.text, pg_catalog.int4) FROM pgbackground_role
INFO:  Executed command: REVOKE EXECUTE ON FUNCTION pg_background_result(pg_catalog.int4) FROM pgbackground_role
INFO:  Executed command: REVOKE EXECUTE ON FUNCTION pg_background_detach(pg_catalog.int4) FROM pgbackground_role
┌─────────────────────────────────┐
│ revoke_pg_background_privileges │
├─────────────────────────────────┤
│ t                               │
└─────────────────────────────────┘
(1 row)
```

## License

BSD

## Author information
Vibhor Kumar
