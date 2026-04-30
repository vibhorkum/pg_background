MODULE_big = pg_background
OBJS = src/pg_background.o src/pg_background_worker.o

EXTENSION = pg_background

# Allow C sources in src/ to find local headers and the Windows shim header
# (windows/pg_background_win.h is included as "pg_background_win.h").
PG_CPPFLAGS += -I$(srcdir)/src -I$(srcdir)/windows

# Ship the base + upgrade scripts you support.
# extension/        — currently supported (1.8, 1.9, 1.10) and their upgrade chain
# extension/legacy/ — pre-1.8 base + upgrade scripts kept so existing installs
#                     can still run ALTER EXTENSION ... UPDATE all the way to 1.10.
DATA = \
	extension/pg_background--1.10.sql \
	extension/pg_background--1.9--1.10.sql \
	extension/pg_background--1.9.sql \
	extension/pg_background--1.8--1.9.sql \
	extension/pg_background--1.8.sql \
	extension/legacy/pg_background--1.7--1.8.sql \
	extension/legacy/pg_background--1.7.sql \
	extension/legacy/pg_background--1.6--1.7.sql \
	extension/legacy/pg_background--1.6.sql \
	extension/legacy/pg_background--1.4--1.6.sql \
	extension/legacy/pg_background--1.5--1.6.sql \
	extension/legacy/pg_background--1.4--1.5.sql \
	extension/legacy/pg_background--1.0--1.4.sql \
	extension/legacy/pg_background--1.1--1.4.sql \
	extension/legacy/pg_background--1.2--1.4.sql \
	extension/legacy/pg_background--1.3--1.4.sql

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
