# pg_background v1.10 — Ergonomics Release

This release is purely additive at the SQL layer. **No worker/C-level
behavior changes.** Existing v1 and v2 callers continue to work unchanged.

## What's in v1.10

### Convenience views

- **`pg_background_list`** — wraps `pg_background_list_v2()` so callers no
  longer have to repeat the 10-column definition list (`pid int4, cookie int8,
  launched_at timestamptz, ...`) at every query site. Same column order/shape.
- **`pg_background_activity`** — `pg_background_list` joined with
  `pg_stat_activity` by `pid` for combined worker + backend visibility in a
  single query. Adds `backend_state`, `wait_event`, `wait_event_type`,
  `xact_start`, `query_start`, `backend_start`, and the live `query` text.

### Never-raises status snapshot

- **`pg_background_outcome` type** and **`pg_background_outcome_v2(pid, cookie)`
  function** combine `list_v2 + result_info_v2 + error_info_v2` into one call.
  Returns NULL fields instead of raising when the handle is gone, when results
  have already been consumed, or when there is no error info — eliminating the
  three nested `BEGIN ... EXCEPTION` blocks users were writing by hand.

### Synchronous one-shot helper

- **`pg_background_run_result` type** and **`pg_background_run_v2(sql,
  queue_size, timeout_ms, label)` function**: `launch + wait + outcome +
  detach` in one call. Returns metadata only (`pid, completed, timed_out,
  has_error, row_count, command_tag, sqlstate, error_message, elapsed_ms`).
  On timeout the worker is canceled with a 1 s grace period so it does not
  outlive the caller. Use the launch/wait/result_v2 pattern when you need
  result rows.

### Documentation

- New **Cookbook** section in README with three copy-paste templates:
  synchronous run, wait-with-timeout-and-error-capture, and launch-many-and-
  gather. All recipes are built on v1.10 helpers and avoid the
  `result_v2`-on-error footgun.
- v1 → v2 **migration table** rewritten with full column-by-column mapping
  (including v1.9 and v1.10 entries) and side-by-side example showing the
  one-shot form.

### Packaging

- **`META.json`** added so the extension can be listed on
  [PGXN](https://pgxn.org).

### Tests

- New regression tests verify view shape, `outcome_v2` success and missing-
  handle paths, `run_v2` success / SQLSTATE error / timeout paths.
- `test-upgrade.sh` extended with a `1.9 → 1.10` step that exercises every
  new object after upgrade.

## What's deferred (not in this PR)

These items from the original ergonomics survey require either C-level
implementation work or significant infrastructure changes; they should ship as
separate, independently reviewable PRs.

| Feature | Why deferred |
|---|---|
| `pg_background_full_sql_v2(pid, cookie)` | Requires exposing full worker SQL through SQL — moderate C work in `worker_info` and the SRF dispatch |
| Worker-emitted NOTIFY on state transitions | Worker-side change to error/exit paths; requires careful interaction with HOLD_INTERRUPTS and shm_mq buffering |
| Cross-session shared registry | Shared-memory hash sized at startup, requires `shared_preload_libraries`, GUC for sizing, ACL story — non-trivial |
| `pg_background_tail_v2(pid, cookie, poll_ms, timeout_ms)` blocking SRF | Custom SRF semantics, blocking + cancellation handling, deserves its own design discussion |
| Official Docker image | Build infrastructure / release pipeline change |

## Compatibility

- PostgreSQL 14, 15, 16, 17, 18.
- Existing v1 and v2 callers are unaffected; only new objects are added.
- `pg_background.control` `default_version = '1.10'`.
- `ALTER EXTENSION pg_background UPDATE TO '1.10'` is the supported upgrade
  path from 1.9.
