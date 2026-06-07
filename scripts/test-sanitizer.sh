#!/bin/bash
#
# Test pg_background under AddressSanitizer + UndefinedBehaviorSanitizer.
#
# We need a PostgreSQL build that was *itself* compiled with the same
# sanitizer flags as our extension; loading an instrumented .so into a
# vanilla PG silently misses bugs (the runtime allocator is unhooked).
# This script builds PG from source with -fsanitize=address,undefined,
# builds the extension with the matching flags, and runs the regression
# suite under it. Catches the memory-safety class of issues that the
# assert-enabled build (test-assert.sh) doesn't (e.g. heap-use-after-free,
# stack-buffer-overflow, signed-integer-overflow, NULL deref).
#
# Aligned with the other scripts/test-*.sh hygiene per CLAUDE.md §7.

set -euo pipefail

PG_VERSION="${1:-17}"
CONTAINER_NAME="pg_background_sanitizer_test_pg${PG_VERSION}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
step()  { echo -e "${BLUE}[STEP]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup() {
    info "Cleaning up container: ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
}

trap cleanup EXIT

echo "========================================"
info "Testing with PostgreSQL ${PG_VERSION} (ASan + UBSan)"
echo "========================================"

cleanup   # in case a previous run left the container behind

# Common sanitizer flags. -fno-omit-frame-pointer makes ASan reports
# carry useful backtraces; -fno-sanitize-recover=all turns UBSan
# warnings into hard errors so CI catches them. detect_leaks=0 because
# postmaster's small known leaks would otherwise drown out real issues
# (PG core has its own leak-checking story).
#
# SAN_RUNTIME_OPTS must be applied to EVERY invocation of a sanitizer-built
# binary, not just the server and the regression run. initdb shells out to
# `postgres -V`, and `make`/`make install` shell out to `pg_config`; with
# LeakSanitizer enabled those benign exit-time leaks make the tool exit
# non-zero and abort the step (initdb then reports "postgres not found").
SAN_CFLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all -O1 -g3"
SAN_LDFLAGS="-fsanitize=address,undefined"
SAN_RUNTIME_OPTS="ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1"

step "Starting Debian container..."
docker run -d \
    --name "${CONTAINER_NAME}" \
    debian:bookworm-slim \
    sleep infinity

step "Installing build dependencies..."
docker exec "${CONTAINER_NAME}" bash -c "
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        build-essential libreadline-dev zlib1g-dev flex bison \
        libxml2-dev libxslt1-dev libssl-dev pkg-config wget sudo locales \
        > /dev/null
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
    locale-gen
"

step "Downloading PostgreSQL ${PG_VERSION}.0 source..."
docker exec "${CONTAINER_NAME}" bash -c "
    cd /tmp
    wget -q https://ftp.postgresql.org/pub/source/v${PG_VERSION}.0/postgresql-${PG_VERSION}.0.tar.gz
    tar xzf postgresql-*.tar.gz
"

step "Building PostgreSQL with -fsanitize=address,undefined ..."
docker exec "${CONTAINER_NAME}" bash -c "
    PG_SRC=\$(ls -d /tmp/postgresql-*/)
    cd \"\$PG_SRC\"
    CFLAGS='${SAN_CFLAGS}' LDFLAGS='${SAN_LDFLAGS}' ./configure \
        --enable-cassert \
        --enable-debug \
        --prefix=/usr/local/pgsql \
        --with-openssl \
        > /dev/null
    make -j\$(nproc) > /dev/null 2>&1
    make install > /dev/null
"

step "Initializing PostgreSQL data directory..."
docker exec "${CONTAINER_NAME}" bash -c "
    useradd -m postgres || true
    mkdir -p /usr/local/pgsql/data
    chown postgres:postgres /usr/local/pgsql/data
    sudo -u postgres env ${SAN_RUNTIME_OPTS} /usr/local/pgsql/bin/initdb -D /usr/local/pgsql/data > /dev/null
    {
        echo \"shared_preload_libraries = ''\"
        echo \"max_worker_processes = 16\"
        echo \"log_min_messages = warning\"
    } >> /usr/local/pgsql/data/postgresql.conf
"

step "Starting PostgreSQL under sanitizer runtime..."
docker exec "${CONTAINER_NAME}" bash -c "
    sudo -u postgres env ${SAN_RUNTIME_OPTS} \
        /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data -l /tmp/pg.log start
    sleep 2
    sudo -u postgres env ${SAN_RUNTIME_OPTS} /usr/local/pgsql/bin/createdb regression || true
"

step "Copying pg_background source into container..."
docker cp . "${CONTAINER_NAME}:/tmp/pg_background"

step "Building pg_background with matching sanitizer flags..."
docker exec "${CONTAINER_NAME}" bash -c "
    cd /tmp/pg_background
    chown -R postgres:postgres .
    sudo -u postgres env ${SAN_RUNTIME_OPTS} PATH=/usr/local/pgsql/bin:\$PATH \
        make CFLAGS='${SAN_CFLAGS}' LDFLAGS='${SAN_LDFLAGS}' clean
    sudo -u postgres env ${SAN_RUNTIME_OPTS} PATH=/usr/local/pgsql/bin:\$PATH \
        make CFLAGS='${SAN_CFLAGS}' LDFLAGS='${SAN_LDFLAGS}'
    sudo -u postgres env ${SAN_RUNTIME_OPTS} PATH=/usr/local/pgsql/bin:\$PATH \
        make install
"

step "Running regression tests under ASan/UBSan..."
set +e
docker exec "${CONTAINER_NAME}" bash -c "
    cd /tmp/pg_background
    sudo -u postgres env PATH=/usr/local/pgsql/bin:\$PATH ${SAN_RUNTIME_OPTS} \
        make installcheck 2>&1
"
TEST_RESULT=$?
set -eo pipefail

if [ $TEST_RESULT -eq 0 ]; then
    info "ASan/UBSan run PASSED on PostgreSQL ${PG_VERSION}"
else
    error "ASan/UBSan run FAILED on PostgreSQL ${PG_VERSION}"
    echo
    echo "=== Postgres log tail ==="
    docker exec "${CONTAINER_NAME}" tail -50 /tmp/pg.log || true
    echo
    echo "=== Regression diffs (if any) ==="
    docker exec "${CONTAINER_NAME}" cat /tmp/pg_background/regression.diffs 2>/dev/null || true
    exit "$TEST_RESULT"
fi
