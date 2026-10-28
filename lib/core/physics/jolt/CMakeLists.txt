# Builds vendor/jolt and the Jolt backend for cinnabar. See docs/physics/design.md#where-jolt-lives.
#
# The justfile configures this project twice:
# - CINNABAR_JOLT_SHARED=ON builds physics_jolt.dll, which the development host loads, so that Jolt is host code.
# - CINNABAR_JOLT_SHARED=OFF builds physics_jolt.lib and Jolt.lib for release executables and tests.
#
# Both put their outputs in <build dir>/out, where lib/core/physics/jolt/jolt.odin looks for them.
cmake_minimum_required(VERSION 3.24)
project(cinnabar_jolt LANGUAGES CXX)

option(CINNABAR_JOLT_SHARED "Build physics_jolt.dll instead of static libraries" OFF)
# Cross-platform determinism costs about 8% (see docs/physics/design.md#determinism).
option(CINNABAR_JOLT_DETERMINISTIC "Build Jolt with CROSS_PLATFORM_DETERMINISTIC" OFF)

# Odin links the static CRT, so the static libraries must use it too. physics_jolt.dll uses it so that it needs no
# runtime DLLs.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

set(out "${CMAKE_BINARY_DIR}/out")
foreach(kind ARCHIVE LIBRARY RUNTIME)
    set(CMAKE_${kind}_OUTPUT_DIRECTORY "${out}")
    set(CMAKE_${kind}_OUTPUT_DIRECTORY_RELEASE "${out}")
endforeach()

# Jolt's options. Positions are f64 offsets from an anchor (see docs/physics/design.md#positions-and-precision).
set(DOUBLE_PRECISION ON CACHE BOOL "" FORCE)
set(CROSS_PLATFORM_DETERMINISTIC ${CINNABAR_JOLT_DETERMINISTIC} CACHE BOOL "" FORCE)
set(OBJECT_LAYER_BITS 32 CACHE STRING "" FORCE)
set(USE_STATIC_MSVC_RUNTIME_LIBRARY ON CACHE BOOL "" FORCE)
set(JPH_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
# Odin's linker does not take link-time code generation objects.
set(INTERPROCEDURAL_OPTIMIZATION OFF CACHE BOOL "" FORCE)
set(FLOATING_POINT_EXCEPTIONS_ENABLED OFF CACHE BOOL "" FORCE)
set(GENERATE_DEBUG_SYMBOLS OFF CACHE BOOL "" FORCE)
set(ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(ENABLE_OBJECT_STREAM OFF CACHE BOOL "" FORCE)
set(PROFILER_IN_DEBUG_AND_RELEASE OFF CACHE BOOL "" FORCE)
set(DEBUG_RENDERER_IN_DEBUG_AND_RELEASE OFF CACHE BOOL "" FORCE)
# Hair's GPU compute is not used (see docs/physics/design.md#future-work).
foreach(compute JPH_USE_DX12 JPH_USE_VK JPH_USE_MTL JPH_USE_CPU_COMPUTE)
    set(${compute} OFF CACHE BOOL "" FORCE)
endforeach()
foreach(target TARGET_UNIT_TESTS TARGET_HELLO_WORLD TARGET_PERFORMANCE_TEST TARGET_SAMPLES TARGET_VIEWER)
    set(${target} OFF CACHE BOOL "" FORCE)
endforeach()

add_subdirectory(../../../../vendor/jolt/Build jolt EXCLUDE_FROM_ALL)

if(CINNABAR_JOLT_SHARED)
    add_library(physics_jolt SHARED jolt_backend.cpp)
    target_compile_definitions(physics_jolt PRIVATE "CN_PHYSICS_EXPORT=extern \"C\" __declspec(dllexport)")
else()
    add_library(physics_jolt STATIC jolt_backend.cpp)
    target_compile_definitions(physics_jolt PRIVATE "CN_PHYSICS_EXPORT=extern \"C\"")
endif()
target_compile_features(physics_jolt PRIVATE cxx_std_17)
target_compile_options(physics_jolt PRIVATE /GR- /W4)
target_include_directories(physics_jolt PRIVATE ..)
target_link_libraries(physics_jolt PRIVATE Jolt)
