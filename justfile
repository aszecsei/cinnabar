set dotenv-load
set windows-shell := ["C:/Program Files/Git/bin/bash.exe", "-c"]

# =================================
# Configuration
# =================================
game := "mygame"
build_dir := "build"
collections := "-collection:cinnabar=lib"
packages := "lib/core lib/engine src/host samples/" + game + " samples/" + game + "/main_release"

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
install:
    git submodule update --init --recursive

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
host:
    mkdir -p "{{build_dir}}"
    odin build src/host {{collections}} -out:"{{build_dir}}/host.exe" -debug

# Build the game DLL. A running host picks it up and hot-reloads it.
game-dll:
    mkdir -p "{{build_dir}}/pdb"
    odin build "samples/{{game}}" {{collections}} -build-mode:dll \
        -out:"{{build_dir}}/{{game}}.dll" \
        -pdb-name:"{{build_dir}}/pdb/{{game}}_$(date +%s%N).pdb" \
        -debug

# Build and run the game in the development host
dev: build
    "./{{build_dir}}/host.exe" "{{build_dir}}/{{game}}.dll"

# Build the statically linked release executable
release:
    mkdir -p "{{build_dir}}"
    odin build "samples/{{game}}/main_release" {{collections}} -out:"{{build_dir}}/{{game}}.exe" -o:speed

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

fmt:
    odinfmt lib src samples -w

# =================================
# Testing
# =================================

test:
    for p in lib/core lib/engine; do odin test "$p" {{collections}} || exit 1; done

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
