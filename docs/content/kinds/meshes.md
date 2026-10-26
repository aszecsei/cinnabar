# Meshes

Meshes come from `.gltf` and `.glb` files, read with `vendor:cgltf`. A glTF file is a `Model` asset, which has no blob of its own: its meshes are `Mesh` sub-assets (see [Identity](../identity-and-cooking.md#identity)), each with its GUID on a `mesh.<name>` line of the model's `.meta` file. `just models` runs `cook models --cache build/cache --config dev|release` with the roots.

- **One mesh asset per glTF mesh**, named for the glTF mesh, in its own space with its own pivot. Node transforms are not baked in, so a mesh that many nodes use is one asset. Each glTF primitive becomes a submesh. Primitives that share a glTF material share a submesh, and each submesh has a material slot named for its glTF material.
- **Unnamed meshes** are named for the first node that uses them, then `mesh_<index>`.
- **Names** are keys in the `.meta` file, so an `=` in a name becomes `_`, and two meshes of one name get `_2` and on.
- **`combine = true`** makes one mesh asset, named for the file without its extension, instead: the cooker walks the default scene's nodes and bakes their transforms into the vertices. This suits a file that is one prop exported in pieces. The default is `false`.
- *Later, a model also makes a prefab of its node hierarchy that places its meshes, and its textures and materials become sub-assets too (texture assets and material instances). That is importing a glTF file as a scene, and it waits for prefabs.*
- **Axes:** glTF is right-handed, with +y up and +z the asset's front. The engine is left-handed, with +x right, +y up and +z forward. The cooker negates x and reverses each triangle's winding, so front faces are clockwise on screen, as `lib/core/gpu` takes them, and back faces cull. The mirror flips the tangent frame's handedness, so a tangent from the file has its bitangent sign flipped too.
- **Missing attributes:** a primitive without normals gets its faces' normals, as glTF specifies. A primitive that is not triangles is left out, with a warning.
- **Vertices** are two streams, so that depth and shadow passes read only positions:

| Stream | Contents | Size |
|---|---|---|
| Positions | `f32` x, y, z | 12 bytes |
| Attributes | The normal, octahedral in a `snorm16` pair; the tangent, octahedral in a `unorm16` pair whose second value's lowest bit is the bitangent's sign (set is -1); the first UV set in `f32`; then the second UV set in `f32` and the vertex color in `unorm8`, when the file has them | 16 to 28 bytes |

- **Processing** with meshoptimizer: weld identical vertices, order each submesh's triangles for the vertex cache and the mesh's vertices for fetching, and build each submesh's meshlets of at most 64 vertices and 124 triangles, each with a bounding sphere and a normal cone for culling. Indices are 16-bit when the mesh has fewer than 65 536 vertices. The Khronos DamagedHelmet sample, 14 556 vertices and 15 452 triangles, cooks into 246 meshlets in a few milliseconds.
- **Tangents** come from the file, or from `meshopt_generateTangents` in its MikkTSpace-compatible mode, which matches how normal maps are baked. A mesh with any primitive that has no tangents gets made tangents for all of them, so its frame is consistent.
- **Bounds:** the mesh and each submesh have an axis-aligned box and a sphere.
- **Not imported yet:** the node hierarchy (except with `combine`), the file's materials, textures, cameras, lights, skins and animations.
- **Import settings:** `combine` (`true` or `false`, default `false`), `scale` (`0.001`, `0.01`, `0.0254`, `0.1`, `1`, `10` or `100`, default `1`: settings are checked against a list of values, so the scale is a choice of common units) and `tangents` (`file` or `generate`, default `file`). The settings apply to every mesh of the file.
- **The cache key** is the model's: the cooker version, the meshoptimizer version, the source path, the source, the GUID and the import settings, and for a `.gltf` file the buffer files that it names. The `mesh.` lines are not in it, because the cooker writes them; a mesh's GUID is its blob's name instead, so a new GUID cooks it. A model is up to date when every one of its meshes has a blob with its key.
- **All or nothing:** a model cooks every mesh into memory before it writes any blob, so a mesh that fails fails the model, and its meshes keep their old blobs together.
- **New and renamed meshes:** the cooker gives a mesh that has no line a new GUID and writes it into the `.meta` file, which makes one more pass. A line whose mesh is gone is a warning and stays, so a mesh renamed back gets its GUID again. A re-import drops those lines.
- **meshoptimizer** is the submodule `vendor/meshoptimizer`, pinned to a release, and `just meshoptimizer` builds it with its own CMake project. Its API is C, so the cooker binds it directly (`tools/cook/meshoptimizer.odin`). `just update-meshoptimizer <tag>` moves the pin.
