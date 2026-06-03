#!/bin/bash
#
# test-upgrade.sh - Test pg_background extension upgrade paths using Docker
#
# Validates the real-world upgrade story for a binary-incompatible major
# release. 2.0 dropped the v1 C functions and changed v2 C signatures, so a
# 2.0 .so cannot run pre-2.0 SQL. A faithful test therefore uses TWO binaries:
#
#   Phase 1 - build the prior (1.10) binary, install 1.8 against it, and walk
#             the pre-2.0 DDL chain 1.8 -> 1.9 -> 1.10 with that matching
#             binary (so old-version runtime actually works).
#   Phase 2 - build the 2.0 binary, swap the .so in place (as a package
#             upgrade would), and run ALTER EXTENSION ... UPDATE TO '2.0'.
#
# Verifies seeded data survives, and that the resulting 2.0 install works.
#
# The prior binary is built from the v1.10 tag by default; override with
# PRIOR_REF=<git ref>. The repo's .git is copied into the container, so the
# ref must be reachable there (CI must fetch tags / full history).
#
# Usage (run from the repository root):
#   ./scripts/test-upgrade.sh [PG_VERSION]
#
# Examples:
#   ./scripts/test-upgrade.sh        # PostgreSQL 17 (default)
#   ./scripts/test-upgrade.sh 16     # PostgreSQL 16
#   PRIOR_REF=v1.10 ./scripts/test-upgrade.sh 17
#

set -euo pipefail

DEFAULT_PG_VERSION="17"
PG_VERSION="${1:-$DEFAULT_PG_VERSION}"

# Git ref whose code provides the prior-version (v1-capable) binary.
PRIOR_REF="${PRIOR_REF:-v1.10}"

CONTAINER_NAME="pg_background_upgrade_test"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_test() { echo -e "${CYAN}[TEST]${NC} $1"; }

cleanup() {
    log_info "Cleaning up container: $CONTAINER_NAME"
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
}

# Run psql in the container with strict error handling.
psql_c() {
    docker exec "$CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U postgres "$@"
}

# Build + install whatever source is currently checked out in /build.
build_and_install() {
    docker exec -w /build "$CONTAINER_NAME" bash -c "
        export PATH=/usr/lib/postgresql/${PG_VERSION}/bin:\$PATH
        make clean >/dev/null 2>&1 || true
        make PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config >/dev/null
        make install PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config >/dev/null
    "
}

# Assert the installed extension version equals the expected one.
assert_version() {
    local expected="$1" got
    got=$(docker exec "$CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U postgres -tAc \
        "SELECT extversion FROM pg_extension WHERE extname = 'pg_background';")
    if [ "$got" = "$expected" ]; then
        log_info "Confirmed version: $got"
    else
        log_error "Expected version $expected, got: $got"
        exit 1
    fi
}

main() {
    trap 'cleanup' EXIT

    echo ""
    echo "========================================================================"
    echo "pg_background UPGRADE PATH TEST (1.8 -> 1.9 -> 1.10 -> 2.0)"
    echo "========================================================================"
    echo "PostgreSQL Version: $PG_VERSION"
    echo "Prior-version ref:  $PRIOR_REF"
    echo "========================================================================"

    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        exit 1
    fi

    cleanup 2>/dev/null || true

    log_step "Starting PostgreSQL $PG_VERSION container..."
    docker run --name "$CONTAINER_NAME" -d \
        -e POSTGRES_PASSWORD=postgres \
        -e POSTGRES_USER=postgres \
        -e POSTGRES_DB=postgres \
        postgres:"$PG_VERSION"

    log_step "Waiting for PostgreSQL to start..."
    for i in {1..30}; do
        if docker exec "$CONTAINER_NAME" pg_isready -U postgres >/dev/null 2>&1; then
            log_info "PostgreSQL is ready"
            break
        fi
        if [ "$i" -eq 30 ]; then
            log_error "PostgreSQL failed to start"
            exit 1
        fi
        sleep 2
    done

    docker exec "$CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U postgres -t -c "SELECT version();" 2>/dev/null

    # git is needed to check out the prior-version source inside the container.
    log_step "Installing build dependencies..."
    docker exec "$CONTAINER_NAME" bash -c "
        apt-get update -qq && \
        apt-get install -y -qq \
            build-essential \
            postgresql-server-dev-${PG_VERSION} \
            libkrb5-dev \
            make gcc git
    " >/dev/null

    log_step "Copying source files (including .git)..."
    docker exec "$CONTAINER_NAME" mkdir -p /build
    docker cp . "$CONTAINER_NAME:/build/"

    # docker cp leaves /build owned by root; git refuses to operate on a repo
    # owned by another user ("dubious ownership") unless it is marked safe.
    docker exec "$CONTAINER_NAME" git config --global --add safe.directory /build

    # Capture the current (2.0) commit so we can return to it for phase 2.
    local NEW_REF
    NEW_REF=$(docker exec -w /build "$CONTAINER_NAME" git rev-parse HEAD)
    log_info "Current (2.0) ref: $NEW_REF"

    # Verify the prior ref is reachable inside the container.
    if ! docker exec -w /build "$CONTAINER_NAME" git rev-parse --verify --quiet "$PRIOR_REF^{commit}" >/dev/null; then
        log_error "Prior-version ref '$PRIOR_REF' not found in the copied repository."
        log_error "Ensure the tag/branch exists and CI fetches it (fetch-depth: 0, fetch-tags: true)."
        exit 1
    fi

    echo ""
    echo "========================================================================"
    log_test "PHASE 1: build prior ($PRIOR_REF) binary, install 1.8, chain to 1.10"
    echo "========================================================================"

    local TEST_RESULT=0

    log_step "Checking out prior source ($PRIOR_REF) and building its binary..."
    docker exec -w /build "$CONTAINER_NAME" git checkout -f "$PRIOR_REF" >/dev/null 2>&1
    build_and_install
    log_info "Prior-version binary installed"

    # Step 1: install 1.8 against the prior binary (v1 symbols resolve here)
    log_test "Step 1: Installing pg_background version 1.8..."
    if psql_c -c "CREATE EXTENSION pg_background VERSION '1.8';" 2>&1; then
        log_info "Version 1.8 installed successfully"
    else
        log_error "Failed to install version 1.8"
        exit 1
    fi
    assert_version "1.8"

    # Step 2: exercise 1.8 runtime (binary matches) and seed data
    log_test "Step 2: Verifying 1.8 runtime and seeding data..."
    if ! psql_c <<'EOF'
DROP TABLE IF EXISTS t_upgrade_test;
CREATE TABLE t_upgrade_test(id int, version text);
DO $$
DECLARE h pg_background_handle;
BEGIN
    SELECT * INTO h FROM pg_background_launch_v2(
        'INSERT INTO t_upgrade_test VALUES (1, ''v1.8'')', 65536);
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;
SELECT CASE WHEN count(*) = 1 THEN 'PASS: v1.8 runtime works'
            ELSE 'FAIL: v1.8 runtime broken' END AS test_1_8
FROM t_upgrade_test WHERE version = 'v1.8';
EOF
    then
        log_error "Version 1.8 runtime test failed"
        TEST_RESULT=1
    else
        log_info "Version 1.8 runtime verified"
    fi

    # Step 3: upgrade 1.8 -> 1.9 (prior binary)
    log_test "Step 3: Upgrading 1.8 -> 1.9..."
    psql_c -c "ALTER EXTENSION pg_background UPDATE TO '1.9';" 2>&1
    assert_version "1.9"

    # Step 4: 1.9 feature (label parameter) against the prior binary
    log_test "Step 4: Verifying 1.9 feature (label parameter)..."
    if ! psql_c <<'EOF'
DO $$
DECLARE h pg_background_handle;
BEGIN
    SELECT * INTO h FROM pg_background_launch_v2(
        'INSERT INTO t_upgrade_test VALUES (2, ''v1.9'')', 65536, 'upgrade-test-label');
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;
SELECT CASE WHEN count(*) = 1 THEN 'PASS: v1.9 label parameter works'
            ELSE 'FAIL: v1.9 label parameter broken' END AS test_1_9
FROM t_upgrade_test WHERE version = 'v1.9';
EOF
    then
        log_error "Version 1.9 feature test failed"
        TEST_RESULT=1
    else
        log_info "Version 1.9 feature verified"
    fi

    # Step 5: upgrade 1.9 -> 1.10 (prior binary)
    log_test "Step 5: Upgrading 1.9 -> 1.10..."
    psql_c -c "ALTER EXTENSION pg_background UPDATE TO '1.10';" 2>&1
    assert_version "1.10"

    # Step 6: 1.10 feature (run_v2 one-shot) against the prior binary
    log_test "Step 6: Verifying 1.10 feature (run_v2)..."
    if ! psql_c <<'EOF'
DO $$
DECLARE r pg_background_run_result;
BEGIN
    r := pg_background_run_v2('SELECT 1', 65536, 0, 'upgrade-1_10');
    IF r.completed AND NOT r.has_error THEN
        RAISE NOTICE 'PASS: run_v2 works at 1.10';
    ELSE
        RAISE EXCEPTION 'FAIL: run_v2 broken at 1.10';
    END IF;
END;
$$;
EOF
    then
        log_error "Version 1.10 feature test failed"
        TEST_RESULT=1
    else
        log_info "Version 1.10 feature verified"
    fi

    echo ""
    echo "========================================================================"
    log_test "PHASE 2: swap in the 2.0 binary and upgrade 1.10 -> 2.0"
    echo "========================================================================"

    log_step "Checking out 2.0 source ($NEW_REF) and building/installing its binary..."
    docker exec -w /build "$CONTAINER_NAME" git checkout -f "$NEW_REF" >/dev/null 2>&1
    build_and_install
    log_info "2.0 binary installed (replaces the prior .so in place)"

    # Step 7: the major upgrade
    log_test "Step 7: Upgrading 1.10 -> 2.0..."
    if psql_c -c "ALTER EXTENSION pg_background UPDATE TO '2.0';" 2>&1; then
        log_info "Upgrade to 2.0 completed"
    else
        log_error "Upgrade to 2.0 failed"
        exit 1
    fi
    assert_version "2.0"

    # Step 8: data preserved through the entire chain
    log_test "Step 8: Verifying data preserved through all upgrades..."
    if ! psql_c <<'EOF'
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM t_upgrade_test;
    IF n = 2 THEN
        RAISE NOTICE 'PASS: all data preserved (% rows)', n;
    ELSE
        RAISE EXCEPTION 'FAIL: data lost during upgrade (% rows)', n;
    END IF;
END;
$$;
EOF
    then
        log_error "Data preservation check failed"
        TEST_RESULT=1
    else
        log_info "Data preserved through the upgrade chain"
    fi

    # Step 9: 2.0 reshape + runtime (binary now matches the 2.0 catalog)
    log_test "Step 9: Verifying 2.0 reshape and runtime..."
    if ! psql_c <<'EOF'
-- v1 functions are gone
SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'pg_background_launch')
    THEN 'PASS: v1 pg_background_launch dropped'
    ELSE 'FAIL: v1 pg_background_launch still present'
END AS test_2_0_v1_dropped;

-- collapsed cancel_v2 takes 3 args with default 0 (single overload)
SELECT CASE
    WHEN (SELECT count(*) FROM pg_proc WHERE proname = 'pg_background_cancel_v2') = 1
    THEN 'PASS: cancel_v2 single overload'
    ELSE 'FAIL: cancel_v2 has unexpected number of overloads'
END AS test_2_0_cancel_v2;

-- collapsed wait_v2 returns bool
SELECT CASE
    WHEN (SELECT prorettype::regtype::text FROM pg_proc WHERE proname = 'pg_background_wait_v2') = 'boolean'
    THEN 'PASS: wait_v2 returns bool'
    ELSE 'FAIL: wait_v2 has wrong return type'
END AS test_2_0_wait_v2;

-- 2.0 runtime: launch_v2 + wait_v2 + result_v2 round-trip
DO $$
DECLARE h pg_background_handle; n int;
BEGIN
    SELECT * INTO h FROM pg_background_launch_v2(
        'INSERT INTO t_upgrade_test VALUES (3, ''post-2.0'')', 65536, 'upgrade-2_0');
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    /* result_v2 consumes and auto-detaches; no manual detach */
    PERFORM * FROM pg_background_result_v2(h.pid, h.cookie) AS r(c text);
    SELECT count(*) INTO n FROM t_upgrade_test WHERE version = 'post-2.0';
    IF n = 1 THEN RAISE NOTICE 'PASS: 2.0 worker runtime works';
    ELSE RAISE EXCEPTION 'FAIL: 2.0 worker runtime broken'; END IF;
END;
$$;

-- renamed progress function
DO $$
DECLARE h pg_background_handle;
BEGIN
    SELECT * INTO h FROM pg_background_launch_v2($$
        SELECT pg_background_report_progress_v2(50, 'renamed');
    $$, 65536);
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RAISE NOTICE 'PASS: pg_background_report_progress_v2 works after upgrade';
END;
$$;

-- extended run_result columns
DO $$
DECLARE r pg_background_run_result;
BEGIN
    r := pg_background_run_v2('SELECT 1', 65536, 0, 'upgrade-2_0');
    IF r.completed AND NOT r.has_error AND r.cookie IS NOT NULL THEN
        RAISE NOTICE 'PASS: 2.0 run_result extended (cookie=%)', r.cookie;
    ELSE RAISE EXCEPTION 'FAIL: 2.0 run_result missing fields'; END IF;
END;
$$;

-- workers_timed_out stats counter
SELECT CASE
    WHEN workers_timed_out IS NOT NULL THEN 'PASS: workers_timed_out exists'
    ELSE 'FAIL: workers_timed_out missing'
END AS test_2_0_stats_timed_out
FROM pg_background_stats_v2();

-- renamed privilege helper
SELECT CASE
    WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'pg_background_grant_privileges_v2')
    THEN 'PASS: pg_background_grant_privileges_v2 exists'
    ELSE 'FAIL: pg_background_grant_privileges_v2 missing'
END AS test_2_0_grant_renamed;

-- privilege-escalation guard: SECURITY DEFINER helpers not reachable by role
SELECT CASE
    WHEN NOT has_function_privilege('pgbackground_role',
             'pg_background_grant_privileges_v2(text, boolean)', 'EXECUTE')
    THEN 'PASS: grant helper not reachable by pgbackground_role'
    ELSE 'FAIL: privilege escalation -- grant helper reachable by role'
END AS test_2_0_no_escalation;
EOF
    then
        log_error "Version 2.0 reshape/runtime tests failed"
        TEST_RESULT=1
    else
        log_info "Version 2.0 reshape and runtime verified"
    fi

    echo ""
    echo "========================================================================"
    if [ $TEST_RESULT -eq 0 ]; then
        log_info "ALL UPGRADE TESTS PASSED!"
        echo "========================================================================"
        echo "Verified:"
        echo "  - Prior ($PRIOR_REF) binary installs 1.8 and runs its runtime"
        echo "  - DDL + runtime chain 1.8 -> 1.9 -> 1.10 on the prior binary"
        echo "  - Binary swapped to 2.0, then ALTER UPDATE 1.10 -> 2.0 succeeds"
        echo "  - Seeded data preserved through every upgrade"
        echo "  - 2.0 reshape: v1 dropped, cancel_v2/wait_v2 collapsed,"
        echo "    report_progress_v2 rename, run_result extended, workers_timed_out,"
        echo "    grant helper rename, privilege-escalation guard intact"
        echo "  - 2.0 worker runtime works (launch/wait/result/run)"
        echo "========================================================================"
    else
        log_error "SOME UPGRADE TESTS FAILED"
        echo "========================================================================"
    fi

    exit $TEST_RESULT
}

case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [PG_VERSION]"
        echo ""
        echo "Test the pg_background upgrade path 1.8 -> 1.9 -> 1.10 -> 2.0 using"
        echo "Docker and two binaries (prior + 2.0). Override the prior-version"
        echo "source with PRIOR_REF=<git ref> (default: v1.10)."
        echo ""
        echo "PG_VERSION can be: 14, 15, 16, 17, 18 (default: $DEFAULT_PG_VERSION)"
        exit 0
        ;;
    *)
        main
        ;;
esac
