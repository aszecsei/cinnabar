# Effects

Effects are `.effect` text files in the content roots: emitters of particles, each with settings, modules and curves, which a `Particle_System` places and the renderer simulates (see [Rendering: Particles](../../rendering/particles.md#particles)). `just effects` runs `cook effects --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`, and the daemon cooks them like any other kind (`tools/cook/effects.odin`).

```
effect 1
emitter smoke
	capacity = 512
	rate = 45
	lifetime = 4 6
	speed = 0.3 0.6
	shape = cone 0.15 15
	softness = 0.3
	module gravity 0 0.2 -0.2
	module noise 0.25 1.2
	curve color = 0:0.3,0.3,0.32,0 0.15:0.3,0.3,0.32,0.6 1:0.36,0.36,0.38,0
	curve size = 0:0.15 1:0.7
```

**The text.** The first line is `effect 1`. Each `emitter <name>` line starts an emitter, at most `MAX_EFFECT_EMITTERS` (8), and the lines indented under it are its settings, modules and curves. A `#` starts a comment.

**Settings.** A range is a value, or a low and a high one, from which each particle picks at random.

| Setting | Values | Default |
|---|---|---|
| `capacity` | The most particles alive at once, 1 to 65536, or to 1024 for a ribbon. It sizes the emitter's range of the pool. | 256 |
| `rate` | Particles a second. | 10 |
| `burst` | A count of particles at the start, and an interval in seconds after which it repeats. Without an interval, it bursts once. | none |
| `lifetime` | A range, in seconds. | 1 |
| `speed` | A range, in meters a second, along the shape's direction. | 1 |
| `spin` | A range, the sprite's turn in radians a second. | 0 |
| `shape` | `point`, `sphere <radius>`, `box <x> <y> <z>` (half extents) or `cone <radius> <angle>` (the base's radius, and the angle from +y in degrees), in the system's space. A point and a sphere send particles out in every direction, a box along +y, and a cone within its angle of +y. | `point` |
| `texture` | `$<guid>` of a texture, whose colors tint the sprites and whose alpha scales their opacity. | a soft round puff |
| `flipbook` | The texture's columns and rows of frames, and frames a second. | 1 1 0 |
| `softness` | Meters in front of an opaque surface over which a sprite fades. | 0 |
| `render` | `sprite`, a sprite for each particle; `ribbon`, one ribbon through the particles in the order that they spawned (see [Ribbons](../../rendering/particles.md#ribbons)); or `mesh`, a mesh at each particle (see [Mesh particles](../../rendering/particles.md#mesh-particles)). | `sprite` |
| `material` | `$<guid>` of a material: for a ribbon, one with `geometry = ribbon`; for a mesh, one that each of its submeshes draws with. | the engine's default ribbon material, or default material |
| `mesh` | `$<guid>` of the mesh that a mesh emitter draws, which it needs. | none |

**Modules** act on each living particle every step, in their order, at most `MAX_EFFECT_MODULES` (8):
- `module gravity <x> <y> <z>`: an acceleration in the world, in meters per second squared.
- `module drag <k>`: slows the velocity by k per second, exponentially.
- `module noise <strength> <frequency>`: a swirl of sines whose components each leave out their own axis, so it has no divergence: particles curl without gathering.
- `module collide <restitution> <friction>`: bounces off what the camera saw last frame (see [Collision](../../rendering/particles.md#collision)), keeping `restitution` of the speed into the surface and `1 - friction` of the speed along it.

**Curves** set a sprite's look, or a ribbon's at each particle, over a particle's life, from its birth at 0 to its death at 1. `curve <name> = <t>:<value> ...` gives keys in rising t, linear between them and held beyond them:
- `color`: r, g, b and opacity, linear, which scale a mesh's vertex colors. An alpha left out is 1. Default: white and opaque.
- `size`: half a side, half a ribbon's width, or a mesh's scale. Default: 0.1.
- `emission`: r, g and b, the light that the sprite gives. Default: none.

**The blob.** The cooker bakes each curve to `EFFECT_CURVE_SAMPLES` (64) evenly spaced samples, so the simulation reads a row and never keys. An `Effect_Blob` (`lib/engine/asset/format/effect.odin`) holds `Effect_Emitter` records, with their settings and a slice of `Effect_Module` records each, and the rows of every emitter's curves.

- **Problems** have their line: an unknown setting, module or curve, a value out of range, keys out of order. An effect with a problem keeps its old blob, so the running game keeps the last good version.
- **The cache key** covers the cooker version, the layout, the source path, the source and the GUID.
- **The editor** opens an effect in a preview beside the viewport, which plays it over a ground (see [Previews](../../rendering/particles.md#previews)), with a button that opens its text in the script editor. Each save shows in the preview once the daemon cooks it. **New Effect** makes one from a template of soft puffs.
- **Hot reload:** a new blob restarts every system that places the effect (see [Systems](../../rendering/particles.md#systems)).
