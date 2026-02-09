-- -------------------------------------------------------------------------
-- NOTIFY case reported by somebody:
-- detach is NOT cancel, so "fail" may still notify.
-- This block asserts that the session does not crash and notifications arrive.
-- -------------------------------------------------------------------------

LISTEN test;

DO $f$
DECLARE
    pid int;
BEGIN
    pid := pg_background_launch($$SELECT pg_notify('test', 'fail')$$);
    PERFORM pg_background_detach(pid);

    pid := pg_background_launch($$SELECT pg_notify('test', 'succeed')$$);
    PERFORM pg_sleep(1);
    PERFORM pg_background_detach(pid);
END;
$f$ LANGUAGE plpgsql;

SELECT pg_sleep(0.2);

-- -------------------------------------------------------------------------
-- v2 NOTIFY: same semantics (detach is not cancel)
-- -------------------------------------------------------------------------

LISTEN test_v2;

DO $f$
DECLARE
    h public.pg_background_handle;
BEGIN
    SELECT * INTO h
    FROM pg_background_launch_v2($$SELECT pg_notify('test_v2', 'fail')$$, 65536);

    PERFORM pg_background_detach_v2(h.pid, h.cookie);

    SELECT * INTO h
    FROM pg_background_launch_v2($$SELECT pg_notify('test_v2', 'succeed')$$, 65536);

    PERFORM pg_sleep(1);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$f$ LANGUAGE plpgsql;

SELECT pg_sleep(0.2);
