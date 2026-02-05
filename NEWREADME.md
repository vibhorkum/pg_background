# pg_background

**Execute PostgreSQL SQL commands in background worker processes**

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-12%E2%80%9318-blue)](https://www.postgresql.org/)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

---

## Overview

`pg_background` is a PostgreSQL extension that enables execution of SQL commands in background worker processes. It provides a robust, production-ready solution for:

- **Async operations**: Run long-running queries without blocking your session
- **Fire-and-forget tasks**: Submit background jobs (VACUUM, data processing) and continue
- **Autonomous transactions**: Better alternative to `dblink` for independent transaction contexts
- **Parallel workloads**: Offload heavy computation to background processes

### Key Features

✅ **Two API Generations**:
- **v1 API**: Simple `launch`/`result`/`detach` (fire-and-forget semantics)
- **v2 API** (1.6+): Cookie-validated handles, explicit `cancel`, `wait`, `list`, and `submit`

✅ **Production-Grade Safety**:
- PID reuse protection via cryptographic cookies
- Explicit cancel semantics (detach ≠ cancel)
- Hardened privilege model with NOLOGIN roles
- NOTIFY race condition fixes

✅ **Operational Control**:
- Blocking and timed waits
- Grace-period termination (SIGTERM → SIGKILL)
- Worker listing for observability and cleanup
- Query preview and error tracking

---

## Compatibility

| PostgreSQL Version | Supported | Notes |
|--------------------|-----------|-------|
| 18                 | ✅ Yes    | Fully tested |
| 17                 | ✅ Yes    | Fully tested |
| 16                 | ✅ Yes    | Fully tested |
| 15                 | ✅ Yes    | Fully tested |
| 14                 | ✅ Yes    | Fully tested |
| 13                 | ✅ Yes    | Fully tested |
| 12                 | ✅ Yes    | Minimum supported |
| 11 and earlier     | ❌ No     | Upgrade required |

**Recommendation**: Use PostgreSQL 14+ for best performance and community support.

---

## Installation

### Prerequisites

- PostgreSQL 12 or later
- `pg_config` in `PATH`
- Development headers (`postgresql-server-dev-XX` on Debian/Ubuntu)

### Build from Source

```bash
git clone https://github.com/vibhorkum/pg_background.git
cd pg_background
make
sudo make install
```

### Enable Extension

```sql
-- As superuser in target database
CREATE EXTENSION pg_background;
```

### Verify Installation

```sql
SELECT extversion FROM pg_extension WHERE extname = 'pg_background';
-- Should show: 1.6
```

---

## Quick Start

### v1 API: Basic Usage

```sql
-- Launch a background query
SELECT pg_background_launch('VACUUM VERBOSE my_table') AS pid \gset

-- Retrieve results
SELECT * FROM pg_background_result(:pid) AS (result TEXT);
```

### v2 API: Recommended for New Code

```sql
-- Launch with cookie-protected handle
SELECT pg_background_launch_v2('SELECT expensive_function()') AS h \gset

-- Wait with timeout (returns true if completed)
SELECT pg_background_wait_v2_timeout((h).pid, (h).cookie, 5000) AS completed;

-- Retrieve results
SELECT * FROM pg_background_result_v2((h).pid, (h).cookie) AS (result TEXT);

-- Always detach when done
SELECT pg_background_detach_v2((h).pid, (h).cookie);
```

### Fire-and-Forget with submit_v2

```sql
-- Submit background job (no result retrieval)
SELECT pg_background_submit_v2('INSERT INTO audit_log SELECT * FROM staging');
```

---

## API Reference

### v1 API (Backward Compatibility)

#### `pg_background_launch(sql TEXT, queue_size INT DEFAULT 65536) → INT`

Launches a background worker and returns its PID.

**Parameters**:
- `sql`: SQL command to execute
- `queue_size`: Shared memory queue size for results (default: 65536 bytes)

**Returns**: Worker process ID

**Example**:
```sql
SELECT pg_background_launch('CREATE INDEX CONCURRENTLY idx_name ON table_name(column)');
```

---

#### `pg_background_result(pid INT) → SETOF RECORD`

Retrieves results from a background worker.

**Parameters**:
- `pid`: Process ID returned by `pg_background_launch`

**Returns**: Set of result rows (must specify column definition)

**Example**:
```sql
SELECT * FROM pg_background_result(12345) AS (count BIGINT);
```

**Important**: Results can only be consumed once.

---

#### `pg_background_detach(pid INT) → VOID`

Detaches from a background worker (fire-and-forget).

**WARNING**: Detach does **NOT** cancel execution. Worker continues running and commits.

**Example**:
```sql
SELECT pg_background_detach(12345);
```

---

### v2 API (Recommended)

#### Type: `pg_background_handle`

Composite type representing a worker identity:
```sql
TYPE pg_background_handle AS (
  pid    INT,
  cookie BIGINT
)
```

The `cookie` provides PID reuse protection.

---

#### `pg_background_launch_v2(sql TEXT, queue_size INT DEFAULT 65536) → pg_background_handle`

Launches a background worker with result retrieval enabled.

**Example**:
```sql
SELECT pg_background_launch_v2('SELECT count(*) FROM large_table');
```

---

#### `pg_background_submit_v2(sql TEXT, queue_size INT DEFAULT 65536) → pg_background_handle`

Launches a background worker in fire-and-forget mode (results disabled).

**Use When**: You don't need query results (DDL, DML, maintenance tasks).

**Example**:
```sql
SELECT pg_background_submit_v2('VACUUM ANALYZE my_table');
```

---

#### `pg_background_result_v2(pid INT, cookie BIGINT) → SETOF RECORD`

Retrieves results from a v2 worker (cookie-validated).

**Example**:
```sql
SELECT * FROM pg_background_result_v2(12345, 67890) AS (result TEXT);
```

---

#### `pg_background_detach_v2(pid INT, cookie BIGINT) → VOID`

Detaches from a v2 worker (stops tracking, but does NOT cancel).

**Example**:
```sql
SELECT pg_background_detach_v2(12345, 67890);
```

---

#### `pg_background_cancel_v2(pid INT, cookie BIGINT) → VOID`

Requests cancellation of a running worker (sends SIGTERM).

**Note**: Best-effort cancellation. Committed work cannot be undone.

**Example**:
```sql
SELECT pg_background_cancel_v2(12345, 67890);
```

---

#### `pg_background_cancel_v2_grace(pid INT, cookie BIGINT, grace_ms INT) → VOID`

Cancels with grace period (SIGTERM → wait → SIGKILL).

**Example**:
```sql
-- Give worker 500ms to clean up before SIGKILL
SELECT pg_background_cancel_v2_grace(12345, 67890, 500);
```

---

#### `pg_background_wait_v2(pid INT, cookie BIGINT) → VOID`

Blocks until worker completes (no timeout).

**Example**:
```sql
SELECT pg_background_wait_v2(12345, 67890);
```

---

#### `pg_background_wait_v2_timeout(pid INT, cookie BIGINT, timeout_ms INT) → BOOLEAN`

Waits for worker completion with timeout.

**Returns**: `true` if worker stopped, `false` if timeout

**Example**:
```sql
-- Wait up to 2 seconds
SELECT pg_background_wait_v2_timeout(12345, 67890, 2000);
```

---

#### `pg_background_list_v2() → SETOF RECORD`

Lists all background workers tracked by the current session.

**Columns**:
```sql
(
  pid          INT,
  cookie       BIGINT,
  launched_at  TIMESTAMPTZ,
  user_id      OID,
  queue_size   INT,
  state        TEXT,           -- 'starting', 'running', 'stopped', 'canceled'
  sql_preview  TEXT,           -- First 120 chars of SQL
  last_error   TEXT,           -- Last error message (if any)
  consumed     BOOL            -- Results already retrieved?
)
```

**Example**:
```sql
SELECT pid, state, sql_preview
FROM pg_background_list_v2() AS (
  pid int4, cookie int8, launched_at timestamptz, user_id oid,
  queue_size int4, state text, sql_preview text, last_error text, consumed bool
)
WHERE state = 'running';
```

---

## Usage Patterns

### Pattern 1: Synchronous Background Execution

```sql
-- Launch and immediately wait for result
SELECT * 
FROM pg_background_result_v2(
  (pg_background_launch_v2('SELECT pg_sleep(5); SELECT 42')).*
) AS (result INT);
```

### Pattern 2: Async with Timeout

```sql
DO $$
DECLARE
  h pg_background_handle;
  completed BOOL;
BEGIN
  -- Launch long-running task
  SELECT * INTO h
  FROM pg_background_launch_v2('SELECT expensive_analytics()');

  -- Wait up to 10 seconds
  completed := pg_background_wait_v2_timeout(h.pid, h.cookie, 10000);

  IF NOT completed THEN
    -- Timeout: cancel and alert
    PERFORM pg_background_cancel_v2(h.pid, h.cookie);
    RAISE NOTICE 'Worker timed out and was cancelled';
  END IF;

  -- Cleanup
  PERFORM pg_background_detach_v2(h.pid, h.cookie);
END $$;
```

### Pattern 3: Cleanup Stopped Workers

```sql
-- Find and detach all stopped workers
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT *
    FROM pg_background_list_v2() AS (
      pid int4, cookie int8, launched_at timestamptz, user_id oid,
      queue_size int4, state text, sql_preview text, last_error text, consumed bool
    )
    WHERE state IN ('stopped', 'canceled')
  LOOP
    PERFORM pg_background_detach_v2(r.pid, r.cookie);
    RAISE NOTICE 'Detached worker pid=% sql=%', r.pid, r.sql_preview;
  END LOOP;
END $$;
```

### Pattern 4: Parallel Batch Processing

```sql
DO $$
DECLARE
  h pg_background_handle;
  handles pg_background_handle[];
  i INT;
BEGIN
  -- Launch 5 parallel workers
  FOR i IN 1..5 LOOP
    SELECT * INTO h
    FROM pg_background_launch_v2(
      format('INSERT INTO partitioned_table SELECT * FROM staging WHERE partition_id = %s', i)
    );
    handles := array_append(handles, h);
  END LOOP;

  -- Wait for all to complete
  FOREACH h IN ARRAY handles LOOP
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
  END LOOP;

  RAISE NOTICE 'All % partitions processed', array_length(handles, 1);
END $$;
```

---

## Security & Privileges

### Hardened Privilege Model

pg_background creates a dedicated **NOLOGIN** role for privilege management:

```sql
-- Role created during extension installation
pgbackground_role  -- NOLOGIN, INHERIT
```

### Grant Privileges

```sql
-- Grant to a user
GRANT pgbackground_role TO app_user;

-- Or use helper function (grants only extension objects, not PUBLIC)
SELECT grant_pg_background_privileges('app_user', true);
```

### Revoke Privileges

```sql
REVOKE pgbackground_role FROM app_user;

-- Or use helper function
SELECT revoke_pg_background_privileges('app_user', true);
```

### Security Best Practices

1. **Never grant to PUBLIC**:
   ```sql
   -- Extension installation already REVOKEs from PUBLIC
   -- DO NOT undo this!
   ```

2. **Use dedicated roles**:
   ```sql
   CREATE ROLE batch_processor NOLOGIN;
   GRANT pgbackground_role TO batch_processor;
   GRANT batch_processor TO actual_user;
   ```

3. **Audit worker launches**:
   ```sql
   -- Monitor who's using background workers
   SELECT user_id::regrole, count(*), array_agg(sql_preview)
   FROM pg_background_list_v2() AS (...)
   GROUP BY user_id;
   ```

---

## Operational Considerations

### Resource Limits

1. **max_worker_processes**: Reserve slots for background workers
   ```sql
   -- In postgresql.conf
   max_worker_processes = 16  -- Default 8; increase if needed
   ```

2. **Shared Memory**: Each worker uses DSM
   ```sql
   -- Monitor DSM usage (PG 13+)
   SELECT * FROM pg_shmem_allocations WHERE name LIKE '%dsm%';
   ```

3. **statement_timeout**: Prevent runaway workers
   ```sql
   -- Set timeout for background SQL
   ALTER ROLE app_user SET statement_timeout = '5min';
   ```

### Monitoring

```sql
-- Active workers by state
SELECT state, count(*)
FROM pg_background_list_v2() AS (...)
GROUP BY state;

-- Long-running workers
SELECT pid, launched_at, age(now(), launched_at) AS runtime, sql_preview
FROM pg_background_list_v2() AS (...)
WHERE state = 'running'
  AND age(now(), launched_at) > interval '5 minutes';
```

### Troubleshooting

#### Worker Fails to Start

```sql
-- Check max_worker_processes
SHOW max_worker_processes;

-- Check current worker count
SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'background worker';
```

**Fix**: Increase `max_worker_processes` in `postgresql.conf` and reload.

#### Results Already Consumed Error

**Cause**: `pg_background_result()` can only be called once per worker.

**Fix**: Don't retrieve results multiple times. Store in temp table if needed:
```sql
CREATE TEMP TABLE results AS
SELECT * FROM pg_background_result(12345) AS (data TEXT);
```

#### Session Crash on Detach

**Cause**: Likely NOTIFY race (fixed in 1.6).

**Fix**: Upgrade to pg_background 1.6+.

#### Worker Doesn't Stop After Detach

**This is expected behavior**. Detach ≠ Cancel.

**Fix**: Use `pg_background_cancel_v2()` to explicitly stop execution.

---

## Limitations & Gotchas

### ❌ Transaction Control Not Allowed

```sql
-- ERROR: transaction control statements not allowed
SELECT pg_background_launch('BEGIN; SELECT 1; COMMIT;');
```

**Workaround**: Workers run in their own transaction context. Use procedural logic if needed.

### ❌ COPY Protocol Not Supported

```sql
-- ERROR: COPY protocol not allowed
SELECT pg_background_launch('COPY table TO STDOUT');
```

**Workaround**: Use `INSERT INTO ... SELECT` instead.

### ⚠️ Detach ≠ Cancel

**Critical Distinction**:

| Action | Stops Execution | Prevents Commit | Drops Tracking |
|--------|-----------------|-----------------|----------------|
| `detach` | ❌ NO | ❌ NO | ✅ YES |
| `cancel` | ⚠️ Best-effort | ⚠️ Best-effort | ❌ NO |

**Example of Common Mistake**:
```sql
-- ❌ WRONG: This does NOT stop the worker!
SELECT pg_background_detach(pid);

-- ✅ CORRECT: Cancel, then detach
SELECT pg_background_cancel_v2(pid, cookie);
SELECT pg_background_detach_v2(pid, cookie);
```

### ⚠️ PID Reuse Risk (v1 API Only)

v1 API uses PID alone (no cookie). On high-throughput systems, PIDs can be reused.

**Mitigation**: Use v2 API for production workloads.

---

## Design & Internals

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  PostgreSQL Session (Launcher)                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ pg_background_launch_v2('SELECT ...')                 │   │
│  └──────────────────────┬───────────────────────────────┘   │
│                         │                                     │
│                         ▼                                     │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ 1. Allocate DSM segment                              │   │
│  │ 2. Serialize: SQL, GUCs, user context                │   │
│  │ 3. Create shm_mq for result streaming                │   │
│  │ 4. Register background worker with postmaster        │   │
│  │ 5. Wait for worker start (shm_mq_wait_for_attach)   │   │
│  │ 6. Store handle in session hash (TopMemoryContext)   │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ DSM + shm_mq
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Background Worker Process                                   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ pg_background_worker_main()                          │   │
│  │ 1. Attach to DSM segment                             │   │
│  │ 2. Connect to database (BackgroundWorkerInitialize)  │   │
│  │ 3. Restore GUC state, user context                   │   │
│  │ 4. Execute SQL (SPI-like via Portal)                 │   │
│  │ 5. Stream results via shm_mq                         │   │
│  │ 6. Commit transaction                                │   │
│  │ 7. Exit (triggers DSM cleanup callback)              │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ Results via shm_mq
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  PostgreSQL Session (Result Retrieval)                       │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ pg_background_result_v2(pid, cookie)                 │   │
│  │ 1. Validate cookie (PID reuse protection)            │   │
│  │ 2. Read from shm_mq (streaming protocol)             │   │
│  │ 3. Parse RowDescription, DataRow, CommandComplete    │   │
│  │ 4. Return tuples to caller                           │   │
│  │ 5. Mark results as consumed                          │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Key Components

1. **DSM (Dynamic Shared Memory)**:
   - Allocated per worker
   - Contains: Fixed data (user, DB), SQL text, GUC state, shm_mq
   - Cleaned up via `on_dsm_detach()` callback

2. **shm_mq (Shared Memory Queue)**:
   - Bidirectional communication (but we only use worker → session)
   - Binary protocol (RowDescription, DataRow, etc.)
   - Fixed-size ring buffer

3. **Session Hash**:
   - `HTAB *worker_hash` keyed by PID
   - Stores: handle, DSM segment, shm_mq handle, cookie, metadata
   - Lives in `TopMemoryContext` (survives transactions)

4. **Cookie Generation**:
   - Timestamp + PID + process pointer XOR
   - Not cryptographically secure, but sufficient for PID disambiguation

5. **Cancellation**:
   - Soft flag: `fdata->cancel_requested` in DSM
   - Hard signal: SIGTERM (grace period) → SIGKILL
   - Worker checks flag before executing SQL

---

## Compatibility & Upgrade Notes

### Upgrading from 1.5 to 1.6

**Breaking Changes**: None

**New Features**:
- v2 API (cookie-validated handles)
- `pg_background_submit_v2()` (fire-and-forget)
- `pg_background_cancel_v2()` (explicit cancel)
- `pg_background_wait_v2*()` (blocking/timeout waits)
- `pg_background_list_v2()` (observability)
- Hardened privilege model

**Upgrade Path**:
```sql
ALTER EXTENSION pg_background UPDATE TO '1.6';
```

**Backward Compatibility**: v1 API unchanged; existing code works without modifications.

---

### Upgrading from 1.0-1.4 to 1.6

Direct upgrade path provided:
```sql
ALTER EXTENSION pg_background UPDATE TO '1.6';
```

**Notable Fixes in 1.6**:
- NOTIFY race condition (caused session crashes)
- Improved error handling
- PID reuse protection (v2 API)

---

## Testing

### Regression Tests

```bash
cd pg_background
make installcheck
```

**Expected Output**: All tests pass (12 tests)

### Manual Smoke Test

```sql
-- Basic launch + result
SELECT * 
FROM pg_background_result(
  pg_background_launch('SELECT 1 AS test')
) AS (test INT);

-- v2 API with handle
DO $$
DECLARE h pg_background_handle;
BEGIN
  SELECT * INTO h FROM pg_background_launch_v2('SELECT 2');
  PERFORM pg_background_detach_v2(h.pid, h.cookie);
END $$;
```

---

## Contributing

Contributions welcome! Please:

1. Open an issue first for discussion
2. Follow PostgreSQL coding conventions
3. Add regression tests for new features
4. Run `make installcheck` before submitting PR

### Code Style

Use `pgindent` for formatting:
```bash
pgindent pg_background.c
```

---

## Support & Resources

- **Issues**: https://github.com/vibhorkum/pg_background/issues
- **PostgreSQL Docs**: https://www.postgresql.org/docs/current/bgworker.html
- **Mailing List**: pgsql-general@postgresql.org

---

## License

GNU General Public License v3.0

See [LICENSE](LICENSE) for full text.

---

## Credits

**Authors**:
- Vibhor Kumar ([@vibhorkum](https://github.com/vibhorkum))
- Contributors: @a-mckinley, @rjuju, @svorcmar, @egor-rogov, @RekGRpth, @Hiroaki-Kubota

**Sponsors**: Community-driven open source project

---

## Changelog

### v1.6 (Current)
- ✨ New v2 API with cookie validation
- ✨ `pg_background_submit_v2()` fire-and-forget
- ✨ `pg_background_cancel_v2()` explicit cancel
- ✨ `pg_background_wait_v2*()` blocking/timeout waits
- ✨ `pg_background_list_v2()` observability
- 🐛 Fixed NOTIFY race condition
- 🔒 Hardened privilege model

### v1.5
- PostgreSQL 15-17 support

### v1.4
- PostgreSQL 14 support

### v1.0-1.3
- Initial releases (PostgreSQL 9.5-13)

---

**Quick Links**:
[Installation](#installation) | [API Reference](#api-reference) | [Security](#security--privileges) | [Troubleshooting](#troubleshooting)
