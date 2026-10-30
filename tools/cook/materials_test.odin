package cook

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"

@(private = "file")
material_options :: proc(t: ^testing.T, tree: Tree) -> Cook_Options {
	options := tree_options(tree)
	dxc, err := os.get_absolute_path("vendor/dxc/1.9.2609/dxc.exe", context.temp_allocator)
	testing.expect(t, err == nil)
	version, ok := dxc_version(dxc)
	testing.expectf(t, ok, "no DXC: run just install-dxc")
	options.dxc, options.dxc_version = dxc, version
	options.includes = make([dynamic]string, context.temp_allocator)
	for dir in ([]string{"lib/core/gpu/shaders", "lib/engine/content/shaders"}) {
		absolute, _ := os.get_absolute_path(dir, context.temp_allocator)
		append(&options.includes, forward_slashes(absolute))
	}
	return options
}

// engine_file is a file of the engine's content, for a test tree to hold its shading models.
@(private = "file")
engine_file :: proc(path: string) -> string {
	data, _ := os.read_entire_file(fmt.tprintf("lib/engine/content/%s", path), context.temp_allocator)
	return string(data)
}

@(private = "file")
ROCK :: `material 1
shading = lit
param tint color = [1, 0.5, 0.25, 1]
param roughness float = 0.5
param albedo texture = white
switch use_albedo = false
---
Surface evaluate(Material_Inputs inputs) {
	Surface s = default_surface();
	s.base_color = params.tint.rgb;
#if use_albedo
	s.base_color *= cn_sample(params.albedo, inputs.uv0).rgb;
#endif
	s.roughness = params.roughness;
	return s;
}
`

@(private = "file")
WAVE :: `material 1
# A surface that rises and falls: displace moves each vertex along its normal with the time.
shading = lit
displacement_bound = 0.5
param amplitude float = 0.2
---
Surface evaluate(Material_Inputs inputs) {
	Surface s = default_surface();
	s.base_color = float3(0.3, 0.5, 0.7);
	return s;
}

float3 displace(Vertex_Inputs v) {
	return v.normal * params.amplitude * sin(v.time + world_position(v).x);
}
`

@(test)
displacing_materials_compile_every_pass_and_keep_their_bound :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_file("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_file("shading/lit.hlsli")},
			{"content/wave.material", WAVE},
			{"content/wave.material.meta", "guid = 00112233445566778899aabbccddeeff\n"},
		},
	)
	defer remove_tree(tree)
	options := material_options(t, tree)
	pass := cook(options, {.Material})
	for p in pass.problems.list {
		if p.error {
			testing.expectf(t, false, "%s:%d: %s", p.file, p.line, p.text)
		}
	}
	testing.expect_value(t, pass.cooked[.Material], 1)
	data := tree_blob(t, tree, format.guid_parse("00112233445566778899aabbccddeeff") or_else {})
	blob, ok := format.material_view(data)
	testing.expect(t, ok)
	if ok {
		// The same passes as any opaque material, the mesh shader path's, the impostor path's and the hit pass
		// included, which all but the impostor's and the hit pass place vertices with the displacement.
		testing.expect_value(t, len(format.material_variants(data, blob)), 18)
		testing.expect(t, .Displaces in blob.flags)
		testing.expect(t, .Reads_Time in blob.flags)
		testing.expect_value(t, blob.displacement_bound, 0.5)
	}

	// A bound below 0 is an error, with its line.
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	bad := "material 1\nshading = lit\ndisplacement_bound = -1\n---\nSurface evaluate(Material_Inputs inputs) { return default_surface(); }\n"
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/wave.material", tree.dir), transmute([]byte)bad) == nil)
	testing.expect(t, !cook(options, {.Material}).ok)
	expect_error(t, &errors, "wave.material:3: displacement_bound is a number of meters, 0 or more")
}

@(test)
patch_materials_have_no_mesh_shader_entries :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_file("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_file("shading/lit.hlsli")},
			{"content/ground.material", "material 1\nshading = lit\ngeometry = patches\n---\nSurface evaluate(Material_Inputs inputs) {\n\tSurface s = default_surface();\n\ts.base_color = inputs.uv0.xyx;\n\treturn s;\n}\n\nfloat3 displace(Vertex_Inputs v) {\n\treturn float3(0, sin(v.uv0.x * 6.28) * 0.5, 0);\n}\n"},
			{"content/ground.material.meta", "guid = 00112233445566778899aabbccddeeff\n"},
		},
	)
	defer remove_tree(tree)
	options := material_options(t, tree)
	pass := cook(options, {.Material})
	for p in pass.problems.list {
		if p.error {
			testing.expectf(t, false, "%s:%d: %s", p.file, p.line, p.text)
		}
	}
	testing.expect_value(t, pass.cooked[.Material], 1)
	data := tree_blob(t, tree, format.guid_parse("00112233445566778899aabbccddeeff") or_else {})
	blob, ok := format.material_view(data)
	testing.expect(t, ok)
	if ok {
		// The forward pass's and the prepass's two stages, and the depth pass's vertex stage, from the patch vertex
		// path; no amplification or mesh stages, no impostor passes, and no hit pass, since rays see no patches.
		testing.expect_value(t, len(format.material_variants(data, blob)), 5)
		testing.expect(t, format.material_code(data, blob, 0, .Hit, .Compute) == nil)
		testing.expect(t, .Patches in blob.flags)
		testing.expect(t, .Displaces in blob.flags)
		testing.expect(t, format.material_code(data, blob, 0, .Forward, .Amplification) == nil)
		testing.expect(t, format.material_code(data, blob, 0, .Forward, .Vertex) != nil)
	}

	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	bad := "material 1\nshading = lit\ngeometry = cloth\n---\nSurface evaluate(Material_Inputs inputs) { return default_surface(); }\n"
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/ground.material", tree.dir), transmute([]byte)bad) == nil)
	testing.expect(t, !cook(options, {.Material}).ok)
	expect_error(t, &errors, "ground.material:3: geometry is mesh, patches, billboard, billboard_axis or ribbon")
}

@(test)
materials_cook_a_variant_for_each_switch_set_and_instances_resolve :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_file("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_file("shading/lit.hlsli")},
			{"content/rock.material", ROCK},
			{"content/rock.material.meta", "guid = 00112233445566778899aabbccddeeff\n"},
			{"content/albedo.png.meta", "guid = 11112222333344445555666677778888\n"},
			{"content/albedo.png", ""},
			{"content/mossy.material_instance", "material_instance 1\nparent = $00112233445566778899aabbccddeeff\nroughness = 0.9\nuse_albedo = true\nalbedo = $11112222333344445555666677778888\n"},
			{"content/mossy.material_instance.meta", "guid = 9999aaaabbbbccccddddeeeeffff0000\n"},
			// An instance of an instance.
			{"content/wet.material_instance", "material_instance 1\nparent = $9999aaaabbbbccccddddeeeeffff0000\nroughness = 0.1\n"},
		},
	)
	defer remove_tree(tree)
	options := material_options(t, tree)

	pass := cook(options, {.Material})
	for p in pass.problems.list {
		if p.error {
			testing.expectf(t, false, "%s:%d: %s", p.file, p.line, p.text)
		}
	}
	testing.expect_value(t, pass.cooked[.Material], 1)
	testing.expect_value(t, pass.cooked[.Material_Instance], 2)

	data := tree_blob(t, tree, format.guid_parse("00112233445566778899aabbccddeeff") or_else {})
	blob, ok := format.material_view(data)
	testing.expect(t, ok)
	if ok {
		// The material's own switches (none) and its instances' (use_albedo): two variants, each with the forward
		// pass's and the prepass's two stages, an opaque depth pass's vertex stage, the mesh shader path's
		// amplification and mesh stages of each of the three, the impostor path's two stages of each, and the hit
		// pass's compute stage.
		testing.expect_value(t, len(format.material_variants(data, blob)), 36)
		testing.expect(t, format.material_code(data, blob, 0, .Hit, .Compute) != nil)
		testing.expect(t, format.material_code(data, blob, 1, .Hit, .Compute) != nil)
		testing.expect(t, format.material_code(data, blob, 1, .Forward, .Pixel) != nil)
		testing.expect(t, format.material_code(data, blob, 1, .Prepass, .Pixel) != nil)
		testing.expect(t, format.material_code(data, blob, 0, .Depth, .Vertex) != nil)
		testing.expect(t, format.material_code(data, blob, 0, .Depth, .Pixel) == nil)
		for pass in ([]format.Material_Pass{.Forward, .Prepass, .Depth}) {
			testing.expect(t, format.material_code(data, blob, 1, pass, .Amplification) != nil)
			testing.expect(t, format.material_code(data, blob, 1, pass, .Mesh) != nil)
		}
		testing.expect_value(t, blob.default_switches, 0)
		// tint, roughness, then the albedo's index: 16 + 4 + 4 bytes, in a block of 32.
		testing.expect_value(t, len(format.blob_bytes(data, blob.block)), 32)
		testing.expect_value(t, format.material_textures(data, blob)[0].offset, 20)
	}
	instance := tree_blob(t, tree, tree_guid(t, tree, "wet.material_instance"))
	view, view_ok := format.material_instance_view(instance)
	testing.expect(t, view_ok)
	if view_ok {
		// Through mossy to rock: rock's tint, wet's roughness, mossy's switch and texture.
		testing.expect_value(t, view.material, format.guid_parse("00112233445566778899aabbccddeeff") or_else {})
		testing.expect_value(t, view.switches, 1)
		block := format.blob_bytes(instance, view.block)
		roughness: f32
		mem.copy(&roughness, &block[16], 4)
		testing.expect_value(t, roughness, 0.1)
		tint: [4]f32
		mem.copy(&tint, &block[0], 16)
		testing.expect_value(t, tint, [4]f32{1, 0.5, 0.25, 1})
		testing.expect_value(t, format.instance_textures(instance, view)[0].guid, format.guid_parse("11112222333344445555666677778888") or_else {})
	}
	testing.expect_value(t, cook(options, {.Material}).current[.Material], 1)
}

@(test)
material_errors_name_their_file_and_line :: proc(t: ^testing.T) {
	rock := ROCK
	broken := strings.concatenate({rock[:strings.index(rock, "s.roughness")], "s.roughness = missing;\n\treturn s;\n}\n"}, context.temp_allocator)
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_file("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_file("shading/lit.hlsli")},
			{"content/broken.material", broken},
			{"content/nowhere.material", "material 1\nshading = toon\n---\nSurface evaluate(Material_Inputs inputs) { return default_surface(); }\n"},
			{"content/orphan.material_instance", "material_instance 1\nparent = $ffeeddccbbaa99887766554433221100\n"},
			{"content/typo.material_instance", "material_instance 1\nparent = $00112233445566778899aabbccddeeff\nroughnes = 1\n"},
			{"content/rock.material", ROCK},
			{"content/rock.material.meta", "guid = 00112233445566778899aabbccddeeff\n"},
		},
	)
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook(material_options(t, tree), {.Material}).ok)
	// The #line before evaluate makes DXC name the material's own line.
	expect_error(t, &errors, "broken.material:14:16: use of undeclared identifier 'missing'")
	expect_error(t, &errors, "nowhere.material: no shading model is named toon")
	expect_error(t, &errors, "orphan.material_instance: its parent ffeeddccbbaa99887766554433221100 is not a material or an instance")
	expect_error(t, &errors, "typo.material_instance:3: its material has no parameter or switch named roughnes")
}

@(test)
unlit_materials_skip_the_light :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/unlit.shading", engine_file("shading/unlit.shading")},
			{"content/unlit.hlsli", engine_file("shading/unlit.hlsli")},
			{"content/glow.material", "material 1\nshading = unlit\nparam color color = [2, 1, 0.5, 1]\n---\nSurface evaluate(Material_Inputs inputs) {\n\tSurface s = default_surface();\n\ts.color = params.color.rgb;\n\treturn s;\n}\n"},
		},
	)
	defer remove_tree(tree)
	pass := cook(material_options(t, tree), {.Material})
	testing.expect(t, pass.ok)
	if blob, ok := format.material_view(tree_blob(t, tree, tree_guid(t, tree, "glow.material"))); ok {
		testing.expect(t, .No_Lighting in blob.flags)
	}
}

@(test)
masked_materials_discard_in_their_depth_pass :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_file("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_file("shading/lit.hlsli")},
			{"content/leaf.material", "material 1\nshading = lit\nblend = masked\ncutoff = 0.3\nparam mask texture = white\n---\nSurface evaluate(Material_Inputs inputs) {\n\tSurface s = default_surface();\n\ts.opacity = cn_sample(params.mask, inputs.uv0).a;\n\treturn s;\n}\n"},
		},
	)
	defer remove_tree(tree)
	pass := cook(material_options(t, tree), {.Material})
	testing.expect(t, pass.ok)
	data := tree_blob(t, tree, tree_guid(t, tree, "leaf.material"))
	if blob, ok := format.material_view(data); ok {
		// The shadow maps discard where the opacity is below the cutoff, so the depth pass has a pixel stage too. Rays
		// evaluate it as well, and its hit pass marks the holes.
		testing.expect_value(t, len(format.material_variants(data, blob)), 19)
		testing.expect(t, format.material_code(data, blob, 0, .Hit, .Compute) != nil)
		testing.expect(t, format.material_code(data, blob, 0, .Depth, .Pixel) != nil)
	}
}

@(private = "file")
GLASS_BODY :: "---\nSurface evaluate(Material_Inputs inputs) {\n\tSurface s = default_surface();\n\ts.opacity = 0.4;\n\treturn s;\n}\n"

@(test)
transparent_materials_cook_their_transparent_passes_only :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_file("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_file("shading/lit.hlsli")},
			{"content/glass.material", "material 1\nshading = lit\nblend = transparent\ncast_shadows = true\n" + GLASS_BODY},
			{"content/sorted.material", "material 1\nshading = lit\nblend = transparent\ntransparency = sorted\n" + GLASS_BODY},
			{"content/glow.material", "material 1\nshading = lit\nblend = additive\n" + GLASS_BODY},
		},
	)
	defer remove_tree(tree)
	pass := cook(material_options(t, tree), {.Material})
	testing.expect(t, pass.ok)
	for name in ([]string{"glass.material", "sorted.material", "glow.material"}) {
		data := tree_blob(t, tree, tree_guid(t, tree, name))
		blob, ok := format.material_view(data)
		if !ok {
			continue
		}
		// No prepass, forward or depth pass: a transparent surface is not in the depth, and casts no shadows.
		testing.expect_value(t, format.material_main_pass(blob), format.Material_Pass.Transparent)
		testing.expect(t, format.material_code(data, blob, 0, .Forward, .Vertex) == nil)
		testing.expect(t, format.material_code(data, blob, 0, .Prepass, .Vertex) == nil)
		testing.expect(t, format.material_code(data, blob, 0, .Depth, .Vertex) == nil)
		// Rays pass through no transparent surface, so the fallback shades its hits.
		testing.expect(t, format.material_code(data, blob, 0, .Hit, .Compute) == nil)
		testing.expect(t, format.material_code(data, blob, 0, .Transparent, .Pixel) != nil)
		testing.expect(t, format.material_code(data, blob, 0, .Transparent_Ids, .Pixel) != nil)
		testing.expect(t, .Cast_Shadows not_in blob.flags)
		// An additive material has no moments: it adds light, and takes none away.
		testing.expect_value(t, format.material_code(data, blob, 0, .Moments, .Pixel) != nil, blob.blend == .Transparent)
		testing.expect_value(t, .Sorted in blob.flags, name == "sorted.material")
	}
}

@(test)
transparency_settings_belong_to_their_blends :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_file("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_file("shading/lit.hlsli")},
			{"content/cut.material", "material 1\nshading = lit\nblend = transparent\ncutoff = 0.5\n" + GLASS_BODY},
			{"content/opaque.material", "material 1\nshading = lit\ntransparency = sorted\n" + GLASS_BODY},
			{"content/odd.material", "material 1\nshading = lit\nblend = transparent\ntransparency = layered\n" + GLASS_BODY},
		},
	)
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook(material_options(t, tree), {.Material}).ok)
	expect_error(t, &errors, "cut.material:4: cutoff is for masked materials; a transparent one blends by its opacity")
	expect_error(t, &errors, "opaque.material:3: transparency is for transparent materials")
	expect_error(t, &errors, "odd.material:4: transparency is moments or sorted")
}

@(private = "file")
DEV :: `material 1
shading = lit
param tint color = [1, 1, 1, 1]
param grid texture = $11112222333344445555666677778888
hotspot 0 0 256 256
hotspot 256 0 512 128
node 1 output
	base_color = @3.rgba
node 2 parameter
	name = "grid"
node 3 texture_sample
	texture = @2.value
`

@(test)
tool_textures_and_hotspots_reach_the_index :: proc(t: ^testing.T) {
	rock := ROCK
	lined := strings.concatenate({rock[:strings.index(rock, "---")], "tool_texture = $22223333444455556666777788889999\n", rock[strings.index(rock, "---"):]}, context.temp_allocator)
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_file("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_file("shading/lit.hlsli")},
			{"content/grid.png.meta", "guid = 11112222333344445555666677778888\n"},
			// A graph's tool texture is the first texture sample's, through its parameter.
			{"content/dev.material", DEV},
			{"content/dev.material.meta", "guid = 00112233445566778899aabbccddeeff\n"},
			// An instance that overrides the sampled parameter measures by its own texture, and a tool_texture line names one.
			{"content/swap.material_instance", "material_instance 1\nparent = $00112233445566778899aabbccddeeff\ngrid = $22223333444455556666777788889999\n"},
			{"content/named.material_instance", "material_instance 1\nparent = $00112233445566778899aabbccddeeff\ntool_texture = $33334444555566667777888899990000\n"},
			// An HLSL material without a line measures by its first texture parameter, which rock's leaves at white.
			{"content/rock.material", ROCK},
			{"content/lined.material", lined},
			{"content/bad.material", "material 1\nshading = lit\nhotspot 10 10 5 5\n---\nSurface evaluate(Material_Inputs inputs) { return default_surface(); }\n"},
		},
	)
	defer remove_tree(tree)
	write_test_image(t, tree, "grid.png", 16, 8)
	options := material_options(t, tree)
	pass := cook(options, {.Texture, .Material}, log_problems = false)
	index: Index
	index_build(&index, pass, options.roots[:])
	defer index_destroy(&index)
	entry :: proc(index: ^Index, path: string) -> (a: cook_link.Asset) {
		for _, candidate in index.assets {
			if candidate.path == path {
				return candidate
			}
		}
		return
	}
	dev := entry(&index, "dev.material")
	testing.expect_value(t, dev.tool_texture, "11112222333344445555666677778888")
	testing.expect(t, len(dev.hotspots) == 2 && dev.hotspots[0] == cook_link.Hotspot{0, 0, 256, 256} && dev.hotspots[1] == cook_link.Hotspot{256, 0, 512, 128})
	swap := entry(&index, "swap.material_instance")
	testing.expect_value(t, swap.tool_texture, "22223333444455556666777788889999")
	testing.expect(t, slice.equal(swap.hotspots, dev.hotspots))
	testing.expect_value(t, entry(&index, "named.material_instance").tool_texture, "33334444555566667777888899990000")
	testing.expect_value(t, entry(&index, "rock.material").tool_texture, "")
	testing.expect_value(t, entry(&index, "lined.material").tool_texture, "22223333444455556666777788889999")
	testing.expect_value(t, entry(&index, "grid.png").size, [2]u32{16, 8})
	bad := entry(&index, "bad.material")
	testing.expect_value(t, bad.status, cook_link.Asset_Status.Failed)
	testing.expect(t, bad.errors >= 1)
	// A pass that changes nothing keeps the entries equal, so the editor hears no delta.
	again: Index
	index_build(&again, cook(options, {.Texture, .Material}, log_problems = false), options.roots[:])
	defer index_destroy(&again)
	testing.expect(t, !index_changed(index_diff(&index, &again)))
}

// A ribbon material draws particle ribbons with its transparent passes only, and an opaque one is an error.
@(test)
ribbon_materials_draw_ribbons :: proc(t: ^testing.T) {
	evaluate := "---\nSurface evaluate(Material_Inputs inputs) {\n\tSurface s = default_surface();\n\ts.base_color = inputs.color.rgb;\n\ts.opacity = inputs.color.a;\n\treturn s;\n}\n"
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_file("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_file("shading/lit.hlsli")},
			{"content/trail.material", fmt.tprintf("material 1\nshading = lit\nblend = transparent\ngeometry = ribbon\n%s", evaluate)},
			{"content/trail.material.meta", "guid = 00112233445566778899aabbccddeeff\n"},
		},
	)
	defer remove_tree(tree)
	options := material_options(t, tree)
	pass := cook(options, {.Material})
	testing.expectf(t, pass.ok, "problems: %v", pass.problems.list)
	data := tree_blob(t, tree, format.guid_parse("00112233445566778899aabbccddeeff") or_else {})
	blob, ok := format.material_view(data)
	testing.expect(t, ok)
	if ok {
		testing.expect(t, .Ribbon in blob.flags)
		testing.expect(t, format.material_code(data, blob, 0, .Hit, .Compute) == nil)
		// The transparent pass, the IDs' and the moments, each a vertex and a pixel stage.
		testing.expect_value(t, len(format.material_variants(data, blob)), 6)
		testing.expect(t, format.material_code(data, blob, 0, .Moments, .Vertex) != nil)
	}

	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	opaque := fmt.tprintf("material 1\nshading = lit\ngeometry = ribbon\n%s", evaluate)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/trail.material", tree.dir), transmute([]byte)opaque) == nil)
	testing.expect(t, !cook(options, {.Material}).ok)
	expect_error(t, &errors, "trail.material:3: a ribbon material's blend is transparent or additive")
}

// A billboard draws its meshes with vertex pulling only: the opaque passes' stages, without the mesh shader path's or
// the impostor path's. An axis billboard is a billboard too.
@(test)
billboard_materials_pull_their_vertices :: proc(t: ^testing.T) {
	evaluate := "---\nSurface evaluate(Material_Inputs inputs) {\n\tSurface s = default_surface();\n\ts.base_color = inputs.uv0.xyx;\n\treturn s;\n}\n"
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_file("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_file("shading/lit.hlsli")},
			{"content/card.material", fmt.tprintf("material 1\nshading = lit\ngeometry = billboard\n%s", evaluate)},
			{"content/card.material.meta", "guid = 00112233445566778899aabbccddeeff\n"},
			{"content/tree.material", fmt.tprintf("material 1\nshading = lit\nblend = masked\ngeometry = billboard_axis\n%s", evaluate)},
			{"content/tree.material.meta", "guid = 00112233445566778899aabbccddee00\n"},
		},
	)
	defer remove_tree(tree)
	options := material_options(t, tree)
	pass := cook(options, {.Material})
	for p in pass.problems.list {
		if p.error {
			testing.expectf(t, false, "%s:%d: %s", p.file, p.line, p.text)
		}
	}
	testing.expect_value(t, pass.cooked[.Material], 2)
	cases := []struct {
		guid:     string,
		flags:    format.Material_Flags,
		variants: int,
	}{{"00112233445566778899aabbccddeeff", {.Billboard}, 6}, {"00112233445566778899aabbccddee00", {.Billboard, .Billboard_Axis}, 7}}
	for c in cases {
		data := tree_blob(t, tree, format.guid_parse(c.guid) or_else {})
		blob, ok := format.material_view(data)
		testing.expect(t, ok)
		if !ok {
			continue
		}
		testing.expect_value(t, len(format.material_variants(data, blob)), c.variants)
		testing.expect_value(t, blob.flags & {.Billboard, .Billboard_Axis}, c.flags)
		testing.expect(t, format.material_code(data, blob, 0, .Forward, .Mesh) == nil)
		testing.expect(t, format.material_code(data, blob, 0, .Impostor_Forward, .Vertex) == nil)
		// Rays see the billboard's mesh as authored, unturned.
		testing.expect(t, format.material_code(data, blob, 0, .Hit, .Compute) != nil)
	}
}
