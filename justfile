set dotenv-load
set windows-shell := ["C:/Program Files/Git/bin/bash.exe", "-c"]

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
packages := "lib/core lib/core/layout lib/core/gpu lib/core/gpu/null lib/core/gpu/" + gpu_backend + " lib/engine lib/engine/render src/host samples/" + game + " samples/" + game + "/main_release"

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
install-agility:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f "{{agility_dir}}/D3D12Core.dll" ] && exit 0
    mkdir -p "{{agility_dir}}"
    curl -sSfL -o "{{agility_dir}}/d3d12.nupkg" "https://www.nuget.org/api/v2/package/Microsoft.Direct3D.D3D12/{{agility_version}}"
    unzip -qjo "{{agility_dir}}/d3d12.nupkg" build/native/bin/x64/D3D12Core.dll build/native/bin/x64/d3d12SDKLayers.dll -d "{{agility_dir}}"
    rm "{{agility_dir}}/d3d12.nupkg"
    echo "✓ Agility SDK {{agility_version}}"

# Download the DirectX Shader Compiler
install-dxc:
    #!/usr/bin/env bash
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
update-luau tag="":
    #!/usr/bin/env bash
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

# Build the host and the game DLL
build: host game-dll

# Build the development host
host: agility-runtime
    mkdir -p "{{build_dir}}"
    odin build src/host {{collections}} -out:"{{build_dir}}/host.exe" -debug

# Compile the game's shaders. Each <name>.hlsl compiles its vs_main, ps_main and cs_main entry points to <name>.<stage>.dxil.
shaders: install-dxc
    #!/usr/bin/env bash
    set -euo pipefail
    for src in samples/{{game}}/shaders/*.hlsl; do
        for stage in vs ps cs; do
            grep -q "\b${stage}_main\b" "$src" || continue
            "{{dxc}}" -nologo -HV 2021 -T "${stage}_6_6" -E "${stage}_main" -I lib/core/gpu/shaders -Zi -Qembed_debug \
                -Fo "${src%.hlsl}.${stage}.dxil" "$src"
        done
    done

# Build the game DLL. A running host picks it up and hot-reloads it.
game-dll: shaders
    mkdir -p "{{build_dir}}/pdb"
    odin build "samples/{{game}}" {{collections}} -build-mode:dll \
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

# Build the statically linked release executable
release: agility-runtime shaders
    mkdir -p "{{build_dir}}"
    odin build "samples/{{game}}/main_release" {{collections}} -out:"{{build_dir}}/{{game}}.exe" -o:speed

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

test:
    for p in lib/core/layout lib/core/gpu lib/core/gpu/null lib/engine/render; do odin test "$p" {{collections}} || exit 1; done

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

add-tag:
    #!/usr/bin/env bash
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
