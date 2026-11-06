# Builds msdfgen's core from vendor/msdfgen for tools/cook, with cn_msdf.cpp, the C API that the cooker calls to make a
# font's atlas (see docs/content/kinds/fonts.md#fonts). `just msdfgen` configures it, and puts cn_msdfgen.lib in
# <build dir>/out, where tools/cook/msdf.odin looks for it.
#
# Only the core is built. msdfgen's extensions read fonts with FreeType and write PNGs; the cooker reads outlines with
# vendor:stb/truetype and writes the atlas as a texture blob, so it needs neither.
cmake_minimum_required(VERSION 3.24)
project(cinnabar_msdfgen LANGUAGES CXX)

# Odin links the static CRT, so the library must use it too.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
set(CMAKE_CXX_STANDARD 17)

set(out "${CMAKE_BINARY_DIR}/out")
foreach(kind ARCHIVE LIBRARY RUNTIME)
    set(CMAKE_${kind}_OUTPUT_DIRECTORY "${out}")
    set(CMAKE_${kind}_OUTPUT_DIRECTORY_RELEASE "${out}")
endforeach()

set(msdfgen "${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor/msdfgen")
file(GLOB core_sources "${msdfgen}/core/*.cpp")

add_library(cn_msdfgen STATIC cn_msdf.cpp ${core_sources})
target_include_directories(cn_msdfgen PRIVATE "${msdfgen}")
target_compile_definitions(cn_msdfgen PRIVATE MSDFGEN_USE_CPP11 MSDFGEN_PUBLIC=)
# msdfgen's sources are not ours to clean up.
set_source_files_properties(${core_sources} PROPERTIES COMPILE_OPTIONS "/W0")
