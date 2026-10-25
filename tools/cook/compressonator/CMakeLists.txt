# Builds Compressonator's block compression core, CMP_Core, from vendor/compressonator for tools/cook, with
# cn_compress.cpp, the C API that the cooker calls (see docs/content-pipeline.md#textures). `just compressonator`
# configures it, and puts cn_compressonator.lib in <build dir>/out, where tools/cook/compressonator.odin looks for it.
#
# vendor/compressonator is a sparse checkout that holds only what this project builds (see install-compressonator in
# the justfile), so this does not use Compressonator's own CMake project, which needs the whole repository.
cmake_minimum_required(VERSION 3.24)
project(cinnabar_compressonator LANGUAGES CXX)

# Odin links the static CRT, so the library must use it too.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
set(CMAKE_CXX_STANDARD 17)

set(out "${CMAKE_BINARY_DIR}/out")
foreach(kind ARCHIVE LIBRARY RUNTIME)
    set(CMAKE_${kind}_OUTPUT_DIRECTORY "${out}")
    set(CMAKE_${kind}_OUTPUT_DIRECTORY_RELEASE "${out}")
endforeach()

set(cmp "${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor/compressonator")
set(core "${cmp}/cmp_core")

add_library(cn_compressonator STATIC
    cn_compress.cpp
    "${core}/source/cmp_core.cpp"
    "${core}/source/core_simd_sse.cpp"
    "${core}/source/core_simd_avx.cpp"
    "${core}/source/core_simd_avx512.cpp"
    "${core}/shaders/bc1_encode_kernel.cpp"
    "${core}/shaders/bc2_encode_kernel.cpp"
    "${core}/shaders/bc3_encode_kernel.cpp"
    "${core}/shaders/bc4_encode_kernel.cpp"
    "${core}/shaders/bc5_encode_kernel.cpp"
    "${core}/shaders/bc6_encode_kernel.cpp"
    "${core}/shaders/bc7_encode_kernel.cpp"
    "${cmp}/applications/_libs/cmp_math/cpu_extensions.cpp"
    "${cmp}/applications/_libs/cmp_math/cmp_math_common.cpp"
)
target_include_directories(cn_compressonator PRIVATE "${core}/shaders" "${core}/source" "${cmp}/applications/_libs/cmp_math")
# The SIMD paths are chosen at run time from the CPU's extensions, so each is compiled for its own instruction set.
set_source_files_properties("${core}/source/core_simd_avx.cpp" PROPERTIES COMPILE_OPTIONS "/arch:AVX2")
set_source_files_properties("${core}/source/core_simd_avx512.cpp" PROPERTIES COMPILE_OPTIONS "/arch:AVX512")
# Compressonator's sources are not ours to clean up.
target_compile_options(cn_compressonator PRIVATE /W0)
