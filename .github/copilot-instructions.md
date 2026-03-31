# GitHub Copilot Instructions for pg_background

This file guides GitHub Copilot to produce better code reviews, suggestions, and comments for this repository.

---

## 1. Repository Context

**pg_background** is a PostgreSQL extension that executes SQL commands in background worker processes. It is:

- Implemented in **C** (PostgreSQL backend code) and **SQL** (extension scripts)
- Tightly coupled to **PostgreSQL internals**: Background Worker API, Dynamic Shared Memory (DSM), SPI, shm_mq
- **Security-sensitive**: Executes arbitrary SQL with caller's privileges
- **Version-sensitive**: Supports PostgreSQL 14-18 with compatibility macros
- **Not a generic application**: PostgreSQL extension patterns differ significantly from typical app code

### Key Semantics to Understand

- **v1 API** (legacy): Returns bare PID, no cancellation support
- **v2 API** (recommended): Returns `(pid, cookie)` handle with explicit cancel/wait/detach
- **`detach` is NOT `cancel`**: `detach_v2()` removes tracking; worker continues and commits. `cancel_v2()` requests termination.
- **Autonomous transactions**: Workers commit independently of the launcher's transaction
- **One-time result consumption**: `result_v2()` can only be called once per handle

---

## 2. Review Expectations

When reviewing PRs in this repository:

### Do
- Review the **entire PR** as a coherent change, not isolated lines
- Consider how changes affect **extension control files**, **SQL scripts**, **C code**, **tests**, and **documentation** together
- Provide **one consolidated maintainer-grade review** rather than piece-by-piece comments
- Distinguish **critical issues** (correctness, security, compatibility) from **nice-to-have** (style, minor improvements)
- Verify that **tests validate the intended semantic change**
- Check that **documentation matches the implemented behavior**

### Do Not
- Provide shallow line-by-line feedback without understanding context
- Suggest generic application patterns that don't apply to PostgreSQL extensions
- Assume background-worker code should look like ordinary async application code
- Suggest broad refactors without verifying PostgreSQL backend semantics
- Focus on style when correctness is the real concern

---

## 3. PostgreSQL-Specific Review Checklist

When reviewing changes, verify:

### Extension Packaging
- [ ] `pg_background.control` version matches latest SQL script
- [ ] Upgrade scripts (`pg_background--X.Y--X.Z.sql`) are correct and minimal
- [ ] No hardcoded `public.` schema references (extension is relocatable)
- [ ] `@extschema@` used correctly for cross-references

### Background Worker Semantics
- [ ] DSM segments created/attached/detached correctly
- [ ] `shm_mq_wait_for_attach()` called before returning handle (prevents NOTIFY race)
- [ ] Worker cleanup happens on all exit paths
- [ ] `BackgroundWorkerHandle` is never `pfree()`d (let PostgreSQL manage it)

### SPI and Transactions
- [ ] `SPI_connect()`/`SPI_finish()` paired correctly
- [ ] No assumptions about caller's transaction state in worker code
- [ ] Error handling uses `PG_TRY`/`PG_CATCH` appropriately

### PostgreSQL Version Compatibility
- [ ] `#if PG_VERSION_NUM` guards for version-specific code
- [ ] Compatibility macros in `pg_background.h` used correctly
- [ ] Tested on all supported versions (14-18)

### Catalog and Schema
- [ ] Correct use of `pg_catalog` qualifications
- [ ] No unsafe `search_path` assumptions
- [ ] Extension objects have correct ownership

### Privilege Model
- [ ] `SECURITY DEFINER` functions set `search_path = pg_catalog`
- [ ] Workers run with caller's privileges, not elevated
- [ ] `pgbackground_role` grants are correct
- [ ] No accidental privilege escalation

---

## 4. Security Review Checklist

Flag these issues as **critical**:

### SECURITY DEFINER Misuse
- Functions using `SECURITY DEFINER` without `SET search_path = pg_catalog`
- `SECURITY DEFINER` on functions that shouldn't need it
- Missing `REVOKE ALL ON FUNCTION ... FROM PUBLIC` for privileged helpers

### Dynamic SQL Risks
- Caller-controlled strings concatenated into SQL without proper quoting
- Missing `format()` with `%L` (literals) or `%I` (identifiers)
- SQL injection vectors in any code path

### Privilege Escalation
- Workers executing with higher privileges than caller
- Extension functions granting unintended access
- Unsafe object ownership assumptions

### Resource Abuse
- Unbounded worker creation without limits
- Unbounded DSM allocation
- Missing input validation on size/timeout parameters
- Denial-of-service vectors through resource exhaustion

### Search Path Safety
- Functions relying on caller's `search_path` for critical operations
- Missing schema qualification for security-sensitive lookups

---

## 5. Documentation and Test Review

### Documentation Must Match Behavior
- If code changes user-visible behavior, README must be updated
- API reference must reflect actual function signatures
- Examples must work with current implementation
- Limitations section must be honest about constraints

### Tests Must Validate Semantics
- New functions need regression tests
- Behavioral changes need test updates
- Error paths need coverage
- Cancel vs detach distinction must be tested explicitly

### Common Review Mistakes
- Suggesting code changes when **documentation is the actual problem**
- Suggesting documentation changes when **code is the actual problem**
- Approving code that changes behavior without corresponding test updates
- Approving tests that don't actually validate the claimed behavior

---

## 6. Common False Positives to Avoid

Do not suggest these patterns that are inappropriate for this codebase:

### Generic Application Patterns
- "Use async/await" - This is C code using PostgreSQL's background worker API
- "Add a thread pool" - PostgreSQL uses processes, not threads; workers are process-based
- "Cache the results" - Results are intentionally one-time consumption via shm_mq
- "Use a mutex" - PostgreSQL uses LWLocks and other backend primitives

### Incorrect Privilege Assumptions
- "Make this function SECURITY DEFINER" - Most functions should be INVOKER; only privilege helpers use DEFINER
- "Grant to PUBLIC" - Extension explicitly avoids PUBLIC grants for security
- "Remove the search_path setting" - Required for SECURITY DEFINER safety

### Incorrect Schema Assumptions
- "Use public.function_name" - Extension is relocatable; don't hardcode schema
- "Create objects in pg_catalog" - Extension objects belong in extension's schema

### Incorrect Transaction Assumptions
- "Wrap in a transaction" - Workers have their own transactions; this is the design
- "Rollback on error in worker" - Worker errors trigger automatic rollback on exit
- "Commit the result" - Worker commits on clean exit; explicit commits not used

### Overly Broad Suggestions
- "Refactor this module" - Only if directly relevant to the PR's purpose
- "Add comprehensive error handling everywhere" - Be specific about which path needs it
- "Modernize the code style" - PostgreSQL has its own style; don't suggest non-PG patterns

---

## 7. Preferred Review Style

### Internal Process
1. Read the entire PR to understand the intended change
2. Identify the category: bug fix, feature, refactor, documentation, test
3. Verify the change is complete: code + tests + docs as needed
4. Check PostgreSQL-specific concerns from the checklists above
5. Distinguish critical issues from suggestions

### Output Format
- **One consolidated review** when possible
- **Critical issues first**, clearly marked
- **Suggestions second**, with rationale
- **Questions third**, when intent is unclear

### Severity Levels
- **Blocker**: Security vulnerability, data corruption risk, broken upgrade path
- **Critical**: Incorrect behavior, missing tests for behavioral change, broken compatibility
- **Major**: Missing documentation, incomplete error handling, suboptimal patterns
- **Minor**: Style issues, minor improvements, documentation polish
- **Nitpick**: Preferences that don't affect correctness

### Rationale Requirements
- Explain **why** something is a problem, not just **what** to change
- Reference PostgreSQL documentation or extension best practices when relevant
- For security issues, explain the attack vector
- For compatibility issues, explain which versions are affected

---

## 8. Code Suggestion Guidelines

When suggesting code changes:

### C Code
- Follow PostgreSQL coding style (4-space indent, K&R braces, C comments)
- Use `palloc`/`pfree`, never `malloc`/`free`
- Use `ereport()` for user errors, `elog()` for internal assertions
- Include `CHECK_FOR_INTERRUPTS()` in loops
- Handle cleanup in error paths with `PG_TRY`/`PG_CATCH`

### SQL Code
- Use `STRICT` for functions that should return NULL on NULL input
- Use `VOLATILE` appropriately for functions with side effects
- Include `PARALLEL UNSAFE` for functions that can't run in parallel workers
- Set `search_path = pg_catalog` for `SECURITY DEFINER` functions

### Test Code
- Use `\gset` to capture values for later assertions
- Include `pg_sleep()` with adequate margins for async operations
- Test both success and failure paths
- Verify cancel actually prevents work (not just detach)

---

## 9. Repository-Specific Knowledge

### Files and Their Purposes
| File | Review Focus |
|------|--------------|
| `pg_background.c` | Core implementation; watch for memory, concurrency, cleanup |
| `pg_background.h` | Version compatibility; ensure macros work on all PG versions |
| `pg_background.control` | Version must match latest SQL script |
| `pg_background--*.sql` | Upgrade paths, privilege grants, schema handling |
| `sql/pg_background.sql` | Test coverage for all behaviors |
| `expected/pg_background.out` | Expected output; watch for version-sensitive differences |
| `test-upgrade.sh` | Upgrade path validation; verify 1.8 → 1.9 transitions |
| `.github/workflows/ci.yml` | CI pipeline; test matrix + relocatable + upgrade tests |

### CI Pipeline Review Checklist
- [ ] Main test matrix covers all PG versions (14-18) and both Ubuntu versions
- [ ] Relocatable test verifies extension works in custom schema
- [ ] Upgrade test validates old → new version transitions
- [ ] New functions added to upgrade tests if behavioral changes
- [ ] CI job dependencies are correct (test-summary depends on all test jobs)

### Critical Invariants
1. Cookie validation prevents PID reuse attacks
2. `detach_v2()` never cancels; `cancel_v2()` never detaches
3. Results are consumed exactly once
4. Workers commit on clean exit, rollback on error
5. DSM is cleaned up on worker exit or launcher detach
6. `pgbackground_role` controls access; PUBLIC has no grants

### v1.9 Features
- Worker labels: `label` parameter on `launch_v2`/`submit_v2`
- Structured errors: `pg_background_error_info_v2()` returns SQLSTATE, message, detail, hint, context
- Result metadata: `pg_background_result_info_v2()` returns row_count, command_tag, completed, has_error
- Batch operations: `pg_background_detach_all_v2()`, `pg_background_cancel_all_v2()`

### Known Limitations (Do Not "Fix")
- Windows: `cancel_v2()` cannot interrupt running statements (OS limitation)
- Cross-database: Workers connect to launcher's database only (PostgreSQL limitation)
- Result streaming: No pagination; results flow through shm_mq (design choice)
- Session-local tracking: `list_v2()` only shows current session's workers (design choice)

---

## 10. Review Quality Checklist

When generating code review comments, verify these before suggesting changes:

### SQL/C Alignment Checks
- [ ] If suggesting SQL function is "not STRICT", verify C code has NULL checks
- [ ] If suggesting data is "stored but not exposed", verify it's not in `list_v2()` or other APIs
- [ ] If suggesting "function doesn't exist", verify against the actual SQL definition files

### Test Comment Accuracy
- [ ] Test comments must match what the test actually verifies
- [ ] Do not assume comments are accurate—read the test code

### Cross-File Consistency
- [ ] Windows exports (`windows/pg_background_win.h`) must include all SQL-callable functions
- [ ] Upgrade scripts must define all functions in the base install script
- [ ] README API reference must match actual function signatures

### Test Isolation
- [ ] Each test section should clean up its own resources
- [ ] Batch operation tests should not rely on leftover workers from earlier tests
- [ ] Counts in expected output must match self-contained test expectations

### Context Before Flagging
- Before flagging "incomplete implementation": trace the full data path (DSM → C → SQL API)
- Before flagging "test is brittle": verify the actual test dependency chain
- Before flagging "function missing": check all SQL files (base install + upgrade scripts)

### Upgrade Script Safety
- [ ] Do not suggest DROP/CREATE for public functions (breaks grants)
- [ ] For optional parameters: suggest adding overloads, not replacing signatures
- [ ] Verify suggested changes preserve upgrade safety
- [ ] Fresh install and upgrade must result in equivalent functionality

### Statistics Accounting
- [ ] Stats increments should happen in ONE place (typically cleanup functions)
- [ ] Check for double-counting if both triggering function and cleanup increment stats
- [ ] Compare similar functions (cancel_v2 vs cancel_all_v2) for accounting consistency

### Batch Helper Function Semantics
- [ ] Batch helpers (e.g., `cancel_all_v2`, `detach_all_v2`) should match semantics of single-operation equivalents
- [ ] Return values should reflect actual completed operations, not snapshot counts
- [ ] For cancel: set cancel flag for all workers (including not-yet-started), send signals only to started workers
- [ ] Keep function header comments aligned with actual output columns after API changes

### v2 API Error Handling Consistency
- [ ] All v2 functions should use the same handle-validation error pattern
- [ ] Missing PID: `ERRCODE_UNDEFINED_OBJECT`, `"PID %d is not attached to this session"`
- [ ] Cookie mismatch: `ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE`, message + hint about stale handle
- [ ] Compare new v2 functions against established patterns (wait_v2, cancel_v2, detach_v2) before suggesting changes

### Feature Test Coverage
- [ ] Feature tests must verify the actual visible value, not just exercise the code path
- [ ] For metadata features (labels, result info, error info): verify the value is correctly exposed
- [ ] Distinguish between "feature is exercised" and "feature value is asserted"

### Shell Script Semantics
- [ ] With `set -e`, `$?` checks after commands are dead code for failure cases
- [ ] psql returns 0 even for SQL errors unless `-v ON_ERROR_STOP=1` is used
- [ ] Suggest `if ! command; then` instead of `command; if [ $? -ne 0 ]`
- [ ] Automated test scripts should use `psql -X -v ON_ERROR_STOP=1` to make SQL errors detectable
- [ ] Cleanup should be guaranteed via `trap 'cleanup' EXIT` rather than manual calls before each exit
