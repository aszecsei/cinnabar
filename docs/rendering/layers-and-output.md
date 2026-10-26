# Layers and output

The world, the view model, the UI and debug drawing each have their own target and rules. The output pass combines them after tone mapping, in SDR or in HDR.

**In this document:** [Layers](#layers)

## Layers

| Layer | Target | Space | Depth | Composited |
|---|---|---|---|---|
| World | Scene color, `RGBA16_Float` | Linear HDR | Scene depth | Is the base |
| View model | The world's targets | Linear HDR | Scene depth, its own projection, a stencil bit | In the forward pass |
| UI | `RGBA8_Unorm`, premultiplied | sRGB-encoded, blended as encoded | None | In the output pass, over the tone-mapped scene |
| Debug | `RGBA8_Unorm_Srgb`, premultiplied | Linear, which the target's sRGB view encodes; the output pass blends it as encoded | Tested lines test scene depth; overlay lines ignore it | In the output pass, over the UI |

- The renderer makes the UI target only with a `ui` hook, and the debug layer only with debug lines or a `debug` hook. Without them, the output pass reads neither.

### View model

A first-person view model needs its own field of view, and it must never go into a wall. A separate target that is composited on top does both, but the view model then misses everything that runs on the scene: it receives no shadows from the world and casts none, it has no ambient occlusion or fog, temporal AA and motion blur do not see it, and bloom and exposure treat it apart from the world. The renderer therefore draws the view model into the world's own targets, as a second view:

1. **The view model prepass runs first.** It draws the view model with its own projection and writes depth and stencil bit 0 (`VIEW_MODEL_STENCIL`). The scene's depth is `D32_Float_S8_Uint` for the stencil.
2. **The world prepass tests stencil bit 0** and draws nowhere that the view model is. A wall that is closer than the arms never covers them. One prepass pipeline does both: its test is `Greater_Equal` against the reference with `Replace`, and the view model draws with the bit as the reference, which passes everywhere and sets it, and the world with 0, which passes only where the bit is clear.
3. **The view model's forward pass** shades it with the world's lights, shadows, ambient occlusion and fog. Its indirect light is the ambient light: the global illumination's probes sit only on the world's surfaces. Its records are relative to the camera, not the render origin (see [GPU scene](gpu-scene.md#gpu-scene)), but they are still world-space positions with no camera rotation. Only its projection differs, so its lighting matches the world's. The forward pipeline tests the stencil bit `Equal` to the reference, so the world's draws never shade the view model's pixels either.
4. **Passes that rebuild positions from depth check the stencil bit**, and use the view model's projection and near plane for its pixels. The shadow mask reads the bit through the depth texture's stencil view (`gpu.stencil_index`). The forward pass finds a pixel's cluster and its place in the fog volume from its position, projected as the camera's projection would place it, not from the pixel, because the clusters and the volume are the camera's screen tiles. The ambient occlusion rebuilds each pixel with its own projection, and a step of its search that crosses from the world onto the view model, or back, finds nothing, so the view model occludes only itself. The global illumination's rays pass the view model's pixels, and its probes skip them. *Later,* depth of field leaves those pixels sharp.

- **Which entities:** those with a `Mesh_Renderer` and the `View_Model` tag (stable ID 37). Their pose is in the world, usually as a child of the camera, so they follow it.
- **The projection:** the camera's `view_model_fov` and `view_model_near`, which reach the frame as `View.view_model_fov` and `view_model_near`; 0 means the camera's own. `view_model_view` gives the view that it draws with. A nearer near plane lets the view model come closer to the eye than the world does.
- **Shadows:** the view model receives the world's shadows: the shadow maps sample at its position relative to the camera, and the mask traces from it. It casts none, into the world or onto itself, because its pose is not its real place in the world: it is in no shadow view and not in the acceleration structure.
- **A game's own draws** in `world_draw` test the stencil bit with `render.WORLD_STENCIL`, so they never cover the view model either. The sample's pipelines do.
- **Debug lines** that test depth compare it only with the world's pixels: over the view model, they draw at the hidden part's alpha, as behind a wall.
- A game that wants a truly separate target can use the `before_post` hook, which still composites in linear HDR before post.

### UI

- The UI draws into its own target in sRGB-encoded values, and blends them as encoded values, as design tools do. A color that a designer picks is the color on the screen.
- The output pass combines the UI with the tone-mapped scene in its shader, not with fixed-function blending, so it can blend in sRGB space, and in HDR output, scale the UI to paper white (see [HDR output](#hdr-output)).
- The UI target has the frame target's size. The scene can render at a lower resolution, and the UI stays sharp.
- The UI renderer itself is not part of this design. It only has to write into the UI target, through the `ui` hook. The sample draws a HUD panel there, with colors picked as sRGB values, and the `Premultiplied` blend.

### Debug

- `cinnabar:engine/debug` is an immediate API: `debug.line`, `debug.box`, `debug.sphere`, `debug.circle`, `debug.arrow`, `debug.axes`, and later text. Each takes a `debug.Draw` (the renderer's is `Renderer.debug`), `World_Position`s, a linear color, a duration in seconds (0 is this frame only) and a mode: `Tested` or `Overlay`. Every shape is lines.
- Any job can call it: a line takes its slot in one array with an atomic add, and lines past `MAX_LINES` are dropped. The array is in host memory, so lines with a duration survive a code reload. `draw_frame` uploads the lines relative to the camera, the tested ones first, and `end_frame` then drops those of this frame only and those that expired.
- Each line is a quad two pixels wide that the vertex shader makes, and a line that passes behind the camera is clipped where it does. Tested lines draw twice: with depth `Less` at `DEBUG_HIDDEN_ALPHA`, then with `Greater_Equal` at full alpha.
- **Tested** shapes read scene depth. The hidden part draws with a lower alpha, so a shape inside a wall still shows where it is. **Overlay** shapes draw over everything.
- The colors are exactly the colors given: no exposure, no tone mapping, no fog.
- The editor's selection outline and gizmo draw into the debug layer: the game adds `editor.add_viewport_passes` in its `debug` hook, with `Frame.debug` as the target (see [Editor](../editor/viewport.md#viewport)).
- Release builds compile the debug calls out: the justfile's release build sets `DEBUG_DRAW` false.

### Output

The output pass is one full-screen pass that writes the frame target (`lib/engine/content/shaders/output.hlsl`):

1. Read the scene, which is pre-exposed, add bloom, and tone map it through the [lookup table](post-processing.md#post-processing), which gives sRGB-encoded colors. Until the table is baked, a plain roll-off to white, `x / (1 + x)`, stands in. *Later, a separate pass tone maps the scene, and this pass reads it, upscaled to the frame's size if the scene's resolution is lower.*
2. Without the table, encode the color to sRGB. In HDR output, the table's colors are in nits: divide them by paper white and encode them with the sRGB curve, which goes on above 1.
3. Blend the UI over it, then the debug layer, both as sRGB-encoded values.
4. Write the result, encoded for the output mode (`Frame.output`). In SDR, the frame target has an sRGB view (`FRAME_TARGET_FORMAT`), so the pass decodes the result to linear first and the view encodes it again. In HDR, the pass decodes it, scales it by paper white and encodes it for the display (see [HDR output](#hdr-output)).

The pass has a pipeline for each output mode's frame target format (`Renderer.output_pipelines`), made when a frame first needs it.

### HDR output

On a display in HDR, the frame reaches it in HDR: highlights go up to the display's peak, while the colors up to SDR's white look as they do in SDR.

- **The mode** is `core`'s (see [GPU](../gpu/presentation.md#presentation)): `Frame.output` holds the frame's `gpu.Output`, with its mode, the frame target's format and the display. A game asks for a mode with `gpu_request_output`; the sample asks for its project's `output` setting (see [Architecture](../overview/architecture.md#project-settings)). The default, `Auto`, is HDR10 on a display in HDR and SDR otherwise. `CINNABAR_OUTPUT` replaces the game's request, for example `CINNABAR_OUTPUT=Scrgb`. The editor's viewport is always SDR.
- **Paper white** is the brightness of SDR's white, in nits. The UI's white has it, and so does the display color that a tone mapper gives 1 in SDR. By default it is the display's SDR white, which Windows' HDR settings set, so the frame's SDR colors are as bright as other SDR content on the desktop. Where that is unknown, it is `DEFAULT_PAPER_WHITE` (200). `Tone_Mapping.paper_white` replaces it.
- **The peak** is the display's maximum luminance, `DEFAULT_PEAK` (1000) when it is unknown, or `Tone_Mapping.peak`. Paper white is at most the peak.
- **The lookup table** bakes the tone mapper's SDR display colors as before, then opens up those above `HDR_KNEE` (0.5) of SDR's white, so that SDR's white reaches the peak instead (`hdr_expand` in `tone_lut.hlsl`). Below the knee, the colors keep their SDR values. Above it, a curve goes on at the same slope and reaches peak / paper white at 1. The curve scales each color by its largest channel, so the tone mapper's hue and desaturation stay. The entries hold the result times paper white, in nits, encoded with the PQ curve. The table bakes again when the mode, paper white or the peak changes.
- **The output pass** blends the UI and the debug layer as in SDR, in sRGB-encoded values relative to paper white, where the scene's highlights are above 1. Then it decodes the result to linear and scales it by paper white. For HDR10, it converts the result from Rec. 709 primaries to Rec. 2020 primaries and encodes it with PQ. For scRGB, it divides by 80 nits, scRGB's 1.
- **A frame whose table is still SDR or HDR** after the mode changes, until the table bakes again, reads the table as it was baked.
- The editor's previews are always SDR. They draw only in shared mode, which is SDR, so the table is SDR for them too.
- *Later:* HDR10 metadata for the swapchain, a UI scale for its brightness separate from the scene's paper white, and a calibration screen for the peak and paper white.
