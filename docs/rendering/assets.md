# Assets and components

How the renderer gets GPU resources for the assets it draws, how components refer to assets, and the renderer's own components.

**In this document:** [GPU residency](#gpu-residency) · [Asset fields](#asset-fields) · [Components](#components)

The renderer draws shader, texture and mesh assets, which the cooker makes (see [Content pipeline](../content/kinds/shaders.md#shaders)).

## GPU residency

The asset runtime keeps blobs on the CPU. The renderer's residency table, in `Renderer`, gives the GPU resources of the assets that it draws.

- **By GUID.** `render.resident_texture(&renderer, guid)` and `render.resident_mesh(&renderer, guid)` return the GPU handles and whether they are ready. The first call loads the asset, creates its resources and streams its data with `gpu_stream_texture` and `gpu_stream_buffer` (see [GPU](../gpu/queues-streaming-readback.md#streaming)). Each later call is a lookup.
- **Until a resource is ready**, a texture gives the default for its usage (white, a flat normal, black) and a mesh draws nothing. Nothing waits for a stream.
- **Hot reload.** When `asset.poll` swaps a blob, the table streams the new data into new resources, and switches to them only when their transfers are done, so the old version draws until then. Then it destroys the old resources.
- **Shaders** are not in the table. A `render.Shader_Pipeline` names its shader by the GUID in the shader's `.meta` file. `render.sync_graphics_pipeline`, `sync_compute_pipeline` and `sync_ray_tracing_pipeline`, called each frame, load the shader, create the pipeline from the blob's entries, and update it when `asset.poll` swaps the blob. On a code reload, `force` updates every pipeline with the new descriptions. A shader change therefore needs no code reload: the daemon cooks it, and the next frame's pipeline compiles from it.
- **Lifetime.** Resident resources have the `Game` scope. A soft restart destroys them with the old game, and loads the assets again, as it loads every asset again (see [Content pipeline](../content/blobs-and-loading.md#loading)).
- **The table** is `render.Residency`: a fixed array of `MAX_RESIDENT` entries in `Game_State`, found by GUID. `residency_update`, once a frame before drawing, swaps in what finished streaming and starts streaming each asset whose blob `asset.poll` swapped. A mesh keeps its position, attribute and index buffers, and the index ranges of its first `MAX_SUBMESHES` submeshes; 16-bit indices are padded to whole words.
- **Failures:** an asset that is not cooked, or whose blob is not of its kind, is logged once and tried again every `RESIDENT_RETRY_FRAMES` frames, or when a newer blob arrives.
- **Unused assets** stay resident. Unloading by use, and streaming mips by distance, come with larger scenes.
- **Acceleration structures:** with `Ray_Query` (`Residency.accels`), a mesh that becomes ready gets a bottom-level acceleration structure of all its triangles, which the renderer builds the next frame that traces shadows (`unbuilt_accels`).
- *Later:* the meshlet streams, for the mesh shader path.

## Asset fields

A component refers to an asset by GUID, in a `format.Guid` field with an `asset` tag that names the kind as the cook link does, in lowercase: ``mesh: format.Guid `asset:"mesh"` ``. A field without the tag takes any asset.

- **Field kind:** the field walker (`scene.component_fields`) gives such a field the `Asset` kind and its `asset_kind`, and the editor link's `Field_Info` carries both. A fixed array of asset references, such as ``materials: [8]format.Guid `asset:"material"` ``, is a field for each element, named `materials.0` and on.
- **Scenes** write the value as `$` and 32 hex digits, or `$0` for none (see [Editor](../editor/document-and-scenes.md#scenes)), and the loader writes the GUID into the field. A component holds the GUID, never a loaded asset: the renderer resolves GUIDs through its residency table.
- **Missing assets:** the cooker warns when a scene names a GUID that no asset or sub-asset in the content has, as it does for a missing script. Field types exist only in the game DLL, so the cooker cannot check the kind; the editor offers and accepts only assets of the field's kind.
- **The properties panel** shows the asset's name, picks from the assets of the field's kind, and accepts one dragged from the content browser (see [Editor](../editor/shell-and-panels.md#properties)).
- *Not yet:* behaviour fields of assets, and asset fields in scripts, which skip them as they skip any field type that they do not know.

## Components

- **`Camera`** (stable ID 32): the vertical field of view in radians and the near plane in meters; 0 in either means 60° or 5 cm. Also the view model's field of view and near plane, 0 for the camera's own (see [View model](layers-and-output.md#view-model)). The camera's pose is its entity's presented `Transform`, and `render.camera_view` gives the view. `Game_State` holds the active camera's entity, as world-wide state (see [World](../world/README.md)). The game's view comes from it, unless an editor is linked (see [Editor](../editor/viewport.md#viewport)).
- **`Mesh_Renderer`** (stable ID 33): a mesh, a material or instance for each of its mesh's first `MAX_MATERIAL_SLOTS` (8) submeshes (`materials.0` and on), and whether it casts shadows. `render.register_components` registers both. The renderer draws every `Mesh_Renderer` through the [GPU scene](gpu-scene.md#gpu-scene).
- **`Directional_Light`** (stable ID 34): a color, an intensity and whether it casts shadows. It shines along its entity's +z.
- **`Point_Light`** (35): a color, an intensity, a range in meters, and whether it casts shadows.
- **`Spot_Light`** (36): a point light in a cone along its entity's +z, with inner and outer half angles in radians.
- **`Quad_Light`** (39): a rectangle of light, a width and a height in meters along its entity's x and y, that shines along its +z, or from both faces when it is two-sided. Also a color, an intensity, a range beyond its shape, and whether it casts shadows (see [Area lights](lighting-and-shadows.md#area-lights)).
- **`Disk_Light`** (40): a disk of light, a width and a height across along its entity's x and y, so an ellipse when they differ. Otherwise as `Quad_Light`.
- **`Line_Light`** (41): a tube of light along its entity's x, with a length and a radius in meters; a radius of 0 is an ideal line. Also a color, an intensity, a range beyond its shape, and whether it casts shadows.
- **Defaults:** a light's color of 0 means white, a range of 0 means `DEFAULT_LIGHT_RANGE` (10 m), an outer angle of 0 means `DEFAULT_SPOT_OUTER` (45°), and an inner angle of 0 means the outer angle. An area light's width, height or length of 0 means `DEFAULT_AREA_SIZE` (1 m). An intensity of 0 is a light that is off.
- **`View_Model`** (37): a tag that makes a `Mesh_Renderer` part of the view model (see [View model](layers-and-output.md#view-model)).
- **The settings components** (38 and 43 to 50), which volumes carry (see [Settings](frame.md#settings)).
