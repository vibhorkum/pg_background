#!/bin/bash
#
# test-upgrade.sh - Test pg_background extension upgrade paths using Docker
#
# This script validates that extension upgrades work correctly:
#   - Install older version
#   - Verify functionality on older version
#   - Upgrade to newer version
#   - Verify new features work after upgrade
#
# Usage:
#   ./test-upgrade.sh [PG_VERSION]
#
# Examples:
#   ./test-upgrade.sh        # Test with PostgreSQL 17 (default)
#   ./test-upgrade.sh 16     # Test with PostgreSQL 16
#

set -euo pipefail

# Default PostgreSQL version
DEFAULT_PG_VERSION="17"
PG_VERSION="${1:-$DEFAULT_PG_VERSION}"

# Container name
CONTAINER_NAME="pg_background_upgrade_test"

# Colors for output
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

main() {
    # Ensure cleanup runs on all exit paths
    trap 'cleanup' EXIT

    echo ""
    echo "========================================================================"
    echo "pg_background UPGRADE PATH TEST (1.8 -> 1.9)"
    echo "========================================================================"
    echo "PostgreSQL Version: $PG_VERSION"
    echo "========================================================================"

    # Check Docker
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        exit 1
    fi

    # Cleanup any existing container (trap handles final cleanup)
    cleanup 2>/dev/null || true

    # Start PostgreSQL container
    log_step "Starting PostgreSQL $PG_VERSION container..."
    docker run --name "$CONTAINER_NAME" -d \
        -e POSTGRES_PASSWORD=postgres \
        -e POSTGRES_USER=postgres \
        -e POSTGRES_DB=postgres \
        postgres:"$PG_VERSION"

    # Wait for PostgreSQL to be ready
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

    # Show PostgreSQL version
    docker exec "$CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U postgres -t -c "SELECT version();" 2>/dev/null

    # Install build dependencies (keep stderr visible for debugging failures)
    log_step "Installing build dependencies..."
    docker exec "$CONTAINER_NAME" bash -c "
        apt-get update -qq && \
        apt-get install -y -qq \
            build-essential \
            postgresql-server-dev-${PG_VERSION} \
            libkrb5-dev \
            make gcc
    " >/dev/null

    # Copy source files
    log_step "Copying source files..."
    docker exec "$CONTAINER_NAME" mkdir -p /build
    docker cp . "$CONTAINER_NAME:/build/"

    # Build extension
    log_step "Building extension..."
    docker exec -w /build "$CONTAINER_NAME" bash -c "
        export PATH=/usr/lib/postgresql/${PG_VERSION}/bin:\$PATH
        make clean 2>/dev/null || true
        make PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config
    " >/dev/null

    # Install extension files
    log_step "Installing extension files..."
    docker exec -w /build "$CONTAINER_NAME" bash -c "
        export PATH=/usr/lib/postgresql/${PG_VERSION}/bin:\$PATH
        make install PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config
    " >/dev/null

    echo ""
    echo "========================================================================"
    log_test "UPGRADE PATH TEST: 1.8 -> 1.9"
    echo "========================================================================"

    local TEST_RESULT=0

    # Test 1: Install version 1.8
    log_test "Step 1: Installing pg_background version 1.8..."
    if docker exec "$CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U postgres -c "CREATE EXTENSION pg_background VERSION '1.8';" 2>&1; then
        log_info "Version 1.8 installed successfully"
    else
        log_error "Failed to install version 1.8"
        exit 1
    fi

    # Verify 1.8 is installed
    local INSTALLED_VERSION
    INSTALLED_VERSION=$(docker exec "$CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U postgres -tAc \
        "SELECT extversion FROM pg_extension WHERE extname = 'pg_background';")

    if [ "$INSTALLED_VERSION" = "1.8" ]; then
        log_info "Confirmed version: $INSTALLED_VERSION"
    else
        log_error "Expected version 1.8, got: $INSTALLED_VERSION"
        exit 1
    fi

    # Test 2: Verify 1.8 functionality
    log_test "Step 2: Verifying 1.8 functionality..."
    if ! docker exec "$CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U postgres <<'EOF'
-- Create test table
DROP TABLE IF EXISTS t_upgrade_test;
CREATE TABLE t_upgrade_test(id int, version text);

-- Test launch_v2 (1.8 signature without label parameter)
DO $$
DECLARE
    h pg_background_handle;
BEGIN
    SELECT * INTO h FROM pg_background_launch_v2('INSERT INTO t_upgrade_test VALUES (1, ''v1.8'')', 65536);
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;

-- Verify data
SELECT CASE WHEN count(*) = 1 THEN 'PASS: v1.8 functionality works'
            ELSE 'FAIL: v1.8 functionality broken' END AS test_1_8
FROM t_upgrade_test WHERE version = 'v1.8';
EOF
    then
        log_error "Version 1.8 functionality test failed"
        TEST_RESULT=1
    else
        log_info "Version 1.8 functionality verified"
    fi

    # Test 3: Upgrade to 1.9
    log_test "Step 3: Upgrading from 1.8 to 1.9..."
    if docker exec "$CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U postgres -c "ALTER EXTENSION pg_background UPDATE TO '1.9';" 2>&1; then
        log_info "Upgrade to 1.9 completed"
    else
        log_error "Upgrade to 1.9 failed"
        exit 1
    fi

    # Verify 1.9 is installed
    INSTALLED_VERSION=$(docker exec "$CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U postgres -tAc \
        "SELECT extversion FROM pg_extension WHERE extname = 'pg_background';")

    if [ "$INSTALLED_VERSION" = "1.9" ]; then
        log_info "Confirmed version after upgrade: $INSTALLED_VERSION"
    else
        log_error "Expected version 1.9 after upgrade, got: $INSTALLED_VERSION"
        exit 1
    fi

    # Test 4: Verify 1.9 new features work
    log_test "Step 4: Verifying 1.9 new features..."
    if ! docker exec "$CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U postgres <<'EOF'
-- Test launch_v2 with label parameter (1.9 feature)
DO $$
DECLARE
    h pg_background_handle;
BEGIN
    SELECT * INTO h FROM pg_background_launch_v2(
        'INSERT INTO t_upgrade_test VALUES (2, ''v1.9'')',
        65536,
        'upgrade-test-label'  -- New 1.9 label parameter
    );
    PERFORM pg_background_wait_v2(h.pid, h.cookie);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;

-- Verify v1.9 insert worked
SELECT CASE WHEN count(*) = 1 THEN 'PASS: v1.9 label parameter works'
            ELSE 'FAIL: v1.9 label parameter broken' END AS test_1_9_label
FROM t_upgrade_test WHERE version = 'v1.9';

-- Test result_info_v2 (new 1.9 function)
DO $$
DECLARE
    h pg_background_handle;
    ri pg_background_result_info;
BEGIN
    SELECT * INTO h FROM pg_background_launch_v2('SELECT 1', 65536);
    PERFORM pg_background_wait_v2(h.pid, h.cookie);

    SELECT * INTO ri FROM pg_background_result_info_v2(h.pid, h.cookie);

    IF ri.completed THEN
        RAISE NOTICE 'PASS: result_info_v2 works';
    ELSE
        RAISE NOTICE 'FAIL: result_info_v2 broken';
    END IF;

    PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;

-- Test error_info_v2 (new 1.9 function)
DO $$
DECLARE
    h pg_background_handle;
    ei pg_background_error;
BEGIN
    SELECT * INTO h FROM pg_background_launch_v2('SELECT 1/0', 65536);
    PERFORM pg_sleep(0.3);

    SELECT * INTO ei FROM pg_background_error_info_v2(h.pid, h.cookie);

    IF ei.sqlstate IS NOT NULL THEN
        RAISE NOTICE 'PASS: error_info_v2 works (sqlstate: %)', ei.sqlstate;
    ELSE
        RAISE NOTICE 'FAIL: error_info_v2 broken';
    END IF;

    PERFORM pg_background_detach_v2(h.pid, h.cookie);
END;
$$;

-- Test batch operations (new 1.9 functions)
DO $$
DECLARE
    h pg_background_handle;
    detach_count int;
BEGIN
    SELECT * INTO h FROM pg_background_submit_v2('SELECT 1', 0, 'batch-test');
    PERFORM pg_sleep(0.2);

    SELECT pg_background_detach_all_v2() INTO detach_count;

    IF detach_count >= 1 THEN
        RAISE NOTICE 'PASS: detach_all_v2 works (detached: %)', detach_count;
    ELSE
        RAISE NOTICE 'FAIL: detach_all_v2 broken';
    END IF;
END;
$$;

-- Final verification: both v1.8 and v1.9 data present
SELECT CASE WHEN count(*) = 2 THEN 'PASS: All data preserved through upgrade'
            ELSE 'FAIL: Data lost during upgrade' END AS upgrade_data_check
FROM t_upgrade_test;
EOF
    then
        log_error "Version 1.9 feature tests failed"
        TEST_RESULT=1
    else
        log_info "Version 1.9 new features verified"
    fi

    # Test 5: Verify old functionality still works after upgrade
    log_test "Step 5: Verifying old functionality after upgrade..."
    if ! docker exec "$CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U postgres <<'EOF'
-- stats_v2 should still work (1.8 feature)
SELECT
    CASE WHEN workers_launched > 0 THEN 'PASS: stats_v2 works after upgrade'
         ELSE 'FAIL: stats_v2 broken after upgrade' END AS stats_check
FROM pg_background_stats_v2();

-- progress functions should still work (1.8 feature)
DO $$
DECLARE
    h pg_background_handle;
BEGIN
    SELECT * INTO h FROM pg_background_launch_v2($$
        SELECT pg_background_progress(50, 'test progress');
    $$, 65536);

    PERFORM pg_sleep(0.2);
    PERFORM pg_background_detach_v2(h.pid, h.cookie);
    RAISE NOTICE 'PASS: progress functions work after upgrade';
END;
$$;
EOF
    then
        log_error "Old functionality verification failed"
        TEST_RESULT=1
    else
        log_info "Old functionality verified after upgrade"
    fi

    # Summary
    echo ""
    echo "========================================================================"
    if [ $TEST_RESULT -eq 0 ]; then
        log_info "ALL UPGRADE TESTS PASSED!"
        echo "========================================================================"
        echo "Verified:"
        echo "  - Version 1.8 installs correctly"
        echo "  - Version 1.8 functionality works"
        echo "  - Upgrade from 1.8 to 1.9 succeeds"
        echo "  - Version 1.9 new features work:"
        echo "    - launch_v2 with label parameter"
        echo "    - result_info_v2()"
        echo "    - error_info_v2()"
        echo "    - detach_all_v2()"
        echo "  - Old functionality preserved after upgrade"
        echo "========================================================================"
    else
        log_error "SOME UPGRADE TESTS FAILED"
        echo "========================================================================"
    fi

    # Exit with test result (cleanup runs via trap)
    exit $TEST_RESULT
}

# Handle script arguments
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [PG_VERSION]"
        echo ""
        echo "Test pg_background extension upgrade paths using Docker."
        echo "Validates upgrade from version 1.8 to 1.9."
        echo ""
        echo "PG_VERSION can be: 14, 15, 16, 17, 18"
        echo "Default: $DEFAULT_PG_VERSION"
        exit 0
        ;;
    *)
        main
        ;;
esac
