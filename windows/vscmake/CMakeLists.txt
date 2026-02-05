cmake_minimum_required(VERSION 3.0.0)

set(PROJECT_NAME "pg_background")
set(PROJECT_ID "pg_background")

project("${PROJECT_ID}")

set(POSTGRESQL_DIR "${CMAKE_INSTALL_PREFIX}" CACHE PATH "PostgreSQL binary directory")

set(LIBRARY_NAME "lib${PROJECT_ID}")

set(EXTENSION_DIR "lib")
set(EXTENSION_DATA_DIR "share/extension")
set(DOCUMENT_DIR "share/${PROJECT_ID}")

set(SOURCES
  "../../pg_background.c"
  "../pg_background_win.h"
)

message(STATUS "*** dump start cmake variables ***")
message(STATUS "POSTGRESQL_DIR=${POSTGRESQL_DIR}")
message(STATUS "${POSTGRESQL_DIR}/lib")
message(STATUS "*** dump end ***")

# Set the library path, adding the PostgreSQL lib dir
link_directories(
  "${POSTGRESQL_DIR}/lib"
)

## Compile a DLL
add_library("${LIBRARY_NAME}" SHARED ${SOURCES})
set_target_properties("${LIBRARY_NAME}"
   PROPERTIES
   OUTPUT_NAME "${PROJECT_ID}"
)

## Compile with plain C
# Nothing to do.

# Disable C++ exceptions
set_source_files_properties(${SOURCES}
  PROPERTIES
  COMPILE_FLAGS "/EHsc"
)

## Set the include path, adding:
##  include\server\port\win32_msvc
##  include\server\port\win32
##  include\server
##  include
include_directories(
  "${POSTGRESQL_DIR}/include/server/port/win32_msvc"
  "${POSTGRESQL_DIR}/include/server/port/win32"
  "${POSTGRESQL_DIR}/include/server"
  "${POSTGRESQL_DIR}/include"
)

# Add postgres.lib to the library link list
target_link_libraries("${LIBRARY_NAME}" "postgres.lib")

# In the C preprocessor definitions add WIN32
set(WIN32 1)
