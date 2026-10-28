# Particles

GPU particles: a `Particle_System` places an effect asset, whose emitters the GPU simulates in frame time and draws as compute sprites among the moment-based transparent surfaces. Read [Transparency](transparency.md#sprites) first for the sprites that they draw as, and [Effects](../content/kinds/effects.md#effects) for the asset.

**In this document:** [Particles](#particles) · [Systems](#systems) · [Time](#time) · [Simulation](#simulation) · [Collision](#collision)

## Particles

`lib/engine/render/particles.odin`. Each emitter of a system owns a range of one pool of particles. Every frame, a thread for each particle of a range ages it, moves it with the emitter's modules and collides it, or, while it is dead, takes one of the frame's new particles. Each living particle then appends a sprite, with its color, size and emission from the emitter's curves at its age, which the sprite passes bin, light and rasterize into the moments with the rest.

- **Lighting** is the sprites': the clusters, the shadow maps, the global illumination and the fog, on an 8x8 grid of points on each sprite (see [Sprites](transparency.md#sprites)). The sample's smoke is lit by the glass scene's point light.
- **Order:** the sprites take their place in the moments, so particles need no sort, and draw among glass.
- **Limits:**
  - Particles draw as sprites only: squares that face the camera.
  - They cast no shadows, have no velocities, and so trail under temporal AA and FSR.
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
- **Records.** The emitters' records, their modules and their curves' rows go into the upload ring, and the frame reserves room for every emitter's capacity of sprites (`reserve_sprites`).

## Time

`Frame_Desc.delta` is the time that the particles step this frame, in seconds, at most `MAX_PARTICLE_DELTA` (0.1 s). The game passes the time that its simulation stepped, so the particles stand still in the editor's Edit mode and while it pauses, and step with Step Frame. The sample passes the step that `editor.simulation` gives. The noise's time is the sum of the steps.

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
