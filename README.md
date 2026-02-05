# pg_background: Run PostgreSQL Commands in Background Workers

This extension allows you to execute arbitrary SQL commands in background worker processes within PostgreSQL (version >= 9.5). It provides a convenient way to offload long-running tasks, perform operations asynchronously, and implement autonomous transactions.

## Features

### Core

* Execute any SQL command in a background worker.
* Retrieve the result of the background command.
* Detach background workers to run independently.
* Enhanced error handling and command result reporting.
* Built-in functions for managing privileges.

### v2 (Operational Control)
- Strong worker identity via `(pid, cookie)` handles
- Explicit cancel semantics (detach ≠ cancel)
- Blocking and timed wait APIs
- List API for observability and cleanup
- Fire-and-forget submit API

### Security
- Hardened privilege model
- Dedicated **NOLOGIN role** for execution privileges
- Helper functions that grant only extension objects (no `public` leakage)

---

## Compatibility

- PostgreSQL **17** is fully supported and tested
- v2 APIs are intended for modern PostgreSQL versions
- v1 APIs remain supported and unchanged
  
## Installation

1. **Prerequisites:**
   * PostgreSQL version >= 12
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
### V1 SQL API:

****pg_background_launch(sql_command TEXT, queue_size INTEGER DEFAULT 65536):****

Executes `sql_command` in a background worker. `queue_size` determines the message queue size (default: 65536). Returns the background worker's process ID.

****pg_background_result(pid INTEGER):****
Retrieves the result of the command executed by the background worker with process ID `pid`.

****pg_background_detach(pid INTEGER):****
Detaches the background worker with process ID `pid`, allowing it to run independently.

### V2 SQL API:

Version 1.6 introduces a new v2 API to address operational and safety concerns:

- PID reuse protection via cookies
- Explicit cancel semantics
- Wait and timeout support
- Worker listing for observability
- Fire-and-forget submit API

#### V2 API Overview

```sql
public.pg_background_handle (
  pid    int4,
  cookie int8
)
```

- pid: background worker process ID
- cookie: unique identifier generated per launch

The cookie ensures that you are controlling **the exact worker instance you launched**, even if PIDs are reused.


## Examples
```sql
-- Run VACUUM in the background
SELECT pg_background_launch('VACUUM VERBOSE public.your_table');

-- Retrieve the result
SELECT * FROM pg_background_result(12345) foo(result TEXT); -- Replace 12345 with the actual pid

-- Run a command and wait for the result
SELECT * FROM pg_background_result(pg_background_launch('SELECT count(*) FROM your_table')) AS foo(count BIGINT);
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

## V2 SQL API (Complete Reference)

****pg_background_launch_v2(sql_command TEXT, queue_size INT DEFAULT 65536)****

Launch work and return a handle

```sql
SELECT pg_background_launch_v2(
  'SELECT pg_sleep(2); SELECT count(*) FROM my_table'
);
```

Use when you need results or lifecycle control.

****pg_background_submit_v2(sql_command TEXT, queue_size INT DEFAULT 65536)****

Fire-and-forget submission.

```sql
SELECT pg_background_submit_v2(
  'INSERT INTO audit_log SELECT * FROM staging_log'
);
```

Designed for side-effect SQL where results are not consumed.

****pg_background_result_v2(pid INT, cookie BIGINT)****

Retrieve results from a v2 worker.

```sql
SELECT *
FROM pg_background_result_v2(12345, 67890)
AS (result TEXT);
```

Results can be consumed only once.

****pg_background_detach_v2(pid INT, cookie BIGINT)****

Detach bookkeeping for a worker.

```sql
SELECT pg_background_detach_v2(pid, cookie);
```

⚠️ Detach does not cancel execution.


****pg_background_cancel_v2(pid INT, cookie BIGINT)****

Request cancellation.

```sql
SELECT pg_background_cancel_v2(pid, cookie);
```

Best-effort cancel; committed work cannot be undone.



****pg_background_cancel_v2_grace(pid INT, cookie BIGINT, grace_ms INT)****

Cancel with a grace period.

```sql
SELECT pg_background_cancel_v2_grace(pid, cookie, 500);
```



****pg_background_wait_v2(pid INT, cookie BIGINT)****

Block until completion.

```sql
SELECT pg_background_wait_v2(pid, cookie);
```

****pg_background_wait_v2_timeout(pid INT, cookie BIGINT, timeout_ms INT) → BOOLEAN****

Wait with timeout.

```sql
SELECT pg_background_wait_v2_timeout(pid, cookie, 2000);
```

Returns true if completed, false otherwise.



****pg_background_list_v2()****

List workers known to the current session.

```sql
SELECT *
FROM pg_background_list_v2()
AS (
  pid int4,
  cookie int8,
  launched_at timestamptz,
  user_id oid,
  queue_size int4,
  state text,
  sql_preview text,
  last_error text,
  consumed bool
);
```

Useful for debugging, monitoring, and cleanup.


### Cancel vs Detach (Critical Distinction)

| Action | Stops execution | Prevents commit | Drops bookkeeping |
|--------|-----------------|-----------------|-------------------|
| detach | ❌ No           | ❌ No           | ✅ Yes            |
| cancel | ⚠️ Best-effort	 | ⚠️ Best-effort	 | ❌ No             |

Rule of thumb:

- Use cancel to stop work
- Use detach to stop tracking

### Decision Guide

| You want to… | Use this |
|--------------|----------|
| Run SQL and get results |	launch_v2 + result_v2 |
| Run SQL asynchronously, no results |	submit_v2 |
| Wait until work completes | 	wait_v2 / wait_v2_timeout |
| Stop a running worker |	cancel_v2 / cancel_v2_grace |
| Stop tracking a worker |	detach_v2 |
| See what’s running |	list_v2 |

## NOTIFY Semantics (Detach ≠ Cancel)

Detaching a worker does not prevent NOTIFY:
```sql
LISTEN test;

DO $$
DECLARE pid int;
BEGIN
  pid := pg_background_launch($$SELECT pg_notify('test','fail')$$);
  PERFORM pg_background_detach(pid);

  pid := pg_background_launch($$SELECT pg_notify('test','succeed')$$);
  PERFORM pg_sleep(1);
  PERFORM pg_background_detach(pid);
END;
$$;
```

Expected behavior:

- Session does not crash
- Notifications may still be delivered

If you need to prevent NOTIFY or commit, use v2 cancel, not detach.

## Privilege Management (Recommended)

### Executor Role

The extension creates a dedicated NOLOGIN role:

```sql
pgbackground_executor
```

Grant it to users or application roles:

```sql
GRANT pgbackground_executor TO app_user;
```

Revoke it:

```sql
REVOKE pgbackground_executor FROM app_user;
```

### Helper Functions

Grant or revoke privileges on extension objects only:

```sql
SELECT grant_pg_background_privileges('pgbackground_executor', true);
SELECT revoke_pg_background_privileges('pgbackground_executor', true);
```

PostgreSQL reserves role names starting with pg_. Avoid such names.

## Use Cases

***Background Tasks:*** Offload long-running tasks like VACUUM, ANALYZE, or CREATE INDEX CONCURRENTLY to background workers.

***Autonomous Transactions:*** Implement autonomous transactions more effectively than with dblink.

***Procedural Languages:*** Execute commands from procedural languages like PL/pgSQL without blocking.
***Async data pipelines***
***PL/pgSQL workflows without blocking***




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

GNU General Public License v3.0

# Author Information
Authors:
* Vibhor Kumar
* @a-mckinley
* @rjuju
* @svorcmar 
* @egor-rogov
* @RekGRpth
* @Hiroaki-Kubota
