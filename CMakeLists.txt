cmake_minimum_required(VERSION 3.24)

project(gitstatus LANGUAGES C CXX)

# build.info is the single source of truth for the version and the libgit2
# pin, and the shell bindings read it too, so we parse it rather than
# duplicating the values here.
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/build.info" build_info REGEX "^[a-z0-9_]+=\"[^\"]*\"$")
foreach(line IN LISTS build_info)
  string(REGEX REPLACE "^([a-z0-9_]+)=\"([^\"]*)\"$" "\\1" key "${line}")
  string(REGEX REPLACE "^([a-z0-9_]+)=\"([^\"]*)\"$" "\\2" value "${line}")
  set("${key}" "${value}")
endforeach()
foreach(var gitstatus_version libgit2_version libgit2_sha256)
  if(NOT DEFINED ${var})
    message(FATAL_ERROR "${var} not set in build.info")
  endif()
endforeach()

option(GITSTATUS_STATIC "Link gitstatusd statically (-static-pie where the toolchain can)" OFF)
set(GITSTATUS_SANITIZE "" CACHE STRING
    "Comma-separated -fsanitize= list applied to gitstatusd and libgit2 (e.g. address,undefined or thread)")
set(GITSTATUS_LIBGIT2_TARBALL "" CACHE FILEPATH
    "libgit2 source tarball to build against; defaults to deps/libgit2-<version>.tar.gz, downloaded if missing")
set(GITSTATUS_EXTRA_LIBS "" CACHE STRING "Extra libraries to link gitstatusd against, beyond what libgit2 already pulls in")

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Keep source and build paths out of the binary (__FILE__ in LOG/CHECK, debug
# info) so that two checkouts produce the same bits. This is a bare try_compile
# rather than check_cxx_compiler_flag() on purpose: including the Check*
# modules here would define their functions under our policy version, and
# libgit2's own struct stat probes (cmake_minimum_required 3.5) then run with
# -std=c90 and fail to see st_mtim.
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/CMakeFiles/prefix_map_probe.cc" "int main() {}\n")
try_compile(HAVE_FILE_PREFIX_MAP
  "${CMAKE_CURRENT_BINARY_DIR}/CMakeFiles/prefix_map_probe"
  SOURCES "${CMAKE_CURRENT_BINARY_DIR}/CMakeFiles/prefix_map_probe.cc"
  COMPILE_DEFINITIONS "-ffile-prefix-map=x=y")
if(HAVE_FILE_PREFIX_MAP)
  add_compile_options(
    "-ffile-prefix-map=${CMAKE_CURRENT_SOURCE_DIR}/="
    "-ffile-prefix-map=${CMAKE_CURRENT_BINARY_DIR}/=")
endif()

if(GITSTATUS_STATIC)
  # -static-pie needs PIE objects on both sides of the link, and -fpie (not
  # -fPIC) is what ./build has always compiled with
  add_compile_options(-fpie)
endif()

if(GITSTATUS_SANITIZE)
  add_compile_options(-fsanitize=${GITSTATUS_SANITIZE} -fno-omit-frame-pointer)
  add_link_options(-fsanitize=${GITSTATUS_SANITIZE})
endif()

# libgit2, from the aauren/libgit2 fork pinned in build.info. The tarball is
# cached in deps/ the same way ./build has always done it, so a checkout that
# already has it builds offline, and cmake verifies the sha256 either way.
if(GITSTATUS_LIBGIT2_TARBALL)
  set(libgit2_url "${GITSTATUS_LIBGIT2_TARBALL}")
else()
  set(libgit2_url "https://github.com/aauren/libgit2/archive/${libgit2_version}.tar.gz")
endif()

set(USE_THREADS ON CACHE BOOL "")
set(USE_NSEC ON CACHE BOOL "")
set(EXPERIMENTAL_SHA256 ON CACHE BOOL "")
set(USE_BUNDLED_ZLIB ON CACHE BOOL "")
set(REGEX_BACKEND builtin CACHE STRING "")
set(USE_HTTP_PARSER builtin CACHE STRING "")
set(USE_SSH OFF CACHE BOOL "")
set(USE_HTTPS OFF CACHE BOOL "")
set(USE_GSSAPI OFF CACHE BOOL "")
set(USE_NTLMCLIENT OFF CACHE BOOL "")
set(BUILD_TESTS OFF CACHE BOOL "")
set(BUILD_CLI OFF CACHE BOOL "")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "")
set(ENABLE_REPRODUCIBLE_BUILDS ON CACHE BOOL "")

include(FetchContent)
FetchContent_Declare(libgit2
  URL "${libgit2_url}"
  URL_HASH "SHA256=${libgit2_sha256}"
  DOWNLOAD_DIR "${CMAKE_CURRENT_SOURCE_DIR}/deps"
  DOWNLOAD_NAME "libgit2-${libgit2_version}.tar.gz"
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(libgit2)

file(GLOB gitstatus_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cc")
add_executable(gitstatusd ${gitstatus_sources})

target_compile_options(gitstatusd PRIVATE -funsigned-char -Wall -Wextra)
target_compile_definitions(gitstatusd PRIVATE
  GITSTATUS_VERSION=${gitstatus_version}
  GITSTATUS_ZERO_NSEC
  _GNU_SOURCE
  _GLIBCXX_ASSERTIONS)

# The generated experimental.h has to shadow the in-tree one, which is why the
# binary dir comes first
target_include_directories(gitstatusd SYSTEM PRIVATE
  "${libgit2_BINARY_DIR}/include"
  "${libgit2_SOURCE_DIR}/include")

find_package(Threads REQUIRED)
target_link_libraries(gitstatusd PRIVATE libgit2package Threads::Threads ${GITSTATUS_EXTRA_LIBS})

# `ctest` runs the fixtures against the binary we just built. The sanitizer
# options match what the roadmap gates were run with: LSan is off because the
# per-thread scan arenas are reported when the daemon exits on EOF.
enable_testing()
add_test(NAME fixtures COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/test/run.sh" $<TARGET_FILE:gitstatusd>)
if(GITSTATUS_SANITIZE)
  set_tests_properties(fixtures PROPERTIES ENVIRONMENT
    "ASAN_OPTIONS=detect_leaks=0;UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1;TSAN_OPTIONS=halt_on_error=1")
endif()

if(GITSTATUS_STATIC)
  include(CheckLinkerFlag)
  check_linker_flag(CXX "-static-pie" HAVE_STATIC_PIE)
  if(HAVE_STATIC_PIE)
    target_link_options(gitstatusd PRIVATE -static-pie)
  else()
    target_link_options(gitstatusd PRIVATE -static)
  endif()
endif()
