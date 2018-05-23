# How to build for Windows by Visual Studio
1. First, Open pg_background.sln on Visual Studio 2017.
Then, change include and library directory. Reference the "Include and library directories" section of https://blog.2ndquadrant.com/compiling-postgresql-extensions-visual-studio-windows/ .
2. Change ${POSTGRESQL_DIR}/include/server/storage/proc.h
```c
extern int	StatementTimeout;
```
to
```c
extern PGDLLIMPORT int	StatementTimeout;
```
3. Choose architecture and build pg_background.