# Shaders

How shaders are compiled by the cooker with the fixed root signature, and how pipelines follow a shader asset's changes without a code reload.

- Shaders are HLSL. `tools/cook` compiles each shader to DXIL with DXC. A Vulkan port adds SPIR-V from DXC. A Metal port adds a metallib from `metal-shaderconverter`.
- Shaders are assets (see [Content pipeline](../content/kinds/shaders.md#shaders)). The cooker compiles each `.hlsl` file's `vs_main`, `ps_main`, `cs_main`, `as_main` and `ms_main` entry points into one blob, with the DXC release that the justfile pins. A file with `[shader("...")]` attributes is a ray tracing library, and its blob has one library entry.
- The cooker attaches the fixed root signature, `CN_ROOT_SIGNATURE` in `cinnabar.hlsli`, to every shader stage. So DXC rejects a shader that binds anything outside it, and the runtime never compiles or reflects shaders. A library gets its global root signature from the pipeline instead.
- A pipeline passes its root signature to D3D12, which then ignores the embedded one. So debug builds compare each shader's embedded root signature with the backend's, and refuse a pipeline whose shaders differ. That catches `CN_ROOT_SIGNATURE` drifting from the backend.
- Pipeline descriptions stay in game code until the asset runtime can load cooked pipeline assets.
- The game and `lib/engine/editor` load shader assets by GUID and create their pipelines from the blobs' entries. When `asset.poll` swaps a shader's blob, its pipelines update with `update_graphics_pipeline` or `update_compute_pipeline`, so a shader change needs no code reload (see [Rendering](../rendering/assets.md#gpu-residency)).
