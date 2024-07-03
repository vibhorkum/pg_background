MODULE_big = pg_background
OBJS = pg_background.o

EXTENSION = pg_background
DATA = pg_background--1.2.sql pg_background--1.0--1.2.sql pg_background--1.1--1.2.sql
REGRESS = pg_background

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
