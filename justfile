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
# The cooker compiles shaders with this DXC release.
dxc_version := "1.9.2609"
dxc_release := "dxc_2026_09_29"
dxc := "vendor/dxc/" + dxc_version + "/dxc.exe"
# The AMD FSR SDK, whose FidelityFX API runs FSR (see docs/gpu/upscalers.md#fsr). Its version must match
# FFX_SDK_VERSION in lib/core/gpu/d3d12/ffx.odin.
fidelityfx_version := "2.3.0"
fidelityfx_dir := "vendor/fidelityfx/" + fidelityfx_version
collections := "-collection:cinnabar=lib -collection:gpu_backend=lib/core/gpu/" + gpu_backend
# Luau's experimental direct field access for engine userdata (see docs/scripting/embedding.md#direct-field-access). Off unless
# CINNABAR_DIRECT_ACCESS=true.
direct_access := env("CINNABAR_DIRECT_ACCESS", "false")
luau_features := "-define:LUAU_DIRECT_ACCESS=" + direct_access
# The development host and game DLL share luau.dll (see docs/scripting/embedding.md#embedding). Everything else links Luau statically.
dev_defines := "-define:LUAU_SHARED=true " + luau_features
# lib/core/luau/luau.odin links the Luau libraries from build/luau, so build_dir must stay "build".
luau_dir := build_dir + "/luau"
cmake_generator := "Visual Studio 17 2022"
compressonator_dir := build_dir + "/compressonator"
meshoptimizer_dir := build_dir + "/meshoptimizer"
clusterlod_dir := build_dir + "/clusterlod"
# What tools/cook/compressonator builds from vendor/compressonator, which is checked out sparsely.
compressonator_paths := "cmp_core license applications/_libs/cmp_math"
# The cooker puts this in every script's cache key, so a Luau update cooks every script again.
luau_version := `git -C vendor/luau describe --tags --always`
# The cooker puts this in every texture's cache key, so a Compressonator update cooks every texture again.
compressonator_version := `git -C vendor/compressonator describe --tags --always 2>/dev/null || echo unknown`
# The cooker puts this in every mesh's cache key, so a meshoptimizer update cooks every mesh again.
meshoptimizer_version := `git -C vendor/meshoptimizer describe --tags --always 2>/dev/null || echo unknown`
content_root := "samples/" + game + "/content"
# Every cook takes the game's content root and the engine's, so one scan gives every asset its .meta file.
roots := "--root game=" + content_root + " --root engine=lib/engine/content"
# What the cooker compiles shaders and materials with: DXC, the directory of the fixed header, cinnabar.hlsli, and the
# engine's material templates and SMAA's reference shader (vendor/smaa).
shader_tools := "--dxc " + dxc + " --include lib/core/gpu/shaders --include lib/engine/content/shaders --include vendor/smaa"
cache_dir := build_dir + "/cache"
# The scripts' Luau definition file, which the cooker type checks against and luau-lsp reads.
script_types := build_dir + "/script-types/cinnabar.d.luau"
packages := "lib/core lib/core/layout lib/core/profile lib/core/jobs lib/core/gpu lib/core/gpu/null lib/core/gpu/" + gpu_backend + " lib/core/luau lib/core/script lib/engine lib/engine/asset lib/engine/asset/format lib/engine/asset/cook_link lib/engine/wire lib/engine/render lib/engine/debug lib/engine/ecs lib/engine/script lib/engine/scene lib/engine/volume lib/engine/project lib/engine/editor lib/engine/editor/link src/host tools/viewer tools/cook tools/ltc_fit samples/" + game + " samples/" + game + "/main_release"

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
install: install-agility install-dxc install-fidelityfx install-compressonator
    git submodule update --init --recursive

# Fetch Compressonator's block compression core at the commit that the repository pins. The repository is over 700 MB,
# so this is a blobless clone that checks out only what tools/cook/compressonator builds. .gitmodules marks the
# submodule `update = none`, so `git submodule update` never checks out the rest.
[script]
install-compressonator:
    set -euo pipefail
    dir=vendor/compressonator
    commit=$(git ls-files --stage "$dir" | awk '{print $2}')
    if [ ! -e "$dir/.git" ]; then
        rmdir "$dir" 2>/dev/null || true
        git clone --quiet --filter=blob:none --no-checkout --sparse "$(git config -f .gitmodules submodule.$dir.url)" "$dir"
        git submodule absorbgitdirs "$dir"
        git -C "$dir" sparse-checkout set --cone {{compressonator_paths}}
        # The clone has an empty index, which an ordinary checkout would keep as the deletion of every file.
        git -C "$dir" fetch --quiet --filter=blob:none origin "$commit"
        git -C "$dir" -c advice.detachedHead=false checkout --quiet --force --detach "$commit"
    fi
    git -C "$dir" sparse-checkout set --cone {{compressonator_paths}}
    if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" != "$commit" ]; then
        git -C "$dir" fetch --quiet --filter=blob:none origin "$commit"
        git -C "$dir" -c advice.detachedHead=false checkout --quiet "$commit"
    fi
    echo "✓ Compressonator $(git -C "$dir" describe --tags --always)"

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

# Download the FidelityFX API's loader and FSR's library, both MIT-licensed (see vendor/fidelityfx/README.md)
[script]
install-fidelityfx:
    set -euo pipefail
    [ -f "{{fidelityfx_dir}}/amd_fidelityfx_upscaler_dx12.dll" ] && exit 0
    mkdir -p "{{fidelityfx_dir}}"
    base="https://raw.githubusercontent.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/v{{fidelityfx_version}}/Kits/FidelityFX/signedbin"
    for dll in amd_fidelityfx_loader_dx12.dll amd_fidelityfx_upscaler_dx12.dll; do
        curl -sSfL -o "{{fidelityfx_dir}}/$dll.part" "$base/$dll"
        mv "{{fidelityfx_dir}}/$dll.part" "{{fidelityfx_dir}}/$dll"
    done
    echo "✓ FidelityFX {{fidelityfx_version}}"

# Setup project for first time
setup: install
    echo "✓ Project ready"

# Update all vendored submodules
update: update-luau update-compressonator update-meshoptimizer

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

# Update meshoptimizer to a release tag (default: latest)
[script]
update-meshoptimizer tag="":
    set -euo pipefail
    git -C vendor/meshoptimizer fetch --tags --quiet
    tag="{{tag}}"
    [ -z "$tag" ] && tag=$(git -C vendor/meshoptimizer tag --list 'v*' --sort=-v:refname | head -n 1)
    git -C vendor/meshoptimizer -c advice.detachedHead=false checkout --quiet "$tag"
    git add vendor/meshoptimizer
    echo "✓ meshoptimizer at $tag"

# Update Compressonator to a release tag (default: latest)
[script]
update-compressonator tag="": install-compressonator
    set -euo pipefail
    git -C vendor/compressonator fetch --tags --quiet --filter=blob:none
    tag="{{tag}}"
    [ -z "$tag" ] && tag=$(git -C vendor/compressonator tag --list 'V*' --sort=-v:refname | head -n 1)
    git -C vendor/compressonator -c advice.detachedHead=false checkout --quiet "$tag"
    git add vendor/compressonator
    echo "✓ Compressonator at $tag"

# =================================
# Development
# =================================

alias b := build

# Build the host and the game DLL, and cook the game's scripts and scenes
build: host game-dll script-types scripts scenes shaders textures models materials

# Build the development host
host: agility-runtime fidelityfx-runtime luau
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
        targets=$([ "$kind" = shared ] && echo luau || echo "luau_shim luau_tools")
        cmake --build "$dir" --config Release --target $targets -- -m -nologo -v:quiet
    done
    # A running host keeps luau.dll locked. Luau is host code, so a changed luau.dll needs a host restart anyway.
    cmp -s "{{luau_dir}}/shared/out/luau.dll" "{{build_dir}}/luau.dll" || cp "{{luau_dir}}/shared/out/luau.dll" "{{build_dir}}/"

# Build Compressonator's block compression core for the cooker
compressonator: install-compressonator
    [ -f "{{compressonator_dir}}/CMakeCache.txt" ] || cmake -S tools/cook/compressonator -B "{{compressonator_dir}}" -G "{{cmake_generator}}" -A x64 > /dev/null
    cmake --build "{{compressonator_dir}}" --config Release -- -m -nologo -v:quiet

# Build meshoptimizer and its cluster LOD builder for the cooker, with the static CRT that Odin links
meshoptimizer:
    [ -f "{{meshoptimizer_dir}}/CMakeCache.txt" ] || cmake -S vendor/meshoptimizer -B "{{meshoptimizer_dir}}" -G "{{cmake_generator}}" -A x64 -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DMESHOPT_INSTALL=OFF > /dev/null
    cmake --build "{{meshoptimizer_dir}}" --config Release -- -m -nologo -v:quiet
    [ -f "{{clusterlod_dir}}/CMakeCache.txt" ] || cmake -S tools/cook/clusterlod -B "{{clusterlod_dir}}" -G "{{cmake_generator}}" -A x64 > /dev/null
    cmake --build "{{clusterlod_dir}}" --config Release -- -m -nologo -v:quiet

# Build the cooker
cook: luau compressonator meshoptimizer
    mkdir -p "{{build_dir}}"
    odin build tools/cook -collection:cinnabar=lib -define:LUAU_VERSION="{{luau_version}}" -define:COMPRESSONATOR_VERSION="{{compressonator_version}}" -define:MESHOPTIMIZER_VERSION="{{meshoptimizer_version}}" -out:"{{build_dir}}/cook.exe" -o:speed

# Cook the game's scripts into the loose cache, build/cache/<config>. A script without a .meta file gets one: commit it.
scripts config="dev": cook
    "./{{build_dir}}/cook.exe" scripts --cache "{{cache_dir}}" --config {{config}} --definitions "{{script_types}}" {{roots}}

# Cook the game's scenes into the loose cache, build/cache/<config>. A scene without a .meta file gets one: commit it.
scenes config="dev": cook
    "./{{build_dir}}/cook.exe" scenes --cache "{{cache_dir}}" --config {{config}} {{roots}}

# Run the cook daemon, which cooks the game's and the engine's content into build/cache/dev whenever they change, until it is
# stopped. A running game swaps the new blobs (see docs/content/daemon-and-operations.md#cook-daemon).
watch: cook install-dxc
    "./{{build_dir}}/cook.exe" daemon --cache "{{cache_dir}}" --definitions "{{script_types}}" {{shader_tools}} {{roots}}

# Write the scripts' type definitions from the game's bindings
script-types: host game-dll
    "./{{build_dir}}/host.exe" "{{build_dir}}/{{game}}.dll" --emit-script-types "{{script_types}}"

# Cook the game's textures and the engine's into the loose cache, build/cache/<config>. A texture without a .meta file
# gets one, with its usage guessed from its name: commit it.
textures config="dev": cook
    "./{{build_dir}}/cook.exe" textures --cache "{{cache_dir}}" --config {{config}} {{roots}}

# Cook the shading models, materials and material instances of the game and the engine into the loose cache,
# build/cache/<config>: each material compiles a variant for each set of static switches that it or an instance uses.
materials config="dev": install-dxc cook
    "./{{build_dir}}/cook.exe" materials --cache "{{cache_dir}}" --config {{config}} {{shader_tools}} {{roots}}

# Cook the game's models and the engine's into the loose cache, build/cache/<config>: each glTF mesh becomes a mesh with
# its own GUID in its model's .meta file. A model without a .meta file gets one: commit it, with the GUIDs it gains.
models config="dev": cook
    "./{{build_dir}}/cook.exe" models --cache "{{cache_dir}}" --config {{config}} {{roots}}

# Cook the game's shaders and the engine's into the loose cache, build/cache/<config>: each <name>.hlsl becomes one blob
# with an entry for each stage. A shader without a .meta file gets one: commit it.
shaders config="dev": install-dxc cook
    "./{{build_dir}}/cook.exe" shaders --cache "{{cache_dir}}" --config {{config}} {{shader_tools}} {{roots}}

# Build the game DLL. A running host picks it up and hot-reloads it.
game-dll: luau
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

# Copy FSR's libraries next to the executables, where the D3D12 backend loads them, with their license. A running host
# keeps them loaded, so only changed ones are copied.
[private]
fidelityfx-runtime: install-fidelityfx
    mkdir -p "{{build_dir}}"
    for dll in amd_fidelityfx_loader_dx12.dll amd_fidelityfx_upscaler_dx12.dll; do cmp -s "{{fidelityfx_dir}}/$dll" "{{build_dir}}/$dll" || cp "{{fidelityfx_dir}}/$dll" "{{build_dir}}/"; done
    cp vendor/fidelityfx/LICENSE.txt "{{build_dir}}/amd_fidelityfx_LICENSE.txt"

# Build and run the game in the development host
dev: build
    "./{{build_dir}}/host.exe" "{{build_dir}}/{{game}}.dll"

# Build the viewer, which shows a host's shared frames in place of the editor's viewport
viewer:
    mkdir -p "{{build_dir}}"
    odin build tools/viewer {{collections}} -out:"{{build_dir}}/viewer.exe" -debug

# Fit the area lights' lookup tables to the Lit shading model's specular, into lib/engine/render/ltc_ggx.bin (see
# docs/rendering/lighting-and-shadows.md#area-lights). Run it after changing Lit's specular, and commit the table.
ltc-fit:
    mkdir -p "{{build_dir}}"
    odin run tools/ltc_fit -o:speed -out:"{{build_dir}}/ltc_fit.exe" -- lib/engine/render/ltc_ggx.bin

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

# Write the editor link's and the cook link's schemas, which the editor's source generator reads (see
# docs/editor/link.md#editor-link)
link-schema: host cook
    "./{{build_dir}}/host.exe" --emit-link-schema "{{build_dir}}/link/link-schema.json"
    "./{{build_dir}}/cook.exe" --emit-link-schema "{{build_dir}}/link/cook-schema.json"

# Build the editor (see docs/editor/processes-and-projects.md#projects)
editor: link-schema
    dotnet build src/editor -nologo -v:quiet

# Build everything and run the game in the editor
edit: build editor
    "./{{build_dir}}/dotnet/bin/Cinnabar.Editor/debug/editor.exe" --host "{{build_dir}}/host.exe" --game "{{build_dir}}/{{game}}.dll" --scene "{{content_root}}/scenes/main.scene" \
        --cook "{{build_dir}}/cook.exe" --cache "{{cache_dir}}" --definitions "{{script_types}}" {{shader_tools}} {{roots}} \
        --project "samples/{{game}}/project.settings"

# Build the statically linked release executable
release: agility-runtime fidelityfx-runtime luau script-types (scripts "release") (scenes "release") (shaders "release") (textures "release") (models "release") (materials "release")
    mkdir -p "{{build_dir}}"
    odin build "samples/{{game}}/main_release" {{collections}} {{luau_features}} -define:CINNABAR_CONTENT_CACHE="{{cache_dir}}/release" -define:DEBUG_DRAW=false -define:PROFILE=false -out:"{{build_dir}}/{{game}}.exe" -o:speed

# Build and run the release executable
run-release: release
    "./{{build_dir}}/{{game}}.exe"

# =================================
# Code Quality
# =================================

check:
    for p in {{packages}}; do odin check "$p" {{collections}} -no-entry-point || exit 1; done

vet:
    for p in {{packages}}; do odin check "$p" {{collections}} -no-entry-point -vet -vet-tabs -vet-style -vet-semicolon || exit 1; done

lint:
    for p in {{packages}}; do odin check "$p" {{collections}} -no-entry-point -vet -vet-tabs -vet-style -strict-style -warnings-as-errors || exit 1; done

# Check that every docs/<path>.md#<section> link in the source, the justfile and the docs resolves to a heading
docs-check:
    python -I tools/check_docs.py .

fmt:
    odinfmt lib src samples -w

# =================================
# Testing
# =================================

# The cooker's tests compile shaders, so they need DXC.
test: luau compressonator meshoptimizer link-schema install-dxc
    for p in lib/core lib/core/layout lib/core/profile lib/core/jobs lib/core/gpu lib/core/gpu/null lib/core/script lib/engine/asset lib/engine/asset/format lib/engine/asset/cook_link lib/engine/wire lib/engine/render lib/engine/debug lib/engine/ecs lib/engine/script lib/engine/scene lib/engine/volume lib/engine/project lib/engine/editor lib/engine/editor/link tools/cook tools/ltc_fit; do odin test "$p" {{collections}} -define:LUAU_VERSION="{{luau_version}}" -define:COMPRESSONATOR_VERSION="{{compressonator_version}}" -define:MESHOPTIMIZER_VERSION="{{meshoptimizer_version}}" || exit 1; done
    # The optional direct field access path must behave the same (see docs/scripting/embedding.md#direct-field-access).
    odin test lib/engine/script {{collections}} -define:LUAU_DIRECT_ACCESS=true
    # Release builds have no profiler, and everything must still run (see docs/core/profiling.md#builds).
    for p in lib/core/profile lib/core/jobs; do odin test "$p" {{collections}} -define:PROFILE=false || exit 1; done
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
