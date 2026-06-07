# pg_background — Cookbook

Copy-paste templates for the most common patterns. All recipes use the
v2 API (cookie-protected handles); the v1 API was removed in 2.0. Each
example assumes the extension has been installed and the calling role
has been granted `pgbackground_role` (see [`README.md`](../README.md)
"Security Model").

---

## Quick recipes (small, idiomatic)

### Synchronous run with metadata

When you want autonomous-transaction semantics and just need to know
whether it worked, how many rows were affected, and the SQLSTATE on
failure. Returns metadata only — for result rows use the next recipe.

```sql
SELECT pid, completed, timed_out, has_error, row_count, command_tag,
       sqlstate, error_message, elapsed_ms
  FROM pg_background_run(
         'INSERT INTO audit_log SELECT now(), current_user, ''login''',
         queue_size  := 0,
         timeout_ms  := 30000,    -- 30s cap; cancels with 1s grace on overrun
         label       := 'audit-login'
       );
```

### Wait-with-timeout, then capture result rows or error

When you need the actual result rows. Uses `outcome` to inspect
state without raising; only calls `result` on the success path.

```sql
DO $$
DECLARE
    h pg_background_handle;
    o pg_background_outcome;
    finished bool;
BEGIN
    h := pg_background_launch('SELECT id, name FROM big_table WHERE active', 65536, 'lookup');

    finished := pg_background_wait(h.pid, h.cookie, 5000);
    IF NOT finished THEN
        PERFORM pg_background_cancel(h.pid, h.cookie, 1000);
        PERFORM pg_background_detach(h.pid, h.cookie);
        RAISE EXCEPTION 'lookup did not complete within 5s';
    END IF;

    o := pg_background_outcome(h.pid, h.cookie);
    IF o.has_error THEN
        PERFORM pg_background_detach(h.pid, h.cookie);
        RAISE EXCEPTION 'lookup failed: % (sqlstate %)', o.error_message, o.sqlstate;
    END IF;

    -- Safe: only consume result rows on the success path.
    INSERT INTO lookup_cache (id, name)
    SELECT id, name
      FROM pg_background_result(h.pid, h.cookie) AS r(id int, name text);

    PERFORM pg_background_detach(h.pid, h.cookie);
END
$$;
```

### Launch many, gather outcomes

When you fan out N independent jobs and want a per-worker outcome row.

```sql
WITH launched AS (
    SELECT (pg_background_launch(
              format('VACUUM (ANALYZE) %I', tablename),
              0,
              'nightly-vacuum-' || tablename)).*
      FROM pg_tables WHERE schemaname = 'public'
),
waited AS (
    SELECT l.pid,
           l.cookie,
           pg_background_wait(l.pid, l.cookie, 60000) AS finished
      FROM launched l
)
SELECT w.pid, w.finished, o.completed, o.has_error,
       o.row_count, o.command_tag, o.sqlstate, o.error_message, o.label
  FROM waited w,
       LATERAL pg_background_outcome(w.pid, w.cookie) AS o;

-- Per-handle detach is preferred (CLAUDE.md §7), but for one-shot scripts
-- the batch helper is fine.
SELECT pg_background_detach_all();
```

### Drain a fan-out with a shared deadline

`drain` waits on every handle in an array against a shared wall-clock
budget, returns one outcome row per input handle in input order, and
detaches each one.

```sql
SELECT pid, completed, has_error, row_count, label
  FROM pg_background_drain(
         ARRAY(SELECT pg_background_launch(
                        format('SELECT count(*) FROM %I', t),
                        0,
                        'count-' || t)
                 FROM pg_tables WHERE schemaname = 'public'),
         60000     -- 60s shared deadline across all handles
       );
```

### "Did any of these finish?" — wait_any

Polls a set of handles, returns the first one whose worker has stopped,
or `NULL` on timeout. Useful for racing tasks.

```sql
DO $$
DECLARE
    hs      pg_background_handle[];
    winner  pg_background_handle;
BEGIN
    hs := ARRAY[
        pg_background_launch('SELECT pg_sleep(2);  SELECT 1', 0, 'race-1'),
        pg_background_launch('SELECT pg_sleep(0.5); SELECT 2', 0, 'race-2'),
        pg_background_launch('SELECT pg_sleep(5);  SELECT 3', 0, 'race-3')
    ];

    winner := pg_background_wait_any(hs, 10000);
    RAISE NOTICE 'first finisher: pid=% (cookie=%)', winner.pid, winner.cookie;

    PERFORM count(*) FROM pg_background_drain(hs, 5000);  -- cleanup the rest
END$$;
```

### Cancel by label

Cancel every worker in this session whose label matches a SQL `LIKE`
pattern. Useful for bulk-cancelling a logical workload identified by a
label prefix.

```sql
SELECT pg_background_cancel_by_label('nightly-vacuum-%');
```

---

## End-to-end use cases

### Background maintenance operations

VACUUM blocks client connections and consumes resources. Run it
asynchronously instead:

```sql
-- Use the pg_background_list view (no column-definition list required).
SELECT (pg_background_launch(
          'VACUUM (VERBOSE, ANALYZE) large_table',
          0,
          'maintenance-vacuum')).*
\gset h_

-- Check progress.
SELECT state, sql_preview, launched_at
  FROM pg_background_list
 WHERE pid = :h_pid AND cookie = :h_cookie;

-- Wait for completion (optional).
SELECT pg_background_wait(:h_pid, :h_cookie);
SELECT pg_background_detach(:h_pid, :h_cookie);
```

### Autonomous audit logging

Audit logs must persist even if the main transaction rolls back. Use
the worker for an independent commit.

> **⚠️ Worker exhaustion**: if `max_worker_processes` is exhausted,
> `pg_background_launch()` raises `ERRCODE_INSUFFICIENT_RESOURCES`.
> For audit logging, that means the message is **lost** unless your
> caller handles the error. The robust template below retries with
> exponential backoff and falls back to a synchronous insert.

**Basic** (not fault-tolerant):

```sql
CREATE FUNCTION log_audit_simple(event_type text, details jsonb)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  h pg_background_handle;
BEGIN
  h := pg_background_submit(
         format(
           'INSERT INTO audit_log (ts, event_type, details) VALUES (now(), %L, %L)',
           event_type, details::text));
  PERFORM pg_background_detach(h.pid, h.cookie);
END;
$$;
```

**Robust** (handles worker exhaustion):

```sql
CREATE FUNCTION log_audit(event_type text, details jsonb)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  h          pg_background_handle;
  retries    int := 3;
  backoff_ms int := 100;
BEGIN
  FOR i IN 1..retries LOOP
    BEGIN
      h := pg_background_submit(
             format(
               'INSERT INTO audit_log (ts, event_type, details) VALUES (now(), %L, %L)',
               event_type, details::text));
      PERFORM pg_background_detach(h.pid, h.cookie);
      RETURN;
    EXCEPTION WHEN insufficient_resources THEN
      IF i = retries THEN
        -- Final fallback: synchronous insert (blocks but doesn't lose data).
        INSERT INTO audit_log (ts, event_type, details)
        VALUES (now(), event_type, details);
        RAISE WARNING 'pg_background exhausted, audit logged synchronously';
        RETURN;
      END IF;
      PERFORM pg_sleep(backoff_ms / 1000.0);
      backoff_ms := backoff_ms * 2;
    END;
  END LOOP;
END;
$$;
```

**Usage in a transaction**:

```sql
BEGIN;
  UPDATE accounts SET balance = balance - 100 WHERE id = 123;
  PERFORM log_audit('withdrawal', '{"account": 123, "amount": 100}');
  ROLLBACK;        -- audit row still exists

SELECT * FROM audit_log ORDER BY ts DESC LIMIT 1;
```

### Asynchronous notification delivery

`pg_notify()` in the main transaction delays commit. Offload to a
worker:

```sql
CREATE FUNCTION notify_async(channel text, payload text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  h pg_background_handle;
BEGIN
  h := pg_background_submit(
         format('SELECT pg_notify(%L, %L)', channel, payload));
  PERFORM pg_background_detach(h.pid, h.cookie);
END;
$$;

-- Usage:
SELECT notify_async('order_updates', '{"order_id": 456, "status": "shipped"}');
```

> **NOTIFY caveat**: NOTIFY frames raised inside a `submit` worker
> are *not* relayed back to the launcher's session. The notify row hits
> `pg_listener` / the notify queue in the worker's own commit, so any
> session that called `LISTEN <channel>` separately *will* receive it —
> but the launching session won't see the protocol-level message echoed.

### Long-running ETL pipeline

ETL blocks a client connection for hours. Launch in the background and
poll for completion via the `pg_background_list` view.

```sql
SELECT (pg_background_launch($$
  INSERT INTO fact_sales
  SELECT * FROM staging_sales WHERE processed = false;
  UPDATE staging_sales SET processed = true;
$$, 0, 'etl-001')).*
\gset etl_

-- Track in your own jobs table:
INSERT INTO job_tracker (job_id, pid, cookie, started_at)
VALUES ('etl-001', :etl_pid, :etl_cookie, now());

-- Later: status check using the convenience view.
SELECT j.job_id, w.state, w.launched_at, (now() - w.launched_at) AS duration
  FROM job_tracker j
  CROSS JOIN LATERAL (
      SELECT * FROM pg_background_list WHERE pid = j.pid AND cookie = j.cookie
  ) w
 WHERE j.job_id = 'etl-001';
```

### Parallel query simulation

PostgreSQL doesn't natively parallelize across separate tables. Launch a
worker per table and aggregate:

```sql
DO $$
DECLARE
    hs         pg_background_handle[];
    total_rows bigint;
BEGIN
    hs := ARRAY[
        pg_background_launch('SELECT count(*) FROM sales',     0, 'pq-sales'),
        pg_background_launch('SELECT count(*) FROM orders',    0, 'pq-orders'),
        pg_background_launch('SELECT count(*) FROM customers', 0, 'pq-customers')
    ];

    PERFORM pg_background_wait(h.pid, h.cookie)
      FROM unnest(hs) h;

    SELECT sum(cnt) INTO total_rows FROM (
        SELECT * FROM pg_background_result((hs[1]).pid, (hs[1]).cookie) AS (cnt bigint)
        UNION ALL
        SELECT * FROM pg_background_result((hs[2]).pid, (hs[2]).cookie) AS (cnt bigint)
        UNION ALL
        SELECT * FROM pg_background_result((hs[3]).pid, (hs[3]).cookie) AS (cnt bigint)
    ) t;

    RAISE NOTICE 'Total rows: %', total_rows;
END$$;
```

### Timeout enforcement

Cancel queries that exceed a time budget:

```sql
CREATE FUNCTION run_with_timeout(sql text, timeout_sec int)
RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  h           pg_background_handle;
  done        bool;
  result_text text;
BEGIN
  h := pg_background_launch(sql);
  done := pg_background_wait(h.pid, h.cookie, timeout_sec * 1000);

  IF NOT done THEN
    RAISE WARNING 'Query timed out after % seconds, cancelling', timeout_sec;
    PERFORM pg_background_cancel(h.pid, h.cookie, 1000);
    PERFORM pg_background_detach(h.pid, h.cookie);
    RETURN 'TIMEOUT';
  END IF;

  SELECT * INTO result_text
    FROM pg_background_result(h.pid, h.cookie) AS (res text);
  RETURN result_text;
END;
$$;

-- Usage:
SELECT run_with_timeout('SELECT pg_sleep(10)', 5);  -- returns 'TIMEOUT'
```

For one-shot uses where you only need metadata, prefer
`pg_background_run(sql, queue_size, timeout_ms, label)` — it does
launch + wait-with-timeout + outcome + detach in a single call and
records the timeout in `pg_background_stats().workers_timed_out`.
