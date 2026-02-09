MODULE_big = pg_background
OBJS = pg_background.o

EXTENSION = pg_background

# Ship the base + upgrade scripts you support
DATA = \
	pg_background--1.6.sql \
	pg_background--1.4--1.6.sql \
	pg_background--1.5--1.6.sql \
	pg_background--1.4--1.5.sql \
	pg_background--1.0--1.4.sql \
	pg_background--1.1--1.4.sql \
	pg_background--1.2--1.4.sql \
	pg_background--1.3--1.4.sql

# Regression
REGRESS = pg_background

# Load extension before running sql/pg_background.sql
# (Keeps expected output clean, avoids "already exists" noise)
REGRESS_OPTS = --load-extension=$(EXTENSION)

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
