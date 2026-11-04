# Builds libogg, libvorbis's encoder and a small interface to them for tools/cook (see docs/content/kinds/audio.md#audio).
# `just vorbis` configures it, and puts cn_vorbis.lib in <build dir>/out, where tools/cook/audio_encode.odin looks for it.
# The runtime decodes with Odin's vendor:stb/vorbis, and links none of this.
cmake_minimum_required(VERSION 3.24)
project(cinnabar_vorbis LANGUAGES C)

# Odin links the static CRT, so the library must use it too.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

set(out "${CMAKE_BINARY_DIR}/out")
foreach(kind ARCHIVE LIBRARY RUNTIME)
    set(CMAKE_${kind}_OUTPUT_DIRECTORY "${out}")
    set(CMAKE_${kind}_OUTPUT_DIRECTORY_RELEASE "${out}")
endforeach()

set(vendor "${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor")
set(ogg "${vendor}/ogg")
set(vorbis "${vendor}/vorbis")

set(vorbis_sources analysis bitrate block codebook envelope floor0 floor1 info lookup lpc lsp mapping0 mdct psy registry res0 sharedbook smallft synthesis vorbisenc window)
list(TRANSFORM vorbis_sources PREPEND "${vorbis}/lib/")
list(TRANSFORM vorbis_sources APPEND ".c")

add_library(cn_vorbis STATIC cn_vorbis.c "${ogg}/src/bitwise.c" "${ogg}/src/framing.c" ${vorbis_sources})
target_include_directories(cn_vorbis PRIVATE "${ogg}/include" "${vorbis}/include" "${vorbis}/lib")
# Their sources are not ours to clean up.
target_compile_options(cn_vorbis PRIVATE /W0)
target_compile_definitions(cn_vorbis PRIVATE _USE_MATH_DEFINES)
