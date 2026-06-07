MODULE_big = pg_background
OBJS = src/pg_background.o src/pg_background_worker.o

EXTENSION = pg_background

# Allow C sources in src/ to find local headers and the Windows shim header
# (windows/pg_background_win.h is included as "pg_background_win.h").
PG_CPPFLAGS += -I$(srcdir)/src -I$(srcdir)/windows

# Ship the 2.0 base script plus the upgrade scripts.
#
# We deliberately do NOT ship the pre-2.0 *base* install scripts
# (1.8/1.9/1.10.sql): 2.0 dropped the v1 C functions, so those scripts
# (which CREATE FUNCTION pg_background_launch ... LANGUAGE C) cannot resolve
# their symbols against the 2.0 .so and a fresh `CREATE EXTENSION VERSION
# '1.8'` would fail. Existing pre-2.0 installs upgrade via the --X--Y scripts
# below (PostgreSQL only needs the upgrade scripts, not the old base scripts,
# to migrate an installed extension). Anyone on a pre-1.8 install must first
# reach 1.8 on the 1.10 release line before moving to 2.0.
DATA = \
	extension/pg_background--2.0.sql \
	extension/pg_background--1.10--2.0.sql \
	extension/pg_background--1.9--1.10.sql \
	extension/pg_background--1.8--1.9.sql

# Regression
REGRESS = pg_background

# Note: The test SQL file handles CREATE EXTENSION itself,
# so we don't use --load-extension here.
# REGRESS_OPTS = --load-extension=$(EXTENSION)

# If your regression needs longer than default (yours has pg_sleep),
# you can tune timeouts via PGOPTIONS if needed.
# Example:
# REGRESS_OPTS += --launcher="env PGOPTIONS='-c statement_timeout=0'"

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

.PHONY: test installcheckclean
test: installcheck

# Sometimes tmp_check residue causes confusion during iteration
installcheckclean:
	rm -rf tmp_check regression.diffs results
