# pg_background v1.10 — Major release

A coherent ergonomics + observability + polish release. Every change is
additive: existing v1 and v2 callers continue to work unchanged.

## Highlights

### Ergonomics layer (no boilerplate left)

- **`pg_background_list` view** — wraps `pg_background_list_v2()` so callers no
  longer have to repeat the 10-column definition list at every query site.
- **`pg_background_activity` view** — `pg_background_list` joined with
  `pg_stat_activity` by `pid` for combined worker + backend visibility.
- **`pg_background_outcome` type** + **`pg_background_outcome_v2(pid, cookie)`**:
  combined never-raises status snapshot (`list_v2 + result_info_v2 +
  error_info_v2`). Returns NULL fields when info is unavailable; never raises.
- **`pg_background_run_result` type** + **`pg_background_run_v2(sql,
  queue_size, timeout_ms, label)`**: synchronous one-shot
  (`launch + wait + outcome + detach`). Returns metadata only; on timeout
  cancels the worker with 1 s grace.

### Tier A — six "loop killer" helpers (new in v1.10)

- **`pg_background_run_query_v2(sql, queue_size, timeout_ms, label, col_def)`**
  → `SETOF record`. Synchronous launch + wait + result + detach **with
  rows**. Raises the worker's SQLSTATE on error.
- **`pg_background_drain_v2(handles[], timeout_ms)`** → `SETOF outcome`.
  Wait for every handle (wall-clock total timeout shared across handles),
  collect outcomes, detach.
- **`pg_background_wait_any_v2(handles[], timeout_ms)`** → handle. Returns
  the first finished handle, NULL on timeout. Adaptive polling 50 ms..500 ms.
- **`pg_background_cancel_by_label_v2(pattern, grace_ms)`** → `int4`.
  LIKE-based label match; returns count canceled.
- **`pg_background_status_v2(pid, cookie)`** → `jsonb`. Driver-friendly
  status snapshot.
- **`pg_background_purge_v2()`** → `int4`. Detach only stopped/done workers.

### Tier B — observability (new in v1.10)

- **`pg_background_full_sql_v2(pid, cookie)`** → `text`. Full SQL the worker
  is/was running, beyond the 120-character preview. Capped at 64 KiB with a
  `[...]` sentinel for longer queries. Survives DSM detach.
- **Worker `application_name`** is now set to `pg_background:<label>:<pid>`
  (or `pg_background:<pid>` without a label), so workers are immediately
  recognizable in `pg_stat_activity` and log lines.

### Internal simplifications (refactors)

- **Metadata-driven privilege helpers**: `grant_pg_background_privileges` /
  `revoke_pg_background_privileges` now iterate `pg_depend` instead of
  carrying a hand-maintained list. Adding a new function never requires
  updating these helpers; CI catches forgetfulness automatically. The
  contract is pinned by a regression test asserting every extension-owned
  function is reachable post-grant and unreachable post-revoke.
- **Polling-loop consolidation**: `pg_background_wait_v2_timeout` and
  `pgbg_send_cancel_signals` now share a single helper `pgbg_wait_for_stop`,
  so the wait-with-backoff loop and `CHECK_FOR_INTERRUPTS` placement live in
  one canonical place.
- **C file split**: worker-process code (`worker_main`,
  `execute_sql_string`, `error_exit`, signal handler) now lives in
  `pg_background_worker.c`. The two halves communicate only via DSM and
  `shm_mq`, so the cross-file surface is small (declared in
  `pg_background_internal.h`). `pg_background.c` shrinks from 3,435 lines
  to ~2,800.

### Polish

- **Backoff jitter** (~12.5 %) added to `pgbg_sleep_with_backoff` to
  decorrelate concurrent sessions polling the same workers.
- **Better `INSUFFICIENT_RESOURCES` hint**: when `RegisterDynamicBackground-
  Worker` fails, the message now mentions both the cluster
  `max_worker_processes` GUC and the per-session `pg_background.max_workers`,
  and points at `pg_background_list` for identifying candidates to detach.

### Documentation

- **30-second tour** at the top of the README: simplest possible example
  (`pg_background_run_v2`) and a "where to go next" cross-reference.
- **"When to use this — and when not to"** decision panel with a
  side-by-side capability table comparing `pg_background`, `pg_cron`,
  `dblink`, `postgres_fdw` across 10 capabilities.
- **Architecture (one-page mental model)**: a Mermaid sequence diagram of
  launcher / DSM / shm_mq / worker showing the launch → execute → return
  dance. Renders natively on GitHub.
- **Cookbook** section with three battle-tested templates: synchronous run,
  wait-with-timeout-and-error capture, launch-many-and-gather.
- **v1 → v2 migration table** with full column-by-column mapping including
  v1.10 entries.

### Packaging

- **`META.json`** for [PGXN](https://pgxn.org).

## Tests

- Regression tests for every new SQL function (Tier A × 6, B3, B6) using
  DO blocks with NOTICE-only output for predictable expected output.
- The metadata-grant contract test now reports `(33 funcs, 2 views
  round-tripped)` — auto-discovers every new function as a smoke test of the
  refactored helpers.
- `test-upgrade.sh` extended with a 1.9 → 1.10 step that exercises every
  new object after upgrade.
- All tests pass on PG 14, 15, 16, 17, 18.

## What's deferred to v1.11

These items appeared in the v1.10 plan but require either DSM struct
changes (new fields with backward-compat concerns) or worker-side
behavioral changes that warrant their own focused PR. None are critical
for v1.10 GA.

| Item | Why deferred |
|---|---|
| **B1** — Worker-emitted `NOTIFY` on state transitions (`launch_v2(..., notify_channel)`) | Adds field to `pg_background_fixed_data` (DSM struct) and a `Async_Notify` call from the worker error path; needs careful interaction with `HOLD_INTERRUPTS`, transaction state, and the existing `'E'` frame on `shm_mq`. |
| **B2** — Optional persistent history table (`pg_background.history_table` GUC + `pg_background_history_create_table` helper) | Worker-side INSERT in best-effort wrapping; design choice on table schema (whom does the extension own); deserves its own design discussion. |
| **B4** — `started_at`, `finished_at`, `duration_ms` in `pg_background_outcome` | Adds DSM fields written by the worker; requires `ALTER TYPE pg_background_outcome ADD ATTRIBUTE` in upgrade SQL and updates to `pg_background_outcome_v2` to read them. |
| **B5** — Per-call `timeout_ms` on `launch_v2` | New 4-arg overload, plumb through DSM, worker takes `max(GUC, per-call)`. The `SET LOCAL pg_background.worker_timeout = N` workaround covers the use case in the meantime. |
| Cross-session registry (`pg_background_session_all_v2`) | Needs `shared_preload_libraries`, shmem hash sized at startup, ACL story. |
| `pg_background_tail_v2` blocking SRF | Custom SRF semantics + blocking cancellation; non-trivial. |
| Official Docker image, PGXN listing upload | Infrastructure / release-pipeline work, separate from extension code. |

## Compatibility

- PostgreSQL 14, 15, 16, 17, 18.
- Existing v1 and v2 callers are unaffected; only new objects are added.
- `pg_background.control` `default_version = '1.10'`.
- `ALTER EXTENSION pg_background UPDATE TO '1.10'` is the supported upgrade
  path from 1.9.
