# CI/CD Documentation

## Overview

The pg_background CI pipeline uses GitHub Actions with containerized PostgreSQL to ensure consistent, deterministic testing across multiple PostgreSQL versions (14-18). The workflow builds the extension on Ubuntu runners with proper development headers and copies the built artifacts into PostgreSQL Docker containers for testing.

## Quick Start

### Local Testing with Docker

The easiest way to run tests locally is using the provided `scripts/test-local.sh` script:

```bash
# Test with default PostgreSQL version (17)
./scripts/test-local.sh

# Test with a specific version
./scripts/test-local.sh 14
./scripts/test-local.sh 15
./scripts/test-local.sh 16
./scripts/test-local.sh 17
./scripts/test-local.sh 18

# Test all supported versions (14-18)
./scripts/test-local.sh all
```

**Requirements**: Docker must be installed and running. No local PostgreSQL installation required.

## CI Workflow Architecture

### Jobs

| Job | Purpose | Runs On | Timeout |
|-----|---------|---------|---------|
| **test** | Build and test against the PostgreSQL × Ubuntu matrix | ubuntu-22.04, ubuntu-24.04 (PG 14–18) | 15 min |
| **relocatable-test** | Verify `CREATE EXTENSION ... WITH SCHEMA` on every supported PG | ubuntu-24.04 (PG 14–18) | 15 min |
| **upgrade-test** | Validate the 1.8 → 1.9 → 1.10 → 2.0 upgrade chain on every supported PG | ubuntu-24.04 (PG 14–18) | 15 min |
| **assert-test** | Run the regression suite against an assert-enabled PG build | ubuntu-24.04 (PG 14–18) | 30 min |
| **sanitizer-test** | Run the regression suite under AddressSanitizer + UndefinedBehaviorSanitizer | ubuntu-24.04 (PG 17) | 30 min |
| **test-summary** | Aggregate matrix results into a single status check | ubuntu-24.04 | — |
| **lint** | Static analysis (**blocking** cppcheck + clang-format) | ubuntu-24.04 | 10 min |
| **security** | CodeQL security scanning | ubuntu-latest | 20 min |

### Test Matrix

The **test** job runs against all combinations:

| Ubuntu Version | PostgreSQL Versions |
|----------------|---------------------|
| 22.04 | 14, 15, 16, 17, 18 |
| 24.04 | 14, 15, 16, 17, 18 |

**Per-job parallelism**:
- `test`: **10** (2 OS × 5 PG)
- `relocatable-test`: **5** (PG 14–18)
- `upgrade-test`: **5** (PG 14–18)
- `assert-test`: **5** (PG 14–18)
- `sanitizer-test`: **1** (PG 17 only — the build is expensive; add more
  versions if a class of issue is suspected to be PG-major-specific)
- `test-summary`, `lint`, `security`: 1 each

**Grand total: 28 jobs per CI run.** This is up from 19 in the
pre-2.0 layout because the relocatable, upgrade, and sanitizer paths
were either single-shot or didn't exist; 2.0's matrix expansion is
deliberate so a PG-major-specific issue in any of those paths cannot
slip through.

### Sanitizer build details

The `sanitizer-test` job builds PostgreSQL from source with
`-fsanitize=address,undefined -fno-omit-frame-pointer
-fno-sanitize-recover=all -O1 -g3` and builds pg_background with the
matching flags. Loading an instrumented `.so` into a vanilla PG silently
misses bugs because the runtime allocator is unhooked, so we need a
PG that was itself instrumented.

Runtime knobs:
- `ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:halt_on_error=1` — leak
  detection is off because postmaster's small known leaks would
  otherwise drown out real issues; halt+abort on error so CI fails on
  the first real find.
- `UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1` — same idea.

### Workflow Triggers

- **Push**: `master`, `main`, `develop`, `v1.*`, `improvements/*` branches
- **Tags**: `v*` (releases)
- **Pull Requests**: To `master` or `main`
- **Manual**: Via `workflow_dispatch`

### Concurrency Control

The workflow automatically cancels in-progress runs when new commits are pushed to the same branch, saving CI minutes and providing faster feedback.

## Build and Test Flow

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Start Docker   │────▶│  Build on Runner │────▶│ Copy to Docker  │
│  PostgreSQL     │     │  (with dev hdrs) │     │   Container     │
└─────────────────┘     └──────────────────┘     └────────┬────────┘
                                                          │
                                                          ▼
                                                 ┌─────────────────┐
                                                 │ Run Regression  │
                                                 │     Tests       │
                                                 └─────────────────┘
```

1. **Start Container**: PostgreSQL container started with `docker run`
2. **Build on Runner**: Extension built with PGDG development headers
3. **Copy Artifacts**: Built `.so` and SQL files copied into running container
4. **Run Tests**: Regression tests connect to containerized PostgreSQL

### Key Features

- **APT Package Caching**: Faster subsequent runs
- **Parallel Matrix Execution**: All 10 test combinations run simultaneously
- **Artifact Upload on Failure**: Regression diffs available for debugging
- **clang/llvm Symlink Handling**: Automatic compatibility for PGXS requirements

## Extension Features Tested

The regression tests verify all pg_background v1.8 functionality:

- **v1 API**: `pg_background_launch()`, `pg_background_result()`, `pg_background_detach()`
- **v2 API**: `pg_background_launch_v2()`, `pg_background_detach_v2()`, `pg_background_cancel_v2()`
- **Wait Functions**: `pg_background_wait_v2()`, `pg_background_wait_v2_timeout()`
- **Progress Reporting**: `pg_background_progress()`, `pg_background_get_progress_v2()`
- **Statistics**: `pg_background_stats_v2()`, `pg_background_list_v2()`
- **GUC Settings**: `pg_background.max_workers`, `pg_background.default_queue_size`, `pg_background.worker_timeout`

## Manual Local Testing

If you prefer not to use `scripts/test-local.sh`, follow these steps:

### 1. Start PostgreSQL Container

```bash
PG_VERSION=17

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

### 2. Install Build Dependencies

```bash
# Add PostgreSQL APT repository
sudo apt-get update
sudo apt-get install -y ca-certificates wget gnupg lsb-release build-essential libkrb5-dev

sudo install -d -m 0755 /usr/share/keyrings
wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
  https://apt.postgresql.org/pub/repos/apt \
  $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt-get update
sudo apt-get install -y \
  postgresql-client-${PG_VERSION} \
  postgresql-server-dev-${PG_VERSION}
```

### 3. Build the Extension

```bash
export PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config
make clean && make
```

### 4. Copy to Container

```bash
PKGLIBDIR=$($PG_CONFIG --pkglibdir)
SHAREDIR=$($PG_CONFIG --sharedir)

docker exec postgres-test mkdir -p "$PKGLIBDIR" "$SHAREDIR/extension"
docker cp pg_background.so postgres-test:$PKGLIBDIR/
docker cp pg_background.control postgres-test:$SHAREDIR/extension/
for f in pg_background--*.sql; do docker cp "$f" postgres-test:$SHAREDIR/extension/; done
```

### 5. Run Tests

```bash
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE=postgres
export PATH=/usr/lib/postgresql/${PG_VERSION}/bin:$PATH
make installcheck REGRESS_OPTS+=" --host=$PGHOST --port=$PGPORT --user=$PGUSER"
```

### 6. Cleanup

```bash
docker stop postgres-test && docker rm postgres-test
```

## Troubleshooting

### Build Fails with "Cannot find postgres.h"

Ensure `PG_CONFIG` points to the correct `pg_config`:

```bash
export PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config
$PG_CONFIG --includedir-server  # Should show header directory
make clean && make
```

### Build Fails with clang-19 or llvm-lto Not Found

PGXS may expect specific clang/llvm versions. Create symlinks:

```bash
sudo ln -sf /usr/bin/clang /usr/bin/clang-19

LLVM_VER=$(ls -d /usr/lib/llvm-* 2>/dev/null | sort -V | tail -1 | sed 's|.*/llvm-||')
sudo mkdir -p /usr/lib/llvm-19/bin
sudo ln -sf /usr/lib/llvm-${LLVM_VER}/bin/llvm-lto /usr/lib/llvm-19/bin/llvm-lto
```

### Tests Fail with Connection Errors

Verify container is running:

```bash
docker ps
docker exec postgres-test pg_isready -U postgres
psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -c "SELECT version();"
```

### Extension Not Found After Copying

Verify paths match `pg_config`:

```bash
docker exec postgres-test ls -la /usr/lib/postgresql/${PG_VERSION}/lib/pg_background.so
docker exec postgres-test ls -la /usr/share/postgresql/${PG_VERSION}/extension/pg_background.control
```

### Regression Test Diffs

Check the diff output:

```bash
cat regression.diffs
cat regression.out
ls results/
```

## CI Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `PG_CONFIG` | Path to pg_config binary | `/usr/lib/postgresql/17/bin/pg_config` |
| `PGHOST` | PostgreSQL host | `127.0.0.1` |
| `PGPORT` | PostgreSQL port | `5432` |
| `PGUSER` | Database user | `postgres` |
| `PGPASSWORD` | Database password | `postgres` |
| `PGDATABASE` | Database name | `postgres` |
| `DEFAULT_PG_VERSION` | Default PG version for lint/security | `17` |

## Contributing

When modifying CI:

1. Test changes locally using `./scripts/test-local.sh` first
2. Consider all matrix combinations (10 total)
3. Update this documentation if workflow changes
4. Keep YAML readable; complex logic goes in step scripts

## References

- [PostgreSQL Docker Hub](https://hub.docker.com/_/postgres)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [PGXS Build System](https://www.postgresql.org/docs/current/extend-pgxs.html)
- [PostgreSQL APT Repository](https://wiki.postgresql.org/wiki/Apt)
- [CodeQL for C/C++](https://codeql.github.com/docs/codeql-language-guides/codeql-for-cpp/)
