-- 1.5 -> 1.6 upgrade

-- add submit
CREATE FUNCTION pg_background_submit_v2(sql pg_catalog.text,
                                       queue_size pg_catalog.int4 DEFAULT 65536)
RETURNS public.pg_background_handle
AS 'MODULE_PATHNAME', 'pg_background_submit_v2'
LANGUAGE C STRICT;

-- add cancel + cancel_grace
CREATE FUNCTION pg_background_cancel_v2(pid pg_catalog.int4, cookie pg_catalog.int8)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_cancel_v2'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_cancel_v2_grace(pid pg_catalog.int4, cookie pg_catalog.int8, grace_ms pg_catalog.int4)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_cancel_v2_grace'
LANGUAGE C STRICT;

-- add wait
CREATE FUNCTION pg_background_wait_v2(pid pg_catalog.int4, cookie pg_catalog.int8)
RETURNS pg_catalog.void
AS 'MODULE_PATHNAME', 'pg_background_wait_v2'
LANGUAGE C STRICT;

CREATE FUNCTION pg_background_wait_v2_timeout(pid pg_catalog.int4, cookie pg_catalog.int8, timeout_ms pg_catalog.int4)
RETURNS pg_catalog.bool
AS 'MODULE_PATHNAME', 'pg_background_wait_v2_timeout'
LANGUAGE C STRICT;

-- add list
CREATE FUNCTION pg_background_list_v2()
RETURNS SETOF pg_catalog.record
AS 'MODULE_PATHNAME', 'pg_background_list_v2'
LANGUAGE C;

-- refresh helpers to include new functions (safe replace)
-- (reuse your hardened versions from 1.6 install, or COPY them here)
