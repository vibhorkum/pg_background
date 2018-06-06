# How to build for Windows by Visual Studio
1. First, Open pg_background.sln on Visual Studio 2017 or Visual Studio 2010.
Then, change include and library directory. Reference the "Include and library directories" section of https://blog.2ndquadrant.com/compiling-postgresql-extensions-visual-studio-windows/ .
2. Choose architecture and build pg_background.

# How to build for Windows by CMake
1. Change CMakeSettings.json.<br>
Set "POSTGRESQL_DIR" to your PostgreSQL install directory.<br>
For example,<br>
```json
"POSTGRESQL_DIR": "C:\\Program Files\\PostgreSQL\\9.5"
```
2. Launch Visual Studio 2017 and Open windows\vscmake folder.
3. Choose architecture and build pg_background.

see also) 
https://docs.microsoft.com/cpp/ide/cmake-tools-for-visual-cpp

# Common
## proc.h
You must change ${POSTGRESQL_DIR}/include/server/storage/proc.h
```c
extern int	StatementTimeout;
```
to
```c
extern PGDLLIMPORT int	StatementTimeout;
## openssl
Maybe opensslconf.h may be necessary.
Get source from https://github.com/openssl/openssl.git and configure the header file.
see also)
https://wiki.openssl.org/index.php/Compilation_and_Installation