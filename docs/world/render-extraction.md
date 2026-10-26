# Render extraction

The one place rendering reads the world: extraction writes presented poses into frame memory, in parallel, relative to an origin. [Rendering](../rendering/gpu-scene.md) is the main consumer.

Rendering does not read the ECS. Each frame, before the render graph is built, extraction writes what the GPU needs into frame memory, usually the upload ring. `lib/engine/render` does this, and `ecs` does not know about rendering.

- An **extractor** selects entities: every entity with a `Transform` that matches the extractor's extra terms. It reads `Previous_Transform` too, if the entity has one. Extractors are registrations, like queries.
- `extract` writes each entity's presented pose (interpolated by the clock's `alpha`) as a 3x4 row-major matrix, relative to an origin. The origin is usually the camera's presented position. The matrix starts each record of a caller-chosen stride, so a game can put its own data after it in the same record, and the records go straight into the upload ring.
- The matrices have no camera rotation, only the camera-relative translation. One set of records can therefore serve several views and the ray tracing acceleration structure. The view rotation and the projection belong in each view's constants.
- Records are in query order. `extract` returns each chunk with the index of its first record, so the caller fills the rest of each record from its own columns. The caller's terms start at `EXTRACT_TERMS` in each chunk view.
- Chunks are processed in parallel jobs. Run extraction after the `Late` stage, while no system runs.

The built-in renderer's [GPU scene](../rendering/gpu-scene.md#gpu-scene) is the main consumer: it extracts every `Mesh_Renderer` relative to a render origin rather than the camera, so that its records persist across frames.
