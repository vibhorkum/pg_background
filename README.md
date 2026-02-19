# pg_background: Production-Grade Background SQL for PostgreSQL

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14--18-blue.svg)](https://www.postgresql.org/)
[![Version](https://img.shields.io/badge/version-1.8-brightgreen.svg)](https://github.com/vibhorkum/pg_background)
[![License](https://img.shields.io/badge/license-PostgreSQL-green.svg)](LICENSE)

Execute arbitrary SQL commands in **background worker processes** within PostgreSQL. Built for production workloads requiring asynchronous execution, autonomous transactions, and long-running operations without blocking client sessions.

---

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [PostgreSQL Version Compatibility](#postgresql-version-compatibility)
- [Installation](#installation)
- [Quick Start](#quick-start)
  - [V2 API (Recommended)](#v2-api-recommended)
  - [V1 API (Legacy)](#v1-api-legacy)
- [Complete API Reference](#complete-api-reference)
  - [V2 Functions](#v2-functions)
  - [V1 Functions (Deprecated)](#v1-functions-deprecated)
- [Critical Semantic Distinctions](#critical-semantic-distinctions)
  - [Cancel vs Detach](#cancel-vs-detach)
  - [V1 vs V2 API](#v1-vs-v2-api)
  - [PID Reuse Protection](#pid-reuse-protection)
  - [NOTIFY and Autonomous Commits](#notify-and-autonomous-commits)
- [Security Model](#security-model)
- [Use Cases with Examples](#use-cases-with-examples)
- [Operational Guidance](#operational-guidance)
  - [Resource Management](#resource-management)
  - [Performance Tuning](#performance-tuning)
  - [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)
- [Architecture & Design](#architecture--design)
- [Known Limitations](#known-limitations)
- [Best Practices](#best-practices)
- [Migration Guide](#migration-guide)
- [Contributing](#contributing)
- [License](#license)
- [Author](#author)

---

## Overview

`pg_background` enables PostgreSQL to execute SQL commands asynchronously in dedicated background worker processes. Unlike `dblink` (which creates a separate connection) or client-side async patterns, `pg_background` workers run **inside** the database server with full access to local resources while operating in **independent transactions**.

**Production-Critical Benefits:**
- **Non-blocking operations**: Launch long-running queries without holding client connections
- **Autonomous transactions**: Commit/rollback independently of the caller's transaction
- **Resource isolation**: Workers have their own memory context and error handling
- **Observable lifecycle**: Track, cancel, and wait for completion with explicit operations
- **Security-hardened**: NOLOGIN role-based access, SECURITY DEFINER helpers, no PUBLIC grants

**Typical Production Use Cases:**
- Background maintenance (VACUUM, ANALYZE, REINDEX)
- Asynchronous audit logging
- Long-running ETL pipelines
- Independent notification delivery
- Parallel query pattern implementation

---

## Key Features

### Core Capabilities
- ✅ **Async SQL Execution**: Offload queries to background workers  
- ✅ **Result Retrieval**: Stream results back via shared memory queues  
- ✅ **Autonomous Transactions**: Commit independently of calling session  
- ✅ **Explicit Lifecycle Control**: Launch, wait, cancel, detach, and list operations  
- ✅ **Production-Hardened Security**: NOLOGIN role, privilege helpers, zero PUBLIC access  

### V2 API Enhancements (v1.6+)
- **Cookie-Based Identity**: `(pid, cookie)` tuples prevent PID reuse confusion
- **Explicit Cancellation**: `cancel_v2()` distinct from `detach_v2()`
- **Synchronous Wait**: `wait_v2()` blocks until completion or timeout
- **Worker Observability**: `list_v2()` for real-time monitoring and cleanup
- **Fire-and-Forget Submit**: `submit_v2()` for side-effect queries

### V1.8 Enhancements
- **Session Statistics**: `stats_v2()` provides worker counts, success/failure rates, and execution times
- **Progress Reporting**: Workers can report progress via `pg_background_progress()`
- **GUC Configuration**: `pg_background.max_workers`, `worker_timeout`, `default_queue_size`
- **Resource Limits**: Built-in max workers enforcement per session
- **Enhanced Robustness**: Overflow protection, UTF-8 aware truncation, race condition fixes
- **Relocatable Extension**: Full support for `CREATE EXTENSION ... WITH SCHEMA`  

---

## PostgreSQL Version Compatibility

| PostgreSQL Version | Support Status | Notes |
|--------------------|----------------|-------|
| **18** | ✅ Fully Supported | TupleDescAttr compatibility layer |
| **17** | ✅ Fully Tested | Recommended for new deployments |
| **16** | ✅ Fully Tested | Production-ready |
| **15** | ✅ Fully Tested | pg_analyze_and_rewrite_fixedparams |
| **14** | ✅ Fully Tested | Minimum supported version |
| **13** | ❌ Not Supported | Use pg_background 1.6 or earlier |
| **< 13** | ❌ Not Supported | Use pg_background 1.4 or earlier |

**Note**: Each PostgreSQL major version requires extension rebuild against its headers.

---

## Installation

### Prerequisites

- PostgreSQL 14+ with development headers (`postgresql-server-dev-*` or `postgresql##-devel`)
- `pg_config` in `$PATH`
- Build essentials: `gcc`, `make`
- Superuser privileges for `CREATE EXTENSION`

### Build from Source

```bash
# Clone repository
git clone https://github.com/vibhorkum/pg_background.git
cd pg_background

# Build extension
make clean
make

# Install (requires appropriate privileges)
sudo make install
```

### Enable Extension

```sql
-- Connect as superuser
CREATE EXTENSION pg_background;

-- Verify installation
SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_background';
-- Expected output:
--    extname     | extversion
-- ---------------+------------
--  pg_background | 1.8
```

### Custom Schema Installation

The extension is **relocatable**, allowing installation in any schema. This is useful for organizing extensions or avoiding namespace conflicts.

```sql
-- Create custom schema
CREATE SCHEMA contrib;

-- Install extension in custom schema
CREATE EXTENSION pg_background WITH SCHEMA contrib;

-- Verify installation
SELECT extname, extversion, nspname AS schema
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname = 'pg_background';
-- Expected output:
--    extname     | extversion | schema
-- ---------------+------------+---------
--  pg_background | 1.8        | contrib
```

**Using Extension in Custom Schema**:

When installed in a custom schema, functions can be called with schema qualification or by adding the schema to `search_path`:

```sql
-- Option 1: Schema-qualified calls
SELECT * FROM contrib.pg_background_launch_v2('SELECT 1') AS h;
SELECT * FROM contrib.pg_background_result_v2(h.pid, h.cookie) AS (result int);

-- Option 2: Add schema to search_path
SET search_path = contrib, public;
SELECT * FROM pg_background_launch_v2('SELECT 1') AS h;
```

**Privileges with Custom Schema**:

The privilege helper functions automatically detect the extension's schema:

```sql
-- Grant privileges (works regardless of installation schema)
SELECT contrib.grant_pg_background_privileges('app_user', true);

-- Or if schema is in search_path
SELECT grant_pg_background_privileges('app_user', true);
```

**Test Cases for Custom Schema Installation**:

```sql
-- Test 1: Basic installation in custom schema
CREATE SCHEMA test_schema;
CREATE EXTENSION pg_background WITH SCHEMA test_schema;

-- Test 2: Launch worker from custom schema
SELECT (h).pid, (h).cookie FROM test_schema.pg_background_launch_v2('SELECT 42') AS h \gset

-- Test 3: Retrieve results
SELECT * FROM test_schema.pg_background_result_v2(:pid, :cookie) AS (val int);
-- Expected: val = 42

-- Test 4: Privilege helpers work with custom schema
CREATE ROLE test_user NOLOGIN;
SELECT test_schema.grant_pg_background_privileges('test_user', true);
-- Should output GRANT statements with test_schema prefix

-- Test 5: Revoke privileges
SELECT test_schema.revoke_pg_background_privileges('test_user', true);

-- Test 6: V2 types are accessible
SELECT (ROW(123, 456789)::test_schema.pg_background_handle).*;
-- Expected: pid=123, cookie=456789

-- Cleanup
DROP ROLE test_user;
DROP EXTENSION pg_background;
DROP SCHEMA test_schema;
```

### Configure PostgreSQL

```sql
-- Set worker process limit (adjust based on your workload)
ALTER SYSTEM SET max_worker_processes = 32;

-- Reload configuration
SELECT pg_reload_conf();

-- Verify setting
SHOW max_worker_processes;
```

### Extension GUC Settings (v1.8+)

```sql
-- Limit concurrent workers per session (default: 16)
SET pg_background.max_workers = 10;

-- Set default queue size for workers (default: 64KB)
SET pg_background.default_queue_size = '256KB';

-- Set worker execution timeout (default: 0 = no limit)
SET pg_background.worker_timeout = '5min';
```

| GUC Parameter | Default | Range | Description |
|---------------|---------|-------|-------------|
| `pg_background.max_workers` | 16 | 1-1000 | Max concurrent workers per session |
| `pg_background.default_queue_size` | 65536 | 4KB-256MB | Default shared memory queue size |
| `pg_background.worker_timeout` | 0 | 0-∞ | Worker execution timeout (0 = no limit) |

---

## Quick Start

### V2 API (Recommended)

The v2 API provides cookie-based handle protection and explicit lifecycle semantics.

#### 1. Launch a Background Job

```sql
-- Launch worker and capture handle
SELECT * FROM pg_background_launch_v2(
  'SELECT pg_sleep(5); SELECT count(*) FROM large_table'
) AS handle;

-- Output:
--   pid  |      cookie       
-- -------+-------------------
--  12345 | 1234567890123456
```

#### 2. Retrieve Results

```sql
-- Results can only be consumed ONCE
SELECT * FROM pg_background_result_v2(12345, 1234567890123456) AS (count BIGINT);

-- Attempting second retrieval will error:
-- ERROR: results already consumed for worker PID 12345
```

#### 3. Fire-and-Forget (Submit)

```sql
-- For queries with side effects only (no result consumption needed)
SELECT * FROM pg_background_submit_v2(
  'INSERT INTO audit_log (ts, event) VALUES (now(), ''system_check'')'
) AS handle;

-- Worker commits and exits automatically
```

#### 4. Cancel a Running Job

```sql
-- Request immediate cancellation
SELECT pg_background_cancel_v2(pid, cookie);

-- Or with grace period (500ms to finish current statement)
SELECT pg_background_cancel_v2_grace(pid, cookie, 500);
```

⚠️ **Windows Limitation**: Cancel on Windows only sets interrupts; it cannot terminate an actively running statement. Always use `statement_timeout` on Windows.

#### 5. Wait for Completion

```sql
-- Block until worker finishes
SELECT pg_background_wait_v2(pid, cookie);

-- Or wait with timeout (returns true if completed)
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
)
ORDER BY launched_at DESC;
```

**State Values**:
- `running`: Actively executing SQL
- `stopped`: Completed successfully
- `canceled`: Terminated via `cancel_v2()`
- `error`: Failed with error (see `last_error`)

#### 7. View Session Statistics (v1.8+)

```sql
-- Get session-wide worker statistics
SELECT * FROM pg_background_stats_v2();

-- Output:
--  workers_launched | workers_completed | workers_failed | workers_active | avg_execution_ms | max_workers
-- ------------------+-------------------+----------------+----------------+------------------+-------------
--                42 |                38 |              2 |              2 |           1234.5 |          16
```

#### 8. Progress Reporting (v1.8+)

**From within worker SQL** (report progress):
```sql
-- Launch a worker that reports progress
SELECT * FROM pg_background_launch_v2($$
  SELECT pg_background_progress(0, 'Starting...');
  -- Do some work...
  SELECT pg_background_progress(25, 'Phase 1 complete');
  -- More work...
  SELECT pg_background_progress(50, 'Halfway done');
  -- Final work...
  SELECT pg_background_progress(100, 'Complete');
$$) AS h \gset;
```

**From launcher** (check progress):
```sql
-- Poll worker progress
SELECT * FROM pg_background_get_progress_v2(:'h.pid', :'h.cookie');

-- Output:
--  progress_pct | progress_msg
-- --------------+---------------
--            50 | Halfway done
```

### V1 API (Legacy)

The v1 API is retained for backward compatibility but **lacks cookie-based PID reuse protection**.

```sql
-- Launch (returns bare PID)
SELECT pg_background_launch('VACUUM VERBOSE my_table') AS pid \gset

-- Retrieve results
SELECT * FROM pg_background_result(:pid) AS (result TEXT);

-- Fire-and-forget (detach does NOT cancel!)
SELECT pg_background_detach(:pid);
```

⚠️ **Production Warning**: The v1 API is vulnerable to PID reuse over long session lifetimes. Always use v2 API in production.

---

## Complete API Reference

### V2 Functions

| Function | Returns | Description | Use Case |
|----------|---------|-------------|----------|
| `pg_background_launch_v2(sql, queue_size)` | `pg_background_handle` | Launch worker, return cookie-protected handle | Standard async execution |
| `pg_background_submit_v2(sql, queue_size)` | `pg_background_handle` | Fire-and-forget (no result consumption) | Side-effect queries (logging, notifications) |
| `pg_background_result_v2(pid, cookie)` | `SETOF record` | Retrieve results (**one-time consumption**) | Collect query output |
| `pg_background_detach_v2(pid, cookie)` | `void` | Stop tracking worker (worker continues) | Cleanup bookkeeping for long-running tasks |
| `pg_background_cancel_v2(pid, cookie)` | `void` | Request cancellation (best-effort) | Terminate unwanted work |
| `pg_background_cancel_v2_grace(pid, cookie, grace_ms)` | `void` | Cancel with grace period (max 3600000ms) | Allow current statement to finish |
| `pg_background_wait_v2(pid, cookie)` | `void` | Block until worker completes | Synchronous barrier |
| `pg_background_wait_v2_timeout(pid, cookie, timeout_ms)` | `bool` | Wait with timeout (returns `true` if done) | Bounded blocking |
| `pg_background_list_v2()` | `SETOF record` | List known workers in current session | Monitoring, debugging, cleanup |
| `pg_background_stats_v2()` | `pg_background_stats` | Session statistics (v1.8+) | Monitoring, debugging |
| `pg_background_progress(pct, msg)` | `void` | Report progress from worker (v1.8+) | Long-running task feedback |
| `pg_background_get_progress_v2(pid, cookie)` | `pg_background_progress` | Get worker progress (v1.8+) | Monitor long-running tasks |

**Parameters**:
- `sql`: SQL command(s) to execute (multiple statements allowed)
- `queue_size`: Shared memory queue size in bytes (default: 65536, min: 4096)
- `pid`: Process ID from handle
- `cookie`: Unique identifier from handle (prevents PID reuse)
- `grace_ms`: Milliseconds to wait before forceful termination (capped at 1 hour)
- `timeout_ms`: Milliseconds to wait for completion

**Handle Type**:
```sql
CREATE TYPE public.pg_background_handle AS (
  pid    int4,   -- Process ID
  cookie int8    -- Unique identifier (prevents PID reuse)
);
```

**Statistics Type** (v1.8+):
```sql
CREATE TYPE public.pg_background_stats AS (
  workers_launched   int8,    -- Total workers launched this session
  workers_completed  int8,    -- Workers completed successfully
  workers_failed     int8,    -- Workers that failed with error
  workers_active     int4,    -- Currently active workers
  avg_execution_ms   float8,  -- Average execution time
  max_workers        int4     -- Current max_workers setting
);
```

**Progress Type** (v1.8+):
```sql
CREATE TYPE public.pg_background_progress AS (
  progress_pct  int4,   -- Progress percentage (0-100)
  progress_msg  text    -- Brief status message
);
```

### V1 Functions (Deprecated)

| Function | Returns | Description | Limitation |
|----------|---------|-------------|------------|
| `pg_background_launch(sql, queue_size)` | `int4` (PID) | Launch worker, return PID | Vulnerable to PID reuse |
| `pg_background_result(pid)` | `SETOF record` | Retrieve results | No cookie validation |
| `pg_background_detach(pid)` | `void` | Stop tracking worker | Does NOT cancel execution |

⚠️ **Migration Path**: Replace v1 calls with v2 equivalents in new code. See [Migration Guide](#migration-guide).

---

## Critical Semantic Distinctions

### Cancel vs Detach

**These operations are NOT interchangeable.** Confusion between them is a common source of production issues.

| Operation | Stops Execution | Prevents Commit | Removes Tracking |
|-----------|-----------------|-----------------|------------------|
| **`cancel_v2()`** | ⚠️ Best-effort (immediate on Unix, limited on Windows) | ⚠️ Best-effort | ❌ No |
| **`detach_v2()`** | ❌ No | ❌ No | ✅ Yes |

**Rule of Thumb**:
- Use **`cancel_v2()`** to **stop work** (terminate execution, prevent commit/notify)
- Use **`detach_v2()`** to **stop tracking** (free bookkeeping memory while worker continues)

#### Example: Detach Does NOT Prevent NOTIFY

```sql
-- Launch worker that sends notification
SELECT * FROM pg_background_launch_v2(
  $$SELECT pg_notify('alerts', 'system_event')$$
) AS h \gset

-- Detach only removes launcher's tracking
SELECT pg_background_detach_v2(:'h.pid', :'h.cookie');

-- Worker STILL runs and sends notification!
-- To actually prevent notification, use:
SELECT pg_background_cancel_v2(:'h.pid', :'h.cookie');
```

#### When to Use Each

**Use `cancel_v2()`**:
- User-initiated cancellation
- Timeout enforcement
- Rollback of unwanted side effects
- Immediate resource reclamation

**Use `detach_v2()`**:
- Long-running maintenance (don't need to track VACUUM for hours)
- Fire-and-forget after successful submission
- Session cleanup before disconnect
- Reducing launcher session memory usage

### V1 vs V2 API

| Aspect | V1 API | V2 API |
|--------|--------|--------|
| **Handle** | Bare `int4` PID | `(pid int4, cookie int8)` composite |
| **PID Reuse Protection** | ❌ None | ✅ Cookie validation |
| **Cancel Operation** | ❌ Not available | ✅ `cancel_v2()` / `cancel_v2_grace()` |
| **Wait Operation** | ❌ Not available (manual polling) | ✅ `wait_v2()` / `wait_v2_timeout()` |
| **Worker Listing** | ❌ Not available | ✅ `list_v2()` |
| **Submit (fire-forget)** | ⚠️ Use `detach()` after `launch()` | ✅ Dedicated `submit_v2()` |
| **Production Use** | ⚠️ Not recommended | ✅ Recommended |

#### Common V1 Pain Point: Column Definition Lists

A frequent source of confusion with the v1 API is the requirement to specify column definitions when retrieving results:

```sql
-- V1 API: MUST specify column definition list
SELECT * FROM pg_background_result(
  pg_background_launch('SELECT pg_sleep(3); SELECT ''done''')
) AS (result text);

-- Without it, you get:
-- ERROR: a column definition list is required for functions returning "record"

-- And if your query returns multiple columns, you must match them exactly:
SELECT * FROM pg_background_result(
  pg_background_launch('SELECT ''done'', ''here''')
) AS (col1 text, col2 text);
-- Mismatched columns cause: ERROR: remote query result rowtype does not match
```

**V2 Solution**: If you just need to wait for completion without retrieving results, use `wait_v2()`:

```sql
-- V2 API: Wait for completion without dealing with result columns
SELECT (h).pid, (h).cookie
FROM pg_background_launch_v2('SELECT pg_sleep(3); SELECT ''done'', ''here''') AS h \gset

-- Simply wait - no column definition needed!
SELECT pg_background_wait_v2(:pid, :cookie);

-- Or with timeout (returns true if completed, false if timed out)
SELECT pg_background_wait_v2_timeout(:pid, :cookie, 5000);

-- Cleanup
SELECT pg_background_detach_v2(:pid, :cookie);
```

This is especially useful for:
- Background maintenance tasks (VACUUM, ANALYZE)
- Fire-and-forget operations where you only care about completion
- Cases where the result structure may vary

### PID Reuse Protection

**The Problem**: Operating systems recycle process IDs. On busy systems, a PID can be reused within minutes.

**V1 API Risk** (PID-only reference):
```sql
-- Day 1: Launch worker
SELECT pg_background_launch('slow_query()') AS pid \gset

-- Day 2: Session still alive, but worker PID may be reused
-- This could attach to a DIFFERENT worker with the SAME PID!
SELECT pg_background_result(:pid);  -- ⚠️ DANGEROUS
```

**V2 API Fix** (PID + Cookie):
```sql
-- Launch with cookie
SELECT * FROM pg_background_launch_v2('slow_query()') AS h \gset

-- Days later: cookie validation prevents mismatch
SELECT pg_background_result_v2(:'h.pid', :'h.cookie');
-- If PID reused, cookie won't match → safe error
```

**Implementation**: Each worker generates a random 64-bit cookie at launch. All operations validate `(pid, cookie)` tuple matches.

### NOTIFY and Autonomous Commits

Workers execute in **separate transactions** from the launcher. This has critical implications:

#### Autonomous Transaction Behavior

```sql
BEGIN;
  -- Launcher transaction starts

  SELECT * FROM pg_background_launch_v2(
    'INSERT INTO audit_log VALUES (now(), ''user_action'')'
  ) AS h \gset;
  
  -- Main work
  UPDATE users SET status = 'active' WHERE id = 123;
  
  -- If we ROLLBACK, the audit_log INSERT still commits!
ROLLBACK;

-- audit_log entry exists despite rollback
```

**Implications**:
- ✅ **Good for**: Audit logging, NOTIFY, stats collection
- ⚠️ **Bad for**: Interdependent data modifications requiring ACID

#### NOTIFY Delivery with Detach

```sql
-- Worker sends notification
SELECT * FROM pg_background_launch_v2(
  $$SELECT pg_notify('channel', 'message')$$
) AS h \gset;

-- Detach removes tracking but does NOT cancel
SELECT pg_background_detach_v2(:'h.pid', :'h.cookie');

-- Notification WILL be delivered (worker commits independently)
```

To **prevent** notification delivery:
```sql
-- Cancel before worker commits
SELECT pg_background_cancel_v2(:'h.pid', :'h.cookie');
```

---

## Security Model

### Privilege Architecture

`pg_background` uses a role-based security model with zero PUBLIC access by default.

#### Default Setup (Automatic)

```sql
-- Extension creates this role automatically:
CREATE ROLE pgbackground_role NOLOGIN INHERIT;

-- All pg_background functions granted to this role
-- PUBLIC has NO access by default
```

#### Grant Access to Users

```sql
-- Method 1: Direct role grant (recommended)
GRANT pgbackground_role TO app_user;

-- Method 2: Helper function (explicit EXECUTE grants)
SELECT grant_pg_background_privileges('app_user', true);
```

#### Revoke Access

```sql
-- Method 1: Revoke role membership
REVOKE pgbackground_role FROM app_user;

-- Method 2: Helper function
SELECT revoke_pg_background_privileges('app_user', true);
```

### Security Considerations

#### 1. SQL Injection Prevention

❌ **Unsafe** (vulnerable to SQL injection):
```sql
CREATE FUNCTION unsafe_launch(user_input text) RETURNS void AS $$
BEGIN
  -- NEVER concatenate untrusted input!
  PERFORM pg_background_launch_v2(
    'SELECT * FROM users WHERE name = ''' || user_input || ''''
  );
END;
$$ LANGUAGE plpgsql;
```

✅ **Safe** (parameterized with `format()`):
```sql
CREATE FUNCTION safe_launch(user_input text) RETURNS void AS $$
BEGIN
  -- Use %L for literal quoting
  PERFORM pg_background_launch_v2(
    format('SELECT * FROM users WHERE name = %L', user_input)
  );
END;
$$ LANGUAGE plpgsql;
```

#### 2. Resource Exhaustion Protection

```sql
-- Application-level quota enforcement
CREATE OR REPLACE FUNCTION launch_with_limit(sql text)
RETURNS pg_background_handle AS $$
DECLARE
  active_count int;
  h pg_background_handle;
BEGIN
  -- Count active workers for current user
  SELECT count(*) INTO active_count
  FROM pg_background_list_v2() AS (
    pid int4, cookie int8, launched_at timestamptz, user_id oid,
    queue_size int4, state text, sql_preview text, last_error text, consumed bool
  )
  WHERE user_id = current_user::regrole::oid
    AND state IN ('running');
  
  IF active_count >= 5 THEN
    RAISE EXCEPTION 'User worker limit exceeded (max 5 concurrent)';
  END IF;
  
  SELECT * INTO h FROM pg_background_launch_v2(sql);
  RETURN h;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

#### 3. Privilege Isolation

- ✅ Workers inherit **current_user** from launcher (not superuser escalation)
- ✅ `SECURITY DEFINER` helpers use pinned `search_path = pg_catalog`
- ✅ No ambient PUBLIC grants
- ⚠️ Workers can access all databases launcher can access

#### 4. Information Disclosure Risks

```sql
-- list_v2() exposes SQL previews (first 120 chars) and error messages
-- For sensitive deployments, create restricted view:

CREATE VIEW public.safe_worker_list AS
SELECT pid, cookie, state, consumed, launched_at
FROM pg_background_list_v2() AS (
  pid int4, cookie int8, launched_at timestamptz, user_id oid,
  queue_size int4, state text, sql_preview text, last_error text, consumed bool
)
WHERE user_id = current_user::regrole::oid;
-- Omit sql_preview and last_error

GRANT SELECT ON public.safe_worker_list TO app_users;
```

### Security Best Practices

1. **Never grant `pgbackground_role` to PUBLIC**
2. **Use v2 API exclusively** (cookie protection)
3. **Set `statement_timeout`** to bound execution time
4. **Implement application-level quotas** (max workers per user/database)
5. **Sanitize all dynamic SQL** with `format()` or `quote_literal()`
6. **Monitor `list_v2()`** for suspicious activity
7. **Audit `pg_stat_activity`** for background worker usage
8. **Test disaster recovery** with active workers

---

## Use Cases with Examples

### 1. Background Maintenance Operations

**Problem**: VACUUM blocks client connections and consumes resources.

**Solution**: Run maintenance asynchronously.

```sql
-- Launch background VACUUM
SELECT * FROM pg_background_launch_v2(
  'VACUUM (VERBOSE, ANALYZE) large_table'
) AS h \gset

-- Check progress periodically
SELECT state, sql_preview
FROM pg_background_list_v2() AS (
  pid int4, cookie int8, launched_at timestamptz, user_id oid,
  queue_size int4, state text, sql_preview text, last_error text, consumed bool
)
WHERE pid = :'h.pid' AND cookie = :'h.cookie';

-- Wait for completion (optional)
SELECT pg_background_wait_v2(:'h.pid', :'h.cookie');

-- Cleanup tracking
SELECT pg_background_detach_v2(:'h.pid', :'h.cookie');
```

### 2. Autonomous Audit Logging

**Problem**: Audit logs must persist even if main transaction rolls back.

**Solution**: Use background worker for independent commit.

> **⚠️ Critical Warning**: If `max_worker_processes` is exhausted, `pg_background_launch_v2()` will throw `INSUFFICIENT_RESOURCES`. For audit logging, this means:
> - The audit message will be **lost**
> - The calling transaction may **fail unexpectedly**
> - Failures occur **unpredictably** under load
>
> See the robust implementation below and [Known Limitation #4](#4-worker-exhaustion-insufficient_resources) for details.

**Basic Example** (not fault-tolerant):

```sql
CREATE FUNCTION log_audit_simple(event_type text, details jsonb)
RETURNS void AS $$
DECLARE
  h pg_background_handle;
BEGIN
  -- Launch audit insert (commits independently)
  SELECT * INTO h FROM pg_background_submit_v2(
    format(
      'INSERT INTO audit_log (ts, event_type, details) VALUES (now(), %L, %L)',
      event_type,
      details::text
    )
  );

  -- Detach immediately (fire-and-forget)
  PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$ LANGUAGE plpgsql;
```

**Robust Example** (handles worker exhaustion):

```sql
CREATE FUNCTION log_audit(event_type text, details jsonb)
RETURNS void AS $$
DECLARE
  h pg_background_handle;
  retries int := 3;
  backoff_ms int := 100;
BEGIN
  FOR i IN 1..retries LOOP
    BEGIN
      SELECT * INTO h FROM pg_background_submit_v2(
        format(
          'INSERT INTO audit_log (ts, event_type, details) VALUES (now(), %L, %L)',
          event_type,
          details::text
        )
      );
      PERFORM pg_background_detach_v2(h.pid, h.cookie);
      RETURN;  -- Success
    EXCEPTION
      WHEN insufficient_resources THEN
        IF i = retries THEN
          -- Final fallback: log synchronously (blocks but doesn't lose data)
          INSERT INTO audit_log (ts, event_type, details)
          VALUES (now(), event_type, details);
          RAISE WARNING 'pg_background exhausted, audit logged synchronously';
          RETURN;
        END IF;
        -- Exponential backoff before retry
        PERFORM pg_sleep(backoff_ms / 1000.0);
        backoff_ms := backoff_ms * 2;
    END;
  END LOOP;
END;
$$ LANGUAGE plpgsql;
```

**Usage in transaction**:

```sql
BEGIN;
  UPDATE accounts SET balance = balance - 100 WHERE id = 123;

  -- Audit log commits even if UPDATE rolls back
  PERFORM log_audit('withdrawal', '{"account": 123, "amount": 100}');

  -- Simulate error
  ROLLBACK;

-- Audit log entry exists!
SELECT * FROM audit_log ORDER BY ts DESC LIMIT 1;
```

### 3. Asynchronous Notification Delivery

**Problem**: `pg_notify()` in main transaction delays commit.

**Solution**: Offload notifications to background worker.

```sql
CREATE FUNCTION notify_async(channel text, payload text)
RETURNS void AS $$
DECLARE
  h pg_background_handle;
BEGIN
  SELECT * INTO h FROM pg_background_submit_v2(
    format('SELECT pg_notify(%L, %L)', channel, payload)
  );
  
  PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$ LANGUAGE plpgsql;

-- Usage
SELECT notify_async('order_updates', '{"order_id": 456, "status": "shipped"}');
```

### 4. Long-Running ETL Pipeline

**Problem**: ETL blocks client connection for hours.

**Solution**: Launch in background, poll for completion.

```sql
-- Launch ETL
SELECT * FROM pg_background_launch_v2($$
  INSERT INTO fact_sales
  SELECT * FROM staging_sales
  WHERE processed = false;
  
  UPDATE staging_sales SET processed = true;
$$) AS h \gset

-- Store handle for later retrieval
INSERT INTO job_tracker (job_id, pid, cookie, started_at)
VALUES ('etl-001', :'h.pid', :'h.cookie', now());

-- Later: check status
SELECT
  j.job_id,
  w.state,
  w.launched_at,
  (now() - w.launched_at) AS duration
FROM job_tracker j
CROSS JOIN LATERAL (
  SELECT *
  FROM pg_background_list_v2() AS (
    pid int4, cookie int8, launched_at timestamptz, user_id oid,
    queue_size int4, state text, sql_preview text, last_error text, consumed bool
  )
  WHERE pid = j.pid AND cookie = j.cookie
) w
WHERE j.job_id = 'etl-001';
```

### 5. Parallel Query Simulation

**Problem**: PostgreSQL doesn't parallelize queries across tables.

**Solution**: Launch concurrent workers for each table.

```sql
DO $$
DECLARE
  h1 pg_background_handle;
  h2 pg_background_handle;
  h3 pg_background_handle;
  total_rows bigint;
BEGIN
  -- Launch parallel workers
  SELECT * INTO h1 FROM pg_background_launch_v2('SELECT count(*) FROM sales');
  SELECT * INTO h2 FROM pg_background_launch_v2('SELECT count(*) FROM orders');
  SELECT * INTO h3 FROM pg_background_launch_v2('SELECT count(*) FROM customers');
  
  -- Wait for all to complete
  PERFORM pg_background_wait_v2(h1.pid, h1.cookie);
  PERFORM pg_background_wait_v2(h2.pid, h2.cookie);
  PERFORM pg_background_wait_v2(h3.pid, h3.cookie);
  
  -- Aggregate results
  SELECT sum(cnt) INTO total_rows FROM (
    SELECT * FROM pg_background_result_v2(h1.pid, h1.cookie) AS (cnt bigint)
    UNION ALL
    SELECT * FROM pg_background_result_v2(h2.pid, h2.cookie) AS (cnt bigint)
    UNION ALL
    SELECT * FROM pg_background_result_v2(h3.pid, h3.cookie) AS (cnt bigint)
  ) t;
  
  RAISE NOTICE 'Total rows: %', total_rows;
END;
$$;
```

### 6. Timeout Enforcement

**Problem**: Need to cancel queries that exceed time budget.

**Solution**: Use `wait_v2_timeout()` with `cancel_v2_grace()`.

```sql
CREATE FUNCTION run_with_timeout(sql text, timeout_sec int)
RETURNS text AS $$
DECLARE
  h pg_background_handle;
  done bool;
  result_text text;
BEGIN
  -- Launch worker
  SELECT * INTO h FROM pg_background_launch_v2(sql);
  
  -- Wait with timeout
  done := pg_background_wait_v2_timeout(h.pid, h.cookie, timeout_sec * 1000);
  
  IF NOT done THEN
    -- Timeout exceeded
    RAISE WARNING 'Query timed out after % seconds, cancelling...', timeout_sec;
    PERFORM pg_background_cancel_v2_grace(h.pid, h.cookie, 1000);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RETURN 'TIMEOUT';
  END IF;
  
  -- Retrieve result
  SELECT * INTO result_text FROM pg_background_result_v2(h.pid, h.cookie) AS (res text);
  RETURN result_text;
END;
$$ LANGUAGE plpgsql;

-- Usage
SELECT run_with_timeout('SELECT pg_sleep(10)', 5);  -- Returns 'TIMEOUT'
```

---

## Operational Guidance

### Resource Management

#### max_worker_processes Limit

Background workers count against PostgreSQL's global `max_worker_processes` limit.

**Check Current Usage**:
```sql
SELECT count(*) AS bgworker_count
FROM pg_stat_activity
WHERE backend_type LIKE '%background%';
```

**Recommended Configuration**:
```sql
-- Formula: autovacuum_workers + max_parallel_workers + pg_background_estimate + buffer
ALTER SYSTEM SET max_worker_processes = 64;  -- Adjust per workload
SELECT pg_reload_conf();
```

**Operational Limits**:
- Default `max_worker_processes`: 8 (often insufficient)
- Recommended minimum for pg_background: 16-32
- Enterprise workloads: 64-128
- Each worker: ~10MB memory overhead

#### Dynamic Shared Memory (DSM) Usage

Each worker allocates one DSM segment for IPC.

**Monitor DSM**:
```sql
SELECT
  name,
  size,
  allocated_size
FROM pg_shmem_allocations
WHERE name LIKE '%pg_background%'
ORDER BY size DESC;
```

**DSM Size**:
- Default queue_size: 65536 bytes (~64KB)
- Minimum queue_size: 4096 bytes (enforced by `shm_mq`)
- Large result sets: increase queue_size parameter

**Example**:
```sql
-- Small results (default)
SELECT pg_background_launch_v2('SELECT id FROM small_table', 65536);

-- Large results (1MB queue)
SELECT pg_background_launch_v2('SELECT * FROM huge_table', 1048576);
```

#### Worker Lifecycle and Cleanup

**Automatic Cleanup**:
- Worker exits → DSM detached → hash entry removed
- Launcher session ends → all tracked workers detached

**Manual Cleanup**:
```sql
-- Detach all completed workers
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT *
    FROM pg_background_list_v2() AS (
      pid int4, cookie int8, launched_at timestamptz, user_id oid,
      queue_size int4, state text, sql_preview text, last_error text, consumed bool
    )
    WHERE state IN ('stopped', 'canceled', 'error')
  LOOP
    PERFORM pg_background_detach_v2(r.pid, r.cookie);
  END LOOP;
END;
$$;
```

### Performance Tuning

#### 1. Queue Size Optimization

**Rule of Thumb**:
- Small queries (< 1000 rows): 65536 (64KB, default)
- Medium queries (< 10000 rows): 262144 (256KB)
- Large queries (>= 10000 rows): 1048576+ (1MB+)

**Trade-offs**:
- Larger queue → less blocking on result production
- Larger queue → more shared memory consumption
- Too small → worker blocks waiting for launcher to consume

**Measure Contention**:
```sql
-- Check if worker is blocking on queue send
SELECT
  pid,
  state,
  wait_event_type,
  wait_event
FROM pg_stat_activity
WHERE backend_type LIKE '%background%'
  AND wait_event = 'SHM_MQ_SEND';
```

#### 2. Statement Timeout

Workers inherit `statement_timeout` from launcher session.

**Set Per-Worker Timeout**:
```sql
-- Temporarily increase timeout
SET statement_timeout = '30min';
SELECT pg_background_launch_v2('slow_aggregation_query()');
RESET statement_timeout;
```

**Set Database-Wide Default**:
```sql
ALTER DATABASE production SET statement_timeout = '10min';
```

#### 3. Work Memory

**Important**: Workers do NOT inherit `work_mem` from launcher.

**Workaround**:
```sql
-- Include SET in worker SQL
SELECT pg_background_launch_v2($$
  SET work_mem = '256MB';
  SELECT * FROM large_table ORDER BY col;
$$);
```

#### 4. Parallel Workers

Background workers are separate from `max_parallel_workers`.

**Configuration**:
```sql
-- Both settings are independent
ALTER SYSTEM SET max_worker_processes = 64;     -- Total pool
ALTER SYSTEM SET max_parallel_workers = 16;     -- Parallel query subset
```

### Monitoring

#### Real-Time Worker Status

```sql
CREATE VIEW pg_background_status AS
SELECT
  w.pid,
  w.cookie,
  w.state,
  left(w.sql_preview, 60) AS sql_snippet,
  w.launched_at,
  (now() - w.launched_at) AS age,
  w.consumed,
  a.state AS pg_state,
  a.wait_event_type,
  a.wait_event,
  a.query AS current_query
FROM pg_background_list_v2() AS (
  pid int4, cookie int8, launched_at timestamptz, user_id oid,
  queue_size int4, state text, sql_preview text, last_error text, consumed bool
) w
LEFT JOIN pg_stat_activity a USING (pid)
ORDER BY w.launched_at DESC;

-- Query it
SELECT * FROM pg_background_status;
```

#### Alerting on Long-Running Workers

```sql
-- Workers running > 1 hour
SELECT
  pid,
  cookie,
  sql_preview,
  (now() - launched_at) AS duration
FROM pg_background_list_v2() AS (
  pid int4, cookie int8, launched_at timestamptz, user_id oid,
  queue_size int4, state text, sql_preview text, last_error text, consumed bool
)
WHERE state = 'running'
  AND (now() - launched_at) > interval '1 hour';
```

#### Prometheus-Style Metrics

```sql
-- Export metrics for monitoring systems
SELECT
  'pg_background_active_workers' AS metric,
  count(*) AS value,
  state AS labels
FROM pg_background_list_v2() AS (
  pid int4, cookie int8, launched_at timestamptz, user_id oid,
  queue_size int4, state text, sql_preview text, last_error text, consumed bool
)
GROUP BY state;
```

---

## Troubleshooting

### Common Issues

#### Issue 1: "could not register background process"

**Symptom**:
```
ERROR: could not register background process
HINT: You may need to increase max_worker_processes.
```

**Cause**: `max_worker_processes` limit reached.

**Solution**:
```sql
-- Check current limit and usage
SHOW max_worker_processes;
SELECT count(*) FROM pg_stat_activity WHERE backend_type LIKE '%worker%';

-- Increase limit (requires restart for some versions)
ALTER SYSTEM SET max_worker_processes = 32;
SELECT pg_reload_conf();  -- Or restart PostgreSQL
```

#### Issue 2: "cookie mismatch for PID XXXXX"

**Symptom**:
```
ERROR: cookie mismatch for PID 12345: expected 1234567890123456, got 9876543210987654
```

**Cause**: PID reused after worker exit, or stale handle.

**Solution**:
- Always use fresh handles from `launch_v2()`
- Never hardcode PID/cookie values
- Don't cache handles across long time periods

```sql
-- ❌ Bad: Reusing old handle
-- h was from hours ago, worker exited, PID reused

-- ✅ Good: Fresh handle per operation
SELECT * FROM pg_background_launch_v2('...') AS h \gset
SELECT pg_background_wait_v2(:'h.pid', :'h.cookie');
```

#### Issue 3: Worker Hangs Indefinitely

**Symptom**: Worker shows `running` state for hours without progress.

**Cause**: Lock contention, infinite loop, or missing `CHECK_FOR_INTERRUPTS`.

**Diagnosis**:
```sql
-- Check what worker is waiting on
SELECT
  w.pid,
  w.sql_preview,
  a.wait_event_type,
  a.wait_event,
  a.state,
  a.query
FROM pg_background_list_v2() AS (
  pid int4, cookie int8, launched_at timestamptz, user_id oid,
  queue_size int4, state text, sql_preview text, last_error text, consumed bool
) w
JOIN pg_stat_activity a USING (pid)
WHERE w.state = 'running';

-- Check locks
SELECT
  l.pid,
  l.locktype,
  l.relation::regclass,
  l.mode,
  l.granted
FROM pg_locks l
WHERE l.pid = <worker_pid>;
```

**Solution**:
```sql
-- Cancel with grace period
SELECT pg_background_cancel_v2_grace(<pid>, <cookie>, 5000);

-- Force cancel if grace period expires
SELECT pg_background_cancel_v2(<pid>, <cookie>);
```

#### Issue 4: "results already consumed"

**Symptom**:
```
ERROR: results already consumed for worker PID 12345
```

**Cause**: Attempting to call `result_v2()` twice on same handle.

**Solution**: Results are **one-time consumption**. Use CTE to reuse:
```sql
-- ✅ Correct: Use CTE to consume once
WITH worker_results AS (
  SELECT * FROM pg_background_result_v2(<pid>, <cookie>) AS (col text)
)
SELECT * FROM worker_results
UNION ALL
SELECT * FROM worker_results;
```

#### Issue 5: DSM Allocation Failure

**Symptom**:
```
ERROR: could not allocate dynamic shared memory
```

**Cause**: Insufficient shared memory or too many DSM segments.

**Solution**:
```sql
-- Check DSM usage
SELECT count(*), sum(size) AS total_bytes
FROM pg_shmem_allocations
WHERE name LIKE '%dsm%';

-- Increase shared memory (postgresql.conf)
-- dynamic_shared_memory_type = posix  (or sysv, mmap)
-- Restart PostgreSQL
```

#### Issue 6: Custom Schema Installation Errors (Fixed in v1.7+)

**Symptom** (in versions before fix):
```
CREATE EXTENSION pg_background WITH SCHEMA contrib;
ERROR: function public.grant_pg_background_privileges(unknown, boolean) does not exist
```

**Cause**: Hardcoded `public.` schema references in SQL scripts when extension is relocatable.

**Status**: **Fixed in v1.7+** for fresh installations. The extension now properly supports custom schema installation.

**Solution for fresh install**:
```sql
-- Install directly in custom schema (v1.7+)
CREATE SCHEMA myschema;
CREATE EXTENSION pg_background WITH SCHEMA myschema;

-- Verify
SELECT * FROM myschema.pg_background_launch_v2('SELECT 1') AS h;
```

**⚠️ Limitation for upgrades**: If you have v1.4, v1.5, or v1.6 already installed, upgrading to v1.7/v1.8 will NOT move the extension to a custom schema. The upgrade scripts for older versions contain hardcoded `public.` references because those versions only supported the public schema.

**To relocate an existing installation**:
```sql
-- 1. Drop existing extension
DROP EXTENSION pg_background;

-- 2. Reinstall in desired schema
CREATE EXTENSION pg_background WITH SCHEMA myschema;
```

#### Issue 7: Column Definition List Required (V1 API)

**Symptom**:
```
SELECT pg_background_result(pg_background_launch('SELECT ''done'''));
ERROR: function returning record called in context that cannot accept type record
HINT: Try calling the function in the FROM clause using a column definition list.

-- Or when columns don't match:
SELECT * FROM pg_background_result(...) AS (result text);
ERROR: remote query result rowtype does not match the specified FROM clause rowtype
```

**Cause**: The v1 `pg_background_result()` returns `SETOF record`, which requires PostgreSQL to know the column types at parse time.

**Solution 1** - Match column definitions exactly:
```sql
-- Single column result
SELECT * FROM pg_background_result(
  pg_background_launch('SELECT ''done''')
) AS (result text);

-- Multiple columns - must match exactly
SELECT * FROM pg_background_result(
  pg_background_launch('SELECT ''done'', ''here''')
) AS (col1 text, col2 text);
```

**Solution 2** - Use V2 API `wait_v2()` if you don't need results:
```sql
-- Launch the worker
SELECT (h).pid, (h).cookie
FROM pg_background_launch_v2('SELECT pg_sleep(3); SELECT ''done'', ''here''') AS h \gset

-- Wait for completion - no column definition needed!
SELECT pg_background_wait_v2(:pid, :cookie);

-- Cleanup
SELECT pg_background_detach_v2(:pid, :cookie);
```

**Recommendation**: Migrate to the V2 API which provides `wait_v2()` for cases where you only need to wait for completion without retrieving results.

### Platform-Specific Issues

#### Windows: Cancel Limitations

**Problem**: On Windows, `cancel_v2()` cannot interrupt actively running statements.

**Explanation**: Windows lacks signal-based interrupts. Cancel only sets interrupt flags checked between statements.

**Workaround**:
```sql
-- Always set statement_timeout on Windows
ALTER DATABASE mydb SET statement_timeout = '5min';

-- Or per-worker:
SELECT pg_background_launch_v2($$
  SET statement_timeout = '5min';
  SELECT slow_function();
$$);
```

**Affected Operations**:
- Long-running CPU-bound queries
- Infinite loops in PL/pgSQL
- Queries with no yielding points

**See**: `windows/README.md` for details.

### Debug Logging

```sql
-- Enable verbose logging
SET client_min_messages = DEBUG1;
SET log_min_messages = DEBUG1;

-- Launch worker (check logs for DSM info)
SELECT * FROM pg_background_launch_v2('SELECT 1') AS h \gset;

-- Check PostgreSQL logs for:
-- - "registered dynamic background worker"
-- - "DSM segment attached"
-- - Worker execution details
```

---

## Architecture & Design

### High-Level Architecture

```
┌──────────────────┐
│  Client Session  │
│  (Launcher)      │
└────────┬─────────┘
         │ 1. pg_background_launch_v2(sql)
         ▼
┌──────────────────────────────────┐
│  Extension C Code                │
│  - Allocate DSM segment          │
│  - RegisterDynamicBgWorker()     │
│  - Create shm_mq                 │
│  - Wait for worker attach        │
└────────┬─────────────────────────┘
         │ 2. Postmaster fork()
         ▼
┌──────────────────────────────────┐
│  Background Worker Process       │
│  - Attach database               │
│  - Restore session GUCs          │
│  - Execute SQL via SPI           │
│  - Send results via shm_mq       │
│  - Exit (DSM cleanup)            │
└──────────────────────────────────┘
         │ 3. Results via shared memory
         ▼
┌──────────────────┐
│  Launcher        │
│  pg_background_  │
│  result_v2()     │
└──────────────────┘
```

### Key Components

#### 1. Dynamic Shared Memory (DSM)

**Purpose**: IPC mechanism for SQL text and result transport.

**Structure**:
- **Key 0 (Fixed Data)**: Session metadata (user, database, cookie)
- **Key 1 (SQL)**: SQL command string (null-terminated)
- **Key 2 (GUC)**: Session GUC settings (serialized)
- **Key 3 (Queue)**: Bidirectional message queue (shm_mq)

**Lifecycle**:
- Created by launcher in `launch_v2()`
- Attached by worker on startup
- Detached by worker on exit (automatic cleanup)
- Launcher detaches on `detach_v2()` or session end

#### 2. Shared Memory Queue (shm_mq)

**Purpose**: Bidirectional streaming transport for results.

**Flow**:
1. Worker executes query via SPI
2. Each result row serialized to shm_mq
3. Launcher reads from shm_mq in `result_v2()`
4. Queue blocks if full (backpressure)

**Tuning**:
- Queue size set at launch (default 64KB)
- Larger queues reduce blocking
- Monitor with `pg_stat_activity.wait_event = 'SHM_MQ_SEND'`

#### 3. Background Worker API

**Registration**:
```c
BackgroundWorker worker;
worker.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
worker.bgw_start_time = BgWorkerStart_ConsistentState;
worker.bgw_main = pg_background_worker_main;
RegisterDynamicBackgroundWorker(&worker, &handle);
```

**Lifecycle Hooks**:
- `bgw_main`: Entry point (`pg_background_worker_main`)
- `bgw_notify_pid`: Launcher PID (for notifications)
- `bgw_main_arg`: DSM handle (Datum)

#### 4. Server Programming Interface (SPI)

**Execution Pipeline**:
```c
SPI_connect();
SPI_execute(sql, false, 0);  // read_only=false, limit=0
while (SPI_processed > 0) {
    // Send result rows via shm_mq
}
SPI_finish();
```

**Result Serialization**:
- `RowDescription`: Column metadata (names, types, formats)
- `DataRow`: Binary-encoded tuple data
- `CommandComplete`: Result tag (e.g., "SELECT 42")

#### 5. Worker Hash Table

**Purpose**: Per-session tracking of launched workers.

**Structure**:
```c
typedef struct pg_background_worker_info {
    int pid;
    uint64 cookie;
    dsm_segment *seg;
    BackgroundWorkerHandle *handle;
    shm_mq_handle *responseq;
    bool consumed;  // Result retrieval guard
} pg_background_worker_info;
```

**Cleanup**:
- On worker exit: `cleanup_worker_info()` callback
- On launcher session end: detach all tracked workers
- On explicit `detach_v2()`: remove hash entry

### Concurrency and Race Conditions

#### NOTIFY Race (Solved in v1.5+)

**Problem**: Launcher returned before worker attached shm_mq → lost NOTIFYs.

**Solution**: `shm_mq_wait_for_attach()` blocks launcher until worker ready.

```c
// In pg_background_launch_v2:
shm_mq_wait_for_attach(mqh);  // BLOCK until worker attaches
return handle;  // Safe to return now
```

#### PID Reuse (Solved in v2 API)

**Problem**: Worker exits, PID reused, launcher attaches to wrong worker.

**Solution**: 64-bit random cookie validated on all operations.

```c
// Generate cookie at launch
fixed_data->cookie = (uint64)random() << 32 | random();

// Validate on every operation
if (worker_info->cookie != provided_cookie)
    ereport(ERROR, "cookie mismatch");
```

#### DSM Cleanup Races (Hardened in v1.6)

**Problem**: Launcher `pfree(handle)` before worker attached → crash.

**Solution**: Never explicitly free handle; let PostgreSQL manage lifetime.

```c
// ❌ OLD (buggy): pfree(handle);
// ✅ NEW: Let handle live until dsm_detach
```

---

## Known Limitations

### 1. Windows Cancel Limitations

**Limitation**: `cancel_v2()` on Windows cannot interrupt running statements.

**Details**:
- Windows lacks `SIGUSR1` equivalent for query cancellation
- Cancel only sets `InterruptPending` flag
- Flag checked between statements, not during execution

**Impact**:
- Infinite loops in PL/pgSQL cannot be interrupted
- Long-running aggregate functions cannot be interrupted mid-execution
- `pg_sleep()` DOES check interrupts (interruptible)

**Workarounds**:
1. Always set `statement_timeout`:
   ```sql
   ALTER DATABASE mydb SET statement_timeout = '5min';
   ```
2. Avoid infinite loops in worker SQL
3. Test cancellation on Unix/Linux platforms first

**Reference**: See `windows/README.md` for implementation details.

### 2. No Cross-Database Workers

**Limitation**: Workers can only connect to the **same database** as launcher.

**Reason**: `BackgroundWorker` API requires database OID at registration.

**Workaround**: Use `dblink` for cross-database operations:
```sql
SELECT pg_background_launch_v2($$
  SELECT * FROM dblink('dbname=other_db', 'SELECT ...')
$$);
```

### 3. Per-Session Worker Limits (v1.8+)

**v1.8 Improvement**: Built-in `pg_background.max_workers` GUC limits concurrent workers per session.

```sql
-- Limit to 10 concurrent workers per session
SET pg_background.max_workers = 10;
```

**Remaining Limitation**: No per-user or per-database quotas across sessions.

**Workaround**: Implement application-level quotas for cross-session limits (see [Security](#security-model)).

### 4. Worker Exhaustion (INSUFFICIENT_RESOURCES)

**Limitation**: When `max_worker_processes` is exhausted, `pg_background_launch()` and `pg_background_launch_v2()` throw `INSUFFICIENT_RESOURCES`.

**Error Message**:
```
ERROR: could not register background process
HINT: You may need to increase max_worker_processes.
```

**Impact**: This is particularly problematic for **autonomous logging** use cases:
1. **Data Loss**: The message intended for logging is lost
2. **Cascading Failures**: The calling transaction may fail unexpectedly
3. **Unpredictable**: Failures occur sporadically under high load

**Why This Happens**: Background workers share the global `max_worker_processes` pool with:
- Parallel query workers (`max_parallel_workers`)
- Autovacuum workers (`autovacuum_max_workers`)
- Logical replication workers
- Custom background workers from other extensions

**Mitigation Strategies**:

1. **Increase worker pool** (reduces frequency, doesn't eliminate):
   ```sql
   ALTER SYSTEM SET max_worker_processes = 64;
   -- Requires PostgreSQL restart
   ```

2. **Implement retry with backoff**:
   ```sql
   BEGIN
     SELECT pg_background_launch_v2(...);
   EXCEPTION
     WHEN insufficient_resources THEN
       PERFORM pg_sleep(0.1);  -- Backoff
       -- Retry or fallback
   END;
   ```

3. **Fallback to synchronous execution** (for critical operations):
   ```sql
   EXCEPTION
     WHEN insufficient_resources THEN
       -- Execute synchronously as fallback
       INSERT INTO audit_log VALUES (...);
   END;
   ```

4. **Pre-check worker availability** (advisory, not guaranteed):
   ```sql
   SELECT count(*) < current_setting('max_worker_processes')::int
   FROM pg_stat_activity
   WHERE backend_type LIKE '%worker%';
   ```

5. **Reserve capacity** by setting conservative `pg_background.max_workers`:
   ```sql
   -- Leave headroom for other workers
   SET pg_background.max_workers = 8;  -- Even if pool is 64
   ```

**Recommendation**: For mission-critical logging, always implement a synchronous fallback. Autonomous transactions via pg_background are **best-effort**, not guaranteed.

**See Also**: [Autonomous Audit Logging](#2-autonomous-audit-logging) for robust implementation patterns.

### 4. Result Consumption is One-Time

**Limitation**: `result_v2()` can only be called **once** per handle.

**Reason**: Results streamed from DSM; no persistent storage.

**Workaround**: Use CTE or temporary table:
```sql
-- Store results in temp table
CREATE TEMP TABLE worker_output AS
  SELECT * FROM pg_background_result_v2(<pid>, <cookie>) AS (col text);

-- Query multiple times
SELECT * FROM worker_output WHERE col LIKE '%foo%';
SELECT count(*) FROM worker_output;
```

### 5. No Result Pagination

**Limitation**: Cannot retrieve results in chunks (all-or-nothing).

**Reason**: shm_mq is streaming; no cursor support.

**Impact**: Large result sets (> queue_size) may block worker.

**Workaround**:
- Increase `queue_size` parameter
- Use `LIMIT` in worker SQL
- Process results incrementally in launcher

### 6. Limited Observability

**Limitation**: `list_v2()` only shows workers in **current session**.

**Reason**: Hash table is session-local (not shared memory).

**Impact**: Cannot observe other sessions' workers.

**Workaround**: Query `pg_stat_activity`:
```sql
SELECT
  pid,
  backend_type,
  state,
  query,
  backend_start
FROM pg_stat_activity
WHERE backend_type LIKE '%background%';
```

### 7. No Transaction Pinning

**Limitation**: Worker transactions are **fully autonomous** (cannot join launcher's transaction).

**Reason**: PostgreSQL does not support distributed transactions.

**Impact**: Cannot implement 2PC-like patterns natively.

**Workaround**: Use `dblink` with `PREPARE TRANSACTION` for XA-like semantics.

---

## Best Practices

### 1. Always Use v2 API in Production

✅ **Correct**:
```sql
SELECT * FROM pg_background_launch_v2('...') AS h \gset
SELECT pg_background_result_v2(:'h.pid', :'h.cookie');
```

❌ **Avoid**:
```sql
SELECT pg_background_launch('...') AS pid \gset  -- No PID reuse protection
SELECT pg_background_result(:pid);
```

### 2. Set Timeouts for All Workers

```sql
-- Database-wide default
ALTER DATABASE production SET statement_timeout = '10min';

-- Or per-worker
SELECT pg_background_launch_v2($$
  SET statement_timeout = '5min';
  SELECT slow_query();
$$);
```

### 3. Use submit_v2() for Fire-and-Forget

```sql
-- ✅ Idiomatic: submit + detach
SELECT * FROM pg_background_submit_v2('INSERT INTO log ...') AS h \gset;
SELECT pg_background_detach_v2(:'h.pid', :'h.cookie');

-- ❌ Verbose: launch + detach without result retrieval
SELECT * FROM pg_background_launch_v2('INSERT INTO log ...') AS h \gset;
SELECT pg_background_detach_v2(:'h.pid', :'h.cookie');
```

### 4. Monitor Worker State Regularly

```sql
-- Scheduled cleanup of stale workers
CREATE OR REPLACE FUNCTION cleanup_stale_workers()
RETURNS void AS $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT *
    FROM pg_background_list_v2() AS (
      pid int4, cookie int8, launched_at timestamptz, user_id oid,
      queue_size int4, state text, sql_preview text, last_error text, consumed bool
    )
    WHERE state IN ('stopped', 'error')
      AND (now() - launched_at) > interval '1 hour'
  LOOP
    PERFORM pg_background_detach_v2(r.pid, r.cookie);
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Run periodically
SELECT cleanup_stale_workers();
```

### 5. Sanitize All Dynamic SQL

```sql
-- ✅ Safe: Use format() with %L
CREATE FUNCTION safe_worker(table_name text) RETURNS void AS $$
BEGIN
  PERFORM pg_background_launch_v2(
    format('VACUUM %I', table_name)  -- %I for identifiers
  );
END;
$$ LANGUAGE plpgsql;
```

### 6. Handle Errors Gracefully

```sql
DO $$
DECLARE
  h pg_background_handle;
  result_val text;
BEGIN
  SELECT * INTO h FROM pg_background_launch_v2('SELECT 1/0');
  
  BEGIN
    SELECT * INTO result_val FROM pg_background_result_v2(h.pid, h.cookie) AS (r text);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Worker failed: %', SQLERRM;
    -- Cleanup
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
  END;
END;
$$;
```

### 7. Document Worker Purpose

```sql
-- ✅ Good: Clear intent
SELECT * FROM pg_background_launch_v2($$
  /* Background VACUUM for nightly maintenance */
  VACUUM (VERBOSE, ANALYZE) user_activity;
$$) AS h \gset;

-- Comment visible in list_v2() sql_preview
```

### 8. Test Disaster Recovery

Ensure application handles:
- PostgreSQL restart (all workers lost)
- Worker crashes (orphaned handles)
- Launcher session termination (workers detached)

```sql
-- Simulate crash: check handle invalidation
SELECT * FROM pg_background_launch_v2('SELECT pg_sleep(100)') AS h \gset;
-- Restart PostgreSQL
SELECT pg_background_wait_v2(:'h.pid', :'h.cookie');  -- Should error gracefully
```

---

## Migration Guide

### Upgrading from v1.7 to v1.8

```sql
ALTER EXTENSION pg_background UPDATE TO '1.8';
```

**New Features**:
- ✅ `pg_background_stats_v2()` - Session statistics
- ✅ `pg_background_progress()` - Worker progress reporting
- ✅ `pg_background_get_progress_v2()` - Get worker progress
- ✅ GUCs: `max_workers`, `worker_timeout`, `default_queue_size`
- ✅ Built-in max workers enforcement
- ✅ Enhanced robustness (overflow protection, UTF-8 truncation)

**Action Items**:
1. Review new GUC settings and configure as needed
2. Consider using progress reporting for long-running workers
3. Use `stats_v2()` for monitoring

### Upgrading from v1.6 to v1.7

```sql
ALTER EXTENSION pg_background UPDATE TO '1.7';
```

**Changes**:
- ✅ Cryptographically secure cookie generation
- ✅ Dedicated memory context (prevents session bloat)
- ✅ Exponential backoff polling (reduces CPU usage)
- ✅ **FIX: Custom schema installation support** (`CREATE EXTENSION ... WITH SCHEMA`)
- ⚠️ No breaking changes

**Custom Schema Support**: Prior to v1.7, installing the extension in a custom schema would fail with `function public.grant_pg_background_privileges does not exist`. This has been fixed by removing hardcoded schema prefixes (PostgreSQL automatically places objects in the target schema for relocatable extensions) and using dynamic schema lookup in privilege helper functions.

> **⚠️ Important Upgrade Note**: Custom schema support is only available for **fresh installs** of v1.7+. If you have an existing installation of v1.4, v1.5, or v1.6, the extension was installed in the `public` schema (older versions did not support custom schemas). Upgrading from these versions will keep the extension in the `public` schema because the upgrade scripts contain hardcoded `public.` references.
>
> **To move an existing installation to a custom schema:**
> ```sql
> -- 1. Drop the existing extension (preserves your data tables)
> DROP EXTENSION pg_background;
>
> -- 2. Create target schema if needed
> CREATE SCHEMA IF NOT EXISTS myschema;
>
> -- 3. Reinstall in custom schema
> CREATE EXTENSION pg_background WITH SCHEMA myschema;
> ```

### Upgrading from v1.5 to v1.6

```sql
ALTER EXTENSION pg_background UPDATE TO '1.6';
```

**Changes**:
- ✅ v1 API unchanged (fully backward compatible)
- ✅ New v2 API functions added
- ✅ `pgbackground_role` created automatically
- ✅ Hardened privilege helpers added
- ⚠️ No breaking changes

**Action Items**:
1. Review privilege grants (v1.6 revokes PUBLIC access)
2. Grant `pgbackground_role` to application users
3. Migrate v1 API calls to v2 in new code

### Upgrading from v1.0-v1.4

```sql
-- Multi-hop upgrade path
ALTER EXTENSION pg_background UPDATE TO '1.4';
ALTER EXTENSION pg_background UPDATE TO '1.6';
```

**Breaking Changes**:
- v1.4: Removed PostgreSQL 9.x support
- v1.5: Changed DSM lifecycle (no functional API changes)
- v1.6: Revoked PUBLIC access (requires explicit grants)

**Action Items**:
1. Test on non-production first
2. Audit existing privilege grants
3. Update application code to use v2 API

### Migrating from v1 to v2 API

| v1 API | v2 API Equivalent |
|--------|-------------------|
| `pg_background_launch(sql)` | `pg_background_launch_v2(sql)` (returns handle) |
| `pg_background_result(pid)` | `pg_background_result_v2(pid, cookie)` |
| `pg_background_detach(pid)` | `pg_background_detach_v2(pid, cookie)` |
| N/A | `pg_background_submit_v2(sql)` (fire-forget) |
| N/A | `pg_background_cancel_v2(pid, cookie)` |
| N/A | `pg_background_wait_v2(pid, cookie)` |
| N/A | `pg_background_list_v2()` |

**Example Migration**:

Before (v1):
```sql
SELECT pg_background_launch('VACUUM my_table') AS pid \gset
SELECT pg_background_detach(:pid);
```

After (v2):
```sql
SELECT * FROM pg_background_submit_v2('VACUUM my_table') AS h \gset;
SELECT pg_background_detach_v2(:'h.pid', :'h.cookie');
```

---

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for:
- Code of conduct
- Development setup
- Coding standards (PostgreSQL style, `pgindent`)
- Testing requirements
- Pull request process

**Quick Start**:
```bash
git clone https://github.com/vibhorkum/pg_background.git
cd pg_background
make clean && make && sudo make install
make installcheck
```

**Before Submitting PR**:
- [ ] Code follows PostgreSQL conventions
- [ ] Regression tests added/updated
- [ ] Tests pass (`make installcheck`)
- [ ] No compiler warnings
- [ ] Documentation updated

---

## License

PostgreSQL License

See [LICENSE](LICENSE) for full text.

---

## Author

**Vibhor Kumar** – Original author and maintainer

**Inspiration**:
- PostgreSQL Background Worker API
- `dblink` extension
- Oracle DBMS_JOB

---

## Related Projects

- **[pg_cron](https://github.com/citusdata/pg_cron)** – Schedule periodic jobs  
- **[dblink](https://www.postgresql.org/docs/current/dblink.html)** – Cross-database/async queries  
- **[pgAgent](https://www.pgagent.org/)** – Job scheduler daemon  
- **[pg_task](https://github.com/RekGRpth/pg_task)** – Task queue extension  

---

**Production Deployments**: For critical workloads, always:
1. Use **v2 API exclusively** (cookie-protected handles)
2. Set **statement_timeout** on all workers
3. **Monitor** `pg_background_list_v2()` and `pg_stat_activity`
4. **Test** disaster recovery scenarios (restarts, crashes)
5. **Audit** privilege grants regularly

**Version**: 1.8
**Last Updated**: 2026-02-18
**Minimum PostgreSQL**: 14
**Tested Through**: PostgreSQL 18
