# GPU-driven rendering and mesh shaders

Indirect draws with draw IDs and count buffers, which the renderer's culling writes, and the mesh shader path with its vertex-pulling fallback.

**In this document:** [GPU-driven rendering](#gpu-driven-rendering) · [Mesh shaders](#mesh-shaders)

## GPU-driven rendering

The engine culls and builds draws on the GPU.

- **Indirect commands:** `cmd_draw_indirect`, `cmd_draw_indexed_indirect` and `cmd_dispatch_indirect`. A draw takes an argument buffer, an offset, a maximum draw count and an optional count buffer: the `u32` at the count offset caps the draws. `cmd_draw_mesh_indirect` is the mesh version (see [Mesh shaders](#mesh-shaders)).
- **Records:** `Draw_Indirect_Args`, `Draw_Indexed_Indirect_Args` and `Dispatch_Indirect_Args` define the argument layouts. Argument and count buffers need the `Indirect` usage, and offsets are multiples of 4. Validation checks that the records are in range.
- **Draw ID:** each draw record starts with a `u32` draw ID, followed by the standard arguments. Shaders read it with the `CN_DRAW_ID` macro. The D3D12 backend delivers it as a root constant through the command signature. A Vulkan backend delivers the `DrawIndex` built-in, which is the record's index from the command's offset. So portable code stores each record's index as its draw ID, and keeps per-draw data in a buffer indexed by it.
- **Instance IDs:** `SV_InstanceID` does not include the first instance on D3D12, but does on Vulkan. Shaders that need the first instance read it from their own data.
- **Barriers:** indirect reads use the `Execute_Indirect` sync and the `Indirect_Argument` access.

## Mesh shaders

- Mesh and amplification shaders are HLSL and compile with the other shaders. They map to `VK_EXT_mesh_shader` and to Metal object and mesh shaders.
- A mesh pipeline replaces the vertex stage with a mesh shader and an optional amplification shader. All other pipeline state is the same, except that the mesh shader declares its topology. A pipeline has a vertex shader or a mesh shader, not both, and creating a mesh pipeline without `Features.Mesh_Shaders` fails.
- `cmd_draw_mesh(groups)` launches amplification groups, or mesh groups if there is no amplification shader. `cmd_draw_mesh_indirect` reads `Draw_Mesh_Indirect_Args` records, which start with a draw ID like the other draw records. Validation checks that each draw matches the bound pipeline's kind, and mesh draws need no index buffer.
- An update cannot turn a vertex pipeline into a mesh pipeline or back, because validation uses the kind before the new version is ready.
- **D3D12:** mesh pipelines compile from a pipeline state stream on the same background jobs, and draws use `DispatchMesh` and a command signature with the draw ID.
- **Fallback:** the engine keeps a vertex-pulling path for devices without mesh shaders. The sample shows both: with mesh shaders, amplification shaders cull the objects and mesh shaders draw them; without, a compute pass culls on the compute queue and an indexed indirect draw draws them. Both paths place vertices with the same shader function.
