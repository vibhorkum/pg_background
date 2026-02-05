# Security Policy

## Supported Versions

We provide security updates for the following versions:

| Version | Supported          | PostgreSQL Versions |
|---------|--------------------|---------------------|
| 1.6     | ✅ Yes (current)   | 12-18               |
| 1.5     | ⚠️ Limited support | 12-17               |
| 1.4     | ❌ No              | 9.5-14              |
| < 1.4   | ❌ No              | 9.5-13              |

**Recommendation**: Always use the latest version (1.6) for security fixes and improvements.

---

## Reporting a Vulnerability

### How to Report

**DO NOT** open public GitHub issues for security vulnerabilities.

**Email**: vibhorkum@gmail.com

**Subject**: `[SECURITY] pg_background vulnerability report`

**Include**:
1. Description of the vulnerability
2. Steps to reproduce
3. PostgreSQL version
4. pg_background version
5. Impact assessment (if possible)
6. Suggested fix (if you have one)

### Response Timeline

- **Initial Response**: Within 48 hours
- **Status Update**: Within 7 days
- **Fix Timeline**: Depends on severity (see below)

### Severity Levels

| Level    | Response Time | Examples                          |
|----------|---------------|-----------------------------------|
| Critical | 24-48 hours   | Remote code execution, privilege escalation |
| High     | 1 week        | SQL injection, data corruption    |
| Medium   | 2 weeks       | Information disclosure, DoS       |
| Low      | 1 month       | Minor information leaks           |

---

## Security Considerations

### Privilege Model

pg_background respects PostgreSQL's permission system:

1. **Default**: No PUBLIC access to extension functions
2. **Recommended**: Use dedicated NOLOGIN role
   ```sql
   GRANT pgbackground_role TO app_user;
   ```

3. **Avoid**: Never grant directly to PUBLIC
   ```sql
   -- ❌ DON'T DO THIS
   GRANT EXECUTE ON FUNCTION pg_background_launch TO PUBLIC;
   ```

### Permission Checks

Workers inherit caller's permissions:

```sql
-- User A launches worker
SELECT pg_background_launch('SELECT * FROM sensitive_table');
-- Worker runs as User A (RLS, column permissions, etc. apply)
```

**Cross-user control protection**:
- v1 API: No cross-user worker control
- v2 API: Cookie validation + permission check

### SQL Injection

**Never** construct SQL dynamically without sanitization:

```sql
-- ❌ VULNERABLE
SELECT pg_background_launch('SELECT * FROM ' || user_input);

-- ✅ SAFE
SELECT pg_background_launch(
  format('SELECT * FROM %I WHERE id = %L', table_name, user_id)
);
```

### Resource Limits

Set limits to prevent DoS:

```sql
-- postgresql.conf
max_worker_processes = 16          -- Limit total workers
statement_timeout = '5min'         -- Prevent runaway queries

-- Per-role limits
ALTER ROLE app_user SET statement_timeout = '2min';
```

### Autonomous Transactions & Commit Semantics

**Important**: Background workers commit independently.

```sql
-- Launcher transaction aborts, but worker commits anyway
BEGIN;
  SELECT pg_background_launch('INSERT INTO audit_log VALUES (1)');
ROLLBACK;
-- audit_log still has row 1!
```

**Security Implication**: Don't rely on transaction rollback to prevent worker commits.

### Known Limitations

1. **No transaction control in workers**:
   - `BEGIN`/`COMMIT`/`ROLLBACK` are disallowed
   - Workers run in auto-commit mode

2. **COPY protocol not supported**:
   - Use `INSERT INTO ... SELECT` instead

3. **Detach ≠ Cancel**:
   - Detaching doesn't stop execution
   - Use `pg_background_cancel_v2()` to stop workers

---

## Security Best Practices

### For Administrators

1. **Audit worker usage**:
   ```sql
   SELECT user_id::regrole, count(*), array_agg(sql_preview)
   FROM pg_background_list_v2() AS (...)
   GROUP BY user_id;
   ```

2. **Monitor resource usage**:
   ```sql
   -- PG 13+
   SELECT * FROM pg_shmem_allocations WHERE name LIKE '%dsm%';
   ```

3. **Set connection limits**:
   ```sql
   ALTER ROLE app_user CONNECTION LIMIT 10;
   ```

4. **Review logs regularly**:
   ```
   log_statement = 'all'  -- In postgresql.conf (for debugging)
   ```

### For Developers

1. **Always validate user inputs**:
   ```sql
   -- Use parameterized queries or format() with %I/%L
   ```

2. **Use v2 API for new code**:
   - Better PID reuse protection
   - Explicit cancel semantics

3. **Set timeouts**:
   ```sql
   SELECT pg_background_wait_v2_timeout(h.pid, h.cookie, 5000);
   ```

4. **Clean up after yourself**:
   ```sql
   -- Always detach when done
   SELECT pg_background_detach_v2(h.pid, h.cookie);
   ```

5. **Handle errors properly**:
   ```sql
   DO $$
   DECLARE h pg_background_handle;
   BEGIN
     SELECT * INTO h FROM pg_background_launch_v2('...');
     -- ... use worker ...
   EXCEPTION WHEN OTHERS THEN
     BEGIN
       PERFORM pg_background_cancel_v2(h.pid, h.cookie);
       PERFORM pg_background_detach_v2(h.pid, h.cookie);
     EXCEPTION WHEN OTHERS THEN
       NULL;  -- Ignore cleanup errors
     END;
     RAISE;
   END $$;
   ```

---

## Past Security Issues

### CVE-YYYY-XXXX (Example Template)

**Issue**: Description of vulnerability  
**Versions Affected**: X.X - X.X  
**Fixed In**: X.X  
**Severity**: Critical/High/Medium/Low  
**Workaround**: How to mitigate before upgrading

---

## Security Disclosure Policy

1. **Responsible Disclosure**: We follow a 90-day disclosure policy
   - 0 days: Report received
   - 7 days: Issue confirmed
   - 30 days: Fix developed & tested
   - 60 days: Fix released
   - 90 days: Public disclosure (if not already disclosed)

2. **Credit**: Security researchers will be credited (unless they request anonymity)

3. **CVE Assignment**: For critical/high severity issues

---

## Contact

**Security Contact**: vibhorkum@gmail.com  
**PGP Key**: (if available, include fingerprint)

**General Support**: https://github.com/vibhorkum/pg_background/issues

---

**Last Updated**: 2026-02-05  
**Version**: 1.0
