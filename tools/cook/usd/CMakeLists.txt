# Builds vendor/lightusd (TinyUSDZ) and cn_usd.cpp, its C interface, for tools/cook (see docs/content/kinds/stages.md).
# `just lightusd` configures it, and puts cn_usd.lib and lightusd_static.lib in <build dir>/out, where tools/cook/usd.odin
# looks for them.
cmake_minimum_required(VERSION 3.24)
project(cinnabar_usd LANGUAGES C CXX)

# Odin links the static CRT, so the libraries must use it too.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
set(CMAKE_CXX_STANDARD 17)
# Odin's linker does not take link-time code generation objects.
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION OFF)

set(out "${CMAKE_BINARY_DIR}/out")
foreach(kind ARCHIVE LIBRARY RUNTIME)
    set(CMAKE_${kind}_OUTPUT_DIRECTORY "${out}")
    set(CMAKE_${kind}_OUTPUT_DIRECTORY_RELEASE "${out}")
endforeach()

# Only the reader, composition and Tydra. The cooker decodes images itself, so LightUSD's image loader, and the stb_image
# it would bring next to Odin's, stay out.
set(LIGHTUSD_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_USE_CCACHE OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_BUILD_BENCHMARKS OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_BUILD_GUI_VIEWER OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_BUILD_QUICKLOOK OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_C_API OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_PYTHON OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_TYDRA ON CACHE BOOL "" FORCE)
# Parsing a crate file in parallel matters for Jungle Ruins' half-gigabyte layers.
set(LIGHTUSD_ENABLE_THREAD ON CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_BUILTIN_IMAGE_LOADER OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_NO_STB_IMAGE_IMPLEMENTATION OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_NO_STB_IMAGE_WRITE_IMPLEMENTATION OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_TIFF OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_EXR OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_TEXTOOLS OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_COLORIO OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_FPNGE OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_MESHOPT OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_USDMTLX OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_JSON OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_USD_TO_GLTF OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_USDOBJ OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_USDFBX OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_USDVOX OFF CACHE BOOL "" FORCE)
# Tydra calls the volume reader whether or not this is on, so it stays on, and so does zstd, which the reader
# decompresses with.
set(LIGHTUSD_WITH_USDVOL ON CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_ZSTD_COMPRESSION ON CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_AUDIO OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_MCP_SERVER OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_QJS OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_WAMR OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_GEOGRAM OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_COROUTINE OFF CACHE BOOL "" FORCE)
set(LIGHTUSD_WITH_REMOTERY OFF CACHE BOOL "" FORCE)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor/lightusd" lightusd EXCLUDE_FROM_ALL)
# LightUSD's sources are not ours to clean up.
target_compile_options(lightusd_static PRIVATE /W0)
# LightUSD's copy of stb_image_write is its own: Odin's vendor:stb defines the same functions, which the cooker's tests
# link.
target_compile_definitions(lightusd_static PRIVATE STB_IMAGE_WRITE_STATIC)

add_library(cn_usd STATIC cn_usd.cpp)
target_link_libraries(cn_usd PRIVATE lightusd_static)
target_include_directories(cn_usd PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor/lightusd/src")
