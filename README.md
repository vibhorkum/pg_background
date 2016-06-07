# Postgres Background Worker

pg_background is an extension for EDB Postgres 9.5.
Initially this extension was shared by Robert Haas in PostgreSQL community for demo purpose. Some modification has been done to keep it in sync with latest version of EDB Postgres version >=9.5

This module allows user to arbitrary command in a background worker and gives capability to users to launch 

1. VACUUM in background
2. Autonomous transaction implementation better than dblink way.
3. Allows to perform task like CREATE INDEX CONCURRENTLY from a procedural language 

This module comes with following SQL APIs:
1. ***pg_background_launch*** : This API takes SQL command, which user wants to execute, and size of queue buffer. This function returns the process id of background worker.
2. ***pg_background_result*** : This API takes the process id as input parameter and returns the result of command executed throught the background worker.
3. ***pg_background_detach*** : This API takes the process id and detach the background process which is waiting for user to read its results.

## Installation steps

1. Copy the source code from repository.
2. set pg_config binary location in PATH environment variable
3. Execute following command to install this module
```sql
make
make install
```
After installing module, please use following command install this extension on source and target database as given below:
```sql
  psql -h server.hostname.org -p 5444 -c "CREATE EXTENSION pg_background;" dbname
```

##Usage:

To execute a command in background user can use following SQL API
```sql
SELECT pg_background_launch('SQL COMMAND');
```

To fetch the result of command executed background worker, user can use following command:
```sql
SELECT pg_background_result(pid)
```
**pid is process id returned by pg_background_launch function **

##Example:

```sql
SELECT pg_background_launch('vacuum verbose public.sales');
 pg_background_launch 
----------------------
                11088
(1 row)


SELECT * from pg_background_result(11088) as (x text);
INFO:  vacuuming "public.sales"
INFO:  index "sales_pkey" now contains 0 row versions in 1 pages
DETAIL:  0 index row versions were removed.
0 index pages have been deleted, 0 are currently reusable.
CPU 0.00s/0.00u sec elapsed 0.00 sec.
INFO:  "sales": found 0 removable, 0 nonremovable row versions in 0 out of 0 pages
DETAIL:  0 dead row versions cannot be removed yet.
There were 0 unused item pointers.
Skipped 0 pages due to buffer pins.
0 pages are entirely empty.
CPU 0.00s/0.00u sec elapsed 0.00 sec.
INFO:  vacuuming "pg_toast.pg_toast_1866942"
INFO:  index "pg_toast_1866942_index" now contains 0 row versions in 1 pages
DETAIL:  0 index row versions were removed.
0 index pages have been deleted, 0 are currently reusable.
CPU 0.00s/0.00u sec elapsed 0.00 sec.
INFO:  "pg_toast_1866942": found 0 removable, 0 nonremovable row versions in 0 out of 0 pages
DETAIL:  0 dead row versions cannot be removed yet.
There were 0 unused item pointers.
Skipped 0 pages due to buffer pins.
0 pages are entirely empty.
CPU 0.00s/0.00u sec elapsed 0.00 sec.
   x    
--------
 VACUUM
(1 row)

```
