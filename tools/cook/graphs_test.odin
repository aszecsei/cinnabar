package cook

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
graph_options :: proc(t: ^testing.T, tree: Tree) -> Cook_Options {
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

@(private = "file")
engine_text :: proc(path: string) -> string {
	data, _ := os.read_entire_file(fmt.tprintf("lib/engine/content/%s", path), context.temp_allocator)
	return string(data)
}

@(private = "file")
expect_no_errors :: proc(t: ^testing.T, pass: Pass) {
	for p in pass.problems.list {
		if p.error {
			testing.expectf(t, false, "%s:%d: %s", p.file, p.line, p.text)
		}
	}
}

// generated reads the generated sources of the cache, for what a graph became.
@(private = "file")
generated :: proc(tree: Tree) -> string {
	b := strings.builder_make(context.temp_allocator)
	dir := fmt.tprintf("%s/cache/dev/generated", tree.dir)
	infos, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for info in infos {
		if strings.has_suffix(info.name, ".hlsl") {
			data, _ := os.read_entire_file(info.fullpath, context.temp_allocator)
			strings.write_string(&b, string(data))
		}
	}
	return strings.to_string(b)
}

@(private = "file")
count_generated :: proc(tree: Tree, suffix: string) -> (count: int) {
	infos, _ := os.read_all_directory_by_path(fmt.tprintf("%s/cache/dev/generated", tree.dir), context.temp_allocator)
	for info in infos {
		count += int(strings.has_suffix(info.name, suffix))
	}
	return
}

@(private = "file")
TINTED :: `material 1
# A texture under a tint, rough where the switch says.
shading = lit
param tint color = [1, 0.5, 0.25, 1]
	group = "Surface"
param albedo texture = white
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
	uv = @7.uv
node 5 switch
	position = [100, 200]
	switch = "shiny"
	on = 0.1
	off = @8.out
node 6 parameter
	position = [-400, 50]
	name = "albedo"
node 7 uv
	position = [-400, 150]
	set = 1
node 8 lerp
	position = [-100, 250]
	a = 0.6
	b = 0.9
	t = @9.time
node 9 time
	position = [-300, 300]
`

@(test)
graphs_generate_evaluate_and_switches_keep_one_branch :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_text("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_text("shading/lit.hlsli")},
			{"content/tinted.material", TINTED},
			{"content/tinted.material.meta", "guid = 00112233445566778899aabbccddeeff\n"},
			{"content/shiny.material_instance", "material_instance 1\nparent = $00112233445566778899aabbccddeeff\nshiny = true\n"},
		},
	)
	defer remove_tree(tree)
	options := graph_options(t, tree)
	pass := cook(options, {.Material})
	expect_no_errors(t, pass)
	testing.expect_value(t, pass.cooked[.Material], 1)
	for a in pass.assets {
		if a.kind == .Material {
			testing.expect_value(t, a.permutations, 2)
		}
	}
	data := tree_blob(t, tree, format.guid_parse("00112233445566778899aabbccddeeff") or_else {})
	blob, ok := format.material_view(data)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, len(format.material_variants(data, blob)), 10)
		// The off branch reads the time, so the material does too.
		testing.expect(t, .Reads_Time in blob.flags)
	}
	source := generated(tree)
	// Any inputs take the widest, so the float3 gets a zero, and the float4 fits base_color, a float3, by its first
	// three components.
	testing.expect(t, strings.contains(source, "float4 n2_value = params.tint;"))
	testing.expect(t, strings.contains(source, "float2 n7_uv = inputs.uv1;"))
	testing.expect(t, strings.contains(source, "float4 n4_rgba = cn_sample((n6_value), (n7_uv));"))
	testing.expect(t, strings.contains(source, "float4 n3_out = (n2_value) * (float4(n4_rgb, 0.0));"))
	testing.expect(t, strings.contains(source, "s.base_color = (n3_out).xyz;"))
	testing.expect(t, strings.contains(source, "s.metallic = 0.25;"))
	// The switch on: its on branch, and nothing of the lerp. Off: the lerp.
	testing.expect(t, strings.contains(source, "float n5_out = 0.1;"))
	testing.expect(t, strings.contains(source, "float n5_out = n8_out;"))
	testing.expect_value(t, strings.count(source, "float n8_out ="), 1)
	// Each node's HLSL has its line, so DXC's messages name the node.
	testing.expect(t, strings.contains(source, fmt.tprintf("#line 14 \"%s/content/tinted.material\"", tree.dir)))
}

@(test)
graph_sources_compile_once_and_keep_their_bytecode :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/shading/lit.shading", engine_text("shading/lit.shading")}, {"content/shading/lit.hlsli", engine_text("shading/lit.hlsli")}, {"content/tinted.material", TINTED}})
	defer remove_tree(tree)
	options := graph_options(t, tree)
	expect_no_errors(t, cook(options, {.Material}))
	sources := count_generated(tree, ".hlsl")
	testing.expect_value(t, sources, 1)
	// A parameter's value is not in the source, so a new tint cooks the blob again from the same bytecode.
	path := fmt.tprintf("%s/content/tinted.material", tree.dir)
	tinted := TINTED
	changed, _ := strings.replace(tinted, "[1, 0.5, 0.25, 1]", "[0, 1, 0, 1]", 1, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)changed) == nil)
	pass := cook(options, {.Material})
	expect_no_errors(t, pass)
	testing.expect_value(t, pass.cooked[.Material], 1)
	testing.expect_value(t, count_generated(tree, ".hlsl"), sources)
}

@(private = "file")
FRESNEL_FUNCTION :: `material_function 1
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
`

@(test)
graphs_call_material_functions :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_text("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_text("shading/lit.hlsli")},
			{"content/rim.material_function", FRESNEL_FUNCTION},
			{"content/rim.material_function.meta", "guid = 11112222333344445555666677778888\n"},
			{
				"content/glow.material",
				"material 1\nshading = lit\nnode 1 output\n\temission = @2.rim\nnode 2 function\n\tfunction = $11112222333344445555666677778888\nnode 3 custom\n\ttype = float\n\tcode = \"float x = a.x * 2; return x;\"\n\ta = 0.5\nnode 4 output_unused_comment\n",
			},
		},
	)
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	// An unknown kind of node is an error, with its line.
	testing.expect(t, !cook(graph_options(t, tree), {.Material}).ok)
	expect_error(t, &errors, "glow.material:11: there is no kind of node named output_unused_comment")

	glow := "material 1\nshading = lit\nnode 1 output\n\temission = @2.rim\n\troughness = @3.out\nnode 2 function\n\tfunction = $11112222333344445555666677778888\nnode 3 custom\n\ttype = float\n\tcode = \"float x = a.x * 2; return x;\"\n\ta = 0.25\n"
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/glow.material", tree.dir), transmute([]byte)glow) == nil)
	pass := cook(graph_options(t, tree), {.Material})
	expect_no_errors(t, pass)
	source := generated(tree)
	testing.expect(t, strings.contains(source, "void mf0(float in_power, Material_Inputs inputs, out float3 out_rim) {"))
	testing.expect(t, strings.contains(source, "\tout_rim = ((float3)n2_out);"))
	// An unlinked input gives the function's default.
	testing.expect(t, strings.contains(source, "\tmf0(3.0, inputs, n2_rim);"))
	// A custom node's code is on a line of its own, after the line of its file.
	testing.expect(t, strings.contains(source, "float custom3(float4 a, float4 b, float4 c, float4 d, Material_Inputs inputs) {\n#line 10"))
	testing.expect(t, strings.contains(source, "\nfloat x = a.x * 2; return x;\n}"))
	for a in pass.assets {
		if a.kind == .Material {
			// The material depends on its function and its shading model.
			testing.expect_value(t, len(a.dependencies), 2)
		}
	}
}

@(test)
graph_errors_name_their_nodes :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_text("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_text("shading/lit.hlsli")},
			{"content/loop.material", "material 1\nshading = lit\nnode 1 output\n\troughness = @2.out\nnode 2 add\n\ta = @3.out\nnode 3 saturate\n\tx = @2.out\n"},
			{"content/types.material", "material 1\nshading = lit\nparam albedo texture = white\nnode 1 output\n\tbase_color = @2.value\nnode 2 parameter\n\tname = \"albedo\"\n"},
			{"content/names.material", "material 1\nshading = lit\nnode 1 output\n\tshininess = 1\n\tbase_color = @2.nope\nnode 2 uv\n"},
			{"content/hlsl.material", "material 1\nshading = lit\nnode 1 output\n\troughness = @2.out\nnode 2 custom\n\ttype = float\n\tcode = \"missing.x\"\n"},
			{"content/both.material", "material 1\nshading = lit\nnode 1 output\n---\nSurface evaluate(Material_Inputs inputs) { return default_surface(); }\n"},
			{"content/scope.material", "material 1\nshading = lit\nnode 1 output\nnode 2 function_input\n"},
		},
	)
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook(graph_options(t, tree), {.Material}).ok)
	expect_error(t, &errors, "loop.material:5: node 2 links back to itself through its inputs")
	expect_error(t, &errors, "types.material:4: the output node's base_color input takes numbers, not a texture")
	expect_error(t, &errors, "names.material:4: the shading model lit has no input named shininess")
	expect_error(t, &errors, "names.material:5: node 2 has no output named nope")
	expect_error(t, &errors, "hlsl.material:7:8: use of undeclared identifier 'missing'")
	expect_error(t, &errors, "both.material: a material defines evaluate")
	expect_error(t, &errors, "both.material: a material defines evaluate with nodes or in HLSL after a `---` line, not both")
	expect_error(t, &errors, "scope.material:4: a function_input node is only in a material function")
}

@(test)
previews_cook_unsaved_text_into_the_preview_area :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{{"content/shading/lit.shading", engine_text("shading/lit.shading")}, {"content/shading/lit.hlsli", engine_text("shading/lit.hlsli")}, {"content/tinted.material", TINTED}, {"content/tinted.material.meta", "guid = 00112233445566778899aabbccddeeff\n"}},
	)
	defer remove_tree(tree)
	options := graph_options(t, tree)
	guid := format.guid_parse("00112233445566778899aabbccddeeff") or_else {}
	tinted := TINTED
	unsaved, _ := strings.replace(tinted, "metallic = 0.25", "metallic = 1", 1, context.temp_allocator)
	problems, ok := cook_preview(options, guid, unsaved)
	testing.expect(t, ok)
	testing.expect_value(t, len(problems.list), 0)
	data, err := os.read_entire_file(fmt.tprintf("%s/cache/dev/preview/00112233445566778899aabbccddeeff.blob", tree.dir), context.temp_allocator)
	testing.expect(t, err == nil)
	if blob, view_ok := format.material_view(data); view_ok {
		// The default switches only.
		testing.expect_value(t, len(format.material_variants(data, blob)), 5)
	}
	// The material's own blob is not cooked by a preview.
	testing.expect(t, !os.exists(fmt.tprintf("%s/cache/dev/00112233445566778899aabbccddeeff.blob", tree.dir)))
	broken, _ := strings.replace(tinted, "name = \"tint\"", "name = \"tnit\"", 1, context.temp_allocator)
	problems, ok = cook_preview(options, guid, broken)
	testing.expect(t, !ok)
	testing.expect_value(t, len(problems.list), 1)
	if len(problems.list) == 1 {
		testing.expect_value(t, problems.list[0].line, 16)
		testing.expect_value(t, problems.list[0].text, "the material has no parameter named tnit")
	}
}

@(test)
position_nodes_read_the_world_and_the_object :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/shading/lit.shading", engine_text("shading/lit.shading")},
			{"content/shading/lit.hlsli", engine_text("shading/lit.hlsli")},
			{"content/stripes.material", "material 1\nshading = lit\nnode 1 output\n\tbase_color = @4.out\nnode 2 position\nnode 3 object_position\nnode 4 add\n\ta = @2.position\n\tb = @3.position\n"},
		},
	)
	defer remove_tree(tree)
	expect_no_errors(t, cook(graph_options(t, tree), {.Material}))
	source := generated(tree)
	// The world position is relative to the render origin, not the camera, so it stays put while the camera moves.
	testing.expect(t, strings.contains(source, "float3 n2_position = world_position(inputs);"))
	testing.expect(t, strings.contains(source, "float3 n3_position = inputs.object_position;"))
}
