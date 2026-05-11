MODULE_big = pg_background
OBJS = src/pg_background.o src/pg_background_worker.o

EXTENSION = pg_background

# Allow C sources in src/ to find local headers and the Windows shim header
# (windows/pg_background_win.h is included as "pg_background_win.h").
PG_CPPFLAGS += -I$(srcdir)/src -I$(srcdir)/windows

# Ship the base + upgrade scripts you support.
#
# v2.0 supports upgrade only from 1.8 onward. Anyone on a pre-1.8 install
# must first upgrade to 1.8 against the 1.10 release line before moving to
# 2.0. The pre-1.8 legacy upgrade scripts have been removed (extension/legacy/
# directory is gone).
DATA = \
	extension/pg_background--2.0.sql \
	extension/pg_background--1.10--2.0.sql \
	extension/pg_background--1.10.sql \
	extension/pg_background--1.9--1.10.sql \
	extension/pg_background--1.9.sql \
	extension/pg_background--1.8--1.9.sql \
	extension/pg_background--1.8.sql

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
