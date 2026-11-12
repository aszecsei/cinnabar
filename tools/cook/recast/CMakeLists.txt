# Builds Recast from vendor/recastnavigation for tools/cook, with cn_recast.cpp, the C API that the cooker calls to bake
# a navmesh's tile (see docs/content/kinds/nav-meshes.md#recast). `just recast` configures it, and puts cn_recast.lib in
# <build dir>/out, where tools/cook/recast.odin looks for it.
#
# Only Recast is built. The runtime reads the cooker's navmesh blobs itself, so Detour, DetourCrowd and DetourTileCache
# are not.
cmake_minimum_required(VERSION 3.24)
project(cinnabar_recast LANGUAGES CXX)

# Odin links the static CRT, so the library must use it too.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
set(CMAKE_CXX_STANDARD 17)
# Odin's linker does not take link-time code generation objects.
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION OFF)

set(out "${CMAKE_BINARY_DIR}/out")
foreach(kind ARCHIVE LIBRARY RUNTIME)
    set(CMAKE_${kind}_OUTPUT_DIRECTORY "${out}")
    set(CMAKE_${kind}_OUTPUT_DIRECTORY_RELEASE "${out}")
endforeach()

set(recast "${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor/recastnavigation/Recast")
file(GLOB recast_sources "${recast}/Source/*.cpp")

add_library(cn_recast STATIC cn_recast.cpp ${recast_sources})
target_include_directories(cn_recast PRIVATE "${recast}/Include")
# Recast's sources are not ours to clean up.
set_source_files_properties(${recast_sources} PROPERTIES COMPILE_OPTIONS "/W0")
