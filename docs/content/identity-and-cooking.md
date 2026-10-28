# Identity and cooking

GUIDs and `.meta` files, and what every cook has in common: shared schemas, cache keys, the single scan, the generation counter, the lock and problems. Each asset kind's own cook is in [kinds](README.md#documents).

**In this document:** [Identity](#identity) · [Cooking](#cooking) · [Future work](README.md#future-work)

## Identity

Every source asset has a GUID, stored in a `.meta` sidecar file next to it with its import settings. The cooker assigns a GUID the first time it sees an asset. Renames and moves keep the GUID as long as the `.meta` file moves too, and the editor makes sure it does. Content refers to other content only by GUID.

- A GUID is 128 random bits, written as 32 hex digits. Engine content (such as the script prelude) has fixed GUIDs in committed `.meta` files.
- A `.meta` file has lines of `key = value`, and `#` comments. `guid` is required. The other keys are import settings. When the cooker finds an asset without a `.meta` file, it writes one. Commit it with the asset.
- **Sub-assets:** one source file can make several assets, such as the meshes of a glTF file. Each sub-asset has its own GUID and its own blob, and loads like any other asset. Its GUID is in its file's `.meta` file, on a line `<kind>.<name> = <guid>`, such as `mesh.Door_Frame = 3f9c...`. The cooker writes the line when it first makes the sub-asset, and finds it again by kind and name, so a re-import keeps every reference. The file itself is the parent, and has a GUID of its own but no blob when it makes only sub-assets.
- **A renamed sub-asset** (a mesh renamed in the modelling tool) gets a new GUID, with a warning that names the old one. The old line stays in the `.meta` file, as a warning, until the asset is re-imported, so a rename back in the modelling tool restores it.
- Two assets with the same GUID, of any kinds, are a cook error, and neither cooks. This happens when an asset is copied with its `.meta` file. Delete the copy's `.meta` file to give it a new GUID.
- Each game has one content root, `samples/<game>/content/`. Engine content is in `lib/engine/content/`. The cooker takes each root with a name, such as `--root game=samples/mygame/content`, and an asset's source path is the root's name and its path in the root, such as `game/scripts/hello.luau`.
- At runtime, a loaded asset is a generational handle in the asset runtime's table. Persistent state holds handles or GUIDs, never pointers into blobs (see [Hot reload](../overview/hot-reload.md#rules)).

## Cooking

- **Shared schemas:** `tools/cook` imports the same asset-type package from `lib/engine` that the runtime uses, `lib/engine/asset/format`, so their struct layouts cannot diverge. That package imports nothing from `lib/core`. Each asset type's version comes from its layout hash, so changing a type invalidates its cache entries.
- **Incremental cooking:** a cache key is a hash of the source files, the import settings and the cooker version.
- **One scan:** every command that cooks scripts or scenes scans the roots once for every kind of asset, and gives each new asset its `.meta` file, whatever kind it cooks. Then it cooks each asset of its kinds whose key changed.
- **The cache's generation:** after a cook writes blobs, it adds one to the counter in `<cache>/<config>/.generation` (see [Loading](blobs-and-loading.md#loading)).
- **One cook at a time:** a cook holds `<cache>/.cook.lock` while it runs. Otherwise two cooks could both give a new asset a `.meta` file, each with its own GUID. Windows deletes the lock when the cook exits, also when it crashes. A dev batch cook that finds the lock held leaves the cache to the cook daemon, which keeps it up to date, so `just build` works while the editor is open. Any other cook stops with an error.
- **Problems:** each error and warning names its file (the asset's source or `.meta` file, or another file such as the definition file), and its line and column when it has them. A batch cook logs each one as `cook: <file>:<line>:<column>: <text>`.
- **Kinds:** scripts, scenes, shaders, textures, models, mesh files and materials. Each kind has an importer: its extensions, its import settings and its cook (see the sections below).
- **Slow kinds use every core.** A texture can take seconds, so block compression spreads each mip's rows of blocks over the CPU's threads. A 2048×2048 color texture with its mips cooks in about 1 s for development and 3 s for release. *Cooking several textures at once, and a pass that reports the assets that it has left so the editor can show progress, come when content grows.*
- **Third-party code** for the importers is in `vendor/`, built with CMake into `build/` like Luau, and linked into `tools/cook` only: Compressonator's `CMP_Core` for block compression, and meshoptimizer for meshes. Odin's `vendor:stb/image` and `vendor:cgltf` read the source files. The runtime links none of them.
- **Compressonator** is a submodule pinned to a release, but its repository is over 700 MB, so `vendor/compressonator` is a blobless clone that checks out only `cmp_core`, `license` and `applications/_libs/cmp_math`. `.gitmodules` marks it `update = none`, so `git submodule update` never checks out the rest, and `just install-compressonator` makes the sparse clone at the pinned commit. `just update-compressonator <tag>` moves the pin. `tools/cook/compressonator` builds `CMP_Core` with its own CMake project, and `cn_compress.cpp` gives the cooker a C API that compresses a whole mip, because `CMP_Core`'s API is C++ and compresses one block at a time.

The kinds below are in the order a game meets them: scripts and scenes are what gameplay is made of, and shaders, textures, meshes and materials are what the renderer draws.

## Future work

- **Parallel DXC.** The cooker runs child processes one at a time, because Windows children inherit every inheritable handle and one DXC can hold another's pipes. The fix is `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` in the startup attributes, which names the handles a child may inherit. Do this when shader and material cooks dominate a pass; a material with many variants already waits on it.
- **Cooking several textures at once, and progress.** Block compression uses every core for one texture, but textures cook one after another, and the editor sees only the finished pass. A pass that reports the assets it has left lets the content browser show progress. Do this when content grows past a few hundred textures.
- **`.exr` textures** with `vendor:OpenEXRCore`, for HDR sources with more than `.hdr`'s RGBE precision. Do this with environment lighting.
- **Cube maps and texture arrays**, which environment lighting needs for sky and reflection captures (see [Rendering](../rendering/lighting-and-shadows.md#future-work)). The blob gains a layer count; the GPU side already has the formats.
- **Alpha-coverage-preserving mips.** A masked texture's coverage shrinks down the mip chain, so cut-outs thin out in the distance. Scaling each mip's alpha so that its coverage at the cutoff matches mip 0's keeps them, as NVIDIA Texture Tools does. Do this when masked materials show it.
- **glTF as a scene.** A model also makes a prefab of its node hierarchy that places its meshes, and its textures and materials become sub-assets (texture assets and material instances). This waits for prefabs (see [Editor](../editor/README.md#future-work)).
- **Skins and animations.** Not imported. They wait for the animation system (see [World](../world/README.md#future-work)); the mesh blob would gain joint indices and weights as a third stream, so the depth passes still read positions only.
