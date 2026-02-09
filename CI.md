# CI/CD Documentation

## Overview

The pg_background CI pipeline uses GitHub Actions with containerized PostgreSQL to ensure consistent, deterministic testing across multiple PostgreSQL versions.

## Architecture

### Workflow Components

1. **Test Job**: Builds and tests the extension against multiple PostgreSQL versions
   - Uses official `postgres` Docker images as service containers
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

## Local Reproduction

### Prerequisites

- Docker installed and running
- PostgreSQL client tools (psql)
- Build tools (gcc, make)

### Testing Against a Specific PostgreSQL Version

To test the extension locally against a specific PostgreSQL version, follow these steps:

#### 1. Start PostgreSQL Container

```bash
# Choose your PostgreSQL version (12-18)
PG_VERSION=16

docker run --name pg-test -d \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_DB=postgres \
  -p 5432:5432 \
  postgres:${PG_VERSION}

# Wait for PostgreSQL to be ready
until docker exec pg-test pg_isready -U postgres; do
  echo "Waiting for PostgreSQL..."
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

# Install (requires sudo)
sudo -E make install
```

#### 4. Run Tests

```bash
# Set connection parameters
export PGHOST=127.0.0.1
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD=postgres
export PGDATABASE=postgres

# Add PostgreSQL binaries to PATH
export PATH=/usr/lib/postgresql/${PG_VERSION}/bin:$PATH

# Run regression tests
make installcheck \
  REGRESS_OPTS+=" --host=$PGHOST --port=$PGPORT --user=$PGUSER"
```

#### 5. Cleanup

```bash
docker stop pg-test
docker rm pg-test
```

### Using Docker Compose (Alternative)

Create a `docker-compose.test.yml`:

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:${PG_VERSION:-16}
    environment:
      POSTGRES_PASSWORD: postgres
      POSTGRES_USER: postgres
      POSTGRES_DB: postgres
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 20
```

Then run:

```bash
PG_VERSION=16 docker-compose -f docker-compose.test.yml up -d
# Wait for health check to pass
# Build and test as above
PG_VERSION=16 docker-compose -f docker-compose.test.yml down
```

## Troubleshooting

### Build Fails with "Cannot find postgres.h"

**Problem**: The compiler cannot find PostgreSQL header files.

**Solution**: Ensure `PG_CONFIG` environment variable points to the correct `pg_config` binary:

```bash
export PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config
$PG_CONFIG --includedir-server  # Should show the header directory
make clean && make
```

### Tests Fail with Connection Errors

**Problem**: Tests cannot connect to the PostgreSQL container.

**Solution**: 
1. Verify the container is running and healthy:
   ```bash
   docker ps
   docker exec pg-test pg_isready -U postgres
   ```

2. Check connection parameters match:
   ```bash
   psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -c "SELECT version();"
   ```

### Permission Denied During Installation

**Problem**: `make install` fails with permission errors.

**Solution**: Use `sudo -E` to preserve environment variables:

```bash
sudo -E make install
```

The `-E` flag ensures `PG_CONFIG` is passed through to the sudo environment.

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

### Service Container Configuration

The PostgreSQL service container is configured with:

```yaml
services:
  postgres:
    image: postgres:${{ matrix.pg }}
    env:
      POSTGRES_PASSWORD: postgres
      POSTGRES_USER: postgres
      POSTGRES_DB: postgres
    ports:
      - 5432:5432
    options: >-
      --health-cmd="pg_isready -U postgres -d postgres"
      --health-interval=5s
      --health-timeout=5s
      --health-retries=20
```

Health checks ensure PostgreSQL is ready before tests begin.

### Makefile PG_CONFIG Override

The Makefile uses `PG_CONFIG ?= pg_config` which allows the variable to be overridden from:
1. Environment variables
2. Command-line arguments

This ensures the correct PostgreSQL version is targeted during build, install, and test phases.

## Contributing

When modifying CI:

1. Test changes locally using Docker first
2. Ensure all matrix combinations are considered
3. Update this documentation if workflow changes
4. Keep YAML readable; move complex logic to scripts if needed

## References

- [PostgreSQL Docker Hub](https://hub.docker.com/_/postgres)
- [GitHub Actions Service Containers](https://docs.github.com/en/actions/using-containerized-services/about-service-containers)
- [PGXS Build System](https://www.postgresql.org/docs/current/extend-pgxs.html)
