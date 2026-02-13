# pg_background v1.7 Improvements

This document summarizes all improvements made in version 1.7, organized by priority level.

## High Priority Fixes

### 1. Cryptographically Secure Cookie Generation

**Problem:** The original cookie generation was deterministic and predictable:
```c
// OLD CODE - Predictable!
uint64 t = (uint64) GetCurrentTimestamp();
uint64 c = (t << 17) ^ (t >> 13) ^ (uint64) MyProcPid ^ (uint64) (uintptr_t) MyProc;
```

An attacker who knows the approximate timestamp and PID could guess the cookie, potentially hijacking background workers.

**Solution:** Use PostgreSQL's cryptographically secure random number generator:
```c
// NEW CODE - Secure
if (!pg_strong_random(&cookie, sizeof(cookie)))
{
    elog(DEBUG1, "pg_strong_random failed, using fallback");
    cookie = pg_background_fallback_random();
}
```

**Benefits:**
- Cookies are now unpredictable (backed by OS CSPRNG)
- Includes fallback for rare CSPRNG failures
- No API changes required

---

### 2. Dedicated Memory Context for Worker Info

**Problem:** Worker tracking data was allocated in `TopMemoryContext`:
```c
// OLD CODE - Memory bloat risk
oldcontext = MemoryContextSwitchTo(TopMemoryContext);
state->info->last_error = pstrdup(edata.message);
```

Long-lived sessions with many workers could accumulate unbounded memory, leading to session memory bloat.

**Solution:** Create a dedicated memory context:
```c
// NEW CODE - Isolated memory management
static MemoryContext WorkerInfoMemoryContext = NULL;

static void ensure_worker_info_memory_context(void)
{
    if (WorkerInfoMemoryContext == NULL)
    {
        WorkerInfoMemoryContext = AllocSetContextCreate(TopMemoryContext,
                                                        "pg_background worker info",
                                                        ALLOCSET_DEFAULT_SIZES);
    }
}
```

**Benefits:**
- Worker info memory is isolated and trackable
- Enables future bulk cleanup operations
- Prevents TopMemoryContext bloat
- Hash table now uses `HASH_CONTEXT` flag for proper memory management

---

## Medium Priority Fixes

### 3. Exponential Backoff in Polling Loops

**Problem:** Fixed 10ms polling interval was inefficient:
```c
// OLD CODE - Fixed interval
for (;;)
{
    ...
    pg_usleep(10 * 1000L);  // Always 10ms
    CHECK_FOR_INTERRUPTS();
}
```

This wastes CPU cycles for long waits and adds unnecessary latency for short waits.

**Solution:** Implement exponential backoff:
```c
// NEW CODE - Adaptive polling
#define PGBG_POLL_INTERVAL_MIN_US   1000    // 1ms minimum
#define PGBG_POLL_INTERVAL_MAX_US   100000  // 100ms maximum
#define PGBG_POLL_BACKOFF_FACTOR    2       // Double each iteration

static void pgbg_sleep_with_backoff(long *interval_us)
{
    pg_usleep(*interval_us);
    *interval_us *= PGBG_POLL_BACKOFF_FACTOR;
    if (*interval_us > PGBG_POLL_INTERVAL_MAX_US)
        *interval_us = PGBG_POLL_INTERVAL_MAX_US;
}
```

**Benefits:**
- Quick response for short operations (starts at 1ms)
- Reduced CPU usage for long waits (caps at 100ms)
- Configurable via constants for tuning

**Applied to:**
- `pg_background_wait_v2_timeout()`
- `pgbg_send_cancel_signals()` (grace period polling)

---

### 4. Eliminated Code Duplication

**Problem:** `pg_background_launch_v2` and `pg_background_submit_v2` had ~90% identical code:
```c
// OLD CODE - Duplicated in both functions
Datum values[2];
bool isnulls[2] = {false, false};
TupleDesc tupdesc;
HeapTuple tuple;

if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
    ereport(ERROR, ...);
tupdesc = BlessTupleDesc(tupdesc);
values[0] = Int32GetDatum((int32) pid);
values[1] = Int64GetDatum((int64) cookie);
tuple = heap_form_tuple(tupdesc, values, isnulls);
```

**Solution:** Extract common logic into helper function:
```c
// NEW CODE - Single implementation
static Datum build_handle_tuple(FunctionCallInfo fcinfo, pid_t pid, uint64 cookie)
{
    Datum values[2];
    bool isnulls[2] = {false, false};
    TupleDesc tupdesc;
    HeapTuple tuple;

    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR, ...);
    tupdesc = BlessTupleDesc(tupdesc);
    values[0] = Int32GetDatum((int32) pid);
    values[1] = Int64GetDatum((int64) cookie);
    tuple = heap_form_tuple(tupdesc, values, isnulls);
    return HeapTupleGetDatum(tuple);
}

// Usage is now simple:
Datum pg_background_launch_v2(PG_FUNCTION_ARGS)
{
    ...
    launch_internal(sql, queue_size, cookie, false, &pid);
    PG_RETURN_DATUM(build_handle_tuple(fcinfo, pid, cookie));
}
```

**Benefits:**
- Single point of maintenance
- Reduced binary size
- Consistent behavior guaranteed
- Easier to test

---

### 5. Error Message Storage Refactoring

**Problem:** Error storage logic was inline and verbose:
```c
// OLD CODE - Inline with magic numbers
if (msg_len > 512)
{
    char *truncated = (char *) palloc(513);
    memcpy(truncated, edata.message, 509);
    strcpy(truncated + 509, "...");
    state->info->last_error = truncated;
}
```

**Solution:** Extract into dedicated function with named constants:
```c
// NEW CODE - Clean abstraction
#define PGBG_MAX_ERROR_MSG_LEN 512

static void store_worker_error(pg_background_worker_info *info, const char *message)
{
    MemoryContext oldcxt = MemoryContextSwitchTo(WorkerInfoMemoryContext);

    if (info->last_error != NULL)
    {
        pfree(info->last_error);
        info->last_error = NULL;
    }

    if (message != NULL)
    {
        size_t msg_len = strlen(message);
        if (msg_len > PGBG_MAX_ERROR_MSG_LEN)
        {
            char *truncated = palloc(PGBG_MAX_ERROR_MSG_LEN + 1);
            memcpy(truncated, message, PGBG_MAX_ERROR_MSG_LEN - 3);
            strcpy(truncated + PGBG_MAX_ERROR_MSG_LEN - 3, "...");
            info->last_error = truncated;
        }
        else
        {
            info->last_error = pstrdup(message);
        }
    }
    else
    {
        info->last_error = pstrdup("unknown error");
    }

    MemoryContextSwitchTo(oldcxt);
}
```

**Benefits:**
- Named constant for truncation limit
- Proper memory context switching
- Reusable across codebase
- Clear responsibility

---

## Low Priority Fixes

### 6. Comprehensive Documentation

**Problem:** Functions lacked documentation headers describing parameters, return values, and behavior.

**Solution:** Added structured documentation blocks for all public and key internal functions:

```c
/*
 * pg_background_launch_v2
 *     Launch a background worker with cookie validation (v2 API).
 *
 * Parameters:
 *     sql        - SQL command(s) to execute (text)
 *     queue_size - Shared memory queue size in bytes (default 65536)
 *
 * Returns: pg_background_handle composite (pid int4, cookie int8)
 *
 * Notes:
 *     - Cookie provides protection against PID reuse attacks
 *     - Results retrieved with pg_background_result_v2(pid, cookie)
 *     - Use pg_background_cancel_v2() to cancel (unlike v1 detach)
 */
```

**Benefits:**
- Self-documenting code
- Easier onboarding for contributors
- IDE/editor tooltip support
- Consistent documentation style

---

### 7. Named Constants for All Magic Numbers

**Problem:** Magic numbers scattered throughout code:
```c
// OLD CODE
if (msg_len > 512)
pg_usleep(10 * 1000L);
hash_create(..., 16, ...);
grace_ms > 3600000
```

**Solution:** Define named constants at the top of the file:
```c
// NEW CODE - Self-documenting constants
#define PGBG_MAX_ERROR_MSG_LEN      512
#define PGBG_POLL_INTERVAL_MIN_US   1000    // 1ms
#define PGBG_POLL_INTERVAL_MAX_US   100000  // 100ms
#define PGBG_POLL_BACKOFF_FACTOR    2
#define PGBG_WORKER_HASH_INIT_SIZE  32
#define PGBG_GRACE_MS_MAX           3600000 // 1 hour
```

**Benefits:**
- Single point of configuration
- Self-documenting
- Easy to tune for different workloads
- Prevents inconsistencies

---

### 8. Code Organization with Section Headers

**Problem:** 1700+ line file with minimal organization.

**Solution:** Added clear section delimiters:
```c
/* ============================================================================
 * CONSTANTS
 * ============================================================================
 */

/* ============================================================================
 * DATA STRUCTURES
 * ============================================================================
 */

/* ============================================================================
 * V2 API FUNCTIONS
 * ============================================================================
 */
```

**Benefits:**
- Easier navigation
- Clear logical grouping
- Faster code reviews
- Better IDE outline support

---

### 9. Enhanced Header File

**Problem:** Header file lacked overview documentation.

**Solution:** Added file-level documentation:
```c
/*--------------------------------------------------------------------------
 *
 * pg_background.h
 *     Header file for pg_background extension.
 *
 * This file contains compatibility macros for supporting multiple
 * PostgreSQL versions (14-18).
 *
 * Copyright (C) 2014, PostgreSQL Global Development Group
 *
 * -------------------------------------------------------------------------
 */
```

---

### 10. DSM Creation Error Check

**Problem:** `dsm_create()` return value wasn't explicitly checked:
```c
// OLD CODE
seg = dsm_create(segsize, 0);
toc = shm_toc_create(...);  // Could crash if seg is NULL
```

**Solution:** Add explicit NULL check with helpful error message:
```c
// NEW CODE
seg = dsm_create(segsize, 0);
if (seg == NULL)
    ereport(ERROR,
            (errcode(ERRCODE_OUT_OF_MEMORY),
             errmsg("could not create dynamic shared memory segment"),
             errhint("You may need to increase dynamic_shared_memory_bytes or max_worker_processes.")));
```

---

## Summary

| Priority | Issue | Fix | Impact |
|----------|-------|-----|--------|
| High | Predictable cookies | pg_strong_random() | Security |
| High | Memory bloat | Dedicated MemoryContext | Stability |
| Medium | CPU waste in polling | Exponential backoff | Performance |
| Medium | Code duplication | Helper functions | Maintainability |
| Low | Missing docs | Function headers | Developer experience |
| Low | Magic numbers | Named constants | Readability |
| Low | Poor organization | Section headers | Navigation |

## Upgrade Path

```sql
-- From 1.6 to 1.7:
ALTER EXTENSION pg_background UPDATE TO '1.7';
```

No SQL schema changes. All improvements are internal C code optimizations.

## Testing Recommendations

After applying this patch, verify:

1. **Cookie uniqueness**: Launch multiple workers rapidly and verify cookies are unique
2. **Memory stability**: Monitor session memory during long-running workloads
3. **Polling efficiency**: Profile CPU usage during wait_v2_timeout operations
4. **Backward compatibility**: Ensure existing v1 and v2 API calls work unchanged
