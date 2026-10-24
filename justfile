set dotenv-load
set windows-shell := ["C:/Program Files/Git/bin/bash.exe", "-c"]
# Multi-line recipes are [script] recipes, which run through this interpreter. A shebang would need cygpath, which only
# Git Bash has on its PATH, so the recipes would fail from other shells.
set script-interpreter := ["C:/Program Files/Git/bin/bash.exe"]

# =================================
# Configuration
# =================================
game := "mygame"
build_dir := "build"
gpu_backend := "d3d12"
# The D3D12 Agility SDK. Its minor version must match AGILITY_SDK_VERSION in lib/core/gpu/d3d12.
agility_version := "1.619.6"
agility_dir := "vendor/agility/" + agility_version
# DXC compiles shaders until tools/cook exists.
dxc_version := "1.9.2609"
dxc_release := "dxc_2026_09_29"
dxc := "vendor/dxc/" + dxc_version + "/dxc.exe"
collections := "-collection:cinnabar=lib -collection:gpu_backend=lib/core/gpu/" + gpu_backend
# Luau's experimental direct field access for engine userdata (see docs/scripting.md#direct-field-access). Off unless
# CINNABAR_DIRECT_ACCESS=true.
direct_access := env("CINNABAR_DIRECT_ACCESS", "false")
luau_features := "-define:LUAU_DIRECT_ACCESS=" + direct_access
# The development host and game DLL share luau.dll (see docs/scripting.md#embedding). Everything else links Luau statically.
dev_defines := "-define:LUAU_SHARED=true " + luau_features
# lib/core/luau/luau.odin links the Luau libraries from build/luau, so build_dir must stay "build".
luau_dir := build_dir + "/luau"
cmake_generator := "Visual Studio 17 2022"
# The cooker puts this in every script's cache key, so a Luau update cooks every script again.
luau_version := `git -C vendor/luau describe --tags --always`
content_root := "samples/" + game + "/content"
cache_dir := build_dir + "/cache"
# The scripts' Luau definition file, which the cooker type checks against and luau-lsp reads.
script_types := build_dir + "/script-types/cinnabar.d.luau"
packages := "lib/core lib/core/layout lib/core/jobs lib/core/gpu lib/core/gpu/null lib/core/gpu/" + gpu_backend + " lib/core/luau lib/core/script lib/engine lib/engine/asset lib/engine/asset/format lib/engine/render lib/engine/ecs lib/engine/script src/host tools/viewer tools/cook samples/" + game + " samples/" + game + "/main_release"

# =================================
# Help
# =================================
[private]
default:
    @just --list

# =================================
# Setup
# =================================

# Install dependencies
install: install-agility install-dxc
    git submodule update --init --recursive

# Download the D3D12 Agility SDK runtime
[script]
install-agility:
    set -euo pipefail
    [ -f "{{agility_dir}}/D3D12Core.dll" ] && exit 0
    mkdir -p "{{agility_dir}}"
    curl -sSfL -o "{{agility_dir}}/d3d12.nupkg" "https://www.nuget.org/api/v2/package/Microsoft.Direct3D.D3D12/{{agility_version}}"
    unzip -qjo "{{agility_dir}}/d3d12.nupkg" build/native/bin/x64/D3D12Core.dll build/native/bin/x64/d3d12SDKLayers.dll -d "{{agility_dir}}"
    rm "{{agility_dir}}/d3d12.nupkg"
    echo "✓ Agility SDK {{agility_version}}"

# Download the DirectX Shader Compiler
[script]
install-dxc:
    set -euo pipefail
    dir="$(dirname "{{dxc}}")"
    [ -f "{{dxc}}" ] && exit 0
    mkdir -p "$dir"
    curl -sSfL -o "$dir/dxc.zip" "https://github.com/microsoft/DirectXShaderCompiler/releases/download/v{{dxc_version}}/{{dxc_release}}.zip"
    # The archive uses backslash separators, so unzip warns and exits with 1. The check below catches real failures.
    unzip -qjo "$dir/dxc.zip" 'bin?x64?dxc.exe' 'bin?x64?dxcompiler.dll' 'bin?x64?dxil.dll' -d "$dir" 2>/dev/null || true
    rm "$dir/dxc.zip"
    [ -f "{{dxc}}" ] || { echo "error: dxc.exe is missing from the archive" >&2; exit 1; }
    echo "✓ DXC {{dxc_version}}"

# Setup project for first time
setup: install
    echo "✓ Project ready"

# Update all vendored submodules
update: update-luau

# Update Luau to a release tag (default: latest)
[script]
update-luau tag="":
    set -euo pipefail
    git -C vendor/luau fetch --tags --quiet
    tag="{{tag}}"
    [ -z "$tag" ] && tag=$(git -C vendor/luau tag --list '0.*' --sort=-v:refname | head -n 1)
    git -C vendor/luau checkout --quiet "$tag"
    git add vendor/luau
    echo "✓ Luau at $tag"

# =================================
# Development
# =================================

alias b := build

# Build the host and the game DLL, and cook the game's scripts
build: host game-dll script-types scripts

# Build the development host
host: agility-runtime luau
    mkdir -p "{{build_dir}}"
    odin build src/host {{collections}} {{dev_defines}} -out:"{{build_dir}}/host.exe" -debug

# Build Luau: luau.dll for development, and static libraries for release builds, tests and the cooker
[script]
luau:
    set -euo pipefail
    for kind in static shared; do
        dir="{{luau_dir}}/$kind"
        shared=$([ "$kind" = shared ] && echo ON || echo OFF)
        [ -f "$dir/CMakeCache.txt" ] || cmake -S lib/core/luau -B "$dir" -G "{{cmake_generator}}" -A x64 -DCINNABAR_LUAU_SHARED=$shared > /dev/null
        target=$([ "$kind" = shared ] && echo luau || echo luau_shim)
        cmake --build "$dir" --config Release --target "$target" -- -m -nologo -v:quiet
    done
    # A running host keeps luau.dll locked. Luau is host code, so a changed luau.dll needs a host restart anyway.
    cmp -s "{{luau_dir}}/shared/out/luau.dll" "{{build_dir}}/luau.dll" || cp "{{luau_dir}}/shared/out/luau.dll" "{{build_dir}}/"

# Build the cooker
cook: luau
    mkdir -p "{{build_dir}}"
    odin build tools/cook -collection:cinnabar=lib -define:LUAU_VERSION="{{luau_version}}" -out:"{{build_dir}}/cook.exe" -o:speed

# Cook the game's scripts into the loose cache, build/cache/<config>. A script without a .meta file gets one: commit it.
scripts config="dev": cook
    "./{{build_dir}}/cook.exe" scripts --cache "{{cache_dir}}" --config {{config}} --definitions "{{script_types}}" --root game="{{content_root}}"

# Write the scripts' type definitions from the game's bindings
script-types: host game-dll
    "./{{build_dir}}/host.exe" "{{build_dir}}/{{game}}.dll" --emit-script-types "{{script_types}}"

# Cook the game's shaders: each <name>.hlsl becomes <name>.<stage>.dxil, or <name>.lib.dxil for a ray tracing library.
# Only changed shaders recompile (see tools/cook).
shaders: install-dxc cook
    "./{{build_dir}}/cook.exe" shaders --dxc "{{dxc}}" --include lib/core/gpu/shaders "samples/{{game}}/shaders"

# Build the game DLL. A running host picks it up and hot-reloads it.
game-dll: shaders luau
    mkdir -p "{{build_dir}}/pdb"
    odin build "samples/{{game}}" {{collections}} {{dev_defines}} -build-mode:dll \
        -out:"{{build_dir}}/{{game}}.dll" \
        -pdb-name:"{{build_dir}}/pdb/{{game}}_$(date +%s%N).pdb" \
        -debug

# Copy the Agility SDK runtime next to the executables, where D3D12SDKPath points
[private]
agility-runtime: install-agility
    mkdir -p "{{build_dir}}/D3D12"
    cp "{{agility_dir}}/D3D12Core.dll" "{{agility_dir}}/d3d12SDKLayers.dll" "{{build_dir}}/D3D12/"

# Build and run the game in the development host
dev: build
    "./{{build_dir}}/host.exe" "{{build_dir}}/{{game}}.dll"

# Build the viewer, which shows a host's shared frames in place of the editor's viewport
viewer:
    mkdir -p "{{build_dir}}"
    odin build tools/viewer {{collections}} -out:"{{build_dir}}/viewer.exe" -debug

# Run the game in shared mode, as the editor will, and show its frames in the viewer
[script]
dev-shared name="cinnabar": build viewer
    set -euo pipefail
    "./{{build_dir}}/host.exe" "{{build_dir}}/{{game}}.dll" --shared "{{name}}" &
    host=$!
    trap 'kill $host 2>/dev/null || true' EXIT
    # The viewer opens the shared objects, so the host must create them first.
    sleep 2
    "./{{build_dir}}/viewer.exe" "{{name}}"

# Build the editor (see docs/editor.md#projects)
editor:
    dotnet build src/editor -nologo -v:quiet

# Build everything and run the game in the editor
edit: build editor
    "./{{build_dir}}/dotnet/bin/Cinnabar.Editor/debug/editor.exe" --host "{{build_dir}}/host.exe" --game "{{build_dir}}/{{game}}.dll"

# Build the statically linked release executable
release: agility-runtime shaders luau script-types (scripts "release")
    mkdir -p "{{build_dir}}"
    odin build "samples/{{game}}/main_release" {{collections}} {{luau_features}} -define:CINNABAR_CONTENT_CACHE="{{cache_dir}}/release" -out:"{{build_dir}}/{{game}}.exe" -o:speed

# Build and run the release executable
run-release: release
    "./{{build_dir}}/{{game}}.exe"

# =================================
# Code Quality
# =================================

# The game embeds its compiled shaders, so checks need them too.
check: shaders
    for p in {{packages}}; do odin check "$p" {{collections}} -no-entry-point || exit 1; done

vet: shaders
    for p in {{packages}}; do odin check "$p" {{collections}} -no-entry-point -vet -vet-tabs -vet-style -vet-semicolon || exit 1; done

lint: shaders
    for p in {{packages}}; do odin check "$p" {{collections}} -no-entry-point -vet -vet-tabs -vet-style -strict-style -warnings-as-errors || exit 1; done

fmt:
    odinfmt lib src samples -w

# =================================
# Testing
# =================================

test: luau
    for p in lib/core lib/core/layout lib/core/jobs lib/core/gpu lib/core/gpu/null lib/core/script lib/engine/asset lib/engine/asset/format lib/engine/render lib/engine/ecs lib/engine/script tools/cook; do odin test "$p" {{collections}} -define:LUAU_VERSION="{{luau_version}}" || exit 1; done
    # The optional direct field access path must behave the same (see docs/scripting.md#direct-field-access).
    odin test lib/engine/script {{collections}} -define:LUAU_DIRECT_ACCESS=true
    dotnet test src/editor

# =================================
# Cleanup
# =================================

clean:
    rm -rf "{{build_dir}}"

# =================================
# Utilities
# =================================

all: clean fmt lint test build release

info:
    odin version
    odin report
    @echo ""
    @just --list

[script]
add-tag:
    set -euo pipefail
    VERSION=$(<VERSION)
    # if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
    #     echo "error: VERSION must contain a semantic version such as 1.2.3" >&2
    #     exit 1
    # fi # uncomment if you want semantic check for version from file VERSION
    git push origin main
    git tag -a "v${VERSION}" -m "Release v${VERSION}"
    git push origin "v${VERSION}"

# # `just remove-tag v0.0.0` or `just remove-tag` (uses fzf)
# remove-tag:
#     #!/usr/bin/env bash
#     set -euo pipefail
#     tag="{{ VERSION }}"
#     [ -z "$tag" ] && tag=$(git tag | sort -V | fzf --prompt="Select tag to remove: ")
#     [ -z "$tag" ] && echo "No tag selected" && exit 1
#     git tag -d "$tag"
#     git push --delete origin "$tag"
