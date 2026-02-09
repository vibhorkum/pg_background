# CI/CD Documentation

## Overview

The pg_background CI pipeline uses GitHub Actions with containerized PostgreSQL to ensure consistent, deterministic testing across multiple PostgreSQL versions. The workflow builds the extension on the Ubuntu runner (with proper dev headers) and then copies the built artifacts into a PostgreSQL Docker container for testing.

## Architecture

### Workflow Components

1. **Test Job**: Builds and tests the extension against multiple PostgreSQL versions
   - Uses official `postgres` Docker images for runtime testing
   - Builds extension on Ubuntu runner with matching PostgreSQL dev headers
   - Copies built artifacts into container for testing
   - Tests against PostgreSQL 12-18 (version 18 on Ubuntu 24.04 only)
   - Runs on both Ubuntu 22.04 and 24.04

2. **Lint Job**: Runs static analysis checks
   - `cppcheck` for C code analysis
   - `clang-format` for code style verification

3. **Security Job**: Performs CodeQL security scanning
   - Analyzes code for security vulnerabilities
   - Uses PostgreSQL 16 headers for build

### Test Matrix

The test job runs against multiple combinations:
- Ubuntu 22.04: PostgreSQL 12, 13, 14, 15, 16, 17
- Ubuntu 24.04: PostgreSQL 13, 14, 15, 16, 17, 18

PostgreSQL 12 is excluded from Ubuntu 24.04 due to package availability.

### Build and Test Flow

1. **Start Container**: PostgreSQL container is started with `docker run`
2. **Build on Runner**: Extension is built on the runner with dev headers for the target PostgreSQL version
3. **Copy Artifacts**: Built `.so` file and extension SQL files are copied into the running container
4. **Run Tests**: Regression tests connect to the containerized PostgreSQL and verify functionality

This hybrid approach ensures:
- Consistent build environment (runner with PGDG packages)
- Isolated runtime environment (containerized PostgreSQL)
- No dependency on pre-installed PostgreSQL on runners
- Reproducible local testing with Docker

## Local Reproduction

### Prerequisites

- Docker installed and running
- PostgreSQL client tools (psql)
- Build tools (gcc, make)
- PostgreSQL development headers

### Testing Against a Specific PostgreSQL Version

To test the extension locally against a specific PostgreSQL version, follow these steps:

#### 1. Start PostgreSQL Container

```bash
# Choose your PostgreSQL version (12-18)
PG_VERSION=16

docker run --name postgres-test -d \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_DB=postgres \
  -p 5432:5432 \
  postgres:${PG_VERSION}

# Wait for PostgreSQL to be ready
for i in {1..30}; do
  if docker exec postgres-test pg_isready -U postgres >/dev/null 2>&1; then
    echo "PostgreSQL is ready"
    break
  fi
  echo "Waiting... ($i/30)"
  sleep 2
done
```

#### 2. Install PostgreSQL Development Headers

```bash
# Add PostgreSQL APT repository
sudo apt-get update
sudo apt-get install -y ca-certificates wget gnupg lsb-release

sudo install -d -m 0755 /usr/share/keyrings
wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
  https://apt.postgresql.org/pub/repos/apt \
  $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list

# Install headers and client tools
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  postgresql-client-${PG_VERSION} \
  postgresql-server-dev-${PG_VERSION} \
  libkrb5-dev
```

#### 3. Build the Extension

```bash
export PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config

# Verify pg_config
$PG_CONFIG --version

# Build
make clean
make
```

#### 4. Copy Extension Files to Container

```bash
# Get PostgreSQL paths
PKGLIBDIR=$($PG_CONFIG --pkglibdir)
SHAREDIR=$($PG_CONFIG --sharedir)

# Copy shared library
docker exec postgres-test mkdir -p "$PKGLIBDIR"
docker cp pg_background.so postgres-test:$PKGLIBDIR/pg_background.so

# Copy extension files
docker exec postgres-test mkdir -p "$SHAREDIR/extension"
docker cp pg_background.control postgres-test:$SHAREDIR/extension/
docker cp pg_background--1.6.sql postgres-test:$SHAREDIR/extension/
for f in pg_background--*.sql; do
  docker cp "$f" postgres-test:$SHAREDIR/extension/
done

# Verify
docker exec postgres-test ls -la "$PKGLIBDIR/pg_background.so"
docker exec postgres-test ls -la "$SHAREDIR/extension/pg_background.control"
```

#### 5. Run Tests

```bash
# Set connection parameters
export PGHOST=127.0.0.1
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD=postgres
export PGDATABASE=postgres

# Add PostgreSQL binaries to PATH
export PATH=/usr/lib/postgresql/${PG_VERSION}/bin:$PATH

# Test extension loads
psql -c "CREATE EXTENSION pg_background;"
psql -c "SELECT * FROM pg_available_extensions WHERE name = 'pg_background';"

# Run regression tests
make installcheck \
  REGRESS_OPTS+=" --host=$PGHOST --port=$PGPORT --user=$PGUSER"
```

#### 6. Cleanup

```bash
docker stop postgres-test
docker rm postgres-test
```

### Quick Test Script

Create a `test-local.sh` script:

```bash
#!/bin/bash
set -euo pipefail

PG_VERSION=${1:-16}

echo "Testing pg_background with PostgreSQL $PG_VERSION"

# Start container
docker run --name pg-test -d \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_DB=postgres \
  -p 5432:5432 \
  postgres:${PG_VERSION}

# Wait for ready
sleep 5
docker exec pg-test pg_isready -U postgres

# Build
export PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config
make clean && make

# Copy files
PKGLIBDIR=$($PG_CONFIG --pkglibdir)
SHAREDIR=$($PG_CONFIG --sharedir)
docker exec pg-test mkdir -p "$PKGLIBDIR" "$SHAREDIR/extension"
docker cp pg_background.so pg-test:$PKGLIBDIR/
docker cp pg_background.control pg-test:$SHAREDIR/extension/
for f in pg_background--*.sql; do docker cp "$f" pg-test:$SHAREDIR/extension/; done

# Test
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE=postgres
export PATH=/usr/lib/postgresql/${PG_VERSION}/bin:$PATH
make installcheck REGRESS_OPTS+=" --host=$PGHOST --port=$PGPORT --user=$PGUSER"

# Cleanup
docker stop pg-test && docker rm pg-test

echo "Tests passed!"
```

Run with: `bash test-local.sh 16`

## Troubleshooting

### Build Fails with "Cannot find postgres.h"

**Problem**: The compiler cannot find PostgreSQL header files.

**Solution**: Ensure `PG_CONFIG` environment variable points to the correct `pg_config` binary:

```bash
export PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config
$PG_CONFIG --includedir-server  # Should show the header directory
make clean && make
```

### Build Fails with clang-19 or llvm-lto not found

**Problem**: PGXS expects specific clang/llvm tool versions that may not be installed.

**Solution**: The CI workflow creates symlinks to available versions. You can do the same locally:

```bash
# Create clang-19 symlink
sudo ln -sf /usr/bin/clang /usr/bin/clang-19

# Find available llvm and create llvm-19 symlink
LLVM_VER=$(ls -d /usr/lib/llvm-* 2>/dev/null | sort -V | tail -1 | sed 's|.*/llvm-||')
sudo mkdir -p /usr/lib/llvm-19/bin
sudo ln -sf /usr/lib/llvm-${LLVM_VER}/bin/llvm-lto /usr/lib/llvm-19/bin/llvm-lto
```

### Tests Fail with Connection Errors

**Problem**: Tests cannot connect to the PostgreSQL container.

**Solution**: 
1. Verify the container is running and healthy:
   ```bash
   docker ps
   docker exec postgres-test pg_isready -U postgres
   ```

2. Check connection parameters match:
   ```bash
   psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -c "SELECT version();"
   ```

### Extension Not Found After Copying

**Problem**: `CREATE EXTENSION` fails with "extension not available".

**Solution**: Verify files were copied to the correct locations:

```bash
docker exec postgres-test ls -la /usr/lib/postgresql/${PG_VERSION}/lib/pg_background.so
docker exec postgres-test ls -la /usr/share/postgresql/${PG_VERSION}/extension/pg_background.control
```

Ensure the paths match what `pg_config` reports.

### Regression Diffs

If regression tests fail, check the diff output:

```bash
cat regression.diffs
cat regression.out
ls results/
```

## CI Workflow Details

### Key Environment Variables

- `PG_CONFIG`: Path to the pg_config binary for the target PostgreSQL version
- `PGHOST`: PostgreSQL host (127.0.0.1 for container)
- `PGPORT`: PostgreSQL port (5432)
- `PGUSER`: Database user (postgres)
- `PGPASSWORD`: Database password (postgres)
- `PGDATABASE`: Database name (postgres)

### Docker Container Configuration

The PostgreSQL container is started with:

```yaml
docker run --name postgres-test -d \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_DB=postgres \
  -p 5432:5432 \
  postgres:${{ matrix.pg }}
```

The container is automatically stopped and removed in the cleanup step.

### Makefile PG_CONFIG Override

The Makefile uses `PG_CONFIG ?= pg_config` which allows the variable to be overridden from:
1. Environment variables
2. Command-line arguments

This ensures the correct PostgreSQL version is targeted during build, install, and test phases.

### Why This Architecture?

**Previous Approach (Service Containers)**:
- Used GitHub Actions service containers
- Built on runner, installed on runner
- Tried to connect to containerized PostgreSQL
- ❌ Extension files not available in container

**Current Approach (Docker + Copy)**:
- Start PostgreSQL container explicitly with `docker run`
- Build on runner with proper dev headers
- Copy built artifacts into container
- ✅ Extension available in container for testing
- ✅ Full control over container lifecycle
- ✅ Easy to reproduce locally

## Contributing

When modifying CI:

1. Test changes locally using Docker first (see Quick Test Script above)
2. Ensure all matrix combinations are considered
3. Update this documentation if workflow changes
4. Keep YAML readable; complex logic can go in the workflow steps

## References

- [PostgreSQL Docker Hub](https://hub.docker.com/_/postgres)
- [GitHub Actions Docker](https://docs.github.com/en/actions/using-containerized-services/about-service-containers)
- [PGXS Build System](https://www.postgresql.org/docs/current/extend-pgxs.html)
- [PostgreSQL Global Development Group APT Repository](https://wiki.postgresql.org/wiki/Apt)
