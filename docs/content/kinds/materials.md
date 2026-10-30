# Materials

Shading models, materials, material instances and material functions are text files that cook together. This document gives their formats and how the cooker generates and compiles HLSL from them. The renderer's side is in [Rendering](../../rendering/materials.md).

**In this document:** [Materials](#materials) · [Material graphs](#material-graphs)

## Materials

Shading models, materials, material instances and material functions are text files (see [Rendering](../../rendering/materials.md#materials)). `just materials` runs `cook materials` with the shader tools and the roots; the daemon cooks them like any other kind. The four kinds cook together, because each depends on the others.

A **shading model** is a `.shading` file, whose name is the file's, and an `.hlsli` beside it:

```
shading 1
# Lit: metallic and roughness.
input base_color float3 = [0.8, 0.8, 0.8]
input roughness float = 0.5
input normal float3 = [0, 0, 1]
flag no_lighting
```

Inputs are `float` to `float4`, each with its default. A shading model has no blob; it is checked at each pass, and a material whose shading model has errors does not cook. Two shading models of one name, in any roots, are an error.

A **material** is a `.material` file: settings and declarations, then its evaluate, as a graph of nodes (see [Material graphs](#material-graphs)) or in HLSL after a `---` line. The engine's built-in materials are HLSL:

```
material 1
shading = lit
blend = masked
cutoff = 0.5
two_sided = false
cast_shadows = true
param tint color = [1, 1, 1, 1]
param roughness float = 0.5
param albedo texture = white
switch use_albedo = true
---
Surface evaluate(Material_Inputs inputs) {
	Surface s = default_surface();
	s.base_color = params.tint.rgb;
#if use_albedo
	s.base_color *= cn_sample(params.albedo, inputs.uv0).rgb;
#endif
	return s;
}
```

- **Parameters** are `float` to `float4`, `color` (a `float4` that the editor shows as a color) and `texture`: a texture asset's GUID after `$`, or `white`, `black` or `normal` for none. A texture parameter that names an asset of another kind is an error. An indented `group = "<name>"` line after a parameter gives the group that the editor shows it in.
- **Static switches** are `true` or `false`, at most 16. Parameters and switches share one set of names, which are HLSL identifiers.
- **Geometry:** `geometry = mesh` (the default), `patches`, which draws the patches of `Surface_Renderer`s instead of meshes, with the patch vertex path and without the mesh shader path's entries (see [Rendering](../../rendering/surfaces.md#materials-for-patches)), or `billboard` or `billboard_axis`, which turn the mesh to face the camera, wholly or about its +y, with vertex pulling alone (see [Rendering](../../rendering/gpu-scene.md#billboards)), or `ribbon`, which draws particle ribbons instead of meshes, in the transparent passes alone, so its blend is `transparent` or `additive` (see [Rendering](../../rendering/particles.md#ribbons)). The blob has the `Patches` flag, `Billboard`, with `Billboard_Axis` for an axis billboard, or `Ribbon`. The source defines `MATERIAL_BILLBOARD` as 0, 1 for a billboard or 2 for an axis billboard, and `MATERIAL_RIBBON` for a ribbon.
- **Displacement:** a material whose HLSL defines `float3 displace(Vertex_Inputs v)`, or whose graph has a `vertex_output` node, moves its vertices (see [Rendering](../../rendering/materials.md#vertex-displacement)); `displacement_bound = <meters>` (0 by default) is how far, which culling allows for. The blob has the `Displaces` flag.
- **Blends:** `opaque` (the default), `masked` with its `cutoff`, `transparent`, and `additive` (see [Rendering](../../rendering/transparency.md#transparency)). A transparent material takes `transparency = moments` (the default) or `sorted`. A cutoff on a transparent or additive material, or a transparency on another, is an error. Transparent and additive materials cast no shadows, whatever `cast_shadows` says.
- **Variants:** the cooker generates a source for each combination of switches that the material or an instance uses, and compiles the entry points of each pass from it: `vs_forward` and `ps_forward`, `vs_prepass` and `ps_prepass`, and `vs_depth`, with `ps_depth` for a masked material. A transparent or additive material has `ps_transparent` and `ps_transparent_ids` instead, and a transparent one also `ps_moments`, each with `vs_forward`. An opaque or masked material of meshes also has the mesh shader path's entries and the impostor path's, `vs_impostor_forward` with `ps_impostor_forward`, `vs_impostor_prepass` with `ps_impostor_prepass` and `vs_impostor_depth` with `ps_impostor_depth` (see [Rendering](../../rendering/gpu-scene.md#impostors)), and every opaque or masked material that does not draw patches or ribbons has `cs_hit`, the hit pass, which compiles with `MATERIAL_HIT=1` and evaluates the material at ray hits (see [Rendering](../../rendering/ray-scene.md#hit-shading)). The main pass, forward or transparent, compiles first; if it fails, the variant's other passes are not compiled, because they would fail the same way. The source defines the settings and the switches, has the shading model's `Surface`, includes its `.hlsli`, declares `Params` and `static Params params`, then the material's evaluate, then the engine's templates of every pass, `material_passes.hlsli`. HLSL after `---` follows a `#line` that names the material's file, and a graph's code has a `#line` before each node's, so DXC's messages name the material's own lines. The shader tools' `--include` gives the templates' directory, `lib/engine/content/shaders`.
- **Hash-named sources:** a generated source is `<cache>/<config>/generated/<hash>.hlsl`, where the hash covers the source, every file that it includes, DXC and the configuration, and each entry's bytecode is beside it as `<hash>.hlsl.<pass>.<stage>.dxil`. Identical sources, as of two combinations of switches that a graph does not tell apart, compile once in a pass, and a later pass or preview of the same source reads the bytecode instead of compiling. A parameter's value is not in the source, so changing one cooks the blob again without DXC. The cooker never deletes old sources.
- **The parameter block** packs the parameters in order, at 4 bytes, as a raw buffer's `Load<Params>` reads them, in a block of whole 16 bytes. A texture's place holds its bindless index, which the runtime writes.
- **The cache key** covers the cooker version, DXC, the configuration, the path, the `.meta` file, the source file, every variant's generated source (which holds the declarations, the HLSL or the graph's code, and the material functions that the graph calls), and every file that they include.
- **Dependencies:** its shading model, its textures, and the material functions that its graph calls.
- **Reads time:** a material whose HLSL reads the time (`frame.time`, `inputs.time` or `v.time`), or whose graph has a Time node, has the blob flag `Reads_Time`, so the editor's previews draw it every frame.
- **Permutations:** the index gives each material the number of combinations of switches that it and its instances use, which the material editor shows.
- **Tool texture and hotspots:** `tool_texture = $<guid>` names the texture that the editor's texture tools measure a face's texel density by (see [Mesh editing](../../editor/mesh-editing.md#texture-tools)). Without the line, it is the texture that the graph's first Texture Sample node samples, through its parameter, or an HLSL material's first texture parameter, which may be none. `hotspot <x0> <y0> <x1> <y1>` lines, in texels of that texture with `x1` above `x0` and `y1` above `y0`, are the material's hotspot rectangles, each a complete tileable piece that the Hotspot tool maps a face onto. The index carries both, with a texture's cooked size; an instance takes its parent's, except that its own `tool_texture` line replaces the texture, as does its override of the sampled parameter.

A **material instance** is a `.material_instance` file:

```
material_instance 1
parent = $00112233445566778899aabbccddeeff
roughness = 0.9
albedo = $11112222333344445555666677778888
use_albedo = false
tool_texture = $11112222333344445555666677778888
```

- Its parent is a material or another instance. It overrides parameters and switches by name, with the parameter's syntax; a name that its material does not have is an error, and so is a loop of parents.
- Its blob holds its material (through every instance between), its switches, and its parameter block with every value resolved, so the runtime never walks the chain.
- Its switches add a variant to its material, which cooks again. Its key covers the sources of it and every parent.

## Material graphs

A material without a `---` line defines its evaluate with nodes, after its settings and declarations. The editor's material editor writes them (see [Editor](../../editor/material-editor.md#material-editor)), and `tools/cook/graphs.odin` reads them and generates HLSL:

```
material 1
shading = lit
param tint color = [1, 0.5, 0.25, 1]
	group = "Surface"
param albedo texture = $6ae47342be33cfa451b9f6643231fd24
switch shiny = false

node 1 output
	position = [400, 0]
	base_color = @3.out
	roughness = @5.out
	metallic = 0.25
node 2 parameter
	position = [-200, -100]
	name = "tint"
node 3 multiply
	position = [100, 0]
	a = @2.value
	b = @4.rgb
node 4 texture_sample
	position = [-200, 50]
	texture = @6.value
node 5 switch
	position = [100, 200]
	switch = "shiny"
	on = 0.1
	off = 0.6
node 6 parameter
	position = [-400, 50]
	name = "albedo"
```

- **A node** is `node <id> <kind>`, with an ID above 0 that no other node of the graph has, then its indented fields: its `position` in the editor's canvas, its inputs and its properties. A field that the file leaves out has its default.
- **Values:** an input is a link, `@<node>.<output>`, or numbers: one, which fills every component, or an array of up to four. A property is numbers, a quoted string with `\"`, `\\`, `\n` and `\t`, a bare word for a choice, or an asset's GUID after `$`.
- **Types:** inputs and outputs are `float` to `float4` or a texture. An `Any` input takes the widest of its node's `Any` inputs, and so does an `Any` output. A value of another width converts as it flows: a scalar fills every component, a wider value keeps its first components, and a narrower one gets zeros. A texture links only to a texture input, and a texture input must be linked: to a texture parameter, or in a function, to a texture input of the function.
- **The output node:** a material's graph has one `output` node, whose inputs are its shading model's surface inputs. One without a link or a value keeps the shading model's default. It may also have one `vertex_output` node, whose `offset` moves the vertices (see [Rendering](../../rendering/materials.md#vertex-displacement)): the nodes that it reaches generate `displace`, in the vertex stage, where a texture sample takes its first mip, and a node that reads what only a pixel has (the view direction, the face's side, Fresnel, parallax occlusion) is an error.
- **Kinds of node:** the cooker's table in `graphs.odin` is the only list of them, and the cook link sends it to the editor (`Node_Info`). They are inputs (a parameter, constants and colors, UV sets, the vertex color, the world position relative to the render origin, the position in the mesh's own space, the normal, the tangent, the direction to the camera, the time, the face's side), texture samples, normal maps and parallax occlusion (see [Rendering](../../rendering/materials.md#parallax-occlusion-mapping)), math (add to divide, min, max, power, step, lerp, clamp, smoothstep, saturate, one minus, negate, abs, square root, floor, ceil, frac, sin, cos, normalize), vectors (dot, cross, length, distance, split, combine, Fresnel, emission as a color times 2^EV), a static switch, custom HLSL, and material functions with their inputs and outputs.
- **Static switches:** a switch node takes its `on` or its `off` input by one of the material's switches. Each variant generates its source with its switches decided, so it keeps only the branch that it uses, and a graph that does not read a switch generates the same source for both of its values, which compiles once.
- **Custom HLSL:** a custom node's `code` is an expression of its four `float4` inputs `a` to `d` and of `inputs`, the `Material_Inputs`, or a function's body that returns the value, of the width of its `type`. It becomes a function of its own before evaluate, after a `#line` that names its line of the file.
- **Generated code:** evaluate gets a local for each output of each node that the output node reaches, in the order that they need each other, named `n<id>_<output>`. A node that its inputs reach again is a loop, which is an error with its line.
- **Errors** name the material's file and the line of the node, or of its field.

A **material function** is a `.material_function` file: only nodes, which materials call with a `function` node. It has no blob, and is checked at each pass, like a shading model.

```
material_function 1
node 1 function_input
	position = [0, 0]
	name = "power"
	type = float
	default = [3, 0, 0, 0]
node 2 fresnel
	position = [200, 0]
	exponent = @1.value
node 3 function_output
	position = [400, 0]
	name = "rim"
	type = float3
	value = @2.out
```

- Its `function_input` nodes are its inputs, by their names, types and defaults, and its `function_output` nodes its outputs. A call whose input has no link or value gives the input's default.
- It has no parameters, switches or output node. A function that calls itself through its nodes is an error.
- Each material that calls it gets it as a function of its own, `mf<n>`, before evaluate. The material's generated source holds it, so a change to the function cooks the materials that call it again.
