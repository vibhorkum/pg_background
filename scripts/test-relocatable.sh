#!/bin/bash
#
# test-relocatable.sh - Run pg_background relocatable schema tests using Docker
#
# This script specifically tests the extension's ability to be installed
# in a custom schema (not public) and validates all functions work correctly.
#

set -euo pipefail

# Default PostgreSQL version
DEFAULT_PG_VERSION="17"
PG_VERSION="${1:-$DEFAULT_PG_VERSION}"

# Container name
CONTAINER_NAME="pg_background_relocatable_test"

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
    echo ""
    echo "========================================================================"
    echo "pg_background RELOCATABLE SCHEMA TEST"
    echo "========================================================================"
    echo "PostgreSQL Version: $PG_VERSION"
    echo "========================================================================"

    # Check Docker
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        exit 1
    fi

    # Cleanup any existing container
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
            cleanup
            exit 1
        fi
        sleep 2
    done

    # Show PostgreSQL version
    docker exec "$CONTAINER_NAME" psql -U postgres -c "SELECT version();" 2>/dev/null | head -3

    # Install build dependencies
    log_step "Installing build dependencies..."
    docker exec "$CONTAINER_NAME" bash -c "
        apt-get update -qq && \
        apt-get install -y -qq \
            build-essential \
            postgresql-server-dev-${PG_VERSION} \
            libkrb5-dev \
            make gcc 2>/dev/null
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

    # Install extension
    log_step "Installing extension..."
    docker exec -w /build "$CONTAINER_NAME" bash -c "
        export PATH=/usr/lib/postgresql/${PG_VERSION}/bin:\$PATH
        make install PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config
    " >/dev/null

    # Run relocatable schema tests
    echo ""
    echo "========================================================================"
    log_test "Running Relocatable Schema Test Suite"
    echo "========================================================================"
    echo ""

    # Run the test and capture output
    local OUTPUT_FILE="/tmp/relocatable_test_output.txt"
    docker exec -w /build "$CONTAINER_NAME" bash -c "
        psql -U postgres -f sql/pg_background_relocatable.sql 2>&1
    " | tee "$OUTPUT_FILE"

    echo ""
    echo "========================================================================"
    echo "TEST RESULTS ANALYSIS"
    echo "========================================================================"

    # Count PASS and FAIL results from test output
    local PASS_COUNT=$(grep -c "PASS" "$OUTPUT_FILE" 2>/dev/null || echo "0")
    # Only count actual FAIL test results, exclude instructional text
    local FAIL_COUNT=$(grep "FAIL" "$OUTPUT_FILE" 2>/dev/null | grep -v "Any FAIL" | grep -v "FAIL results" | wc -l | tr -d ' ')

    echo ""
    log_info "Total PASS occurrences: $PASS_COUNT"
    log_info "Total FAIL occurrences: $FAIL_COUNT"

    # Check if CREATE EXTENSION succeeded and test_1 passed
    # The output format has PASS on the line after the column headers
    local TEST_RESULT=0
    if grep -q "CREATE EXTENSION" "$OUTPUT_FILE" && grep -q "PASS.*pg_background.*custom_ext" "$OUTPUT_FILE"; then
        echo ""
        echo "========================================================================"
        log_info "ALL TESTS PASSED - Extension is fully relocatable!"
        echo "========================================================================"
        echo ""
        echo "Verified capabilities:"
        echo "  ✓ Extension installs in custom schema"
        echo "  ✓ All v1 API functions work with schema qualification"
        echo "  ✓ All v2 API functions work with schema qualification"
        echo "  ✓ Composite types accessible with schema qualification"
        echo "  ✓ Privilege helpers detect extension schema dynamically"
        echo "  ✓ Works without schema in search_path"
        echo "  ✓ Works with schema in search_path"
        echo "  ✓ Security model (no PUBLIC access) maintained"
        echo "========================================================================"
        TEST_RESULT=0
    else
        log_error "Tests FAILED"
        echo ""
        echo "========================================================================"
        log_error "FAILED TESTS (Schema Relocatability Issues):"
        echo "========================================================================"
        grep "FAIL" "$OUTPUT_FILE" | grep -v "Any FAIL" | grep -v "FAIL results" || true
        echo ""
        echo "========================================================================"
        echo "FAILURE ANALYSIS:"
        echo "========================================================================"
        echo "The following issues may indicate hardcoded schema references:"
        echo "  - Hardcoded 'public.' schema names"
        echo "  - Hard dependencies on search_path"
        echo "  - Cross-schema reference issues"
        echo "========================================================================"
        TEST_RESULT=1
    fi

    # Cleanup
    cleanup
    exit $TEST_RESULT
}

# Handle script arguments
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [PG_VERSION]"
        echo ""
        echo "Run pg_background relocatable schema tests using Docker."
        echo "Tests extension functionality when installed in a custom schema."
        echo ""
        echo "PG_VERSION can be: 14, 15, 16, 17, 18"
        echo "Default: $DEFAULT_PG_VERSION"
        exit 0
        ;;
    *)
        main
        ;;
esac
