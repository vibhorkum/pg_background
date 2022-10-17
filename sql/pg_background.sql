CREATE EXTENSION pg_background;

CREATE TABLE t(id integer);

SELECT * FROM pg_background_result(pg_background_launch('INSERT INTO t SELECT 1')) AS (result TEXT);

SELECT * FROM t;

SELECT * FROM pg_background_discard_result(pg_background_launch($$DROP TABLE IF EXISTS not_a_table; SELECT 1, 'val'$$));
