######################################################################
# @author      : Ruan E. Formigoni (ruanformigoni@gmail.com)
# @file        : CMakeLists
# @created     : Thursday Jan 26, 2023 12:17:13 -03
######################################################################

cmake_minimum_required(VERSION 3.1)

project(Fim DESCRIPTION "Application Chroot Subsystem" LANGUAGES CXX)

# Conan
set(CMAKE_MODULE_PATH ${CMAKE_BINARY_DIR})

# Compiler
message(STATUS "Compiler: ${CMAKE_CXX_COMPILER}")
add_definitions("--std=c++17 -Wall -Wextra")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -static")
message(STATUS "CMAKE_C_FLAGS: ${CMAKE_C_FLAGS}")
message(STATUS "CMAKE_CXX_FLAGS: ${CMAKE_CXX_FLAGS}")
set(CMAKE_BUILD_TYPE Debug)

# Tools
## XXD
find_program(XXD_COMMAND xxd)
if(NOT XXD_COMMAND)
  message(FATAL_ERROR "xxd command not found")
endif()

find_program(GIT_COMMAND git)
if(NOT GIT_COMMAND)
  message(FATAL_ERROR "git command not found")
endif()

# Define the command to generate script.h from script.sh
add_custom_command(
  OUTPUT boot.h
  COMMAND ${XXD_COMMAND} -i "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/_boot.sh" > "${CMAKE_CURRENT_SOURCE_DIR}/boot.h"
  COMMAND sed -Ei "s|unsigned char.*=|unsigned char _script_boot\[\] =|g" "${CMAKE_CURRENT_SOURCE_DIR}/boot.h"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/_boot.sh"
  COMMENT "Generating boot.h from _boot.sh"
  VERBATIM
)

# External libraries
if(NOT fmt_FOUND)
  find_package(fmt REQUIRED)
endif()

if(NOT range-v3_FOUND)
  find_package(range-v3 REQUIRED)
endif()

# Definitions
## Timestamp
string(TIMESTAMP TIMESTAMP "%Y%m%d%H%M%S")
add_definitions("-DTIMESTAMP=${TIMESTAMP}")
message(STATUS "TIMESTAMP: ${TIMESTAMP}")
## Commit
execute_process(
  COMMAND ${GIT_COMMAND} rev-parse --short HEAD
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  OUTPUT_VARIABLE GIT_COMMIT_HASH
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
add_definitions("-DCOMMIT=\"${GIT_COMMIT_HASH}\"")
message(STATUS "GIT COMMIT HASH: ${GIT_COMMIT_HASH}")

# Main executable
add_executable(main main.cpp boot.h)
target_link_libraries(main PRIVATE fmt::fmt)
target_link_libraries(main PRIVATE range-v3::range-v3)
