# Particles

GPU particles: a `Particle_System` places an effect asset, whose emitters the GPU simulates in frame time and draws as compute sprites among the moment-based transparent surfaces, as ribbons, or as meshes. Read [Transparency](transparency.md#sprites) first for the sprites that they draw as, and [Effects](../content/kinds/effects.md#effects) for the asset.

**In this document:** [Particles](#particles) · [Systems](#systems) · [Time](#time) · [Simulation](#simulation) · [Collision](#collision) · [Ribbons](#ribbons) · [Mesh particles](#mesh-particles) · [Previews](#previews)

## Particles

`lib/engine/render/particles.odin`. Each emitter of a system owns a range of one pool of particles. Every frame, a thread for each particle of a range ages it, moves it with the emitter's modules and collides it, or, while it is dead, takes one of the frame's new particles. Each living particle then appends a sprite, with its color, size and emission from the emitter's curves at its age, which the sprite passes bin, light and rasterize into the moments with the rest.

- **Lighting** is the sprites': the clusters, the shadow maps, the global illumination and the fog, on an 8x8 grid of points on each sprite (see [Sprites](transparency.md#sprites)). The sample's smoke is lit by the glass scene's point light.
- **Order:** the sprites take their place in the moments, so particles need no sort, and draw among glass.
- **Limits:**
  - Particles draw as sprites, squares that face the camera, as ribbons (see [Ribbons](#ribbons)), or as meshes (see [Mesh particles](#mesh-particles)).
  - Sprites and ribbons cast no shadows and have no velocities, so they trail under temporal AA. Under FSR, the moments' mask keeps sprites and moment-based ribbons from trailing; sorted and additive ribbons still trail (see [FSR](anti-aliasing.md#fsr)).
  - They draw in the camera's view only.

## Systems

**`Particle_System`** (52) places an effect at its entity's Transform:
- `effect`: the effect asset.
- `paused`: stops new particles; those alive live out their lives.
- `rate_scale`: scales the emitters' rates and bursts; 0 means 1.

`begin_particles` steps the systems on the CPU each frame, after the sprites begin:
- **Slots.** Each system has a slot, at most `MAX_PARTICLE_SYSTEMS` (256), keyed by its entity, as the GPU scene's are: a system that is no longer seen, because it was despawned, lost its component or went inactive, returns its ranges to the pool. A system that the editor hides keeps its particles where they are and draws none.
- **Starting.** The first frame of an effect, a new effect, or a new version of its blob, starts the system: each emitter takes a range of `capacity` particles from the pool, `MAX_PARTICLES` (262144) of 48 bytes, by first fit, and its particles start dead. An emitter that the pool has no room for draws nothing, which is logged once.
- **The anchor.** Particles are relative to the system's anchor, its position when it started, so they stay where they are in the world when the system moves, and the render origin's moves do not touch them. Each frame gives the anchor relative to this frame's camera and last frame's.
- **Spawning.** Each emitter's rate times the frame's time, with the fraction carried to the next frame, and its bursts when they are due, are the frame's new particles, at most its capacity.
- **Records.** The emitters' records, their modules and their curves' rows go into the upload ring, and the frame reserves room for the capacity of sprites of every sprite emitter (`reserve_sprites`).

## Time

`Frame_Desc.delta` is the time that the particles step this frame, in seconds, at most `MAX_PARTICLE_DELTA` (0.1 s). The game passes the time that its simulation stepped, so the particles stand still in the editor's Edit mode and while it pauses, and step with Step Frame. The sample passes the step that `editor.simulation` gives.

- **Playing in the editor.** While `delta` is 0, the systems in `Frame_Desc.playing` step by the host's time since the last frame instead, at most `MAX_PARTICLE_DELTA`. `editor.playing` gives the editor's selection, so a selected effect plays in Edit and while paused, every other one stays where it is, and one that is deselected stops where it is. In Play, every system steps by `delta`.
- **Each system's time** is its own: an emitter's record carries the time that its system steps this frame, and its age, which the noise moves with.

## Simulation

`particle_update.hlsl`, before the prepass: a dispatch for each emitter, a thread for each particle of its range.

- **A living particle** ages by the step, and dies at its lifetime. Otherwise the emitter's modules act in their order (`gravity`, `drag`, `noise`), it moves by its velocity and turns by its spin, and then it collides.
- **A dead particle** takes a ticket from the emitter's counter, which a copy zeroes each frame. While tickets are below the frame's new particles, it starts:
  - in the emitter's shape, in the system's space at its pose;
  - with a speed, a lifetime and a spin from their ranges, and a random turn;
  - at a random time within the step, along its velocity, so a steady rate does not spawn in layers.
  So no list of free particles is kept: the dead ones take the new ones.
- **The sprite** of each living particle is appended with `append_sprite`: its color, size and emission from the curves at its age over its lifetime, and its flipbook frame from its age.

## Collision

The simulation runs before the prepass, so it collides with what the camera saw last frame, as Unity's VFX Graph and Unreal's Niagara do for their depth collision.

- **The history.** After the prepass, `particle_history.hlsl` writes each pixel's view depth and world normal into a history texture (`PARTICLE_HISTORY_FORMAT`, `RGBA16_Float`), which the next frame's update reads. Where nothing drew, the depth is as far as the format holds.
- **A collision.** A particle with `collide` projects with last frame's view projection. When it is behind the depth there by less than a thickness, 0.3 m or twice its step, whichever is more, and moving into the surface, it bounces: it keeps `restitution` of its speed into the surface and `1 - friction` of its speed along it, and moves back out by how far it went in.
- **No collision** happens off last frame's screen, in the first frame, after the frame's size changes, or behind what last frame showed.

## Ribbons

An emitter with `render = ribbon` draws its particles as one ribbon, a strip through them in the order that they spawned, oldest first, as a trail does. The sample's trail effect is a ribbon behind the glass scene's spinner.

- **Spawning.** A ribbon's emitter spawns in its range's order: `Particle_Slot.head` is where it spawns next, and the frame's new particles take the places after it, over the oldest ones. So the range is a ring, and its particles stay in the order that they spawned. A ribbon has at most `MAX_RIBBON_CAPACITY` (1024) particles, since one group builds it. Its emitter's record has the `EMITTER_RIBBON` flag, and the update appends no sprites for it and reserves none.
- **The item.** `add_ribbon_items`, while `build_scene` writes the instances, gives each ribbon of each started system that is not hidden an item with the `ITEM_RIBBON` flag in its material's bin, with an instance slot at the system's anchor, keyed by `particle_key`, and a range of `Particles.ribbon_vertices`, two for each particle of its capacity, which grows to hold them. `cull_draws.hlsl` skips the item, as it skips a surface's.
- **The build.** `ribbon_build.hlsl`, after the update, a group for each ribbon that its system stepped this frame, a thread for each particle of its range from the oldest: the living ones are compacted in their order with wave prefix counts, and each writes the ribbon's two edges at it (`Ribbon_Vertex`, 64 bytes), its size's width apart, across the ribbon's direction there and facing the camera, with its color, both from the emitter's curves at its age. `u` is the particle's age over its lifetime, and `v` is 0 on one edge and 1 on the other. Then thread 0 takes the ribbon's draw in its item's bin of the camera's view, as `cull_draws.hlsl` takes a mesh's: two triangles for each segment between two particles. A ribbon of fewer than two living particles draws nothing.
- **The material.** A ribbon draws with the emitter's `material`, a material with `geometry = ribbon`, or the engine's default ribbon material (`lib/engine/content/materials/default_ribbon.material`): lit, transparent and two-sided, its color from the color curve, fading toward its edges. A ribbon material's vertex path (`material_ribbon.hlsli`) reads the vertices from `Frame_Constants.ribbon_vertices`, and the vertex goes through `finish_vertex`, so the instance places it. A ribbon material is transparent or additive and draws only in the transparent passes; on a `Mesh_Renderer` the default material stands in, and its preview is the background.
- **Limits:** a ribbon draws in the camera's view only, and a ribbon whose system did not step this frame, because it is hidden or the frame has no particles to step, draws nothing.

## Mesh particles

An emitter with `render = mesh` draws a mesh at each of its particles, with its `material` on each submesh, or the engine's default material. The sample's smoke effect has gold nuggets, the sample's box, that tumble out and bounce on the floor.

- **The items.** `add_mesh_particle_items`, while `build_scene` writes the instances, gives each submesh of each mesh emitter of each started system that is not hidden an item with the `ITEM_PARTICLES` flag, and each emitter a range of `capacity` instances in `Particles.mesh_instances`, which grows to hold them. The item's instance is the system's anchor, as a ribbon's is, which the sorted draws sort by. `sort_bins` gives the items of each material a bin of their own after its own, as it does impostors, which draws with vertex pulling (`Scene_Frame.bin_particles`), so an opaque material on the mesh shader path draws mesh particles too. `cull_draws.hlsl` skips the items.
- **The instances.** In the update, each living particle of a mesh emitter appends an `Instance_Record` instead of a sprite, at its emitter's first instance, counted in the second half of the counters (from `MAX_FRAME_EMITTERS`):
  - its pose: turned by its rotation about an axis of its own, from its seed, and scaled by its size, at its position relative to the GPU scene's origin;
  - its pose before this step as last frame's, so it has a velocity;
  - its system's ID, so the editor picks the system;
  - its color from the color curve, as unorm8, which scales its mesh's vertex colors in `inputs.color`.
- **The draws.** `particle_meshes.hlsl`, after the update, a thread for each item in each view: each item takes one draw in its bin, with `DRAW_PARTICLES`, whose vertex count is its submesh's indices times its emitter's living particles. The vertex path (`load_vertex` in `material_vertex.hlsli`) draws the submesh once for each particle, with its instance from `Frame_Constants.particle_instances`. An item draws in the camera's view and, when its material casts shadows, in every shadow view; the view model's view draws none.
- **Limits:** mesh particles are not culled, by view or by particle, nor in the ray-traced shadows; and an effect's preview draws no mesh particles.

## Previews

The editor shows an effect in a preview of its own, as it shows a material (see [Material previews](materials.md#material-previews)). A preview of an effect is the same `Open_Preview` with the effect's GUID: the game's `editor` package finds that its blob is an effect's, sets `Preview_Desc.effect`, and draws the preview in every frame that it can, since the effect plays.

`add_preview_passes` draws an effect's preview into its target:
- **The ground:** the engine's default material on the preview plane, `EFFECT_PREVIEW_GROUND` (6 m) a side, drawn as a material preview draws its mesh, with the camera orbiting a point `EFFECT_PREVIEW_HEIGHT` (0.75 m) over it. Until the plane and the material are ready, the effect plays over the background.
- **A frame of its own:** the preview's targets, its constants as its camera's, one directional light and the ambient light. Its sprites have buffers of their own (`Sprites.preview`), since the frame's are in use, and its particles a history of their own, so they collide with the ground.
- **The system:** a slot for each preview (`Particles.previews`), which plays the effect at the preview's origin by the host's time. A new effect, or a new version of its blob, starts it again, so each save of the effect restarts it once it cooks.
- Then the moments, the sprites' passes and the composite, and the output pass's tone mapping into the target.
