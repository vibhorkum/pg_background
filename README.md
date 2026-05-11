# pg_background: Production-Grade Background SQL for PostgreSQL

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14--18-blue.svg)](https://www.postgresql.org/)
[![Version](https://img.shields.io/badge/version-2.0-brightgreen.svg)](https://github.com/vibhorkum/pg_background)
[![License](https://img.shields.io/badge/license-PostgreSQL-green.svg)](LICENSE)
[![CI](https://github.com/vibhorkum/pg_background/actions/workflows/ci.yml/badge.svg)](https://github.com/vibhorkum/pg_background/actions/workflows/ci.yml)

Execute arbitrary SQL commands in **background worker processes** within PostgreSQL. Built for production workloads requiring asynchronous execution, autonomous transactions, and long-running operations without blocking client sessions.

### 30-second tour

```sql
CREATE EXTENSION pg_background;

-- Simplest case: run something in an autonomous transaction, get the outcome.
SELECT completed, has_error, sqlstate, error_message, row_count, command_tag, elapsed_ms
  FROM pg_background_run_v2(
         'INSERT INTO audit_log (ts, who) VALUES (now(), current_user)',
         queue_size := 0,
         timeout_ms := 30000,
         label      := 'audit-login'
       );

-- See every worker tracked by this session.
SELECT pid, state, label, sql_preview FROM pg_background_list;
```

When you need the actual result rows, swap `run_v2` for the
`launch_v2 → wait_v2 → result_v2` pattern shown in [Quick Start](#quick-start)
or [Cookbook recipe 2](#cookbook).

**Where to go next**

| If you want to… | Read |
|---|---|
| See it in 5 minutes | [Quick Start](#quick-start) |
| Copy a working pattern | [Cookbook](#cookbook) — three battle-tested templates |
| Look up a function | [API Reference](#complete-api-reference) |
| Understand the `cancel` vs `detach` distinction | [Critical Semantic Distinctions](#critical-semantic-distinctions) |
| Decide whether this fits your problem | [When to use this — and when not to](#when-to-use-this--and-when-not-to) |

---

## Table of Contents

- [Overview](#overview)
- [When to use this — and when not to](#when-to-use-this--and-when-not-to)
- [Architecture (at a glance)](#architecture-at-a-glance) · deep dive: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [Key Features](#key-features)
- [PostgreSQL Version Compatibility](#postgresql-version-compatibility)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Complete API Reference](#complete-api-reference)
- [Critical Semantic Distinctions](#critical-semantic-distinctions)
  - Cancel vs Detach · V1 vs V2 (v1 removed in 2.0) · PID reuse · NOTIFY semantics
- [Security Model](#security-model)
- [Operational Guidance](#operational-guidance)
- [Troubleshooting](#troubleshooting)
- [Known Limitations](#known-limitations)
- [Best Practices](#best-practices)
- [Cookbook](#cookbook--see-docscookbookmd) — full content in [`docs/COOKBOOK.md`](docs/COOKBOOK.md)
- [Migration Guide](#migration-guide--see-docsmigrationmd) — full content in [`docs/MIGRATION.md`](docs/MIGRATION.md)
- [Testing](#testing)
- [Contributing](#contributing) · [License](#license) · [Author](#author)

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

## When to use this — and when not to

### Good fit ✅
- **Autonomous transactions** — log audit events, send notifications, or update counters that must commit even if the parent transaction rolls back.
- **Ad-hoc async maintenance** — kick off a `VACUUM`, `REINDEX`, or backfill from a SQL session without blocking it.
- **Pre-known fan-out** — split a workload into N independent SQL statements and gather their outcomes (see [Cookbook recipe 3](#cookbook)).
- **Bounded long-running queries** with a deadline — `pg_background_run_v2(sql, queue_size, timeout_ms, label)` gives you a single SQL call with timeout and cancel-on-overrun.

### Not a fit ❌
| You want… | Use instead |
|---|---|
| A cron-style job scheduler | [`pg_cron`](https://github.com/citusdata/pg_cron) |
| Cross-server SQL execution | `dblink` or `postgres_fdw` |
| Cross-database execution | Workers are per-database; use `dblink` from inside a worker if you must |
| Workflow orchestration with retries / DAGs | An application-layer job runner |
| Persistent job queue with state across restarts | A real queue (Redis, RabbitMQ) or table-backed queue with explicit polling |
| Result caching / re-fetching | Workers stream results once; persist them to a table yourself |

`pg_background` provides primitives, not orchestration. If you need durable queueing, retries, scheduling, or coordination across sessions, build it on top — or use a tool that specializes in it.

### Side-by-side: `pg_background` vs neighboring tools

A 30-second decision table. Pick the row that matches your job, not the column you've used before.

| Capability | `pg_background` | `pg_cron` | `dblink` | `postgres_fdw` |
|---|---|---|---|---|
| Run SQL **in the background**, in the same db, in its own transaction | ✅ | ❌ runs on a schedule | ❌ runs in caller's flow | ❌ runs in caller's flow |
| **Autonomous transactions** (commit independently of caller) | ✅ | ✅ | ✅ (separate connection) | ❌ |
| **Scheduled / cron-style** execution | ❌ | ✅ | ❌ | ❌ |
| Run SQL on a **different host** | ❌ | ❌ | ✅ | ✅ |
| Run SQL in a **different database** of same cluster | ❌ | ✅ (per-db jobs) | ✅ | ✅ |
| **Cookie-protected** lifecycle (cancel/wait/list with PID-reuse safety) | ✅ | ❌ | ❌ | ❌ |
| **Structured error returns** (real SQLSTATE + detail/hint/context) | ✅ | partial | partial | partial |
| Persistent job state / **survives restart** | ❌ session-local | ✅ | ❌ | ❌ |
| **DAG / retry / dependency** orchestration | ❌ | ❌ | ❌ | ❌ |

**Common patterns**

- **Audit logging that must commit even on rollback** → `pg_background_run_v2` with `submit_v2`-style fire-and-forget. Don't use `dblink` (callable but heavier per call).
- **Nightly maintenance at 02:00** → `pg_cron`. Don't use `pg_background` (no scheduler).
- **Read from another host's table** → `postgres_fdw`. Don't use `pg_background` (single-host).
- **Synchronous fan-out: launch N updates, wait for all** → `pg_background_drain_v2`. Don't use `dblink` (no batch primitive).
- **Cancel a long-running job from another session** — none of these tools is great. `pg_background_cancel_v2` works but only from the launching session today; cluster-wide cancel needs a manual `pg_cancel_backend` against the worker PID.

---

## Architecture (at a glance)

The launcher allocates a DSM segment, registers a dynamic background
worker, and waits for it to attach a shared-memory queue. The worker
restores the launcher's GUCs, runs the SQL via SPI, streams rows back
through the queue, and writes structured metadata (row count, command
tag, error fields) into a launcher-readable struct in DSM. The
launcher consumes rows via `pg_background_result_v2` and tears down
through `pg_background_detach_v2`; an `on_dsm_detach` callback ensures
leaks are impossible even on abnormal exit.

The full sequence diagram, TOC layout, concurrency-race history, and
publish-flag patterns are in **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)**.

---

## Key Features

### Core capabilities
- **Async SQL execution** — offload queries to background workers running inside the server
- **Autonomous transactions** — workers commit (or roll back) independently of the caller
- **Explicit lifecycle** — `launch`, `wait`, `cancel`, `detach`, and `list` operations with documented semantics
- **Cookie-protected handles** — `(pid, cookie)` tuples prevent PID-reuse confusion in long-lived sessions
- **Structured error reporting** — real `SQLSTATE`, message, detail, hint, and context propagated from worker to launcher
- **Observability built in** — per-session worker registry (`pg_background_list`), counters (`pg_background_stats_v2`), progress reporting, optional labels
- **Hardened security** — NOLOGIN executor role, no PUBLIC grants, privilege helpers with pinned `search_path`
- **Relocatable** — `CREATE EXTENSION pg_background WITH SCHEMA myschema` works fully

### What's new in v2.0 (major release)

**Breaking changes** — see [`docs/MIGRATION.md`](docs/MIGRATION.md) for the full upgrade path:

- The v1 API (`pg_background_launch`, `pg_background_result`, `pg_background_detach` — no `_v2` suffix) was **removed**. Use the cookie-protected v2 API.
- `pg_background_cancel_v2_grace` and `pg_background_wait_v2_timeout` were **collapsed** into the base functions with a third `grace_ms` / `timeout_ms` argument that defaults to 0.
- `pg_background_wait_v2` now returns `bool` (was `void`); `timeout_ms <= 0` blocks indefinitely (matches the 1.x default), `> 0` waits up to N ms.
- `pg_background_status_v2` was removed — call `to_jsonb(pg_background_outcome_v2(...))` directly.
- `pg_background_progress` (function) renamed to **`pg_background_report_progress_v2`**; type `pg_background_progress` renamed to **`pg_background_progress_info`**.
- Privilege helpers renamed: **`pg_background_grant_privileges_v2`** / **`pg_background_revoke_privileges_v2`**.

**Forward-compatibility additions** — adding columns later is painful, so 2.0 widens the composite types now:

- `pg_background_stats` gains `workers_timed_out int8` (separate from `workers_canceled`; bumped by `pg_background_run_v2` on timeout).
- `pg_background_result_info` gains `started_at`, `finished_at` (timestamptz) — the worker writes these around its SPI loop.
- `pg_background_error` gains `schema_name`, `table_name`, `column_name`, `constraint_name` — sourced from PG's `edata` for heap/access errors.
- `pg_background_run_result` now **extends** `pg_background_outcome` (gains `cookie`, `state`, `consumed`, `label`, `launched_at`) plus `timed_out` + `elapsed_ms`. No more duplicate column shape.

**Internal**: 2.0 prunes pre-1.8 upgrade scripts (`extension/legacy/` is gone). Anyone on a pre-1.8 install must reach 1.8 against the 1.10 release line first.

### Earlier milestones

- **v1.10**: `pg_background_list` / `pg_background_activity` views; `pg_background_outcome_v2` (never-raises status snapshot); `pg_background_run_v2` synchronous one-shot.
- **v1.9**: worker labels, structured errors (`pg_background_error_info_v2`), result metadata (`pg_background_result_info_v2`), batch ops (`detach_all_v2`, `cancel_all_v2`).
- **v1.8**: session statistics, progress reporting, GUCs (`pg_background.max_workers`, `default_queue_size`, `worker_timeout`).
- **v1.6**: cryptographically secure cookies for PID-reuse protection.

The full chain is documented in [`docs/MIGRATION.md`](docs/MIGRATION.md).

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
--  pg_background | 1.10
```

### Library Loading

`pg_background` does **not** require `shared_preload_libraries`. Workers are
registered dynamically (`RegisterDynamicBackgroundWorker`) and each worker
process loads the library dynamically when it starts.

Adding `pg_background` to `shared_preload_libraries` is **optional** and only
needed if you want the extension's GUC parameters
(`pg_background.max_workers`, `pg_background.default_queue_size`,
`pg_background.worker_timeout`) available in `postgresql.conf` and visible in
all sessions from the start. Without SPL, the GUCs are registered on first
use (`CREATE EXTENSION`, `LOAD`, or the first `launch_v2` call). A session
`SET` before that point raises an `unrecognized configuration parameter`
error. The warning behavior applies to configuration file entries (for
example, `postgresql.conf` or `ALTER SYSTEM`) that are read before the
library is loaded.

| | Without SPL | With SPL |
|---|---|---|
| Extension works? | Yes | Yes |
| GUCs in `postgresql.conf` | Not until first load | Immediately |
| After `make install` | Workers pick up new `.so` automatically | **Restart required** (postmaster caches the library) |
| Recommended for | Development, staging, simple setups | Production with tuned GUCs |

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
--  pg_background | 1.10       | contrib
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
SELECT contrib.pg_background_grant_privileges_v2('app_user', true);

-- Or if schema is in search_path
SELECT pg_background_grant_privileges_v2('app_user', true);
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
SELECT test_schema.pg_background_grant_privileges_v2('test_user', true);
-- Should output GRANT statements with test_schema prefix

-- Test 5: Revoke privileges
SELECT test_schema.pg_background_revoke_privileges_v2('test_user', true);

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

The v2 API provides cookie-based handle protection and explicit lifecycle semantics. If you only ever read one section, **use `pg_background_run_v2()`** (item 0 below) — it covers the common case in one SQL call.

#### 0. Easiest path: synchronous one-shot (`pg_background_run_v2`)

Use this when you want autonomous-transaction semantics and just need to know whether the SQL succeeded, how many rows it affected, and the SQLSTATE if it failed. Returns metadata only — no result rows.

```sql
SELECT completed, has_error, sqlstate, error_message,
       row_count, command_tag, elapsed_ms, timed_out
  FROM pg_background_run_v2(
         'INSERT INTO audit_log (ts, who) VALUES (now(), current_user)',
         queue_size := 0,
         timeout_ms := 30000,         -- 30 s cap; cancels with 1 s grace on overrun
         label      := 'audit-login'
       );

-- completed | has_error | sqlstate | error_message | row_count | command_tag | elapsed_ms | timed_out
-- t         | f         | NULL     | NULL          | 1         | INSERT 0 1  | 14         | f
```

When you actually need **result rows**, use the launch + wait + result_v2 pattern (items 1, 2, 5 below) or jump straight to [Cookbook recipe 2](#cookbook).

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
-- ERROR:  PID 12345 is not attached to this session
-- (auto-detach happens after the first successful consumption)
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
SELECT pg_background_cancel_v2(pid, cookie, 500);
```

⚠️ **Windows Limitation**: Cancel on Windows only sets interrupts; it cannot terminate an actively running statement. Always use `statement_timeout` on Windows.

#### 5. Wait for Completion

```sql
-- Block until worker finishes
SELECT pg_background_wait_v2(pid, cookie);

-- Or wait with timeout (returns true if completed)
SELECT pg_background_wait_v2(pid, cookie, 5000);  -- 5 seconds
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


## Complete API Reference

### V2 Functions

| Function | Returns | Description | Use Case |
|----------|---------|-------------|----------|
| `pg_background_launch_v2(sql, queue_size, label)` | `pg_background_handle` | Launch worker with optional label (v1.9) | Standard async execution |
| `pg_background_submit_v2(sql, queue_size, label)` | `pg_background_handle` | Fire-and-forget with optional label (v1.9) | Side-effect queries |
| `pg_background_result_v2(pid, cookie)` | `SETOF record` | Retrieve results (**one-time consumption**) | Collect query output |
| `pg_background_result_info_v2(pid, cookie)` | `pg_background_result_info` | Get result metadata (v1.9) | Check completion without consuming |
| `pg_background_error_info_v2(pid, cookie)` | `pg_background_error` | Get structured error details (v1.9) | Error diagnostics |
| `pg_background_detach_v2(pid, cookie)` | `void` | Stop tracking worker (worker continues) | Cleanup bookkeeping |
| `pg_background_detach_all_v2()` | `int4` | Detach all workers in session (v1.9) | Session cleanup |
| `pg_background_cancel_v2(pid, cookie, grace_ms DEFAULT 0)` | `void` | Cancel via SIGTERM (`grace_ms=0`) or SIGTERM + grace + SIGKILL (`grace_ms>0`, capped at 3600000) | Terminate unwanted work |
| `pg_background_cancel_all_v2()` | `int4` | Cancel all workers in session (v1.9) | Emergency cleanup |
| `pg_background_wait_v2(pid, cookie, timeout_ms DEFAULT 0)` | `bool` | `timeout_ms<=0` blocks indefinitely (returns `true`); `>0` waits up to N ms (returns `true` if stopped, `false` on timeout) | Synchronous barrier / bounded wait |
| `pg_background_list_v2()` | `SETOF record` | List known workers in current session (column-definition list required) | Internal — prefer the view below |
| `pg_background_stats_v2()` | `pg_background_stats` | Session statistics | Monitoring, debugging |
| `pg_background_report_progress_v2(pct, msg)` | `void` | Report progress from worker (v2.0 rename of `pg_background_progress`) | Long-running task feedback |
| `pg_background_get_progress_v2(pid, cookie)` | `pg_background_progress_info` | Get worker progress | Monitor long-running tasks |
| `pg_background_outcome_v2(pid, cookie)` | `pg_background_outcome` | Combined status snapshot — never raises | Safe status retrieval |
| `pg_background_run_v2(sql, queue_size, timeout_ms, label)` | `pg_background_run_result` | Synchronous one-shot: launch + wait + outcome + detach | Autonomous-transaction-style runs |
| `pg_background_list` (view) | rows of `list_v2()` | Convenience view; no column-definition list required | Day-to-day observation |
| `pg_background_activity` (view) | join with `pg_stat_activity` | Worker registry + backend state in one query | Combined monitoring |
| `pg_background_full_sql_v2(pid, cookie)` | `text` | Full SQL the worker is running (capped at 64 KiB) | Debugging beyond the 120-char `sql_preview` |

**Tier A "loop killers"** — convenience helpers built on the v2 primitives:

| Function | Returns | Description |
|---|---|---|
| `pg_background_run_query_v2(sql, queue_size, timeout_ms, label, col_def)` | `SETOF record` | Synchronous launch + wait + result + detach with rows; `col_def` matches the AS clause at the call site |
| `pg_background_drain_v2(handles, timeout_ms)` | `SETOF pg_background_outcome` | Wait for every handle (shared wall-clock budget), collect outcomes, detach |
| `pg_background_wait_any_v2(handles, timeout_ms)` | `pg_background_handle` | Return the first handle to finish (50–500 ms adaptive polling); NULL on timeout |
| `pg_background_cancel_by_label_v2(pattern, grace_ms)` | `int4` | Cancel every worker whose label matches the SQL `LIKE` pattern; returns count |
| `pg_background_purge_v2()` | `int4` | Detach only workers that have already stopped (vs `detach_all_v2` which is unconditional) |

**Parameters**:
- `sql`: SQL command(s) to execute (multiple statements allowed)
- `queue_size`: Shared memory queue size in bytes (default: 65536, min: 4096)
- `pid`: Process ID from handle
- `cookie`: Unique identifier from handle (prevents PID reuse)
- `label`: Optional worker label for identification (v1.9, default: NULL)
- `grace_ms`: Milliseconds to wait before forceful termination (capped at 1 hour)
- `timeout_ms`: Milliseconds to wait for completion

**Handle Type**:
```sql
CREATE TYPE pg_background_handle AS (
  pid    int4,   -- Process ID
  cookie int8    -- Unique identifier (prevents PID reuse)
);
```

**Statistics Type**:
```sql
CREATE TYPE pg_background_stats AS (
  workers_launched   int8,    -- Total workers launched this session
  workers_completed  int8,    -- Workers completed successfully
  workers_failed     int8,    -- Workers that failed with error
  workers_canceled   int8,    -- Workers explicitly canceled (v1.9)
  workers_timed_out  int8,    -- Workers canceled by run_v2 timeout (v2.0)
  workers_active     int4,    -- Currently active workers
  avg_execution_ms   float8,  -- Average execution time
  max_workers        int4     -- Current max_workers setting
);
```

**Progress Type** (v2.0 renamed from `pg_background_progress`):
```sql
CREATE TYPE pg_background_progress_info AS (
  progress_pct  int4,   -- Progress percentage (0-100)
  progress_msg  text    -- Brief status message
);
```

**Result Info Type** (v1.9+):
```sql
CREATE TYPE pg_background_result_info AS (
  row_count    int8,    -- Number of rows returned/affected
  command_tag  text,    -- Command tag (SELECT, INSERT, etc.)
  completed    bool,    -- True if worker completed
  has_error    bool     -- True if SQL execution error was captured
);
```

> **Note**: `has_error` indicates SQL execution errors captured through structured error reporting. Early worker failures (e.g., resource exhaustion, connection issues) before SQL execution begins do not set this flag. The combination of `completed=true`, `has_error=false`, and `error_info_v2() IS NULL` indicates likely success, but does not guarantee the worker completed without infrastructure-level failures.

**Error Type** (v1.9+):
```sql
CREATE TYPE pg_background_error AS (
  sqlstate  text,   -- SQLSTATE error code (e.g., '23505')
  message   text,   -- Primary error message
  detail    text,   -- Detailed error info (if any)
  hint      text,   -- Hint for resolution (if any)
  context   text    -- Error context/stack trace
);
```

**Outcome Type** (v1.10+):
```sql
CREATE TYPE pg_background_outcome AS (
  pid            int4,
  cookie         int8,
  state          text,         -- starting/running/stopped/canceled/error (NULL if not in this session)
  consumed       bool,
  completed      bool,         -- from result_info_v2
  has_error      bool,         -- from result_info_v2
  row_count      int8,         -- from result_info_v2
  command_tag    text,         -- from result_info_v2
  sqlstate       text,         -- from error_info_v2
  error_message  text,         -- from error_info_v2.message
  label          text,
  launched_at    timestamptz
);
```

`pg_background_outcome_v2()` populates this snapshot by combining
`pg_background_list_v2`, `pg_background_result_info_v2`, and
`pg_background_error_info_v2`. It catches all exceptions internally and leaves
unavailable fields NULL — handy after `result_v2` has consumed results, after a
worker has been cleaned up, or when you simply do not want to write three
nested `BEGIN ... EXCEPTION` blocks.

**Run Result Type** (v1.10+):
```sql
CREATE TYPE pg_background_run_result AS (
  pid             int4,
  completed       bool,
  timed_out       bool,
  has_error       bool,
  row_count       int8,
  command_tag     text,
  sqlstate        text,
  error_message   text,
  elapsed_ms      int8
);
```

`pg_background_run_v2(sql, queue_size, timeout_ms, label)` runs a single SQL
command in a worker, waits up to `timeout_ms` (0 = wait forever), cancels the
worker with 1 s grace if it does not finish in time, gathers the outcome, and
detaches the handle. It returns metadata only — no result rows. Use the
launch/wait/result_v2 pattern (see [Cookbook recipe 2](#cookbook)) when you
need result rows.

#### Structured Error Returns — SQLSTATE Semantics

`pg_background_error_info_v2(pid, cookie)` returns the **real** five-character
`SQLSTATE` emitted by the worker's failed statement, not a synthesized
`08006 "lost connection to worker process"`. The worker's `PG_CATCH` handler
copies `ErrorData` from the caught `ereport(ERROR)`, stores the fields in DSM
(with `error_sqlstate` written last as a publish flag) and calls
`EmitErrorReport()` + `ReadyForQuery(DestRemote)` + `pq_flush()` so the launcher
sees the actual `'E'` error frame over `shm_mq`.

Typical codes returned end-to-end (v1.9+):

| Trigger SQL                                      | Returned `sqlstate` | Path            |
|--------------------------------------------------|---------------------|-----------------|
| `SELECT 1/0`                                     | `22012`             | execute         |
| `RAISE EXCEPTION 'custom error'`                 | `P0001`             | execute         |
| `INSERT NULL` into `NOT NULL` column             | `23502`             | execute         |
| `INSERT` violating `INITIALLY DEFERRED` FK       | `23503`             | commit          |
| `pg_background_cancel_v2()` during `pg_sleep()`  | `57014`             | execute         |

**Recommended pattern**: call `error_info_v2` from the same PL/pgSQL
`EXCEPTION` block that observes the failure. Once the launcher's transaction
aborts, `cleanup_worker_info` removes the hash entry and the next transaction
will see `ERRCODE_UNDEFINED_OBJECT` ("PID N is not attached to this session").

```sql
DO $$
DECLARE
    h pg_background_handle;
    s text;
BEGIN
    h := pg_background_launch_v2('SELECT 1/0');
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    SELECT sqlstate INTO s
      FROM pg_background_error_info_v2(h.pid, h.cookie);
    RAISE NOTICE 'worker sqlstate=%', s;   -- 22012
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
END$$;
```

> **Important — do not call `result_v2()` on an error path.** `result_v2()`
> re-raises the worker's error in the launcher via `ereport(ERROR)`, which
> aborts the current transaction and triggers `cleanup_worker_info` before you
> can inspect `error_info_v2()`. For error diagnosis, the supported pattern is
> `launch_v2 -> wait_v2 -> error_info_v2 -> detach_v2` (no `result_v2`).

> **`08006` is now reserved for infra-level failures only.** The launcher
> synthesizes `ERRCODE_CONNECTION_FAILURE "lost connection to worker process"`
> only when the worker died before it could propagate a real error (see
> [Known Limitations — Early worker failures](#9-early-worker-failures-before-pq_redirect_to_shm_mq)).
> Under normal operation, any SQL-level error inside the worker surfaces as
> the concrete SQLSTATE shown in the table above.

### Deployment Order

The fix for end-to-end SQLSTATE propagation lives in the compiled
`pg_background.so`. Whether a server restart is required depends on how the
library is loaded (see [Library Loading](#library-loading)):

- **With `shared_preload_libraries`**: the postmaster dlopens the library
  once at startup and every forked background worker inherits the cached
  handle. After replacing the `.so` on disk you must restart PostgreSQL —
  a plain `pg_reload_conf()` is not sufficient.
- **Without SPL** (the default): each background worker dlopens the library
  in its own process, so a fresh `pg_background_launch_v2(...)` call picks
  up the new binary automatically. No server restart is needed; at most,
  reconnect long-lived client sessions.

1. Build and install: `make clean && make && sudo make install`.
2. **Reload the library:**
   - SPL setup → `pg_ctl restart` / systemd / platform equivalent.
   - On-demand setup → no action required (optionally reconnect clients).
3. Verify on staging that real SQLSTATEs propagate:
   ```sql
   DO $$
   DECLARE h pg_background_handle; s text;
   BEGIN
       h := pg_background_launch_v2('SELECT 1/0');
       PERFORM pg_background_wait_v2(h.pid, h.cookie);
       SELECT sqlstate INTO s FROM pg_background_error_info_v2(h.pid, h.cookie);
       ASSERT s = '22012', 'expected 22012, got ' || s;
       PERFORM pg_background_detach_v2(h.pid, h.cookie);
   END$$;
   ```
4. **Only after step 3 succeeds**, remove any PL/pgSQL workarounds that read
   `error_info_v2` as a fallback after catching `08006`. Before the fix ships
   they were the only way to get a usable SQLSTATE; after the fix they become
   dead code, but keeping them in place during the rollout is harmless.

### Rollback Order

To roll back to a pre-fix `.so` (for example if another extension in the same
image regresses):

1. **First** restore the PL/pgSQL workarounds in user code (they expect
   `SQLERRM` to degrade to `08006` and then read `error_info_v2` out of band).
2. **Only after step 1**, install the old `.so` and restart PostgreSQL.

Doing rollback in the reverse order (old `.so` first) causes user functions to
see raw `08006` errors without the fallback path, which can manifest as
`WHEN others` branches swallowing what used to be diagnosable SQLSTATEs.


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

### V1 → V2 (historical context)

The v1 API (bare `int4` PID, no cookie, no cancel/wait) was removed in
2.0. See [`docs/MIGRATION.md`](docs/MIGRATION.md) for the v1→v2 mapping
table and a port-this-into-that example.

### PID Reuse Protection

**The Problem**: Operating systems recycle process IDs. On busy systems, a PID can be reused within minutes.

**Pre-2.0 risk** (the deleted v1 API used a PID-only reference):
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
SELECT pg_background_grant_privileges_v2('app_user', true);
```

#### Revoke Access

```sql
-- Method 1: Revoke role membership
REVOKE pgbackground_role FROM app_user;

-- Method 2: Helper function
SELECT pg_background_revoke_privileges_v2('app_user', true);
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
  FROM pg_background_list
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

CREATE VIEW safe_worker_list AS
SELECT pid, cookie, state, consumed, launched_at
FROM pg_background_list
WHERE user_id = current_user::regrole::oid;
-- Omit sql_preview and last_error

GRANT SELECT ON safe_worker_list TO app_users;
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

## Use Cases — see the Cookbook

End-to-end examples (background maintenance, autonomous audit logging
with retry/fallback, async notification delivery, long-running ETL with
job tracking, parallel-query simulation, timeout enforcement) plus
quick-recipe templates live in **[`docs/COOKBOOK.md`](docs/COOKBOOK.md)**.


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
    FROM pg_background_list
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
FROM pg_background_list w
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
FROM pg_background_list
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
FROM pg_background_list
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
FROM pg_background_list w
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
SELECT pg_background_cancel_v2(<pid>, <cookie>, 5000);

-- Force cancel if grace period expires
SELECT pg_background_cancel_v2(<pid>, <cookie>);
```

#### Issue 4: "PID is not attached to this session" after a successful result

**Symptom**:
```
ERROR:  PID 12345 is not attached to this session
```

raised by `pg_background_result_v2(pid, cookie)` after a previous call
on the same handle returned rows successfully.

**Cause**: results are one-time consumption. The first successful
`result_v2` call auto-detaches the worker; the second call sees no
tracked entry for that PID and raises `ERRCODE_UNDEFINED_OBJECT`. Note:
this is the same SQLSTATE you'd get from a wrong PID, so the message is
worded the same.

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
ERROR: function public.pg_background_grant_privileges_v2(unknown, boolean) does not exist
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

#### Issue 7: "column definition list is required" / "rowtype does not match"

**Symptom**:
```
ERROR: function returning record called in context that cannot accept type record
HINT: Try calling the function in the FROM clause using a column definition list.

-- Or when columns don't match what the worker actually emitted:
ERROR: remote query result rowtype does not match the specified FROM clause rowtype
```

**Cause**: `pg_background_result_v2()` and `pg_background_list_v2()`
return `SETOF record`. PostgreSQL needs the row shape declared at parse
time, either via `AS (col1 type, col2 type, ...)` or by reading from a
view/wrapper that has a fixed row type.

**Solutions**:

```sql
-- Match the AS list to the worker's actual columns:
SELECT * FROM pg_background_result_v2(:pid, :cookie) AS (result text);
SELECT * FROM pg_background_result_v2(:pid, :cookie) AS (col1 text, col2 text);
```

If you only need to wait for completion (no rows), use `wait_v2`:

```sql
SELECT pg_background_wait_v2(:pid, :cookie);              -- block forever
SELECT pg_background_wait_v2(:pid, :cookie, 5000);        -- bounded
```

If you only need *metadata* (row count, command tag, error info), use
`pg_background_run_v2()` or `pg_background_outcome_v2()` — neither
requires a column-definition list.

For monitoring, prefer the **`pg_background_list`** view (introduced in
1.10) over `pg_background_list_v2()` directly — the view declares the
row type so callers don't have to.

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

**See**: `windows/ReadMe.md` for details.

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

## Architecture & Design — see docs/ARCHITECTURE.md

The deep architecture write-up (sequence diagram, DSM TOC layout,
key components, concurrency-race history, publish-flag patterns) is in
**[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)**.


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

**Reference**: See `windows/ReadMe.md` for implementation details.

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

### 5. Result Consumption is One-Time

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

### 6. No Result Pagination

**Limitation**: Cannot retrieve results in chunks (all-or-nothing).

**Reason**: shm_mq is streaming; no cursor support.

**Impact**: Large result sets (> queue_size) may block worker.

**Workaround**:
- Increase `queue_size` parameter
- Use `LIMIT` in worker SQL
- Process results incrementally in launcher

### 7. Limited Observability

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

### 8. No Transaction Pinning

**Limitation**: Worker transactions are **fully autonomous** (cannot join launcher's transaction).

**Reason**: PostgreSQL does not support distributed transactions.

**Impact**: Cannot implement 2PC-like patterns natively.

**Workaround**: Use `dblink` with `PREPARE TRANSACTION` for XA-like semantics.

### 9. Early Worker Failures (Before `pq_redirect_to_shm_mq`)

**Limitation**: Errors raised in the worker **before** `pq_redirect_to_shm_mq()`
installs the shm_mq destination cannot be captured as a structured error.

**What is "early"**: The small window between worker startup and the
`pq_redirect_to_shm_mq()` call in `pg_background_worker_main` — primarily:

- Failure to attach the DSM segment (`dsm_attach` returning NULL).
- `shm_toc_lookup` failure (missing TOC entry — implies an internally
  inconsistent DSM, typically a sign of server misconfiguration).
- Out-of-memory during the initial worker setup allocations.

**Observable behavior for the launcher**:

- `pg_background_result_v2()` raises `SQLSTATE 08006 "lost connection to
  worker process"` when it tries to read results from the detached shm_mq.
  `pg_background_wait_v2()` blocks on `WaitForBackgroundWorkerShutdown` and
  returns silently — it does not raise; the early worker exit leaves no
  structured error on the wire for it to observe.
- `pg_background_error_info_v2()` returns `NULL` row (no structured info).
- `pg_background_result_info_v2()` reports `completed=true, has_error=false`
  since the worker never got far enough to run SQL.

**Why it cannot be captured**: the worker's error-propagation contract
(`EmitErrorReport` over shm_mq, `ReadyForQuery(DestRemote)`, `pq_flush`)
requires the shm_mq destination to already be installed. Before
`pq_redirect_to_shm_mq`, `ereport(ERROR)` goes to the server log only; the
launcher observes the worker exit and synthesizes `08006`.

**Impact in practice**: these are infrastructure-level failures (DSM OOM,
misconfigured `dynamic_shared_memory_type`, missing `shm_toc` entry). They
are rare in a correctly configured server and do not indicate user-level SQL
problems.

**Recommended handling**: treat a `08006` from `pg_background_result_v2()`
as an infra signal — do not attempt to parse an `error_info_v2` row that may
be `NULL`. All ordinary SQL errors (syntax, constraint violation,
division-by-zero, `RAISE EXCEPTION`, statement cancel) propagate through the
normal path and appear as their real SQLSTATE, not `08006`.

### 10. Worker SIGSEGV in PG bgworker startup under concurrent cancel

**Limitation**: when several long-running workers are launched in close
succession in the same session and then cancelled concurrently (e.g. via
`pg_background_cancel_by_label_v2` against a label pattern matching ≥2
workers, especially with `grace_ms > 0`), one of the workers occasionally
dies with **signal 11 (SIGSEGV)**. PostgreSQL's postmaster sees the
abnormal exit and triggers a crash-recovery cycle, terminating the launcher
session.

**Diagnostic finding (2.0)**: the segfaulting worker emits **zero log
output** before dying — no `STATEMENT`, no `ERROR`, not even an early
`elog(LOG, ...)` placed at the very top of `pg_background_worker_main`.
That means the SIGSEGV occurs in PostgreSQL's background-worker startup
machinery, **before our `worker_main` runs and before
`pq_redirect_to_shm_mq` has installed the launcher-bound logging
destination**. We initially suspected a race in our `error_exit`; the
PGBG-DBG-instrumented run showed a working-but-canceled sibling worker
walking every `error_exit` stage cleanly while the dying worker emitted
nothing at all — so the bug is upstream of pg_background, in the PG
bgworker setup path that runs between postmaster fork and our entry point.

**Reproduction**: ~75% under the in-tree regression suite on PG 17 in
Docker with 2–4 concurrent `pg_sleep(60)` workers receiving SIGTERM in
close succession (the previous form of the `cancel_by_label_v2` test).
Single-worker `cancel_by_label_v2` does not reproduce.

**Defensive C-side fixes in 2.0** (section F): two unrelated cleanups in
`pg_background_worker_error_exit` that match PostgreSQL's standard error
handling pattern. They do not fix the SIGSEGV (it isn't in our code) but
they're real correctness improvements:
- Removed a `RESUME_INTERRUPTS()` before `proc_exit(1)` so a queued
  second-cancel cannot be dispatched into proc_exit's cleanup chain.
- Reordered to `EmitErrorReport → AbortCurrentTransaction → FlushErrorState`
  (was `emit → flush → abort`, which let abort callbacks fire into an
  empty error stack).

**Workarounds for callers**:
- Prefer `cancel_v2(pid, cookie, 0)` (immediate SIGTERM, no grace) followed
  by an explicit `wait_v2(pid, cookie, timeout_ms)` for a bounded wait.
- Stagger cancels: cancel one worker at a time rather than calling
  `cancel_by_label_v2` against a pattern matching many concurrent workers.
- Set `statement_timeout` on the worker SQL so it self-cancels rather than
  relying on cluster-side cancellation.

**Status / next steps**: settling this requires a core dump from a
reproduction (run with `ulimit -c unlimited`, install the dump path in
`/proc/sys/kernel/core_pattern`, and inspect with `gdb`). The frame at
the top of the stack will identify which PG infrastructure call SEGVs —
most likely `procsignal_sigusr1_handler`, `BackgroundWorkerInitializeConnection`,
or a `LWLock` access during early shared-memory setup, before our worker
has installed its own SIGTERM handler.


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

> **NOTIFY note for `submit_v2`**: NOTIFY frames raised inside a worker
> are forwarded to the launcher's protocol output only while the launcher
> is parked inside `pg_background_result_v2(...)`. A `submit_v2` worker
> never has a result reader, so any `NOTIFY` it emits is effectively
> dropped — the row hits the worker's transaction (`pg_listener` /
> `pg_notify_queue`) but the *message* on the wire is not relayed back to
> a session that called `LISTEN`. If a NOTIFY needs to reach a listening
> session, use `launch_v2` + `result_v2`, or write the notification to a
> table the listener polls.

### Worker GUC propagation

`pg_background_launch_v2` / `submit_v2` propagate the launching session's
**full** GUC state to the worker via `SerializeGUCState` (the same
mechanism PostgreSQL uses for parallel workers). The worker calls
`RestoreGUCState` at startup and inherits everything: `search_path`,
`statement_timeout`, `lock_timeout`, role-based settings, custom GUCs.
This is intentional, but it means session-local knobs you may not want
inside a long-running worker (e.g.
`idle_in_transaction_session_timeout`) are inherited too.

If you need a tighter GUC profile for a worker, set the GUC in the
launching session **before** calling `launch_v2`/`submit_v2`:

```sql
SET LOCAL statement_timeout = '30s';
SELECT pg_background_run_v2('SELECT slow_thing()');
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
    FROM pg_background_list
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

## Cookbook — see docs/COOKBOOK.md

Copy-paste templates (synchronous run with metadata, wait-with-timeout
+ result-or-error, fan-out + drain, wait-any, cancel-by-label) plus
the end-to-end use cases live in **[`docs/COOKBOOK.md`](docs/COOKBOOK.md)**.

---

## Migration Guide — see docs/MIGRATION.md

The 1.10 → 2.0 migration story (dropped APIs, renamed helpers, type
field additions) and every older 1.x → 1.x upgrade chain live in
**[`docs/MIGRATION.md`](docs/MIGRATION.md)**. The v1 → v2 API mapping
table is also there.

---

## Testing

### Local Testing (Native)

If you have PostgreSQL development files installed locally:

```bash
# Build and install
make clean && make
sudo make install

# Run regression tests
make installcheck

# Clean test artifacts
make installcheckclean
```

### Docker-Based Testing (Recommended)

Docker-based testing requires no local PostgreSQL installation:

```bash
# Test with PostgreSQL 17 (default)
./scripts/test-local.sh

# Test with specific PostgreSQL version
./scripts/test-local.sh 14
./scripts/test-local.sh 16

# Test all supported versions (14-18)
./scripts/test-local.sh all
```

### Relocatable Extension Testing

Verify the extension works correctly when installed in a custom schema:

```bash
# Run comprehensive relocatable tests
./scripts/test-relocatable.sh 17
```

### Upgrade Path Testing

Validate extension upgrades work correctly:

```bash
# Test 1.8 → 1.9 upgrade path
./scripts/test-upgrade.sh 17
```

### CI Pipeline

The project uses GitHub Actions for continuous integration:

| Job | Description |
|-----|-------------|
| **test** | Matrix: PG 14-18 × ubuntu-22.04/24.04 regression tests |
| **relocatable-test** | Validates custom schema installation (PG 17) |
| **upgrade-test** | Validates 1.8 → 1.9 upgrade path |
| **lint** | cppcheck and clang-format checks |
| **security** | CodeQL security analysis |

All tests must pass before merging to main branches.

---

## Contributing

We welcome contributions! Please see [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for:
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

This project is licensed under the [PostgreSQL License](LICENSE).

Copyright (c) 2014-2026, Vibhor Kumar and contributors.
Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group.

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

**Version**: 2.0
**Last Updated**: 2026-05-10
**Minimum PostgreSQL**: 14
**Tested Through**: PostgreSQL 18

**Companion docs**: [`docs/MIGRATION.md`](docs/MIGRATION.md) · [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · [`docs/COOKBOOK.md`](docs/COOKBOOK.md) · [`docs/SECURITY.md`](docs/SECURITY.md) · [`docs/CI.md`](docs/CI.md) · [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md)
