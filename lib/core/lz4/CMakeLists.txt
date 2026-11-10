# Builds LZ4's block codec from vendor/lz4 for the cooker, which compresses a mesh's pages with it, and the runtime,
# which decompresses them (see docs/content/kinds/meshes.md#pages). `just lz4` configures it, and puts cn_lz4.lib in
# <build dir>/out, where lib/core/lz4/lz4.odin looks for it.
cmake_minimum_required(VERSION 3.24)
project(cinnabar_lz4 LANGUAGES C)

# Odin links the static CRT, so the library must use it too.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

set(out "${CMAKE_BINARY_DIR}/out")
foreach(kind ARCHIVE LIBRARY RUNTIME)
    set(CMAKE_${kind}_OUTPUT_DIRECTORY "${out}")
    set(CMAKE_${kind}_OUTPUT_DIRECTORY_RELEASE "${out}")
endforeach()

set(lz4 "${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor/lz4/lib")

add_library(cn_lz4 STATIC "${lz4}/lz4.c" "${lz4}/lz4hc.c")
target_include_directories(cn_lz4 PRIVATE "${lz4}")
# LZ4's sources are not ours to clean up.
target_compile_options(cn_lz4 PRIVATE /W0)
