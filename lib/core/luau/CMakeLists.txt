# Builds vendor/luau for cinnabar. See docs/scripting.md#embedding.
#
# The justfile configures this project twice:
# - CINNABAR_LUAU_SHARED=ON builds luau.dll, which the development host and the game DLL share.
# - CINNABAR_LUAU_SHARED=OFF builds static libraries for release executables, tests and tools/cook, and luau_tools,
#   the helpers that only tools/cook uses.
#
# Both put their outputs in <build dir>/out, where lib/core/luau/luau.odin looks for them.
cmake_minimum_required(VERSION 3.24)
project(cinnabar_luau LANGUAGES CXX)

option(CINNABAR_LUAU_SHARED "Build luau.dll instead of static libraries" OFF)

set(LUAU_BUILD_CLI OFF CACHE BOOL "" FORCE)
set(LUAU_BUILD_TESTS OFF CACHE BOOL "" FORCE)
# Odin links the static CRT, so the static libraries must use it too. luau.dll uses it so that it needs no runtime DLLs.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

set(out "${CMAKE_BINARY_DIR}/out")
foreach(kind ARCHIVE LIBRARY RUNTIME)
    set(CMAKE_${kind}_OUTPUT_DIRECTORY "${out}")
    set(CMAKE_${kind}_OUTPUT_DIRECTORY_RELEASE "${out}")
endforeach()

add_subdirectory(../../../vendor/luau luau EXCLUDE_FROM_ALL)

# The C API with longjmp errors, as the Odin bindings expect (see docs/scripting.md#embedding).
if(CINNABAR_LUAU_SHARED)
    set(export "__declspec(dllexport)")
else()
    set(export "")
endif()
target_compile_definitions(Luau.VM PUBLIC "LUA_API=extern \"C\" ${export}" LUA_USE_LONGJMP=1)
target_compile_definitions(Luau.Compiler PUBLIC "LUACODE_API=extern \"C\" ${export}")
target_compile_definitions(Luau.CodeGen PUBLIC "LUACODEGEN_API=extern \"C\" ${export}")

if(CINNABAR_LUAU_SHARED)
    add_library(luau SHARED luau_shim.cpp)
    target_compile_definitions(luau PRIVATE "CN_LUAU_API=extern \"C\" ${export}")
    target_link_libraries(luau PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,Luau.VM,Luau.CodeGen,Luau.Compiler>")
else()
    add_library(luau_shim STATIC luau_shim.cpp)
    target_compile_definitions(luau_shim PRIVATE "CN_LUAU_API=extern \"C\"")
    add_dependencies(luau_shim Luau.VM Luau.CodeGen Luau.Compiler Luau.Ast Luau.Bytecode Luau.Common)

    # Helpers for tools/cook over Luau's C++ libraries.
    add_library(luau_tools STATIC luau_tools.cpp)
    target_compile_definitions(luau_tools PRIVATE "CN_LUAU_API=extern \"C\"")
    target_link_libraries(luau_tools PRIVATE Luau.Ast Luau.Analysis)
endif()
