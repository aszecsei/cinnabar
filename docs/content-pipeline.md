# Content pipeline

`tools/cook` compiles source assets into blobs. Development builds read blobs from a loose cache, and release builds read them from bundles. See [Architecture](architecture.md#content-pipeline) for the overview.

## Identity

Every source asset has a GUID, stored in a `.meta` sidecar file next to it with its import settings. The cooker assigns a GUID the first time it sees an asset. Renames and moves keep the GUID as long as the `.meta` file moves too, and the editor makes sure it does. Content refers to other content only by GUID.

## Cooking

- **Shared schemas:** `tools/cook` imports the same asset-type package from `lib/engine` that the runtime uses, so their struct layouts cannot diverge. Each asset type's version comes from its layout hash, so changing a type invalidates its cache entries.
- **Incremental cooking:** a cache key is a hash of the source files, the import settings and the cooker version.
- **Shaders** are HLSL. `tools/cook` compiles them with DXC to DXIL for D3D12. DXC can also produce SPIR-V for a future Vulkan backend. The cooker stores each shader's reflected binding layout with its bytecode, so the runtime never compiles or reflects shaders. The DXC version is part of the cache key.

## Blob format

Compiled blobs use offsets instead of pointers. The runtime can map a blob and use it without parsing. Blobs are aligned for direct GPU upload and compressed individually.

## Loading

- **Two sources, one format:** the asset runtime reads through an `Asset_Source` interface with two backends. `Loose_Cache` is used in development and `Bundle` is used in release. Both read the same blob format.
- **Bundles** (`*.cbb`) contain a header, a table of contents sorted by GUID, and aligned blobs. A bundle is a load unit (global, per-level, or a streaming chunk), and it lists the bundles it depends on.
- **Asset hot reload:** in development, the cook daemon watches `source/` and tells the running game when a blob changes. The asset runtime swaps the data behind the asset's generational handle.
