# pg_background - PostgreSQL Background Worker Extension

Execute SQL commands in dedicated background worker processes for PostgreSQL (version 9.5+).

## Overview

`pg_background` allows you to run arbitrary SQL commands in isolated background worker processes. This enables asynchronous execution of long-running operations, autonomous transactions, and parallel processing patterns without blocking your main connection.

**Key Features:**
- Execute any SQL command in a background worker process
- Retrieve results asynchronously via shared memory queues
- Detach workers to run independently
- Full transaction isolation from launching session
- Security model based on role privileges
- Support for PostgreSQL 9.5 through 18.0+

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
- [Usage Examples](#usage-examples)
- [Security & Permissions](#security--permissions)
- [Architecture & Design](#architecture--design)
- [Performance Considerations](#performance-considerations)
- [Limitations & Caveats](#limitations--caveats)
- [Troubleshooting](#troubleshooting)
- [Compatibility](#compatibility)
- [Development](#development)
- [License](#license)

## Installation

### Prerequisites

- PostgreSQL 9.5 or later
- `pg_config` in your PATH
- Build tools (gcc, make)

### Build from Source

```bash
# Clone the repository
git clone https://github.com/vibhorkum/pg_background.git
cd pg_background

# Build and install
make
sudo make install

# Enable in your database
psql -d your_database -c "CREATE EXTENSION pg_background;"
```

### Verify Installation

```sql
SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_background';
```

## Quick Start

### Basic Example

```sql
-- Launch a background task
SELECT pg_background_launch('VACUUM VERBOSE my_table');
 pg_background_launch 
----------------------
                 12345
(1 row)

-- Retrieve the result using the returned PID
SELECT * FROM pg_background_result(12345) AS (result TEXT);
   result   
------------
 VACUUM
(1 row)
```

### Wait for Result

```sql
-- Launch and immediately wait for completion
SELECT * FROM pg_background_result(
    pg_background_launch('SELECT count(*) FROM my_table')
) AS (count BIGINT);
  count  
---------
 1000000
(1 row)
```

### Detached Background Execution

```sql
-- Launch worker and detach (fire-and-forget)
DO $$
DECLARE
    worker_pid INTEGER;
BEGIN
    worker_pid := pg_background_launch('CREATE INDEX CONCURRENTLY idx_my_table ON my_table(column)');
    PERFORM pg_background_detach(worker_pid);
    RAISE NOTICE 'Background index creation started with PID %', worker_pid;
END $$;
```

## API Reference

### pg_background_launch

```sql
pg_background_launch(
    sql TEXT,
    queue_size INTEGER DEFAULT 65536
) RETURNS INTEGER
```

Launches a background worker to execute the specified SQL command.

**Parameters:**
- `sql`: SQL command to execute (can be any valid SQL)
- `queue_size`: Size in bytes of the message queue for results (default: 64 KB)

**Returns:** Process ID (PID) of the background worker

**Notes:**
- Queue size must be at least `shm_mq_minimum_size` (typically 16 bytes)
- Larger queue sizes allow for bigger result sets
- Worker executes in the context of the launching user

**Example:**
```sql
SELECT pg_background_launch('ANALYZE my_table', 131072); -- 128 KB queue
```

---

### pg_background_result

```sql
pg_background_result(pid INTEGER) RETURNS SETOF RECORD
```

Retrieves results from a background worker process.

**Parameters:**
- `pid`: Process ID returned by `pg_background_launch()`

**Returns:** Set of records matching the column definition list

**Behavior:**
- Blocks until worker completes
- Can only be called once per worker (results are consumed)
- Must provide column definition list in FROM clause
- If query returns rows, column types must match definition
- If query returns no rows, returns command completion tags as TEXT

**Errors:**
- `ERRCODE_UNDEFINED_OBJECT`: PID not attached to this session
- `ERRCODE_UNDEFINED_OBJECT`: Results already consumed
- `ERRCODE_CONNECTION_FAILURE`: Worker died prematurely
- `ERRCODE_DATATYPE_MISMATCH`: Result type mismatch

**Example:**
```sql
-- Query with result rows
SELECT * FROM pg_background_result(12345) AS (id INT, name TEXT);

-- Command with no result rows (returns tag)
SELECT * FROM pg_background_result(12345) AS (result TEXT);
```

---

### pg_background_detach

```sql
pg_background_detach(pid INTEGER) RETURNS VOID
```

Detaches from a background worker, allowing it to run independently.

**Parameters:**
- `pid`: Process ID of the worker to detach

**Returns:** Void

**Behavior:**
- Detaches the shared memory queue
- Worker continues execution even if launching session terminates
- Results can no longer be retrieved after detaching
- Use for fire-and-forget operations

**Errors:**
- `ERRCODE_UNDEFINED_OBJECT`: PID not attached to this session

**Example:**
```sql
-- Detach immediately after launch
PERFORM pg_background_detach(pg_background_launch('VACUUM FULL my_table'));
```

---

### grant_pg_background_privileges

```sql
grant_pg_background_privileges(
    user_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
) RETURNS BOOLEAN
```

Grants EXECUTE privileges on all pg_background functions to a role.

**Parameters:**
- `user_name`: Name of the role to grant privileges to
- `print_commands`: If TRUE, prints executed GRANT commands

**Returns:** TRUE on success, FALSE on error

**Security:** `SECURITY DEFINER` - runs as extension owner

**Example:**
```sql
CREATE ROLE background_user;
SELECT grant_pg_background_privileges('background_user', TRUE);
```

---

### revoke_pg_background_privileges

```sql
revoke_pg_background_privileges(
    user_name TEXT,
    print_commands BOOLEAN DEFAULT FALSE
) RETURNS BOOLEAN
```

Revokes EXECUTE privileges on all pg_background functions from a role.

**Parameters:**
- `user_name`: Name of the role to revoke privileges from
- `print_commands`: If TRUE, prints executed REVOKE commands

**Returns:** TRUE on success, FALSE on error

**Security:** `SECURITY DEFINER` - runs as extension owner

**Example:**
```sql
SELECT revoke_pg_background_privileges('background_user', TRUE);
DROP ROLE background_user;
```

## Usage Examples

### Long-Running Maintenance

```sql
-- Launch VACUUM in background
SELECT pg_background_launch('VACUUM VERBOSE ANALYZE large_table');

-- Check progress in pg_stat_activity
SELECT pid, state, query, state_change 
FROM pg_stat_activity 
WHERE query LIKE '%VACUUM%';

-- Retrieve results when complete
SELECT * FROM pg_background_result(12345) AS (result TEXT);
```

### Autonomous Transactions

```sql
-- Perform independent transaction in background
-- Useful for logging that should commit regardless of main transaction
DO $$
DECLARE
    log_worker INTEGER;
BEGIN
    log_worker := pg_background_launch(
        'INSERT INTO audit_log (event, timestamp) VALUES (''job_started'', now())'
    );
    PERFORM pg_background_detach(log_worker);
    
    -- Main work here (may rollback)
    -- Audit log entry is independent
END $$;
```

### Parallel Data Processing

```sql
-- Process data in parallel chunks
WITH workers AS (
    SELECT 
        partition_id,
        pg_background_launch(
            format('SELECT process_partition(%L)', partition_id)
        ) AS pid
    FROM generate_series(1, 10) AS partition_id
)
SELECT 
    partition_id,
    (SELECT result FROM pg_background_result(pid) AS (result BOOLEAN))
FROM workers;
```

### Timeout Pattern

```sql
-- Implement query timeout using statement_timeout in worker
SELECT * FROM pg_background_result(
    pg_background_launch(
        'SET statement_timeout = ''5s''; SELECT expensive_query()'
    )
) AS (result TEXT);
```

### Async Index Creation

```sql
-- Create index without blocking
SELECT pg_background_detach(
    pg_background_launch(
        'CREATE INDEX CONCURRENTLY idx_users_email ON users(email)'
    )
);

-- Monitor progress
SELECT 
    phase, 
    blocks_done, 
    blocks_total,
    round(100.0 * blocks_done / NULLIF(blocks_total, 0), 2) AS pct_done
FROM pg_stat_progress_create_index
WHERE command = 'CREATE INDEX CONCURRENTLY';
```

## Security & Permissions

### Permission Model

By default, all pg_background functions are **REVOKED from PUBLIC**. Access must be explicitly granted.

**Security Principles:**
1. **User Context:** Workers execute SQL as the launching user
2. **Role Membership:** Only users with role privileges can access worker results
3. **No Privilege Escalation:** Workers cannot perform actions the launching user couldn't do
4. **Session Isolation:** Workers from different sessions are isolated

### Recommended Setup

```sql
-- Create dedicated role for background processing
CREATE ROLE pg_bg_executor;

-- Grant necessary database privileges
GRANT CONNECT ON DATABASE mydb TO pg_bg_executor;
GRANT USAGE ON SCHEMA public TO pg_bg_executor;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO pg_bg_executor;

-- Grant pg_background privileges
SELECT grant_pg_background_privileges('pg_bg_executor', FALSE);

-- Assign role to users
GRANT pg_bg_executor TO alice, bob;
```

### Security Considerations

⚠️ **Important Security Notes:**

1. **SQL Injection:** The extension does not sanitize or validate SQL. Ensure input comes from trusted sources.

2. **Resource Limits:** Workers consume background worker slots. Set `max_worker_processes` appropriately.

3. **Memory Usage:** Large result sets require large queue sizes. Monitor shared memory consumption.

4. **Audit Logging:** Workers appear in `pg_stat_activity` but may not be logged depending on logging configuration.

5. **Superuser Bypass:** Superusers can launch workers and retrieve any user's results (by role membership).

## Architecture & Design

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                     Client Session                          │
│  ┌────────────────────────────────────────────────────┐    │
│  │  pg_background_launch('SELECT ...')                 │    │
│  │    ↓                                                 │    │
│  │  1. Allocate DSM segment                            │    │
│  │  2. Serialize: SQL, GUCs, user context              │    │
│  │  3. Create shared message queue                     │    │
│  │  4. Register background worker                      │    │
│  │  5. Return worker PID                               │    │
│  └────────────────────────────────────────────────────┘    │
│                           │                                  │
│                           │ DSM handle passed                │
│                           ↓                                  │
│  ┌────────────────────────────────────────────────────┐    │
│  │         Background Worker Process                   │    │
│  │  ┌──────────────────────────────────────────┐      │    │
│  │  │ 1. Attach to DSM segment                  │      │    │
│  │  │ 2. Extract SQL, GUCs, user context        │      │    │
│  │  │ 3. Connect to database as user            │      │    │
│  │  │ 4. Restore GUC state                      │      │    │
│  │  │ 5. Execute SQL                            │      │    │
│  │  │ 6. Send results to shared queue           │      │    │
│  │  │ 7. Signal completion                      │      │    │
│  │  └──────────────────────────────────────────┘      │    │
│  └────────────────────────────────────────────────────┘    │
│                           │                                  │
│                           │ Results via shm_mq               │
│                           ↓                                  │
│  ┌────────────────────────────────────────────────────┐    │
│  │  pg_background_result(pid)                          │    │
│  │    ↓                                                 │    │
│  │  1. Lookup worker by PID                            │    │
│  │  2. Read messages from queue                        │    │
│  │  3. Parse protocol messages (T, D, C, E, N)         │    │
│  │  4. Return rows or command tags                     │    │
│  │  5. Detach DSM on completion                        │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### Memory Management

- **DSM Segment:** Dynamically allocated shared memory for communication
- **Message Queue:** Fixed-size circular buffer for result transfer
- **Memory Contexts:** Separate contexts for parse/plan and execution
- **Result Buffers:** Binary protocol format for efficient transfer

### Protocol

Uses PostgreSQL's libpq protocol messages over shared memory:
- `T` - RowDescription (column metadata)
- `D` - DataRow (result row)
- `C` - CommandComplete (completion tag)
- `E` - ErrorResponse (error message)
- `N` - NoticeResponse (notice message)
- `Z` - ReadyForQuery (worker finished)

### Worker Lifecycle

1. **Launch:** Client allocates DSM, registers worker
2. **Startup:** Worker attaches to DSM, connects to database
3. **Execution:** Worker runs SQL, sends results to queue
4. **Completion:** Worker signals completion, exits
5. **Cleanup:** DSM is unmapped, resources released

## Performance Considerations

### Memory Usage

- **Queue Size:** Default 64 KB. Increase for large result sets.
- **DSM Overhead:** ~100 bytes per worker for metadata
- **Result Set:** Limited by queue size unless using detach

**Tuning Example:**
```sql
-- For large result sets, increase queue size
SELECT pg_background_launch(
    'SELECT * FROM huge_table',
    1048576  -- 1 MB queue
);
```

### Worker Limits

- **Max Workers:** Controlled by `max_worker_processes` GUC
- **Per-Database:** No built-in limit (respects total max)
- **Per-User:** No built-in limit

**Recommended Configuration:**
```sql
-- In postgresql.conf
max_worker_processes = 16        # Increase if needed
max_parallel_workers = 8         # Separate from pg_background
```

### Best Practices

✅ **Do:**
- Use detach for fire-and-forget operations
- Set appropriate queue sizes for expected result sets
- Monitor worker usage via `pg_stat_activity`
- Use statement timeouts to prevent runaway queries

❌ **Don't:**
- Launch hundreds of concurrent workers (resource exhaustion)
- Use tiny queue sizes for large result sets
- Assume workers complete in specific order
- Rely on worker PIDs for long-term tracking

## Limitations & Caveats

### Known Limitations

1. **Transaction Control:** Cannot use `BEGIN`, `COMMIT`, `ROLLBACK` in worker SQL
   - Each worker runs as a single auto-commit transaction

2. **PID Reuse:** Worker PIDs may be reused by the OS
   - Within a session, tracking is safe
   - Cross-session PID tracking is unreliable

3. **Result Retrieval:** Can only call `pg_background_result()` once per worker
   - Results are consumed and discarded after retrieval

4. **Error Handling:** FATAL errors in worker are downgraded to ERROR in client
   - Prevents client session termination

5. **COPY Protocol:** Not supported
   - Cannot use `COPY TO/FROM STDOUT` in worker

6. **Prepared Statements:** Not preserved across sessions
   - Each worker starts with fresh prepared statement namespace

### PostgreSQL Version Differences

- **< 10.0:** DSM pin/unpin race condition remains (rare)
- **>= 15.0:** Uses `pg_analyze_and_rewrite_fixedparams`
- **>= 18.0:** Updated for tuple descriptor API changes

## Troubleshooting

### Common Issues

#### "could not register background process"

**Cause:** Insufficient background worker slots

**Solution:**
```sql
-- Check current usage
SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'background worker';

-- Increase limit in postgresql.conf
max_worker_processes = 20

-- Restart PostgreSQL
```

#### "PID %d is not attached to this session"

**Cause:** Worker PID not found in session's hash table

**Possible Reasons:**
- Wrong PID specified
- Worker already consumed/detached
- PID from different session

**Solution:**
```sql
-- Verify worker is yours
SELECT pid, state, query FROM pg_stat_activity WHERE pid = 12345;
```

#### "results for PID %d have already been consumed"

**Cause:** Called `pg_background_result()` twice

**Solution:**
- Store results in a temporary table if needed multiple times
```sql
CREATE TEMP TABLE worker_results AS
SELECT * FROM pg_background_result(12345) AS (id INT, value TEXT);
```

#### "lost connection to worker process with PID %d"

**Cause:** Worker crashed or was killed

**Investigation:**
```sql
-- Check PostgreSQL logs for worker error messages
-- Look for:
--   "background worker ... exited with exit code ..."
--   "terminating background worker ... due to administrator command"
```

#### "remote query result rowtype does not match"

**Cause:** Column definition list doesn't match actual result

**Solution:**
```sql
-- Ensure types match exactly
-- Wrong:
SELECT * FROM pg_background_result(pid) AS (count TEXT);

-- Right (if query returns BIGINT):
SELECT * FROM pg_background_result(pid) AS (count BIGINT);
```

### Debugging Tips

#### Enable Verbose Logging

```sql
-- In postgresql.conf or SET command
log_min_messages = DEBUG1
log_error_verbosity = VERBOSE
```

#### Monitor Active Workers

```sql
-- View all pg_background workers
SELECT 
    pid, 
    application_name,
    state,
    query,
    backend_start,
    state_change,
    now() - state_change AS duration
FROM pg_stat_activity
WHERE application_name LIKE '%pg_background%'
   OR query LIKE '%pg_background%';
```

#### Check DSM Usage

```sql
-- PostgreSQL 13+
SELECT * FROM pg_shmem_allocations 
WHERE name LIKE '%dsm%';
```

## Compatibility

### Supported PostgreSQL Versions

| Version | Status | Notes |
|---------|--------|-------|
| 9.5     | ✅ Supported | Original target version |
| 10.x    | ✅ Supported | Added DSM segment pinning |
| 11.x    | ✅ Supported | Background worker type support |
| 12.x    | ✅ Supported | |
| 13.x    | ✅ Supported | Command tag enum changes |
| 14.x    | ✅ Supported | |
| 15.x    | ✅ Supported | Query analysis API changes |
| 16.x    | ✅ Supported | |
| 17.x    | ✅ Supported | |
| 18.x    | ✅ Supported | Latest - Tuple descriptor API updates |

### Upgrade Path

#### From v1.4 to v1.6

```sql
-- No data migration needed
ALTER EXTENSION pg_background UPDATE TO '1.6';
```

**Changes in v1.6:**
- Fixed memory leaks in result processing
- Added NULL pointer checks for stability
- Improved error messages with better context
- Fixed SQL injection in privilege grant/revoke INFO messages
- Enhanced documentation

**Breaking Changes:** None (fully backward compatible)

### Platform Support

- **Linux:** ✅ Fully supported (primary development platform)
- **macOS:** ✅ Supported
- **Windows:** ⚠️ Experimental (see `windows/` directory for patches)
- **FreeBSD:** ✅ Supported
- **Other UNIX:** Likely works (not regularly tested)

## Development

### Building for Development

```bash
# Debug build with assertions
make clean
CFLAGS="-g -O0 -DUSE_ASSERT_CHECKING" make

# Install to local PostgreSQL
make install

# Run regression tests
make installcheck
```

### Running Tests

```bash
# Basic regression test
make installcheck

# Verbose output
make installcheck REGRESS_OPTS="--verbose"

# Specific test
make installcheck REGRESS=pg_background
```

### Code Style

Follows PostgreSQL coding conventions:
- pgindent for formatting
- Tab indentation (4 spaces display)
- Max 80 characters per line (preferred)
- Function comments in header style

### Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes with tests
4. Run `make installcheck`
5. Submit pull request

### Reporting Issues

Include:
- PostgreSQL version (`SELECT version()`)
- Extension version (`SELECT extversion FROM pg_extension WHERE extname = 'pg_background'`)
- Operating system
- Minimal reproduction case
- PostgreSQL logs (if crash/error)

## License

GNU General Public License v3.0

See [LICENSE](LICENSE) file for full text.

## Authors

- **Vibhor Kumar** - Original author
- **Contributors:**
  - @a-mckinley
  - @rjuju
  - @svorcmar
  - @egor-rogov
  - @RekGRpth
  - @Hiroaki-Kubota

## Acknowledgments

- PostgreSQL Global Development Group for the background worker API
- All contributors and issue reporters

## Additional Resources

- [PostgreSQL Background Workers Documentation](https://www.postgresql.org/docs/current/bgworker.html)
- [Dynamic Shared Memory](https://www.postgresql.org/docs/current/dsm.html)
- [Extension Building Infrastructure](https://www.postgresql.org/docs/current/extend-pgxs.html)

---

**Last Updated:** 2026-02-05  
**Extension Version:** 1.6  
**Documentation Version:** 1.0
