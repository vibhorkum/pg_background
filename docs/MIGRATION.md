# pg_background — Migration Guide

This guide is the authoritative reference for moving between pg_background
versions. Read the section for the version you're upgrading **from**; each
section is self-contained.

> **Supported upgrade source for 2.0 is 1.8 or newer.** If you are running
> a pre-1.8 version, first upgrade to 1.8 against the 1.10 release line, then
> follow the 1.10 → 2.0 instructions below. The pre-1.8 upgrade scripts that
> previously lived in `extension/legacy/` were removed.

---

## 1.10 → 2.0 (major release)

2.0 is a deliberate cleanup release. Several APIs were renamed or removed,
and several composite types gained forward-compatibility columns. Any
migration that touches the surface needs a code change.

The upgrade is invoked the usual way:

```sql
ALTER EXTENSION pg_background UPDATE TO '2.0';
```

The script in `extension/pg_background--1.10--2.0.sql` performs the changes
described below atomically. After it runs, every grant the
`pgbackground_role` previously held is reapplied; explicit grants you made
to other roles for renamed objects need to be reissued (see *Privilege
helpers* below).

### The `_v2` suffix is retired (canonical names + deprecated aliases)

The `_v2` suffix existed only to distinguish the cookie-protected API from
the original v1 functions. With v1 gone (below), the suffix no longer
distinguishes anything, so **2.0 makes the unsuffixed names canonical**:

| Through 1.10 | 2.0 canonical | 2.0 `_v2` alias |
|---|---|---|
| `pg_background_launch_v2(...)` | `pg_background_launch(...)` | kept, deprecated |
| `pg_background_submit_v2(...)` | `pg_background_submit(...)` | kept, deprecated |
| `pg_background_result_v2(...)` | `pg_background_result(...)` | kept, deprecated |
| `pg_background_detach_v2(...)` | `pg_background_detach(...)` | kept, deprecated |
| `pg_background_cancel_v2(...)` | `pg_background_cancel(...)` | kept, deprecated |
| `pg_background_wait_v2(...)` | `pg_background_wait(...)` | kept, deprecated |
| `pg_background_list_v2()` | `pg_background_list()` | kept, deprecated |
| `pg_background_stats_v2()` | `pg_background_stats()` | kept, deprecated |
| `pg_background_get_progress_v2(...)` | `pg_background_get_progress(...)` | kept, deprecated |
| `pg_background_result_info_v2(...)` | `pg_background_result_info(...)` | kept, deprecated |
| `pg_background_error_info_v2(...)` | `pg_background_error_info(...)` | kept, deprecated |
| `pg_background_detach_all_v2()` | `pg_background_detach_all()` | kept, deprecated |
| `pg_background_cancel_all_v2()` | `pg_background_cancel_all()` | kept, deprecated |
| `pg_background_outcome_v2(...)` | `pg_background_outcome(...)` | kept, deprecated |
| `pg_background_run_v2(...)` | `pg_background_run(...)` | kept, deprecated |
| `pg_background_run_query_v2(...)` | `pg_background_run_query(...)` | kept, deprecated |
| `pg_background_drain_v2(...)` | `pg_background_drain(...)` | kept, deprecated |
| `pg_background_wait_any_v2(...)` | `pg_background_wait_any(...)` | kept, deprecated |
| `pg_background_cancel_by_label_v2(...)` | `pg_background_cancel_by_label(...)` | kept, deprecated |
| `pg_background_purge_v2()` | `pg_background_purge()` | kept, deprecated |
| `pg_background_full_sql_v2(...)` | `pg_background_full_sql(...)` | kept, deprecated |

**No code change is required for the rename.** Every `_v2` name that shipped
through 1.10 is kept as a thin deprecated alias that forwards to the
canonical function with identical behavior; the aliases are **slated for
removal in 3.0**. Migrate at your own pace — new code should use the
unsuffixed names. A `DEPRECATED ... Removed in 3.0` comment is attached to
each alias (`\df+`).

The canonical names coexist with same-named objects of a different kind,
resolved by call syntax:

- `pg_background_list` is the **view** (preferred for monitoring);
  `pg_background_list()` is the raw set-returning function.
- `pg_background_stats` / `pg_background_outcome` are **composite types**;
  `pg_background_stats()` / `pg_background_outcome(...)` are functions.

Names that are **new in 2.0** have no `_v2` alias because no released `_v2`
name ever existed for them: `pg_background_report_progress` (the worker-side
writer that shipped through 1.10 was `pg_background_progress`, renamed
below), the internal `pg_background_record_timeout`, and the privilege
helpers (renamed from `grant_pg_background_privileges` /
`revoke_pg_background_privileges`, below).

### Removed: the v1 API; the unsuffixed names now mean the v2 API

The original v1 functions — `pg_background_launch(sql, queue_size)` returning
`int4`, `pg_background_result(pid)`, `pg_background_detach(pid)` — are gone.
They were thin shims over the v2 path that existed for backward
compatibility with releases before 1.6.

Note that the unsuffixed names are **back, but with the cookie-protected v2
semantics** (see the rename table above): `pg_background_launch` now returns
a `pg_background_handle` (`pid` + `cookie`), not a bare `int4`. If you have
v1 muscle memory, the name is the same but the shape changed.

| Before (1.x, v1) | After (2.0, canonical) |
|---|---|
| `pg_background_launch(sql, queue_size)` returns `int4` | `pg_background_launch(sql, queue_size)` returns `pg_background_handle` (pid + cookie) |
| `pg_background_result(pid)` | `pg_background_result(pid, cookie)` |
| `pg_background_detach(pid)` | `pg_background_detach(pid, cookie)` |

The rewrite is mechanical: capture both `pid` and `cookie` from the handle
returned by `launch`/`submit`, and pass the cookie to every later operation
on that worker. (The `_v2`-suffixed names work identically if you prefer to
defer the rename — they are deprecated aliases removed in 3.0.)

```sql
-- Before (v1)
SELECT pg_background_launch('SELECT 1') AS pid \gset
SELECT * FROM pg_background_result(:pid) AS (x int);

-- After (2.0 canonical)
SELECT (h).pid AS pid, (h).cookie AS cookie
  FROM (SELECT pg_background_launch('SELECT 1') AS h) s \gset
SELECT * FROM pg_background_result(:pid, :cookie) AS (x int);
```

The cookie protects against PID-reuse hits — the worker you launched cannot
be confused with an unrelated worker that happens to acquire the same PID
later.

### Collapsed: `cancel_v2` / `wait_v2` overloads

The `_grace` and `_timeout` suffix variants were merged into the base
function with an extra parameter that defaults to a sensible value.

| Before (1.10) | After (2.0) |
|---|---|
| `pg_background_cancel_v2(pid, cookie)` | `pg_background_cancel_v2(pid, cookie)` (unchanged — uses `grace_ms = 0`) |
| `pg_background_cancel_v2_grace(pid, cookie, grace_ms)` | `pg_background_cancel_v2(pid, cookie, grace_ms)` |
| `pg_background_wait_v2(pid, cookie)` returns `void` | `pg_background_wait_v2(pid, cookie)` returns `bool` (true) — uses `timeout_ms = 0`, blocks indefinitely |
| `pg_background_wait_v2_timeout(pid, cookie, timeout_ms)` returns `bool` | `pg_background_wait_v2(pid, cookie, timeout_ms)` returns `bool` |

Two semantic notes worth surfacing:

- `wait_v2` now **always returns `bool`**. Old callers that ignored the void
  return value continue to work; old callers that assigned the result to a
  variable see no change either way.
- For `wait_v2`, `timeout_ms <= 0` blocks indefinitely (matches the 1.x
  default of `wait_v2(pid, cookie)`) while `timeout_ms > 0` waits up to that
  many milliseconds. **`timeout_ms = 0` does not poll.** If you want a poll
  ("is it done yet?"), pass `timeout_ms = 1`. The legacy
  `wait_v2_timeout(pid, cookie, 0)` polling pattern needs to be rewritten to
  `wait_v2(pid, cookie, 1)`.

### Removed: `pg_background_status_v2`

The jsonb wrapper around `pg_background_outcome_v2` was a thin one-liner.
Drivers that decode JSON natively can call it themselves:

```sql
-- Before
SELECT pg_background_status_v2(pid, cookie);

-- After
SELECT to_jsonb(pg_background_outcome_v2(pid, cookie));
```

### Renamed: progress reporting

The worker-side write call had no `_v2` suffix in 1.x and clashed with the
type of the same name. In 2.0 both were renamed for coherence.

| Before (1.x) | After (2.0) |
|---|---|
| `pg_background_progress(pct, msg)` (function) | `pg_background_report_progress(pct, msg)` |
| `pg_background_progress` (type) | `pg_background_progress_info` |
| `pg_background_get_progress_v2(pid, cookie)` returns `pg_background_progress` | `pg_background_get_progress(pid, cookie)` returns `pg_background_progress_info` |

If your worker SQL calls `pg_background_progress(50, 'halfway')`, change
the call to `pg_background_report_progress(50, 'halfway')`. This is a hard
rename with **no alias** — the old `pg_background_progress` name is gone.
The type rename is only visible if you explicitly reference the type by
name (most callers don't).

### Renamed: privilege helpers

| Before (1.x) | After (2.0) |
|---|---|
| `grant_pg_background_privileges(role)` | `pg_background_grant_privileges(role)` |
| `revoke_pg_background_privileges(role)` | `pg_background_revoke_privileges(role)` |

The unprefixed names were polluting the install schema. These are hard
renames with **no `_v2` alias** (the `_v2`-suffixed privilege-helper names
never shipped in a released version). After the upgrade script runs, the
helper is reapplied to `pgbackground_role` automatically; if you've granted
to other roles, reissue the grant by calling the new helper:

```sql
SELECT pg_background_grant_privileges('app_executor', false);
```

### Forward-compatible additions to composite types

These are not breaking *if* you are using positional decoding, but they
*are* breaking if you SELECT specific columns into a row variable that has
the old shape. Most code uses named-field access, in which case nothing
changes.

| Type | New columns | Notes |
|---|---|---|
| `pg_background_stats` | `workers_timed_out int8` | Separate counter from `workers_canceled`, bumped by `pg_background_run_v2` on timeout |
| `pg_background_result_info` | `started_at`, `finished_at` (timestamptz, nullable) | Worker writes these around the SPI loop |
| `pg_background_error` | `schema_name`, `table_name`, `column_name`, `constraint_name` (text, nullable) | Sourced from PG's `edata`; populated for heap/access-layer errors |
| `pg_background_run_result` | now extends `pg_background_outcome` (gains `cookie`, `state`, `consumed`, `label`, `launched_at`) plus `timed_out`, `elapsed_ms` | Replaces 1.10's standalone shape |

If you do `SELECT * INTO some_row FROM pg_background_run_v2(...)`,
`some_row` must have the new wider shape. PL/pgSQL will give you a clear
"column count mismatch" error if not — easy to spot.

### What didn't change

- `pg_background_handle` type — same shape.
- `pg_background_launch_v2`, `pg_background_submit_v2`, `pg_background_result_v2`, `pg_background_detach_v2` — unchanged signatures.
- `pg_background_outcome_v2`, `pg_background_outcome` type — unchanged.
- `pg_background_list`, `pg_background_activity` views — unchanged.
- `pg_background_full_sql_v2` — unchanged.
- `pg_background_detach_all_v2`, `pg_background_cancel_all_v2` — unchanged.
- The Tier A helpers (`run_query_v2`, `drain_v2`, `wait_any_v2`, `cancel_by_label_v2`, `purge_v2`) — same SQL signatures; their bodies were rewired to use the new `cancel_v2` / `wait_v2`.

### Internal: the workers_timed_out counter

`pg_background_run_v2` now records a session-local counter when it cancels
a worker due to its own `timeout_ms` parameter. `pg_background_stats_v2()`
exposes this counter as `workers_timed_out`. A separate timeout via
`statement_timeout` inside the worker will continue to be classified as a
worker error (`workers_failed`) rather than a timeout.

### Privilege model

`pgbackground_role` is unchanged. The grant helper is invoked once at the
end of the upgrade script with `pgbackground_role`, which restores every
function/type/view grant the role used to hold against the new surface.

If you depend on the previous unprefixed helpers (e.g. inside a deployment
playbook that calls `grant_pg_background_privileges(...)`), update it to
the new name.

---

## Older upgrade paths

For pre-1.10 source versions, chain through the supported steps. 2.0
itself only ships the 1.10 → 2.0 upgrade script; if you're on 1.7 or
older you must reach 1.10 against the 1.10 release line first.

```sql
-- pre-1.8 → 1.8 (against 1.10 release line)
ALTER EXTENSION pg_background UPDATE TO '1.8';
-- 1.8 → 1.9
ALTER EXTENSION pg_background UPDATE TO '1.9';
-- 1.9 → 1.10
ALTER EXTENSION pg_background UPDATE TO '1.10';
-- 1.10 → 2.0  (this guide, above)
ALTER EXTENSION pg_background UPDATE TO '2.0';
```

### 1.9 → 1.10

```sql
ALTER EXTENSION pg_background UPDATE TO '1.10';
```

What you get:
- `pg_background_list` view (no column-definition list at the call site).
- `pg_background_activity` view (joined with `pg_stat_activity`).
- `pg_background_outcome_v2()` — never-raises status snapshot.
- `pg_background_run_v2()` — synchronous one-shot.

Action items:
- No code change required. Existing v1 and v2 callers keep working.
- Optional: replace ad-hoc column-def lists with the new
  `pg_background_list` view in monitoring queries.
- Optional: replace bespoke `launch + wait + cleanup` wrappers with
  `pg_background_run_v2()`.

### 1.8 → 1.9

```sql
ALTER EXTENSION pg_background UPDATE TO '1.9';
```

What you get:
- `label` parameter on `launch_v2`/`submit_v2` for operational clarity.
- `pg_background_error_info_v2()` returning structured errors with real
  `SQLSTATE`.
- `pg_background_result_info_v2()` for row count / command tag /
  completion flags.
- Batch helpers: `pg_background_detach_all_v2()`,
  `pg_background_cancel_all_v2()`.

### 1.7 → 1.8

```sql
ALTER EXTENSION pg_background UPDATE TO '1.8';
```

What you get:
- `pg_background_stats_v2()` — session statistics.
- `pg_background_progress()` (renamed to `pg_background_report_progress`
  in 2.0) — worker progress reporting.
- `pg_background_get_progress_v2()` — get worker progress.
- GUCs: `max_workers`, `worker_timeout`, `default_queue_size`.
- Built-in `max_workers` enforcement.
- Robustness fixes: overflow protection, UTF-8-aware truncation.

Action items:
- Review the new GUC settings and configure as needed.
- Consider using progress reporting for long-running workers.
- Use `stats_v2()` for monitoring.

### 1.6 → 1.7

```sql
ALTER EXTENSION pg_background UPDATE TO '1.7';
```

Changes:
- Cryptographically secure cookie generation.
- Dedicated memory context (prevents session bloat).
- Exponential backoff polling (reduces CPU usage).
- **Fix**: custom-schema installation (`CREATE EXTENSION ... WITH SCHEMA`).
- No breaking changes.

> **⚠️ Upgrade note**: custom-schema support is only available for
> *fresh* installs of 1.7+. If you already have 1.4/1.5/1.6 installed,
> the extension is in `public` because those versions did not support
> custom schemas. The upgrade scripts contain hardcoded `public.`
> references and cannot relocate the extension. To move an existing
> install to a custom schema, drop and reinstall:
>
> ```sql
> DROP EXTENSION pg_background;
> CREATE SCHEMA IF NOT EXISTS myschema;
> CREATE EXTENSION pg_background WITH SCHEMA myschema;
> ```

### 1.5 → 1.6

```sql
ALTER EXTENSION pg_background UPDATE TO '1.6';
```

Changes:
- v1 API unchanged (fully backward compatible).
- New v2 API functions added.
- `pgbackground_role` created automatically.
- Hardened privilege helpers added.
- No breaking changes.

Action items:
- Review privilege grants (1.6 revokes PUBLIC access).
- Grant `pgbackground_role` to application users.
- Migrate v1 API calls to v2 in new code.

### 1.0 – 1.4 → 1.6

```sql
ALTER EXTENSION pg_background UPDATE TO '1.4';
ALTER EXTENSION pg_background UPDATE TO '1.6';
```

Breaking changes along the way:
- 1.4 removed PostgreSQL 9.x support.
- 1.5 changed DSM lifecycle (no functional API changes).
- 1.6 revoked PUBLIC access (requires explicit grants).

Action items:
- Test on non-production first.
- Audit existing privilege grants.
- Update application code to use v2 API.

### Migrating v1 → v2 (API surface mapping)

The v1 API was *removed* in 2.0 (see the top section of this document).
For pre-2.0 callers still on v1, this table is the side-by-side mapping
to use when porting.

| v1 (removed in 2.0) | v2 (current) | Notes |
|---|---|---|
| `pg_background_launch(sql, queue_size)` → `int4` | `pg_background_launch_v2(sql, queue_size, label)` → `pg_background_handle` | v2 returns `(pid, cookie)` composite; cookie protects against PID reuse |
| `pg_background_result(pid)` → `SETOF record` | `pg_background_result_v2(pid, cookie)` → `SETOF record` | Same one-time consumption rule. Avoid calling on errored workers — use `error_info_v2` instead |
| `pg_background_detach(pid)` → `void` | `pg_background_detach_v2(pid, cookie)` → `void` | Detach removes tracking; the worker keeps running and commits |
| _(no equivalent)_ | `pg_background_submit_v2(sql, queue_size, label)` | Dedicated fire-and-forget; clearer than `launch + detach` |
| _(no equivalent)_ | `pg_background_cancel_v2(pid, cookie, grace_ms)` | SIGTERM, optional grace window before SIGKILL |
| _(no equivalent)_ | `pg_background_wait_v2(pid, cookie, timeout_ms)` | Block until exit, optionally bounded |
| _(no equivalent)_ | `pg_background_list_v2()` / `pg_background_list` view | Per-session worker registry with state, label, last_error |
| _(no equivalent)_ | `pg_background_stats_v2()` | Counters: launched, completed, failed, canceled, timed_out, active, avg_execution_ms |
| _(no equivalent)_ | `pg_background_result_info_v2(pid, cookie)` | Row count, command tag, started_at/finished_at, completion/error flags |
| _(no equivalent)_ | `pg_background_error_info_v2(pid, cookie)` | Structured error: SQLSTATE, message, detail, hint, context, schema/table/column/constraint |
| _(no equivalent)_ | `pg_background_outcome_v2(pid, cookie)` | Combined snapshot — never raises |
| _(no equivalent)_ | `pg_background_run_v2(sql, queue_size, timeout_ms, label)` | Synchronous one-shot: launch + wait + outcome + detach |

#### Example port

Before (v1):
```sql
-- fire-and-forget VACUUM
SELECT pg_background_launch('VACUUM my_table') AS pid \gset
SELECT pg_background_detach(:pid);
```

After (v2, idiomatic):
```sql
-- explicit fire-and-forget
SELECT (h).pid AS pid, (h).cookie AS cookie
  FROM (SELECT pg_background_submit_v2('VACUUM my_table', 0, 'nightly-vacuum') AS h) s
\gset
SELECT pg_background_detach_v2(:pid, :cookie);
```

After (v2, simpler — synchronous one-shot):
```sql
-- launch, wait, capture metadata, detach — one call
SELECT * FROM pg_background_run_v2('VACUUM my_table', 0, 0, 'nightly-vacuum');
```

## Verifying the upgrade

After upgrading, confirm:

```sql
SELECT extversion FROM pg_extension WHERE extname = 'pg_background';
-- Expected: 2.0

\df pg_background_launch
-- Expected: 0 rows (v1 dropped).

\df pg_background_cancel_v2
-- Expected: one row, signature (int4, int8, int4) with default for the third arg.

\df pg_background_wait_v2
-- Expected: one row, signature (int4, int8, int4) returning bool.
```

If `\df pg_background_launch` returns a row, the upgrade did not run; check
`SELECT extversion ...` and rerun the `ALTER EXTENSION ... UPDATE TO '2.0'`.

## Reporting upgrade issues

File an issue at
<https://github.com/vibhorkum/pg_background/issues> with the source
version, target version, and the full error output (including any
`pg_background_grant_privileges RAISE NOTICE` lines).
