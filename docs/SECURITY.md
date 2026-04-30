# Security Policy

## Reporting Security Vulnerabilities

The pg_background team takes security seriously. We appreciate your efforts to responsibly disclose your findings.

### How to Report

**DO NOT** open a public GitHub issue for security vulnerabilities.

Instead, please email:
- **Primary Contact**: vibhor.aim@gmail.com
- **Subject**: `[SECURITY] pg_background vulnerability report`

Include in your report:
1. **Description** of the vulnerability
2. **Steps to reproduce** (proof-of-concept)
3. **Impact assessment** (what can be exploited?)
4. **Affected versions** (if known)
5. **Suggested fix** (if you have one)

### Response Timeline

- **Initial response**: Within 48 hours
- **Triage**: Within 1 week
- **Fix development**: Depends on severity (see below)
- **Public disclosure**: After fix is released and users have time to upgrade

### Severity Levels

| Severity | Response Time | Examples |
|----------|---------------|----------|
| **Critical** | 1-2 days | Privilege escalation, remote code execution |
| **High** | 1 week | Data corruption, denial of service |
| **Medium** | 2 weeks | Information disclosure, local DoS |
| **Low** | 1 month | Minor information leaks |

---

## Security Best Practices

### Privilege Model

#### Creating Roles

```sql
-- Create dedicated role for pg_background
CREATE ROLE pgbackground_role NOLOGIN INHERIT;

-- Grant to application users (NOT superusers for production)
GRANT pgbackground_role TO app_user;
```

#### Revoking Access

```sql
-- Revoke from specific user
REVOKE pgbackground_role FROM app_user;

-- Or use helper function
SELECT revoke_pg_background_privileges('app_user', true);
```

#### Never Grant to PUBLIC

```sql
-- ❌ DANGEROUS: Don't do this!
GRANT pgbackground_role TO PUBLIC;

-- ✅ SAFE: Grant only to specific roles
GRANT pgbackground_role TO trusted_app_role;
```

### SQL Injection Prevention

#### Unsafe (Vulnerable)

```sql
-- ❌ DANGEROUS: Untrusted input in dynamic SQL
DO $$
DECLARE
  user_input text := get_user_input();  -- Could be malicious
BEGIN
  PERFORM pg_background_launch_v2(
    'SELECT * FROM users WHERE id = ' || user_input  -- SQL INJECTION!
  );
END;
$$;
```

#### Safe (Parameterized)

```sql
-- ✅ SAFE: Use format() with proper quoting
DO $$
DECLARE
  user_input text := get_user_input();
BEGIN
  PERFORM pg_background_launch_v2(
    format('SELECT * FROM users WHERE id = %L', user_input)  -- Safely quoted
  );
END;
$$;
```

### Resource Limits

#### Prevent Resource Exhaustion

```sql
-- 1. Set max_worker_processes appropriately
ALTER SYSTEM SET max_worker_processes = 32;  -- Not unlimited!

-- 2. Monitor active workers
CREATE OR REPLACE FUNCTION check_worker_limit()
RETURNS boolean AS $$
DECLARE
  active_count int;
BEGIN
  SELECT count(*) INTO active_count
  FROM pg_background_list_v2() AS (
    pid int4, cookie int8, launched_at timestamptz, user_id oid,
    queue_size int4, state text, sql_preview text, last_error text, consumed bool
  )
  WHERE state = 'running';
  
  RETURN active_count < 20;  -- Application-specific limit
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. Use before launching workers
DO $$
BEGIN
  IF NOT check_worker_limit() THEN
    RAISE EXCEPTION 'Too many active workers';
  END IF;
  
  PERFORM pg_background_launch_v2('...');
END;
$$;
```

#### Statement Timeout

```sql
-- Set timeout to prevent runaway queries
SET statement_timeout = '5min';

-- Worker inherits this setting
SELECT pg_background_launch_v2('slow_query()');
```

### Autonomous Transaction Risks

#### Understanding Isolation

```sql
-- ⚠️ IMPORTANT: Worker commits are independent
BEGIN;
  -- Launch background worker
  SELECT * FROM pg_background_launch_v2(
    'INSERT INTO audit_log VALUES (now(), ''user_login'')'
  ) AS h \gset;
  
  -- Main transaction work
  UPDATE users SET last_login = now() WHERE id = 123;
  
  -- If we ROLLBACK here, audit_log INSERT still commits!
ROLLBACK;
```

**Implication**: Use background workers for truly independent operations only (e.g., logging, notifications, async processing).

#### Secure Patterns

```sql
-- ✅ GOOD: Audit logging (should commit regardless)
SELECT pg_background_submit_v2(
  format('INSERT INTO audit_log VALUES (now(), %L)', action)
);

-- ✅ GOOD: Async notification
SELECT pg_background_submit_v2(
  format('SELECT pg_notify(''channel'', %L)', message)
);

-- ❌ BAD: Interdependent data modifications
BEGIN;
  INSERT INTO orders VALUES (...);
  
  -- Don't do this! Order INSERT might rollback, but payment won't
  SELECT pg_background_submit_v2('INSERT INTO payments VALUES (...)');
COMMIT;
```

---

## Known Security Considerations

### 1. PID Reuse (Mitigated in v2 API)

**Issue**: On systems with high process churn, PIDs can be reused quickly.

**v1 API Vulnerability**:
```sql
-- ❌ VULNERABLE: PID might be reused after hours/days
SELECT pg_background_launch('...') AS pid \gset
-- ... session lives for weeks ...
SELECT pg_background_result(:pid);  -- Might attach to WRONG worker!
```

**v2 API Fix**:
```sql
-- ✅ SAFE: Cookie prevents PID reuse confusion
SELECT * FROM pg_background_launch_v2('...') AS h \gset
-- ... time passes ...
SELECT pg_background_result_v2(:'h.pid', :'h.cookie');  -- Cookie validated
```

**Recommendation**: Always use v2 API in production.

### 2. Information Disclosure

**Issue**: Error messages may leak sensitive data.

**Mitigation**:
- Error messages are truncated at 512 bytes (as of v1.6)
- Use `pg_background_list_v2()` judiciously (shows SQL previews)
- Restrict `pgbackground_role` to trusted users only

**Example**:
```sql
-- last_error in list_v2() might show:
-- "duplicate key value violates unique constraint: value (secret_data)"

-- Protect with VIEW + RLS
CREATE VIEW safe_worker_list AS
SELECT pid, cookie, state, consumed
FROM pg_background_list_v2() AS (...);
-- Omit sql_preview and last_error from public view
```

### 3. Denial of Service

**Issue**: Malicious user could spawn many workers.

**Mitigation**:
```sql
-- Application-level rate limiting
CREATE TABLE user_worker_quota (
  user_id oid PRIMARY KEY,
  workers_launched int DEFAULT 0,
  last_reset timestamptz DEFAULT now()
);

-- Check quota before launch
CREATE OR REPLACE FUNCTION launch_with_quota(sql text)
RETURNS pg_background_handle AS $$
DECLARE
  h pg_background_handle;
BEGIN
  -- Rate limit: 10 workers per minute
  UPDATE user_worker_quota
  SET workers_launched = CASE
    WHEN now() - last_reset > interval '1 minute' THEN 1
    ELSE workers_launched + 1
  END,
  last_reset = CASE
    WHEN now() - last_reset > interval '1 minute' THEN now()
    ELSE last_reset
  END
  WHERE user_id = current_user::regrole::oid;
  
  IF (SELECT workers_launched FROM user_worker_quota WHERE user_id = current_user::regrole::oid) > 10 THEN
    RAISE EXCEPTION 'Worker quota exceeded';
  END IF;
  
  SELECT * INTO h FROM pg_background_launch_v2(sql);
  RETURN h;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### 4. Windows Cancel Limitations

**Issue**: On Windows, `cancel_v2()` cannot interrupt running queries.

**Security Impact**: Low, but could enable resource exhaustion.

**Mitigation**:
```sql
-- Always set statement_timeout on Windows
ALTER DATABASE mydb SET statement_timeout = '10min';

-- Or per-session:
SET statement_timeout = '5min';
SELECT pg_background_launch_v2('potentially_slow_query()');
```

**See also**: [README.md § Windows Limitations](README.md#windows-limitations)

---

## Hardening Checklist

Production deployments should:

- [ ] Use v2 API exclusively (avoid v1 PID reuse issues)
- [ ] Grant `pgbackground_role` only to trusted users
- [ ] Never grant to `PUBLIC`
- [ ] Set `max_worker_processes` appropriately (not unlimited)
- [ ] Implement application-level rate limiting
- [ ] Use `statement_timeout` to bound query execution
- [ ] Validate/sanitize all user input in dynamic SQL
- [ ] Monitor `pg_background_list_v2()` for suspicious activity
- [ ] Review audit logs for privilege escalation attempts
- [ ] Test disaster recovery with background workers running
- [ ] Document autonomous transaction usage in app code

---

## Security Update Notifications

Subscribe to security advisories:

1. **GitHub Watch**: Watch this repo for "Releases only" or "All activity"
2. **GitHub Security Advisories**: https://github.com/vibhorkum/pg_background/security/advisories
3. **Mailing List**: pgsql-general@postgresql.org (major PostgreSQL ecosystem issues)

---

## Vulnerability Disclosure Policy

### Our Commitments

- **Acknowledge** your report within 48 hours
- **Keep you informed** of progress on a fix
- **Credit you** in release notes (unless you prefer anonymity)
- **Coordinate disclosure** with you before making details public

### Your Responsibilities

- **Act in good faith**: Don't exploit the vulnerability beyond proof-of-concept
- **Minimize impact**: Don't exfiltrate data, disrupt services, or access accounts
- **Maintain confidentiality**: Don't disclose until we've released a fix
- **Give us reasonable time**: Allow 90 days for fix development before public disclosure

### Bug Bounty

This project does not currently offer a bug bounty program. However, we greatly appreciate responsible disclosure and will publicly acknowledge contributors.

---

## Past Security Issues

| CVE ID | Severity | Affected Versions | Fixed In | Description |
|--------|----------|-------------------|----------|-------------|
| N/A | N/A | N/A | N/A | No CVEs assigned to date |

---

## Security-Related Changes in v1.6

- ✅ Grace period overflow protection (cap at 1 hour)
- ✅ Error message truncation (512 bytes max)
- ✅ Bounds checking for column count in RowDescription
- ✅ Explicit ResourceOwner cleanup before proc_exit
- ✅ Volatile access for cancel flag (race mitigation)
- ✅ Enhanced documentation on PID reuse edge cases
- ✅ Windows cancel limitations documented

---

## References

- [PostgreSQL Security](https://www.postgresql.org/support/security/)
- [PostgreSQL CVE List](https://www.cvedetails.com/product/575/PostgreSQL-PostgreSQL.html)
- [OWASP SQL Injection Prevention](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html)

---

## Contact

- **Security Issues**: vibhor.aim@gmail.com
- **General Support**: https://github.com/vibhorkum/pg_background/issues

---

Last updated: 2026-02-05
