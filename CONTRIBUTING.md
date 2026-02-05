# Contributing to pg_background

Thank you for your interest in contributing to pg_background!

## Code of Conduct

Be respectful, professional, and constructive in all interactions.

## How to Contribute

### Reporting Bugs

1. Check existing issues to avoid duplicates
2. Include:
   - PostgreSQL version
   - pg_background version
   - Minimal reproducible example
   - Expected vs actual behavior
   - Relevant logs/error messages

### Suggesting Features

1. Open an issue describing:
   - Use case
   - Proposed API
   - Backward compatibility impact

### Submitting Pull Requests

#### Prerequisites

- PostgreSQL 12+ development headers
- Git
- C compiler (GCC or Clang)

#### Workflow

1. **Fork the repository**

2. **Create a feature branch**
   ```bash
   git checkout -b feature/my-improvement
   ```

3. **Make your changes**
   - Follow PostgreSQL coding style (see below)
   - Add regression tests for new features
   - Update documentation

4. **Test your changes**
   ```bash
   make clean
   make
   make installcheck
   ```

5. **Commit with descriptive messages**
   ```bash
   git commit -m "Add feature: <description>"
   ```

6. **Push and create PR**
   ```bash
   git push origin feature/my-improvement
   ```

7. **Address review feedback**

## Coding Style

### C Code

Follow PostgreSQL conventions:

```c
/* Function-level comment explaining purpose */
static void
my_function(int arg1, const char *arg2)
{
    int         local_var;
    const char *another_var;

    /* Comment before logic block */
    if (arg1 > 0)
    {
        /* Indent with tabs (width 4) */
        local_var = arg1 * 2;
    }
    else
        local_var = 0;

    return;
}
```

**Key Points**:
- Tabs (width 4) for indentation
- Opening braces on same line for `if`/`while`/`for`
- Function opening brace on new line
- Variable alignment in declarations
- Comments before code blocks

### pgindent

Format code with `pgindent`:
```bash
pgindent --indent=tab --tabsize=4 pg_background.c
```

### SQL

```sql
-- Use lowercase for keywords in documentation
select * from pg_background_list_v2() as (...);

-- Use uppercase for keywords in extension SQL files
SELECT pg_background_launch('SELECT 1');
```

## Testing

### Regression Tests

Add tests to `sql/pg_background.sql` and expected output to `expected/pg_background.out`.

**Example**:
```sql
-- Test new cancel API
SELECT (h).pid AS test_pid, (h).cookie AS test_cookie
FROM (SELECT pg_background_launch_v2('SELECT pg_sleep(10)') AS h) s
\gset

SELECT pg_background_cancel_v2(:test_pid, :test_cookie);
SELECT pg_background_detach_v2(:test_pid, :test_cookie);
```

Run tests:
```bash
make installcheck
```

### Manual Testing

Test on multiple PostgreSQL versions:
```bash
for PG in 12 13 14 15 16 17; do
    export PG_CONFIG=/usr/lib/postgresql/$PG/bin/pg_config
    make clean && make && sudo make install && make installcheck
done
```

## Documentation

### Code Comments

```c
/*
 * function_name - Short description
 *
 * Longer description explaining:
 * - What it does
 * - When to use it
 * - Side effects
 *
 * Parameters:
 *   arg1: Description
 *   arg2: Description
 *
 * Returns: Description of return value
 *
 * Errors:
 *   - ERROR_CODE: When this happens
 */
```

### README Updates

Update README.md if changing:
- API signatures
- Behavior
- Limitations
- Examples

## Versioning

We use semantic versioning (MAJOR.MINOR):

- **MAJOR**: Breaking API changes
- **MINOR**: New features, backward-compatible

Extension version in `pg_background.control`:
```
default_version = '1.6'
```

## Compatibility

### PostgreSQL Versions

Support PG 12-18:
```c
#if PG_VERSION_NUM < 120000 || PG_VERSION_NUM >= 190000
#error "pg_background supports PostgreSQL 12-18 only"
#endif
```

### Backward Compatibility

- Never remove public functions
- Don't change function signatures
- Deprecate instead of removing
- Document breaking changes prominently

## Security

### Reporting Vulnerabilities

**DO NOT** open public issues for security vulnerabilities.

Email: vibhorkum@gmail.com

See [SECURITY.md](SECURITY.md) for details.

### Security Checklist

- [ ] No SQL injection vectors
- [ ] Proper permission checks (`has_privs_of_role`)
- [ ] No buffer overflows
- [ ] Safe memory management (TopMemoryContext for persistent data)
- [ ] Validate all user inputs

## Review Process

1. **Automated CI** runs on PR:
   - Build on PG 12-17
   - Regression tests
   - Compiler warnings check

2. **Maintainer review**:
   - Code quality
   - Performance impact
   - Documentation completeness

3. **Approval & merge**

## Getting Help

- **Discussions**: GitHub Discussions
- **Issues**: Bug reports and feature requests
- **IRC**: #postgresql on Libera.Chat

## Recognition

Contributors will be acknowledged in:
- CHANGELOG
- Git history
- README credits section

Thank you for contributing! 🎉
