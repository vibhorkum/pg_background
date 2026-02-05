# pg_background: Production-Grade Async SQL for PostgreSQL

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-12%2B-blue.svg)](https://www.postgresql.org/)
[![License](https://img.shields.io/badge/license-GPL--3.0-green.svg)](LICENSE)

Run arbitrary SQL commands in **background worker processes** within PostgreSQL. Built for asynchronous workflows, autonomous transactions, and long-running operations without blocking your application.

---

## Features

### Core Capabilities
- ✅ **Async SQL Execution**: Offload queries to background workers
- ✅ **Result Retrieval**: Stream results back to the launcher session
- ✅ **Autonomous Transactions**: Commit independently of the calling session
- ✅ **PID Reuse Protection**: Cookie-based handles prevent stale references (v2 API)
- ✅ **Explicit Lifecycle Control**: Cancel, wait, detach, and list operations
- ✅ **Production-Hardened**: NOLOGIN role, privilege helpers, security-definer functions

### v2 API Enhancements (v1.6+)
- **Strong Identity**: `(pid, cookie)` tuples prevent handle confusion
- **Cancel Semantics**: Explicit cancellation (detach ≠ cancel)
- **Wait/Timeout**: Block until completion or timeout
- **Observability**: `pg_background_list_v2()` for monitoring and cleanup
- **Fire-and-Forget**: `submit_v2()` for side-effect queries

---

## Supported PostgreSQL Versions

| Version | Status | Notes |
|---------|--------|-------|
| 18 | ✅ Supported | Portal API compat |
| 17 | ✅ Tested | Full support |
| 16 | ✅ Tested | Recommended |
| 15 | ✅ Tested | ProcessCompletedNotifies removed |
| 14 | ✅ Tested | Full support |
| 13 | ✅ Tested | Full support |
| 12 | ✅ Tested | Minimum version |
| < 12 | ❌ Not supported | Use pg_background 1.4 |

---

## Installation

### Prerequisites
- PostgreSQL 12 or later
- `pg_config` in your `PATH`
- Build tools: `gcc`, `make`

### Build from Source
```bash
git clone https://github.com/vibhorkum/pg_background.git
cd pg_background
make
sudo make install
```

### Enable Extension
```sql
CREATE EXTENSION pg_background;
```

### Verify Installation
```sql
SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_background';
-- Should return: pg_background | 1.6
```

---

## Quick Start

### V2 API (Recommended)

#### 1. Launch a Background Job
```sql
-- Returns (pid int4, cookie int8)
SELECT * FROM pg_background_launch_v2(
  'SELECT pg_sleep(5); SELECT count(*) FROM large_table'
) AS handle;

-- Example output:
  pid  |      cookie       
-------+-------------------
 12345 | 1234567890123456
```

#### 2. Retrieve Results
```sql
-- Use pid and cookie from above
SELECT * FROM pg_background_result_v2(12345, 1234567890123456) AS (count BIGINT);
```

#### 3. Fire-and-Forget
```sql
-- For side-effect queries (no result consumption)
SELECT * FROM pg_background_submit_v2(
  'INSERT INTO audit_log SELECT * FROM staging'
) AS handle;
```

#### 4. Cancel a Running Job
```sql
-- Request cancellation
SELECT pg_background_cancel_v2(pid, cookie);

-- Or with grace period (500ms)
SELECT pg_background_cancel_v2_grace(pid, cookie, 500);
```

#### 5. Wait for Completion
```sql
-- Block until done
SELECT pg_background_wait_v2(pid, cookie);

-- Or with timeout (returns true if completed)
SELECT pg_background_wait_v2_timeout(pid, cookie, 5000);  -- 5 seconds
```

#### 6. List Active Workers
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

---

### V1 API (Legacy)

#### Basic Usage
```sql
-- Launch
SELECT pg_background_launch('VACUUM VERBOSE my_table') AS pid \gset

-- Retrieve results
SELECT * FROM pg_background_result(:pid) AS (result TEXT);

-- Fire-and-forget (detach)
SELECT pg_background_detach(:pid);
```

---

## API Reference

### V2 Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `pg_background_launch_v2(sql, queue_size)` | `pg_background_handle` | Launch worker, return handle |
| `pg_background_submit_v2(sql, queue_size)` | `pg_background_handle` | Fire-and-forget (no result consumption) |
| `pg_background_result_v2(pid, cookie)` | `SETOF record` | Retrieve results (consume once) |
| `pg_background_detach_v2(pid, cookie)` | `void` | Stop tracking (worker continues) |
| `pg_background_cancel_v2(pid, cookie)` | `void` | Request cancellation |
| `pg_background_cancel_v2_grace(pid, cookie, grace_ms)` | `void` | Cancel with grace period |
| `pg_background_wait_v2(pid, cookie)` | `void` | Block until completion |
| `pg_background_wait_v2_timeout(pid, cookie, timeout_ms)` | `bool` | Wait with timeout (returns `true` if done) |
| `pg_background_list_v2()` | `SETOF record` | List known workers |

### V2 Handle Type
```sql
CREATE TYPE public.pg_background_handle AS (
  pid    int4,   -- Process ID
  cookie int8    -- Unique identifier (prevents PID reuse)
);
```

### V1 Functions (Deprecated)

| Function | Returns | Description |
|----------|---------|-------------|
| `pg_background_launch(sql, queue_size)` | `int4` (pid) | Launch worker, return PID |
| `pg_background_result(pid)` | `SETOF record` | Retrieve results |
| `pg_background_detach(pid)` | `void` | Fire-and-forget |

---

## Critical Distinctions

### Cancel vs Detach

| Action | Stops Execution | Prevents Commit | Drops Bookkeeping |
|--------|-----------------|-----------------|-------------------|
| `cancel_v2` | ⚠️ Best-effort | ⚠️ Best-effort | ❌ No |
| `detach_v2` | ❌ No | ❌ No | ✅ Yes |

**Rule of Thumb**:
- Use `cancel` to **stop work**
- Use `detach` to **stop tracking**

### NOTIFY Semantics
Detaching a worker does **NOT** prevent `NOTIFY` or commits:
```sql
-- Worker will notify even after detach
SELECT * FROM pg_background_launch_v2($$SELECT pg_notify('test', 'msg')$$) AS h;
SELECT pg_background_detach_v2(h.pid, h.cookie);
-- Notification may still be delivered!
```

To prevent `NOTIFY`, use `cancel_v2`:
```sql
SELECT pg_background_cancel_v2(h.pid, h.cookie);
```

---

## Security

### Privilege Model

#### 1. Create a Dedicated Role
```sql
-- Extension creates this role automatically:
CREATE ROLE pgbackground_role NOLOGIN INHERIT;
```

#### 2. Grant Privileges
```sql
-- Grant to application role
GRANT pgbackground_role TO app_user;

-- Or use helper function
SELECT grant_pg_background_privileges('app_user', true);
```

#### 3. Revoke Privileges
```sql
REVOKE pgbackground_role FROM app_user;

-- Or use helper function
SELECT revoke_pg_background_privileges('app_user', true);
```

### Security Considerations
- ✅ **No PUBLIC access**: All functions revoked from public by default
- ✅ **SECURITY DEFINER helpers**: Pinned `search_path` prevents hijacking
- ✅ **User-ID checks**: `check_rights()` validates role membership
- ⚠️ **SQL injection**: Avoid dynamic SQL in untrusted input
- ⚠️ **Resource limits**: No per-user quotas (monitor with `list_v2()`)

---

## Use Cases

### 1. Background Maintenance
```sql
-- Run VACUUM without blocking
SELECT * FROM pg_background_launch_v2('VACUUM ANALYZE large_table') AS h;
SELECT pg_background_wait_v2(h.pid, h.cookie);
```

### 2. Autonomous Transactions
```sql
-- Insert audit log independently of main transaction
DO $$
DECLARE h public.pg_background_handle;
BEGIN
  -- Launch background insert
  SELECT * INTO h FROM pg_background_launch_v2(
    'INSERT INTO audit_log VALUES (...)'
  );
  
  -- Main work may ROLLBACK, but audit log commits independently
  PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;
```

### 3. Async Data Pipelines
```sql
-- Process staging data asynchronously
SELECT * FROM pg_background_submit_v2(
  'INSERT INTO facts SELECT * FROM staging WHERE processed = false'
) AS h;

-- Check status later
SELECT * FROM pg_background_list_v2()
WHERE pid = (h).pid AND cookie = (h).cookie;
```

### 4. Parallel Query Simulation
```sql
-- Launch multiple workers
DO $$
DECLARE
  h1 public.pg_background_handle;
  h2 public.pg_background_handle;
BEGIN
  SELECT * INTO h1 FROM pg_background_launch_v2('SELECT count(*) FROM sales');
  SELECT * INTO h2 FROM pg_background_launch_v2('SELECT count(*) FROM orders');
  
  -- Wait for both
  PERFORM pg_background_wait_v2(h1.pid, h1.cookie);
  PERFORM pg_background_wait_v2(h2.pid, h2.cookie);
  
  -- Retrieve results
  PERFORM * FROM pg_background_result_v2(h1.pid, h1.cookie) AS (cnt BIGINT);
  PERFORM * FROM pg_background_result_v2(h2.pid, h2.cookie) AS (cnt BIGINT);
END;
$$;
```

---

## Operational Notes

### Resource Usage

#### max_worker_processes
Background workers count against PostgreSQL's `max_worker_processes` limit:
```sql
-- Check current usage
SELECT count(*) AS active_workers
FROM pg_stat_activity
WHERE backend_type LIKE '%background%';

-- Recommended: Reserve headroom
ALTER SYSTEM SET max_worker_processes = 32;  -- Adjust as needed
SELECT pg_reload_conf();
```

#### Dynamic Shared Memory (DSM)
Each worker uses one DSM segment (default 65536 bytes):
```sql
-- Monitor DSM usage
SELECT * FROM pg_shmem_allocations WHERE name LIKE '%pg_background%';
```

### Performance Tuning

#### Queue Size
Adjust for large result sets:
```sql
-- Small results (default)
SELECT pg_background_launch_v2('SELECT * FROM small_table', 65536);

-- Large results
SELECT pg_background_launch_v2('SELECT * FROM huge_table', 1048576);  -- 1MB
```

#### Statement Timeout
Worker inherits session's `statement_timeout`:
```sql
-- Set timeout before launch
SET statement_timeout = '5min';
SELECT pg_background_launch_v2('slow_query()');
```

---

## Troubleshooting

### Issue: "could not register background process"
**Cause**: `max_worker_processes` limit reached  
**Fix**:
```sql
ALTER SYSTEM SET max_worker_processes = <higher_value>;
SELECT pg_reload_conf();
```

### Issue: "cookie mismatch for PID XXXXX"
**Cause**: Worker restarted or PID reused  
**Fix**: Always use fresh handle from `launch_v2()`; don't hardcode PIDs

### Issue: Worker hangs indefinitely
**Cause**: Lock contention or infinite loop  
**Fix**:
```sql
-- Check locks
SELECT * FROM pg_locks WHERE pid = <worker_pid>;

-- Cancel worker
SELECT pg_background_cancel_v2_grace(<pid>, <cookie>, 5000);
```

### Issue: Results already consumed
**Cause**: `result_v2()` called twice on same handle  
**Fix**: Results can only be retrieved **once**; use `detach_v2()` for fire-and-forget

---

## Design & Internals

### Architecture
```
┌─────────────┐                     ┌──────────────────┐
│ SQL Session │ ─────launch─────▶   │ Postmaster       │
│ (launcher)  │                     │ (fork worker)    │
└─────────────┘                     └──────────────────┘
       │                                       │
       │ DSM handle (pid + cookie)             │
       │                                       ▼
       │                              ┌──────────────────┐
       │◀─────shm_mq (results)────────│ Background Worker│
       │                              │ (isolated proc)  │
       └──────────────────────────────┤ SPI execution    │
                                      └──────────────────┘
```

### Key Components
1. **DSM (Dynamic Shared Memory)**: IPC transport for SQL text + results
2. **shm_mq (Shared Memory Queue)**: Bidirectional message queue
3. **BackgroundWorker API**: Process lifecycle management
4. **SPI (Server Programming Interface)**: Query execution
5. **Portal API**: Parse/plan/execute pipeline
6. **Hash Table**: Per-session worker metadata tracking

### Worker Lifecycle
1. **Launch**: `RegisterDynamicBackgroundWorker()` → DSM setup → `shm_mq_wait_for_attach()`
2. **Execution**: Worker attaches DB → restores GUCs → SPI exec → sends results
3. **Completion**: Worker exits → DSM detach → cleanup callback removes hash entry
4. **Detach**: Launcher unpins mapping → stops tracking (worker continues)
5. **Cancel**: Launcher sets cancel flag → sends SIGTERM → worker checks interrupts

---

## Compatibility & Upgrade Notes

### Upgrading from v1.5 to v1.6
```sql
ALTER EXTENSION pg_background UPDATE TO '1.6';
```

**Changes**:
- ✅ v1 API unchanged (backward compatible)
- ✅ New v2 API functions added
- ✅ `pgbackground_role` created automatically
- ⚠️ No breaking changes

### Upgrading from v1.0-v1.4
```sql
ALTER EXTENSION pg_background UPDATE TO '1.6';
```

**Changes**:
- ⚠️ Multi-hop upgrade (1.0 → 1.4 → 1.6)
- ⚠️ Intermediate versions may have schema changes

---

## Common Pitfalls

### 1. Detach ≠ Cancel
❌ **Wrong**:
```sql
SELECT pg_background_detach_v2(pid, cookie);  -- Worker STILL runs!
```

✅ **Correct**:
```sql
SELECT pg_background_cancel_v2(pid, cookie);  -- Actually stops worker
```

### 2. PID Reuse
❌ **Wrong (v1 API)**:
```sql
SELECT pg_background_launch('...') AS pid \gset
-- ... session lives for weeks ...
SELECT pg_background_result(:pid);  -- May attach to WRONG worker!
```

✅ **Correct (v2 API)**:
```sql
SELECT * FROM pg_background_launch_v2('...') AS h \gset
SELECT pg_background_result_v2(:'h.pid', :'h.cookie');  -- Safe!
```

### 3. Consuming Results Twice
❌ **Wrong**:
```sql
SELECT * FROM pg_background_result_v2(pid, cookie) AS (col TEXT);
SELECT * FROM pg_background_result_v2(pid, cookie) AS (col TEXT);  -- ERROR!
```

✅ **Correct**:
```sql
WITH results AS (
  SELECT * FROM pg_background_result_v2(pid, cookie) AS (col TEXT)
)
SELECT * FROM results;  -- Use CTE to consume once
```

### 4. Blocking the Launcher
❌ **Wrong**:
```sql
-- Blocks until worker finishes (defeats the purpose!)
SELECT * FROM pg_background_result(pg_background_launch('slow_query()')) AS (r TEXT);
```

✅ **Correct**:
```sql
-- Launch asynchronously, poll status later
SELECT * FROM pg_background_launch_v2('slow_query()') AS h \gset

-- Do other work...

-- Check if done
SELECT pg_background_wait_v2_timeout(:'h.pid', :'h.cookie', 100);  -- 100ms timeout
```

---

## Examples

### Monitoring Active Workers
```sql
-- Clean operational view
SELECT
  pid,
  cookie,
  state,
  left(sql_preview, 50) AS sql,
  launched_at,
  (now() - launched_at) AS age,
  consumed
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
)
ORDER BY launched_at DESC;
```

### Bulk Cleanup
```sql
-- Detach all stopped workers
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT *
    FROM pg_background_list_v2()
    AS (
      pid int4, cookie int8, launched_at timestamptz, user_id oid,
      queue_size int4, state text, sql_preview text, last_error text, consumed bool
    )
    WHERE state IN ('stopped', 'canceled')
  LOOP
    PERFORM pg_background_detach_v2(r.pid, r.cookie);
  END LOOP;
END;
$$;
```

### Timeout Handling
```sql
DO $$
DECLARE
  h public.pg_background_handle;
  done bool;
BEGIN
  SELECT * INTO h FROM pg_background_launch_v2('SELECT pg_sleep(10)');
  
  -- Wait up to 2 seconds
  done := pg_background_wait_v2_timeout(h.pid, h.cookie, 2000);
  
  IF NOT done THEN
    RAISE NOTICE 'Worker timed out, cancelling...';
    PERFORM pg_background_cancel_v2_grace(h.pid, h.cookie, 500);
  END IF;
  
  PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;
```

---

## License

GNU General Public License v3.0

---

## Contributing

Contributions welcome! Please:
1. Open an issue for bugs/features
2. Follow PostgreSQL coding style (`pgindent`)
3. Add regression tests to `sql/pg_background.sql`
4. Run `make installcheck` before submitting PR

---

## Authors

- **Vibhor Kumar** (original author)
- **@a-mckinley** (v2 API contributions)
- **@rjuju** (bug fixes)
- **@svorcmar** (Windows support)
- **@egor-rogov** (code review)
- **@RekGRpth** (packaging)
- **@Hiroaki-Kubota** (testing)

---

## Support

- **Issues**: https://github.com/vibhorkum/pg_background/issues
- **Discussions**: https://github.com/vibhorkum/pg_background/discussions
- **Mailing List**: pgsql-general@postgresql.org

---

## Related Projects

- **pg_cron**: Schedule periodic jobs ([GitHub](https://github.com/citusdata/pg_cron))
- **dblink**: Cross-database queries ([PostgreSQL docs](https://www.postgresql.org/docs/current/dblink.html))
- **pgAgent**: Job scheduler ([pgAgent](https://www.pgagent.org/))

---

**Note**: For production deployments, always use the v2 API for cookie-based handle protection and explicit lifecycle control.
