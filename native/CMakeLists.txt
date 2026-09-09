cmake_minimum_required(VERSION 3.10)
project(recovery_library VERSION 0.0.1 LANGUAGES C)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
add_compile_options(-O3)

# minlzlib（hardnested 的 xz 字典解压依赖）
add_subdirectory(minlzlib)

add_library(recovery SHARED
    recovery.c
    crapto1.c
    crypto1.c
    bucketsort.c
    mfkey.c
    parity.c
    hardnested.c
    pm3/commonutil.c
    pm3/ui.c
    pm3/util_posix.c
    pm3/util.c
    hardnested/tables.c
    hardnested/hardnested_bruteforce.c
    hardnested/hardnested_bitarray_core.c
    hardnested/hardnested_bf_core.c)

target_include_directories(recovery PRIVATE .)
set_target_properties(recovery PROPERTIES OUTPUT_NAME "recovery")
target_link_libraries(recovery PRIVATE minlzlib m)
