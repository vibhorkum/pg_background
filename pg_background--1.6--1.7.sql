-- pg_background upgrade script from 1.6 to 1.7
--
-- This upgrade contains internal C code improvements only.
-- No SQL schema changes are required.
--
-- Version 1.7 Improvements:
--   - Cryptographically secure cookie generation (pg_strong_random)
--   - Dedicated memory context for worker info (prevents memory bloat)
--   - Exponential backoff in polling loops (reduces CPU usage)
--   - Refactored internal code (eliminates duplication)
--   - Enhanced documentation and error messages
--
-- IMPORTANT: After running ALTER EXTENSION, you must restart any
-- existing background workers for them to use the new code.

-- No SQL changes needed - all improvements are in the C code.
-- The extension just needs to be updated to load the new shared library.

DO $$
BEGIN
    RAISE NOTICE 'pg_background upgraded to 1.7';
    RAISE NOTICE 'Internal improvements: secure cookies, memory management, polling efficiency';
END
$$;
