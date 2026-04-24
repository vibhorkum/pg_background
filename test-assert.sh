#!/bin/bash
#
# Test pg_background against assert-enabled PostgreSQL build
# This reproduces the FailedAssertion in CopyErrorData on error paths
#

set -e

PG_VERSION="${1:-14}"
CONTAINER_NAME="pg_background_assert_test_pg${PG_VERSION}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup() {
    info "Cleaning up container: ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
}

trap cleanup EXIT

echo "========================================"
info "Testing with PostgreSQL ${PG_VERSION} (ASSERT-ENABLED)"
echo "========================================"

cleanup

step "Starting Debian container for PostgreSQL build..."
docker run -d \
    --name "${CONTAINER_NAME}" \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    debian:bookworm-slim \
    sleep infinity

step "Installing build dependencies..."
docker exec "${CONTAINER_NAME}" bash -c "
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        build-essential \
        libreadline-dev \
        zlib1g-dev \
        flex \
        bison \
        libxml2-dev \
        libxslt1-dev \
        libssl-dev \
        libxml2-utils \
        xsltproc \
        pkg-config \
        wget \
        sudo \
        locales \
        > /dev/null

    # Set up locale
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
    locale-gen
"

# Use the .0 release tarball — it is kept on the PostgreSQL FTP permanently.
# The exact patch level does not matter for assert-enabled regression testing;
# we only need the source to build with --enable-cassert.
step "Downloading PostgreSQL ${PG_VERSION}.0 source..."
docker exec "${CONTAINER_NAME}" bash -c "
    cd /tmp
    wget -q https://ftp.postgresql.org/pub/source/v${PG_VERSION}.0/postgresql-${PG_VERSION}.0.tar.gz
    tar xzf postgresql-*.tar.gz
"

step "Building PostgreSQL with --enable-cassert (assertions enabled)..."
docker exec "${CONTAINER_NAME}" bash -c '
    PG_SRC=$(ls -d /tmp/postgresql-*/)
    cd "$PG_SRC"
    ./configure \
        --enable-cassert \
        --enable-debug \
        --prefix=/usr/local/pgsql \
        --with-openssl \
        > /dev/null
    make -j$(nproc) > /dev/null 2>&1
    make install > /dev/null
'

step "Setting up PostgreSQL user and data directory..."
docker exec "${CONTAINER_NAME}" bash -c "
    useradd -m postgres || true
    mkdir -p /usr/local/pgsql/data
    chown postgres:postgres /usr/local/pgsql/data

    # Initialize database
    sudo -u postgres /usr/local/pgsql/bin/initdb -D /usr/local/pgsql/data

    # Configure for testing
    echo \"shared_preload_libraries = ''\" >> /usr/local/pgsql/data/postgresql.conf
    echo \"max_worker_processes = 16\" >> /usr/local/pgsql/data/postgresql.conf
    echo \"log_min_messages = warning\" >> /usr/local/pgsql/data/postgresql.conf
"

step "Starting PostgreSQL..."
docker exec "${CONTAINER_NAME}" bash -c "
    sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data -l /tmp/pg.log start
    sleep 2
    sudo -u postgres /usr/local/pgsql/bin/createdb regression || true
"

step "Verifying PostgreSQL is assert-enabled..."
docker exec "${CONTAINER_NAME}" bash -c "
    sudo -u postgres /usr/local/pgsql/bin/psql -c \"SHOW debug_assertions;\" regression
"

step "Copying pg_background source to container..."
docker cp . "${CONTAINER_NAME}:/tmp/pg_background"

step "Building pg_background extension..."
docker exec "${CONTAINER_NAME}" bash -c "
    cd /tmp/pg_background
    export PATH=/usr/local/pgsql/bin:\$PATH
    make clean
    make
    make install
"

step "Running regression tests (expecting failure on error path)..."
set +e  # Don't exit on test failure - we expect it might fail

docker exec "${CONTAINER_NAME}" bash -c '
    cd /tmp/pg_background
    export PATH=/usr/local/pgsql/bin:$PATH
    chown -R postgres:postgres /tmp/pg_background
    sudo -u postgres env PATH=/usr/local/pgsql/bin:$PATH make installcheck 2>&1
'
TEST_RESULT=$?

set -e

if [ $TEST_RESULT -eq 0 ]; then
    info "All tests PASSED on assert-enabled PostgreSQL ${PG_VERSION}"
else
    error "Tests FAILED on assert-enabled PostgreSQL ${PG_VERSION}"

    step "Checking for assertion failures in logs..."
    docker exec "${CONTAINER_NAME}" bash -c "
        echo '=== PostgreSQL Log (last 50 lines) ==='
        tail -50 /tmp/pg.log || true
        echo ''
        echo '=== Regression Diffs ==='
        cat /tmp/pg_background/regression.diffs 2>/dev/null || echo 'No diffs file'
    "
fi

exit $TEST_RESULT
