# Builds meshoptimizer's cluster LOD builder, demo/clusterlod.h, for tools/cook (see docs/content/kinds/meshes.md#meshlets).
# `just meshoptimizer` configures it, and puts cn_clusterlod.lib in <build dir>/out, where tools/cook/meshoptimizer.odin
# looks for it. It calls meshoptimizer, which the cooker links on its own.
cmake_minimum_required(VERSION 3.24)
project(cinnabar_clusterlod LANGUAGES CXX)

# Odin links the static CRT, so the library must use it too.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
set(CMAKE_CXX_STANDARD 17)

set(out "${CMAKE_BINARY_DIR}/out")
foreach(kind ARCHIVE LIBRARY RUNTIME)
    set(CMAKE_${kind}_OUTPUT_DIRECTORY "${out}")
    set(CMAKE_${kind}_OUTPUT_DIRECTORY_RELEASE "${out}")
endforeach()

set(meshopt "${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor/meshoptimizer")

add_library(cn_clusterlod STATIC clusterlod.cpp)
target_include_directories(cn_clusterlod PRIVATE "${meshopt}/src" "${meshopt}/demo")
# meshoptimizer's sources are not ours to clean up.
target_compile_options(cn_clusterlod PRIVATE /W0)
