# Contributing to pg_background

Thank you for your interest in contributing to pg_background! This document provides guidelines for contributing to the project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Coding Standards](#coding-standards)
- [Testing Requirements](#testing-requirements)
- [Commit Guidelines](#commit-guidelines)
- [Pull Request Process](#pull-request-process)
- [Review Process](#review-process)

---

## Code of Conduct

This project follows the [PostgreSQL Community Code of Conduct](https://www.postgresql.org/about/policies/coc/). Please be respectful and constructive in all interactions.

---

## Getting Started

### Prerequisites

- PostgreSQL 14 or later (development headers required)
- GCC or Clang compiler
- `make` build system
- `git` for version control

### Setting Up Development Environment

```bash
# Clone the repository
git clone https://github.com/vibhorkum/pg_background.git
cd pg_background

# Build the extension
make clean
make

# Install to PostgreSQL (requires appropriate permissions)
sudo make install

# Run regression tests
make installcheck
```

---

## Development Workflow

1. **Fork** the repository on GitHub
2. **Create a branch** for your feature or bugfix:
   ```bash
   git checkout -b feature/my-feature
   # or
   git checkout -b bugfix/issue-123
   ```
3. **Make your changes** following the coding standards
4. **Test thoroughly** (see Testing Requirements)
5. **Commit** your changes with clear messages
6. **Push** to your fork:
   ```bash
   git push origin feature/my-feature
   ```
7. **Submit a Pull Request** with a clear description

---

## Coding Standards

### PostgreSQL Coding Conventions

pg_background follows [PostgreSQL coding conventions](https://www.postgresql.org/docs/current/source.html):

#### Style Guidelines

- **Indentation**: 4 spaces (no tabs)
- **Line length**: Max 80 characters (soft limit; 100 hard limit)
- **Braces**: K&R style (opening brace on same line)
- **Comments**: Use C-style `/* */` comments, not C++ `//`

#### Naming Conventions

```c
/* Functions: lowercase with underscores */
static void cleanup_worker_info(dsm_segment *seg, Datum pid_datum);

/* Types: lowercase with underscores */
typedef struct pg_background_worker_info
{
    /* ... */
} pg_background_worker_info;

/* Macros: UPPERCASE with underscores */
#define PG_BACKGROUND_MAGIC 0x50674267

/* Constants: UPPERCASE or lowercase depending on context */
#define PGBG_SQL_PREVIEW_LEN 120
```

#### Memory Management

- **Always** use PostgreSQL memory contexts (`palloc`, `pfree`)
- **Never** use C library `malloc`/`free`
- Use `TopMemoryContext` for session-lifetime allocations
- Clean up resources in error paths using `PG_TRY`/`PG_CATCH`

#### Error Handling

```c
/* Use ereport for user-facing errors */
ereport(ERROR,
        (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
         errmsg("queue size must be at least %zu bytes", shm_mq_minimum_size)));

/* Use elog for internal assertions */
elog(DEBUG1, "worker_hash entry for PID %d already removed", pid);
```

### Code Formatting

We use `pgindent` for automatic formatting:

```bash
# Format a single file
pgindent pg_background.c

# Check formatting without modifying
pgindent --check pg_background.c
```

**Note**: `pgindent` requires PostgreSQL source tree. See [PostgreSQL wiki](https://wiki.postgresql.org/wiki/Running_pgindent) for setup.

---

## Testing Requirements

### Regression Tests

All code changes must include regression tests in `sql/pg_background.sql`:

```sql
-- Test your new feature
SELECT * FROM pg_background_launch_v2('SELECT 1') AS h \gset
SELECT * FROM pg_background_result_v2(:h_pid, :h_cookie) AS (result int);
```

Update expected output in `expected/pg_background.out` if needed.

### Running Tests

```bash
# Run all regression tests
make installcheck

# Run specific test
make installcheck REGRESS=pg_background

# Clean up test artifacts
make installcheckclean
```

### Test Coverage Goals

- **Critical paths**: 100% coverage (launch, result, detach, cancel)
- **Edge cases**: PID reuse, DSM cleanup races, error handling
- **Error conditions**: Invalid inputs, permission failures
- **Concurrency**: Concurrent detach/result operations

### Manual Testing Checklist

Before submitting a PR:

- [ ] Tested on PostgreSQL 14 (minimum version)
- [ ] Tested on latest stable PostgreSQL version
- [ ] No compiler warnings (`-Wall -Wextra`)
- [ ] No memory leaks (use `valgrind` if available)
- [ ] No resource leaks (check `pg_stat_activity`, `pg_shmem_allocations`)
- [ ] Regression tests pass
- [ ] Documentation updated if API changed

---

## Commit Guidelines

### Commit Message Format

```
Short summary (50 chars max)

Detailed explanation of the change, including:
- What was changed and why
- Any behavior changes
- References to issues (e.g., "Fixes #123")

(optional) Breaking changes or migration notes
```

### Good Commit Messages

✅ **Good**:
```
Add CHECK_FOR_INTERRUPTS to result loop

Allows cancellation of long-running result retrieval. Without this,
Ctrl-C or pg_terminate_backend() won't interrupt the launcher session
while it's blocked reading results.

Fixes #456
```

❌ **Bad**:
```
Fix bug
```

### Atomic Commits

- One logical change per commit
- Commit compiles and passes tests
- Can be cherry-picked or reverted independently

---

## Pull Request Process

### Before Submitting

1. Rebase on latest `main`:
   ```bash
   git fetch origin
   git rebase origin/main
   ```

2. Squash fixup commits if needed:
   ```bash
   git rebase -i origin/main
   ```

3. Run full test suite:
   ```bash
   make clean && make && make installcheck
   ```

### PR Description Template

```markdown
## Description
Brief summary of changes

## Motivation
Why is this change needed?

## Changes Made
- Change 1
- Change 2

## Testing
- [ ] Regression tests added/updated
- [ ] Manual testing performed
- [ ] Tested on PG 14
- [ ] Tested on latest PG

## Breaking Changes
None / List any breaking changes

## Checklist
- [ ] Code follows style guidelines
- [ ] Comments added for complex logic
- [ ] Documentation updated
- [ ] Regression tests pass
- [ ] No compiler warnings
```

### PR Size Guidelines

- **Small**: < 100 lines changed (preferred)
- **Medium**: 100-500 lines
- **Large**: > 500 lines (split if possible)

Large PRs should be split into smaller, logical commits for easier review.

---

## Review Process

### What Reviewers Look For

1. **Correctness**: Does it solve the problem?
2. **Safety**: Memory leaks? Race conditions? Resource cleanup?
3. **Style**: Follows PostgreSQL conventions?
4. **Tests**: Adequate test coverage?
5. **Documentation**: Clear comments and README updates?
6. **Compatibility**: Works on PG 14-18?

### Responding to Feedback

- Be open to suggestions and constructive criticism
- Respond to all comments, even if just "Fixed" or "Done"
- Push new commits for changes (don't force-push during review)
- Request re-review when ready

### Approval Criteria

PRs require:
- ✅ At least one approval from maintainer
- ✅ All CI checks passing
- ✅ No unresolved comments
- ✅ Documentation updated (if applicable)

---

## Development Tips

### Debugging

```sql
-- Enable debug logging
SET client_min_messages = DEBUG1;

-- Check active workers
SELECT * FROM pg_background_list_v2() AS (...);

-- Check DSM usage
SELECT * FROM pg_shmem_allocations WHERE name LIKE '%pg_background%';
```

### Common Pitfalls

❌ **Don't**: Call `pfree()` on `BackgroundWorkerHandle`
✅ **Do**: Let PostgreSQL manage handle lifetime

❌ **Don't**: Use `malloc()`/`free()`
✅ **Do**: Use `palloc()`/`pfree()` with proper memory context

❌ **Don't**: Ignore error context cleanup
✅ **Do**: Use `PG_TRY`/`PG_CATCH` for robust error handling

### Useful Resources

- [PostgreSQL Backend Internals](https://www.postgresql.org/docs/current/source.html)
- [Background Workers Documentation](https://www.postgresql.org/docs/current/bgworker.html)
- [Dynamic Shared Memory](https://www.postgresql.org/docs/current/shm-mq.html)
- [PostgreSQL Extension Best Practices](https://wiki.postgresql.org/wiki/ExtensionBestPractices)

---

## Questions?

- **GitHub Issues**: https://github.com/vibhorkum/pg_background/issues
- **Discussions**: https://github.com/vibhorkum/pg_background/discussions
- **Mailing List**: pgsql-general@postgresql.org

---

Thank you for contributing! 🎉
