# Quality

How much the frame may cost, which a game's settings menu chooses and the hardware limits (`lib/engine/render/quality.odin`). Read [Frame: Settings](frame.md#settings) first: the settings there are the look, and this is the cost of drawing it.

## Quality

The renderer has two kinds of settings, and keeps them apart.

- **The look** is the [settings components](frame.md#settings) on volumes: the ambient occlusion's radius, the shadows' reach, the fog's density. An artist sets them per scene or per room, and they are the same at every quality.
- **The cost** is a `render.Quality`: each feature's technique and its level. A player sets it per machine, and it is the same in every room.

A volume says how far the ambient occlusion reaches; the quality says how many slices find it.

`Quality` is plain data, with no procedures or strings, so it lives in `Game_State` and a code reload keeps it (see [Hot reload](../overview/hot-reload.md#rules)).

| Field | Values | What it sets |
|---|---|---|
| `shadows.level` | `Low` … `Ultra` | The shadow maps' atlas, cascades and filter (`SHADOW_PARAMS`) |
| `shadows.ray_traced` | `bool` | Traced shadows for the first `MAX_MASK_LIGHTS` lights (see [Shadows](lighting-and-shadows.md#shadows)). Needs `Ray_Query` |
| `ao.technique` | `Off`, `Gtao`, `Ssao`, `Hbao` | The [ambient occlusion](ambient-occlusion.md#techniques)'s search |
| `ao.level` | `Low` … `Ultra` | The search's samples and steps (`AO_PARAMS`, a table for each technique) |
| `gi.technique` | `Off`, `Screen_Cascades` | The [global illumination](global-illumination.md#global-illumination) |
| `gi.level` | `Low` … `Ultra` | The cascades, their probe spacing, the rays' steps and the history's length (`GI_PARAMS`) |
| `fog` | `Low` … `Ultra` | The fog volume's depth slices (`FOG_LEVEL_SLICES`) |
| `aa` | `Off`, `Taa`, `Fxaa`, `Smaa`, `Fsr` | The [anti-aliasing](anti-aliasing.md#anti-aliasing). `Fsr` needs the device to run it |
| `render_scale` | `MIN_RENDER_SCALE` (0.5) to 1; 0 gives 1 | The scene's share of the frame's width and height, which temporal AA and FSR [upscale](anti-aliasing.md#upscaling) and the output pass otherwise stretches |

- **Each enum lists only what exists.** DLSS and XeSS join `Aa_Technique` when they are built (see [Future work](#future-work)), so a menu never offers a choice that draws nothing. A menu offers `Fsr` where `Caps.upscalers` has it: `clamp_quality` gives temporal AA in its place elsewhere.
- **Presets:** `preset_quality(preset, caps)` puts every feature at one level, with GTAO, the screen cascades and temporal AA, and traced shadows from High up where the device has them. `quality_preset(q, caps)` names the preset that a quality is, or `Custom`.
- **The zero `Quality`** is the cheapest frame at full resolution, with every feature that can be off off. The renderer never starts from it: `renderer_init` takes `default_quality`.

## Order in the frame

`draw_frame` takes the frame's settings in three steps, and each step can only turn a feature off:

1. `resolve_settings` blends the volumes at the camera, or the game gives `Frame_Desc.settings`.
2. `apply_quality` writes each feature's level into its settings (`Shadow_Settings.level`, `Ao_Settings.level`, and so on) and turns off the features whose technique is `Off`.
3. `apply_debug` turns off the features that the editor's viewport turns off (see [Debug views](post-processing.md#debug-views)).

So a room whose volume turns the ambient occlusion off has none at Ultra, and a quality without ambient occlusion has none in any room.

- **The frame's quality** is `Renderer.quality`, which `set_quality(&renderer, q)` sets from the next frame on. `Frame_Desc.quality` replaces it for one frame, as the editor's viewport may.
- **Each pass reads its level's parameters** from a table beside it, in place of the constants that it had. The constants that remain are maximums that size arrays, such as `SHADOW_CASCADES` (4).

## Levels

| Level | Shadow atlas | Cascades | Shadow filter | GTAO slices × steps | GI cascades, spacing, steps | Fog slices |
|---|---|---|---|---|---|---|
| Low | 2048, cells of 1024 | 2 | 1 tap (2x2) | 1 × 2 | 4, 16 px, 4 | 32 |
| Medium | 4096, cells of 1024 | 3 | 4 taps (3x3) | 2 × 2 | 5, 8 px, 6 | 48 |
| High | 4096, cells of 1024 | 4 | 4 taps (3x3) | 3 × 3 | 5, 8 px, 8 | 64 |
| Ultra | 8192, cells of 2048 | 4 | 9 taps (4x4) | 9 × 3 | 6, 4 px, 12 | 96 |

- **Before levels,** the frame drew High's shadows and GI, Ultra's GTAO, and High's fog.
- **Shadow cascades:** with fewer than four, `cascade_splits` divides the same reach among them, and repeats the last split in the unused places of `Frame_Constants.cascade_splits`, so no depth looks for a cascade past them. The slots for spot and point lights start after the cascades' cells, so a level with fewer cascades has room for more lights' maps.
- **The shadow filter** is `Frame_Constants.shadow_filter`, a `Shadow_Filter`. `shadow_map` in `material_lighting.hlsli` branches on it. Every pixel takes the same branch, so it costs no material permutation.
- **The ambient occlusion's levels** are each technique's own (see [Techniques](ambient-occlusion.md#techniques)); GTAO's are XeGTAO's presets. The samples and steps are in the search's constants, and its loops are no longer unrolled.
- **GI's levels** trade probes for cascades: each cascade's interval is four times as long as the one before, from a length that scales with the spacing, so sparser probes need fewer cascades to reach as far. Sparser probes are noisier, so their histories average over more frames. The spacing and the steps are in `Gi_Constants`.
- **Fog's slices** reach the injection in `Fog_Push.grid.z` and the forward pass in `Frame_Constants.fog_slices`.

## Hardware caps

`Renderer.caps`, a `Caps`, is what the device can do that the quality depends on: `ray_query`, the adapter's `vendor`, its `video_memory`, and the vendors' `upscalers` that it runs. `device_caps(platform)` reads them from `Platform_API.gpu_features`, `gpu_adapter` (see [GPU: Adapter](../gpu/interface.md#adapter)) and `gpu_upscalers` (see [GPU: Upscalers](../gpu/upscalers.md#upscalers)) when the renderer starts.

- **Defaults:** `default_quality(caps)` picks a preset by the video memory: Low below 4 GiB, Medium below 6 GiB, High below 10 GiB, Ultra above, and High when the memory is unknown, as on an adapter that shares the CPU's.
- **Limits:** `clamp_quality(q, caps)` turns off what the device cannot do, such as traced shadows without `Ray_Query`, gives temporal AA, which upscales too, for an upscaler that the device does not run, and puts each enum back in its range, since a settings file or a script may give any number. `set_quality` and `Frame_Desc.quality` both go through it.
- `CINNABAR_DISABLE_FEATURES=Ray_Query` hides the feature, as it does everywhere, to try the fallback on hardware that has it.

## Changing quality while the game runs

A change takes effect on the next frame, and nothing waits for the GPU.

- **Sizes:** the atlas, the GI cascades, the fog volume and, with the render scale, the scene's targets are the graph's transient textures, and the [texture cache](../gpu/render-graph.md#render-graph) makes a new one when a description changes. The histories (GI, fog) start again, as they do on a resize.
- **Pipelines** do not change with a level: the levels are constants that the passes read. A technique's pipelines are synced whether or not the frame uses it, so switching to it does not wait for it to compile. For example, the shadow mask's pipeline and the traced fog injection are synced on every device with `Ray_Query`.
- **FSR** makes its upscaler the first frame that uses it, and again when the frame's size changes, which compiles FSR's pipelines on the main thread for a moment (see [Anti-aliasing](anti-aliasing.md#fsr)). Until then, and while its motion pass compiles, temporal AA stands in.
- **Traced shadows:** the GPU scene's acceleration structure is made the first frame that traces, and every mesh gets its own then (`residency_enable_accels`), which the next frames build. When tracing turns off, the structures stay, so turning it on again builds nothing new. Until the traced fog injection is ready, the fog lights the traced lights without shadows.

## Saved quality

The player's choice is in the [project settings](../overview/architecture.md#project-settings), as `quality.*` keys: the project's file gives the project's default, and the user's file the machine's.

| Key | Values |
|---|---|
| `quality.preset` | `Low`, `Medium`, `High`, `Ultra`, `Custom` |
| `quality.shadows` | `Low` … `Ultra` |
| `quality.shadows.ray_traced` | `true`, `false` |
| `quality.ao` | `Off`, `Gtao`, `Ssao`, `Hbao` |
| `quality.ao.level` | `Low` … `Ultra` |
| `quality.gi` | `Off`, `Screen_Cascades` |
| `quality.gi.level` | `Low` … `Ultra` |
| `quality.fog` | `Low` … `Ultra` |
| `quality.aa` | `Off`, `Taa`, `Fxaa`, `Smaa`, `Fsr` |
| `quality.render_scale` | A number from 0.5 to 1 |

- **Reading:** `project.quality(settings, caps)` starts from the preset, or from `default_quality` without one, and each other key replaces the preset's value for its feature. A fresh machine with no keys gets the defaults for its hardware.
- **Saving:** `project.save_quality(platform, path, q, caps)` writes every key to the user's file through `Platform_API.file_write`, so the user's file alone gives the quality. It changes each key's line in place and keeps the file's other lines, as the editor's `ProjectSettings.Set` does. The next `project.refresh` reads it back.
- **The sample** applies the files' quality when they change. F9 takes the next preset, Shift+F9 turns traced shadows on or off, Ctrl+F9 takes the next ambient occlusion technique, Alt+F9 the next anti-aliasing technique that the device runs, and Ctrl+Shift+F9 the next render scale: 1, 0.75, 0.67 and 0.5. Each saves the quality to `project.user.settings`, as a settings menu would.

## Future work

The phases that follow this one, in order, each worth doing on its own:

- **A script API** (`Render.quality`, `Render.set_quality`, `Render.caps`, `Render.save_quality`) for settings menus in Luau, and a quality drop-down in the editor's viewport that sets `Frame_Desc.quality`.
- **DLSS and XeSS** as `Aa_Technique`s beside FSR, through the GPU interface's upscalers, once their licenses are reviewed (see [Anti-aliasing](anti-aliasing.md#future-work)).
- **Levels for the transparency and the bloom**, when their cost shows in a profile.
