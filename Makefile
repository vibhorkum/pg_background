MODULE_big = pg_background
OBJS = pg_background.o

EXTENSION = pg_background
DATA = pg_background--1.5.sql  pg_background--1.4--1.5.sql pg_background--1.0--1.4.sql pg_background--1.1--1.4.sql pg_background--1.2--1.4.sql pg_background--1.3--1.4.sql
REGRESS = pg_background

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
