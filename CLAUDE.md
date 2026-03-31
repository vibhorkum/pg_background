# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## 1. Repository Purpose

pg_background is a PostgreSQL extension that executes SQL commands in background worker processes. Workers run inside the PostgreSQL server with their own transactions, enabling:

- Asynchronous SQL execution without blocking client sessions
- Autonomous transactions that commit/rollback independently of the caller
- Observable worker lifecycle with explicit launch/wait/cancel/detach semantics

**Appropriate changes include:**
- Bug fixes to worker lifecycle, DSM handling, or result streaming
- Improvements to observability, error handling, or resource cleanup
- PostgreSQL version compatibility updates
- Security hardening
- API ergonomics improvements that preserve backward compatibility
- Documentation and test coverage improvements

**Changes that require careful consideration:**
- New SQL-callable functions (API surface expansion)
- Changes to handle/cookie semantics
- Modifications to worker transaction behavior
- Anything affecting upgrade paths

---

## 2. Core Design Principles

### Preserve PostgreSQL-native design
This extension uses PostgreSQL's native Background Worker API, Dynamic Shared Memory, and SPI. Do not introduce external dependencies or non-PostgreSQL patterns.

### Prefer simple APIs over feature creep
The extension provides async SQL execution primitives. Resist adding orchestration, scheduling, or workflow features that belong in application code or dedicated tools like pg_cron.

### Keep background worker behavior understandable
Workers execute SQL in independent transactions. This autonomy is the feature, not a bug. Do not add implicit coordination that obscures transaction boundaries.

### Prefer explicit behavior over magic
- `detach_v2()` removes tracking; it does NOT cancel
- `cancel_v2()` requests termination; it does NOT guarantee immediate stop
- Results are consumed once; there is no hidden caching

Document behavioral semantics precisely. Users should never be surprised by what a function does.

### Maintain two API generations carefully
- v1 API: Preserved for backward compatibility. Do not add features to v1.
- v2 API: Cookie-protected handles, explicit lifecycle. New features go here.

Do not blur the distinction between v1 and v2 semantics.

---

## 3. PostgreSQL Extension Rules

### Control file semantics
- `pg_background.control` declares `relocatable = true`
- `default_version` must match the latest `pg_background--X.Y.sql`
- Do not add `requires` unless genuinely needed

### Install and upgrade scripts
- Base install scripts: `pg_background--X.Y.sql` (complete, standalone)
- Upgrade scripts: `pg_background--X.Y--X.Z.sql` (incremental changes only)
- Upgrade scripts must be idempotent where possible
- Never break upgrade paths from supported prior versions
- Test upgrades explicitly: `ALTER EXTENSION pg_background UPDATE TO 'X.Y'`

### Version support
- Supported: PostgreSQL 14, 15, 16, 17, 18
- Version-specific code uses `#if PG_VERSION_NUM` guards in C
- Compatibility macros live in `pg_background.h`
- Do not add version-specific SQL without strong justification

### Schema and ownership
- Extension objects belong to the installing superuser
- The extension is relocatable; do not hardcode `public.` in SQL scripts
- Use `@extschema@` or dynamic schema lookup for cross-references
- `pgbackground_role` is created for privilege management; do not grant to PUBLIC

---

## 4. C Code Rules

### Follow PostgreSQL backend coding patterns
- 4-space indentation, no tabs
- K&R brace style
- C-style comments only (`/* */`)
- Function names: `lowercase_with_underscores`
- Macros: `UPPERCASE_WITH_UNDERSCORES`

### Memory context discipline
- Use `palloc`/`pfree`, never `malloc`/`free`
- Long-lived allocations use dedicated memory contexts (e.g., `PgBackgroundWorkerContext`)
- Worker info hash entries are context-managed to prevent session memory bloat
- Clean up in error paths using `PG_TRY`/`PG_CATCH`/`PG_FINALLY`

### SPI and transaction handling
- Workers use `SPI_connect()`/`SPI_finish()` for SQL execution
- Workers run in their own transaction; do not assume caller's transaction state
- Commit happens automatically when worker exits cleanly
- Explicit `SPI_commit()` calls are not used; worker exit triggers commit

### Worker lifecycle and cleanup
- DSM segments are created by launcher, attached by worker
- Worker attaches DSM on startup, detaches on exit (automatic cleanup)
- Launcher tracks workers in session-local hash table
- Never `pfree()` the `BackgroundWorkerHandle`; let PostgreSQL manage it
- Use `shm_mq_wait_for_attach()` before returning handle to SQL (prevents NOTIFY race)

### Concurrency and state
- Worker hash table is session-local; no cross-session visibility
- Cookie validation prevents PID reuse confusion
- Use `pg_strong_random()` for cryptographically secure cookie generation
- Polling loops use exponential backoff to reduce CPU usage
- Always call `CHECK_FOR_INTERRUPTS()` in loops

### DSM synchronization patterns
- Worker writes to DSM fields may be observed concurrently by launcher
- For multi-field data, use a "publish flag" pattern: write data fields first, then the flag
- Use `pg_write_barrier()` before setting publish flag to ensure field ordering
- Readers check the flag first, then `pg_read_barrier()`, then read other fields
- Example: `error_sqlstate` is the publish flag for error fields; written LAST by worker
- `cleanup_worker_info` callback can read DSM before unmap; use `seg` argument

### Comments
- Document non-obvious backend behavior
- Explain why certain PostgreSQL APIs are used
- Mark fields in structs with access patterns: `[L]` launcher, `[W]` worker, `[B]` both

---

## 5. Security Rules

### Unsafe search_path
- All `SECURITY DEFINER` functions must set `search_path = pg_catalog`
- Do not rely on caller's `search_path` for object resolution in privileged functions
- The privilege helper functions (`grant_pg_background_privileges`, etc.) use dynamic schema lookup

### Caller-controlled SQL
- Workers execute arbitrary SQL provided by the caller
- This is intentional; the caller's privileges apply
- Do not execute caller SQL with elevated privileges
- Document SQL injection risks clearly; recommend `format()` with `%L`/`%I`

### Privilege model
- Workers inherit `current_user` from launcher, not superuser
- Extension functions are granted to `pgbackground_role`, not PUBLIC
- Users must be explicitly granted `pgbackground_role` or function EXECUTE
- `SECURITY DEFINER` is used only for privilege helper functions, not core operations

### Input validation
- Validate `queue_size` bounds (min: `shm_mq_minimum_size`, max: 256MB)
- Validate `grace_ms` bounds (max: 1 hour)
- Validate `timeout_ms` bounds (max: 24 hours)
- Truncate SQL preview safely (UTF-8 aware) to prevent buffer issues

### Resource abuse prevention
- `pg_background.max_workers` GUC limits concurrent workers per session
- Workers count against global `max_worker_processes`
- DSM segments are bounded by `queue_size` parameter
- Long-running workers should use `statement_timeout`

### Keep internals private
- Internal helper functions in C are `static`
- Internal SQL functions use naming conventions that discourage direct use
- Do not expose DSM handles or internal state to SQL callers

---

## 6. API Design Rules

### Keep the SQL API simple and explicit
- Function names clearly indicate behavior: `launch`, `result`, `detach`, `cancel`, `wait`, `submit`
- `_v2` suffix distinguishes cookie-protected API from legacy
- Return types are explicit: `pg_background_handle`, `pg_background_stats`, etc.

### Naming consistency
- All v2 functions: `pg_background_<verb>_v2`
- Variants with options: `pg_background_<verb>_v2_<option>` (e.g., `wait_v2_timeout`, `cancel_v2_grace`)
- Type names: `pg_background_<noun>`

### Backward compatibility
- v1 API is frozen; do not change signatures or behavior
- v2 API additions must not break existing v2 callers
- New optional parameters should have sensible defaults
- Deprecate, do not remove, unless security requires it

### Document behavioral semantics
- `detach` vs `cancel`: different operations, document the distinction everywhere
- Result consumption: one-time only, document clearly
- Worker state values: `running`, `stopped`, `canceled`, `error` - defined meanings

### Runtime behavior changes
- Any change to when/how workers commit requires documentation update
- Any change to error handling requires test update
- Do not silently change timeout, cleanup, or cancellation behavior

---

## 7. Testing Rules

### Regression tests for new behavior
- All new SQL functions need tests in `sql/pg_background.sql`
- Expected output in `expected/pg_background.out`
- Alternative outputs (version differences) in `expected/pg_background_1.out`

### Test coverage requirements
- Happy path: launch, result retrieval, cleanup
- Cancel path: verify work is not committed after cancel
- Detach path: verify work IS committed after detach (detach != cancel)
- Error conditions: invalid handles, cookie mismatches, resource exhaustion
- Privilege paths: verify `pgbackground_role` grants work correctly
- Timeout behavior: `wait_v2_timeout` returns false on timeout, true on completion

### Version-sensitive testing
- `./test-local.sh all` tests PostgreSQL 14-18
- CI matrix covers ubuntu-22.04 and ubuntu-24.04 with all PG versions
- Version-specific expected outputs when necessary

### CI pipeline coverage
- **Main test matrix**: Runs `make installcheck` on PG 14-18 × ubuntu-22.04/24.04
- **Relocatable test**: Verifies extension works in custom schema (not just `public`)
- **Upgrade test**: Validates upgrade path from 1.8 → 1.9 using `test-upgrade.sh`
- All three test types must pass before merge

### Upgrade path testing
- `./test-upgrade.sh [PG_VERSION]` tests extension upgrades in Docker
- Validates: old version installs, old functionality works, upgrade succeeds, new features work, old features preserved
- Always test upgrade paths when adding new functions or types
- Upgrade scripts must be additive; never remove objects in upgrade scripts

### Failure and cleanup testing
- Test worker crash behavior
- Test launcher session termination
- Test DSM cleanup after abnormal exit
- Test `max_workers` limit enforcement

### Test maintenance
- Do not remove test coverage without equivalent replacement
- Flaky tests (timing-dependent) should use adequate sleep margins

### Test isolation and independence
- Each test section should be self-contained and not rely on state from other sections
- Explicitly clean up resources (detach workers) after each test
- Do not rely on batch operations (like `detach_all_v2`) to clean up from earlier tests
- Test comments must accurately describe what the test verifies
- Tests must be deterministic; avoid race conditions in assertions

---

## 8. Documentation Rules

### README accuracy
- README.md must match actual current behavior
- API reference must list all functions with correct signatures
- Examples must be tested and working

### Honest limitations
- Document Windows cancel limitations clearly
- Document `max_worker_processes` exhaustion behavior
- Document one-time result consumption
- Document autonomous transaction implications

### Version documentation
- Supported PostgreSQL versions in README and control file
- Migration guide for version upgrades
- Breaking changes documented in version sections

### Operational guidance
- Document GUC settings and their effects
- Document resource implications (DSM, worker slots)
- Document monitoring approaches (`list_v2`, `stats_v2`, `pg_stat_activity`)

### Distinguish usage from internals
- User-facing API documentation in main README sections
- Architecture and design details in dedicated section
- Internal implementation notes in code comments, not user docs

---

## 9. Review Rules

### Prefer minimal reviewable patches
- One logical change per PR
- Separate refactoring from behavioral changes
- Separate documentation from code changes when substantial

### Avoid unrelated refactors
- Do not "clean up" code unrelated to the PR's purpose
- Style-only changes should be separate PRs
- Do not move code around without clear justification

### Explain breaking changes explicitly
- PR description must call out any API changes
- PR description must call out any behavioral changes
- Upgrade path implications must be documented

### Correctness over cleverness
- Prefer straightforward code that's obviously correct
- Avoid clever optimizations without measured justification
- Avoid premature abstraction

### Review checklist
- [ ] Compiles without warnings on all supported PG versions
- [ ] Regression tests pass (`make installcheck`)
- [ ] New behavior has test coverage
- [ ] Documentation updated if user-visible
- [ ] No memory leaks (check with valgrind if uncertain)
- [ ] No resource leaks (DSM, worker slots)
- [ ] Security implications considered

### Validating AI-generated code reviews (GitHub Copilot, etc.)
- Always validate review comments against actual code and repository context
- Do not assume AI suggestions are correct just because they sound plausible
- Skip reviews that are incorrect or do not fit the PostgreSQL extension context
- Prefer simple, practical fixes over clever or invasive changes
- When a pattern issue is identified, check nearby code for similar problems

### SQL/C alignment requirements
- If SQL function is not STRICT, C code must check `PG_ARGISNULL()` for required parameters
- If C code stores data in DSM, ensure it's exposed through observable SQL APIs
- New features must be testable via SQL (not just internal state changes)
- Windows exports (`windows/pg_background_win.h`) must include all SQL-callable functions

### Upgrade script safety
- Do not DROP and recreate public functions in upgrade scripts (breaks grants/OIDs)
- When adding optional parameters, add function overloads rather than dropping/recreating
- Keep fresh install and upgrade paths aligned in functionality
- Preserve grants by adding new signatures alongside existing ones

### Statistics accounting consistency
- Stats increments should happen in one place, typically cleanup functions
- Avoid double-counting: if cleanup increments a stat, don't also increment in the triggering function
- Keep cancel/complete/fail paths consistent in their stats accounting

### Batch helper function semantics
- Batch functions (e.g., `cancel_all_v2`, `detach_all_v2`) should stay semantically aligned with their single-operation equivalents
- Return values should reflect actual completed operations, not snapshot counts (workers may be cleaned up between snapshot and processing)
- For cancel operations: set cancel flag for all workers (including not-yet-started), but only send signals to started workers
- Keep internal comments aligned with actual column lists when output shape changes

### v2 API error handling consistency
- All v2 functions should use the same handle-validation pattern:
  - Missing PID: `ERRCODE_UNDEFINED_OBJECT`, `"PID %d is not attached to this session"`
  - Cookie mismatch: `ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE`, `"cookie mismatch for PID %d"`, with hint `"The worker may have been restarted or the handle is stale."`
- New v2 functions must follow this established convention unless there is a documented reason to differ

### Test coverage for new features
- Feature tests must verify the actual visible value of the feature, not just exercise it
- For metadata features (labels, result info, error info), add direct assertions that query and verify the value
- Example: if adding a label parameter, add a test that queries `list_v2()` and verifies the label is visible

### Shell script patterns (test-upgrade.sh, test-local.sh)
- With `set -e`, do not rely on `$?` checks after commands that would already abort
- Use `if ! command; then` instead of `command; if [ $? -ne 0 ]`
- Use `psql -X -v ON_ERROR_STOP=1` in automated test scripts to ensure SQL errors propagate as non-zero exit codes
- Ensure cleanup runs on all exit paths via `trap 'cleanup' EXIT` rather than manual cleanup calls before each exit
- Test scripts should rely on output string matching for SQL success when ON_ERROR_STOP is not used (psql returns 0 even for SQL errors)

---

## 10. Feature Scope Guidance

### Good fit for pg_background

| Feature Type | Examples |
|--------------|----------|
| Safer async execution | Better error propagation, structured error returns |
| Observability | Progress reporting, execution statistics, worker introspection, labels |
| Result/error handling | Improved result metadata, error context preservation |
| Resource management | Better worker limits, queue size tuning, timeout enforcement |
| API ergonomics | Convenience wrappers, batch operations, better handle management |
| Security hardening | Privilege model improvements, input validation |

### v1.9 Features (Current)

| Feature | Function/Type |
|---------|---------------|
| Worker labels | `label` parameter on `launch_v2`/`submit_v2` |
| Structured errors | `pg_background_error_info_v2()`, `pg_background_error` type |
| Result metadata | `pg_background_result_info_v2()`, `pg_background_result_info` type |
| Batch operations | `pg_background_detach_all_v2()`, `pg_background_cancel_all_v2()` |

### Bad fit for pg_background

| Feature Type | Why it doesn't belong |
|--------------|----------------------|
| Full job scheduler | Use pg_cron; pg_background is for ad-hoc async execution |
| Distributed queue | Application-layer concern; adds complexity and dependencies |
| Workflow orchestration | Out of scope; pg_background executes SQL, not workflows |
| Cross-database execution | PostgreSQL limitation; use dblink within workers if needed |
| Persistent job storage | Requires tables, state management; not extension's purpose |
| Retry logic | Application-layer concern; extension provides primitives |
| Result caching | Complicates semantics; results are intentionally one-time |

### Gray areas (discuss before implementing)

- Worker pools with pre-forked processes
- Priority queues for worker scheduling
- Cross-session worker visibility
- Automatic cleanup policies
- Integration hooks for external monitoring

---

## Build Commands

```bash
# Build (requires PostgreSQL dev headers, pg_config in PATH)
make clean && make

# Install (requires appropriate privileges)
sudo make install

# Run regression tests
make installcheck

# Clean test artifacts
make installcheckclean

# Docker-based testing (no local PostgreSQL required)
./test-local.sh          # Test with PostgreSQL 17 (default)
./test-local.sh 14       # Test with specific version
./test-local.sh all      # Test all supported versions (14-18)

# Upgrade path testing
./test-upgrade.sh        # Test 1.8 → 1.9 upgrade on PG 17
./test-upgrade.sh 16     # Test upgrade on specific PG version
```

---

## Architecture Quick Reference

```
Launcher Session                    Background Worker
       |                                   |
       | pg_background_launch_v2()         |
       |   - Allocate DSM segment          |
       |   - Write SQL, GUCs, metadata     |
       |   - RegisterDynamicBackgroundWorker()
       |   - Wait for shm_mq attach        |
       |                                   |
       |<---- (pid, cookie) handle --------|
       |                                   |
       |                            Worker starts:
       |                              - Attach DSM
       |                              - Connect to database
       |                              - SPI_execute(SQL)
       |                              - Stream results via shm_mq
       |                              - Exit (auto-commit)
       |                                   |
       | pg_background_result_v2()         |
       |   - Read from shm_mq              |
       |   - Return result rows            |
       |                                   |
       | pg_background_detach_v2()         |
       |   - Remove from tracking hash     |
       |   - DSM cleanup                   |
       v                                   v
```

### Key Files

| File | Purpose |
|------|---------|
| `pg_background.c` | All C implementation (~3200 lines) |
| `pg_background.h` | Version compatibility macros |
| `pg_background.control` | Extension metadata (version 1.9) |
| `pg_background--1.9.sql` | Current version install script |
| `pg_background--1.8--1.9.sql` | Upgrade from 1.8 |
| `sql/pg_background.sql` | Regression tests |
| `expected/pg_background.out` | Expected test output |
| `test-local.sh` | Docker-based multi-version testing |
| `test-upgrade.sh` | Docker-based upgrade path testing |
| `.github/workflows/ci.yml` | CI pipeline (test matrix, relocatable, upgrade) |

## 11. Incremental Prompt Mode (AI Workflow Contract)

This repository supports **incremental prompt mode** to reduce repetitive instructions.

When a prompt contains only:

- GitHub Copilot feedback
- CI failures
- Regression diffs
- Small feature requests
- Documentation fixes

Claude should automatically:

- Apply all rules from this `CLAUDE.md`
- Treat the prompt as **delta-only instructions**
- Avoid requiring repeated instructions

### Default Workflow for Incremental Prompts

When receiving incremental prompts, Claude should automatically:

#### 1. Validate Suggestions First
- Validate GitHub Copilot feedback against actual repository context
- Validate CI failure root cause before changing code
- Validate regression diffs before changing expected output
- Confirm SQL/C/test/doc consistency before applying fixes

Do **not** blindly apply suggestions.

#### 2. Prefer Minimal Practical Fixes
- Avoid large refactors unless explicitly requested
- Avoid unrelated cleanup
- Prefer small, targeted, maintainable fixes
- Preserve existing behavior unless a behavior change is intentional and documented

#### 3. Check Nearby Similar Areas
When fixing one issue:
- Inspect nearby code for the same issue pattern
- Fix similar occurrences when low risk and clearly useful
- Avoid broad invasive changes

#### 4. Maintain Cross-Component Consistency
When modifying code, keep these aligned:
- C code
- SQL install scripts
- SQL upgrade scripts
- Regression tests
- Expected output files
- Docker tests
- CI workflows
- README and other docs

#### 5. Run Required Validation
After changes, run what is relevant:
- `make`
- `make installcheck`
- Docker/local test scripts if affected
- Upgrade tests if affected
- Relocatable tests if affected
- CI-equivalent checks if practical

Be explicit about what was actually run versus only inspected.

#### 6. Keep Documentation Current
Update when necessary:
- `README.md`
- `CLAUDE.md`
- `.github/copilot-instructions.md`

Documentation must match actual behavior.

#### 7. Branch Discipline
- Stay on the current branch
- Do **not** create a new branch unless explicitly requested
- Keep changes logically grouped and reviewable

### Prompt Contract

When a user provides a short prompt with only incremental items, assume:

- `CLAUDE.md` is the standing base instruction set
- The prompt contains only the new delta
- All repository rules apply automatically

### Example Incremental Prompt

Example minimal prompt:

```text
Review the following Copilot feedback:

1. ...
2. ...
3. ...
```

Fix where appropriate.

Claude should automatically:
- Validate feedback
- Apply minimal fixes
- Update tests if needed
- Update docs if needed
- Run validation

#### Example CI Failure Prompt
```text
Fix the following CI failure:

<logs>
```
Claude should automatically:
- Identify root cause
- Apply minimal correct fix
- Update tests/docs if required
- Validate the result

#### Example Regression Diff Prompt
```text
Fix regression diff:

<diff>
```

Claude should automatically:
- Determine whether code or expected output is wrong
- Apply the minimal correct fix
- Validate with tests

#### Default Response Structure (When Useful)

When providing a structured response, use:
1. Current State
2. Review of Issues
3. Fix Strategy
4. Changes Made
5. Files Updated
6. Validation Results
7. Remaining Follow-Up

### Final Rule

For incremental prompts, Claude should assume:
- Base rules come from `CLAUDE.md`
- Only the new issue needs to be provided in the prompt
- Repeated instructions should not be required
