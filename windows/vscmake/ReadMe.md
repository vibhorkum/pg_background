# How to build for Windows by CMake
1. Change CMakeSettings.json.<br>
Set "POSTGRESQL_DIR" to your PostgreSQL install directory.<br>
For example,<br>
```json
"POSTGRESQL_DIR": "C:\\Program Files\\PostgreSQL\\9.5"
```
2. Change ${POSTGRESQL_DIR}/include/server/storage/proc.h
```c
extern int	StatementTimeout;
```
to
```c
extern PGDLLIMPORT int	StatementTimeout;
```
3. Launch Visual Studio 2017 and Open windows\vscmake folder.
4. Choose architecture and build pg_background.

see also) 
https://docs.microsoft.com/cpp/ide/cmake-tools-for-visual-cpp