package cook

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

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
		// The material's own switches (none) and its instances' (use_albedo): two variants of two stages.
		testing.expect_value(t, len(format.material_variants(data, blob)), 4)
		testing.expect(t, format.material_code(data, blob, 1, .Forward, .Pixel) != nil)
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
