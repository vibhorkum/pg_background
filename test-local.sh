#!/bin/bash
#
# test-local.sh - Run pg_background regression tests locally using Docker
#
# This script builds AND tests entirely within Docker containers,
# so you don't need PostgreSQL development files installed locally.
#
# Usage:
#   ./test-local.sh [PG_VERSION]
#
# Examples:
#   ./test-local.sh        # Test with PostgreSQL 17 (default)
#   ./test-local.sh 14     # Test with PostgreSQL 14
#   ./test-local.sh 15     # Test with PostgreSQL 15
#   ./test-local.sh all    # Test with all supported versions (14-18)
#
# Requirements:
#   - Docker installed and running
#

set -euo pipefail

# Default PostgreSQL version
DEFAULT_PG_VERSION="17"
PG_VERSION="${1:-$DEFAULT_PG_VERSION}"

# Container name prefix
CONTAINER_NAME="pg_background_test"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

cleanup() {
    local container="$1"
    log_info "Cleaning up container: $container"
    docker stop "$container" 2>/dev/null || true
    docker rm "$container" 2>/dev/null || true
}

run_test() {
    local pg_ver="$1"
    local container="${CONTAINER_NAME}_pg${pg_ver}"

    echo ""
    echo "========================================"
    log_info "Testing with PostgreSQL $pg_ver"
    echo "========================================"

    # Cleanup any existing container
    cleanup "$container"

    # Start PostgreSQL container with build tools
    log_step "Starting PostgreSQL $pg_ver container..."

    # Use debian-based postgres image and install build dependencies
    docker run --name "$container" -d \
        -e POSTGRES_PASSWORD=postgres \
        -e POSTGRES_USER=postgres \
        -e POSTGRES_DB=postgres \
        postgres:"$pg_ver"

    # Wait for PostgreSQL to be ready
    log_step "Waiting for PostgreSQL to start..."
    for i in {1..30}; do
        if docker exec "$container" pg_isready -U postgres >/dev/null 2>&1; then
            log_info "PostgreSQL is ready"
            break
        fi
        if [ "$i" -eq 30 ]; then
            log_error "PostgreSQL failed to start within 60 seconds"
            cleanup "$container"
            return 1
        fi
        echo "  Waiting... ($i/30)"
        sleep 2
    done

    # Show PostgreSQL version
    docker exec "$container" psql -U postgres -c "SELECT version();" 2>/dev/null || true

    # Install build dependencies inside the container
    log_step "Installing build dependencies in container..."
    docker exec "$container" bash -c "
        apt-get update -qq && \
        apt-get install -y -qq \
            build-essential \
            postgresql-server-dev-${pg_ver} \
            libkrb5-dev \
            make \
            gcc \
            2>/dev/null
    "

    # Copy source files to container
    log_step "Copying source files to container..."
    docker exec "$container" mkdir -p /build
    docker cp . "$container:/build/"

    # Build the extension inside the container
    log_step "Building extension inside container..."
    if ! docker exec -w /build "$container" bash -c "
        export PATH=/usr/lib/postgresql/${pg_ver}/bin:\$PATH
        make clean 2>/dev/null || true
        make PG_CONFIG=/usr/lib/postgresql/${pg_ver}/bin/pg_config
    "; then
        log_error "Build failed for PostgreSQL $pg_ver"
        echo ""
        echo "=== Build Output ==="
        docker exec -w /build "$container" bash -c "make PG_CONFIG=/usr/lib/postgresql/${pg_ver}/bin/pg_config 2>&1" || true
        cleanup "$container"
        return 1
    fi

    # Install the extension
    log_step "Installing extension..."
    docker exec -w /build "$container" bash -c "
        export PATH=/usr/lib/postgresql/${pg_ver}/bin:\$PATH
        make install PG_CONFIG=/usr/lib/postgresql/${pg_ver}/bin/pg_config
    "

    # Verify installation
    log_step "Verifying installation..."
    docker exec "$container" ls -la /usr/lib/postgresql/${pg_ver}/lib/pg_background.so
    docker exec "$container" ls -la /usr/share/postgresql/${pg_ver}/extension/pg_background* 2>/dev/null || true

    # Run the regression tests
    log_step "Running regression tests (installcheck)..."
    if docker exec -w /build "$container" bash -c "
        export PATH=/usr/lib/postgresql/${pg_ver}/bin:\$PATH
        export PGHOST=/var/run/postgresql
        export PGUSER=postgres
        export PGDATABASE=postgres
        make installcheck PG_CONFIG=/usr/lib/postgresql/${pg_ver}/bin/pg_config REGRESS_OPTS='--user=postgres' 2>&1
    "; then
        echo ""
        log_info "All tests PASSED for PostgreSQL $pg_ver"
        cleanup "$container"
        return 0
    else
        log_error "Tests FAILED for PostgreSQL $pg_ver"
        echo ""
        echo "=== Regression Diffs ==="
        docker exec -w /build "$container" cat regression.diffs 2>/dev/null || echo "No diffs file"
        echo ""
        echo "=== Expected Output ==="
        docker exec -w /build "$container" cat expected/pg_background.out 2>/dev/null | head -100 || true
        echo ""
        echo "=== Actual Output ==="
        docker exec -w /build "$container" cat results/pg_background.out 2>/dev/null | head -100 || true
        echo ""
        echo "=== Container Logs (last 30 lines) ==="
        docker logs "$container" 2>&1 | tail -30
        cleanup "$container"
        return 1
    fi
}

# Main execution
main() {
    # Check Docker is available
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed or not in PATH"
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        log_info "Please start Docker Desktop and try again"
        exit 1
    fi

    local failed_versions=()
    local passed_versions=()

    if [ "$PG_VERSION" = "all" ]; then
        # Test all supported versions
        for ver in 14 15 16 17 18; do
            if run_test "$ver"; then
                passed_versions+=("$ver")
            else
                failed_versions+=("$ver")
            fi
        done

        echo ""
        echo "========================================"
        echo "Test Summary"
        echo "========================================"
        if [ ${#passed_versions[@]} -gt 0 ]; then
            log_info "Passed: ${passed_versions[*]}"
        fi
        if [ ${#failed_versions[@]} -gt 0 ]; then
            log_error "Failed: ${failed_versions[*]}"
            exit 1
        fi
    else
        # Test single version
        if ! run_test "$PG_VERSION"; then
            exit 1
        fi
    fi

    echo ""
    log_info "All tests completed successfully!"
}

# Handle script arguments
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [PG_VERSION]"
        echo ""
        echo "Run pg_background regression tests using Docker."
        echo "Builds and tests entirely within containers - no local PostgreSQL needed."
        echo ""
        echo "PG_VERSION can be: 14, 15, 16, 17, 18, or 'all'"
        echo "Default: $DEFAULT_PG_VERSION"
        echo ""
        echo "Examples:"
        echo "  $0          # Test with PostgreSQL 17"
        echo "  $0 14       # Test with PostgreSQL 14"
        echo "  $0 all      # Test with all versions (14-18)"
        exit 0
        ;;
    *)
        main
        ;;
esac
