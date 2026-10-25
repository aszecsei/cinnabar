package cook

import "core:fmt"
import "core:os"
import "core:testing"

import format "cinnabar:engine/asset/format"

// The DXC release that `just install-dxc` puts in vendor/dxc. The tests run from the repository's root.
@(private = "file")
TEST_DXC :: "vendor/dxc/1.9.2609/dxc.exe"

@(private = "file")
shader_options :: proc(t: ^testing.T, tree: Tree) -> Cook_Options {
	options := tree_options(tree)
	dxc, err := os.get_absolute_path(TEST_DXC, context.temp_allocator)
	testing.expect(t, err == nil)
	version, ok := dxc_version(dxc)
	testing.expectf(t, ok, "no DXC at %s: run just install-dxc", TEST_DXC)
	options.dxc, options.dxc_version = dxc, version
	options.includes = make([dynamic]string, context.temp_allocator)
	include, _ := os.get_absolute_path("lib/core/gpu/shaders", context.temp_allocator)
	append(&options.includes, forward_slashes(include))
	return options
}

@(private = "file")
SHADER_SOURCE :: `#include "cinnabar.hlsli"
#include "color.hlsli"

float4 vs_main(uint id : SV_VertexID) : SV_Position { return float4(0, 0, 0, 1); }
float4 ps_main() : SV_Target { return COLOR; }
`

@(test)
shaders_cook_into_one_blob_with_a_stage_each :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/flat.hlsl", SHADER_SOURCE}, {"content/color.hlsli", "#define COLOR float4(1, 0, 0, 1)\n"}})
	defer remove_tree(tree)
	options := shader_options(t, tree)

	pass := cook(options, {.Shader})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Shader], 1)
	// An include is not an asset, so it has no .meta file.
	testing.expect(t, !os.exists(fmt.tprintf("%s/content/color.hlsli.meta", tree.dir)))

	guid := tree_guid(t, tree, "flat.hlsl")
	data := tree_blob(t, tree, guid)
	blob, ok := format.shader_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, format.shader_stages(data, blob), format.Shader_Stages{.Vertex, .Pixel})
	testing.expect_value(t, format.blob_string(data, blob.source_path), "game/flat.hlsl")
	// DXIL starts with a DXBC container.
	testing.expect_value(t, string(format.shader_code(data, blob, .Pixel)[:4]), "DXBC")

	testing.expect_value(t, cook(options, {.Shader}).current[.Shader], 1)
	// A change to an include cooks the shader again.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/color.hlsli", tree.dir), transmute([]byte)string("#define COLOR float4(0, 1, 0, 1)\n")) == nil)
	testing.expect_value(t, cook(options, {.Shader}).cooked[.Shader], 1)
}

@(test)
a_broken_shader_keeps_its_blob_and_reports_the_line :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/flat.hlsl", SHADER_SOURCE}, {"content/color.hlsli", "#define COLOR float4(1, 0, 0, 1)\n"}})
	defer remove_tree(tree)
	options := shader_options(t, tree)
	testing.expect(t, cook(options, {.Shader}).ok)
	guid := tree_guid(t, tree, "flat.hlsl")
	before := tree_blob(t, tree, guid)

	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	broken := "#include \"cinnabar.hlsli\"\nfloat4 ps_main() : SV_Target {\n\treturn missing;\n}\n"
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/flat.hlsl", tree.dir), transmute([]byte)broken) == nil)
	pass := cook(options, {.Shader})
	testing.expect(t, !pass.ok)
	expect_error(t, &errors, "flat.hlsl:3:9: use of undeclared identifier 'missing'")
	testing.expect_value(t, string(tree_blob(t, tree, guid)), string(before))

	// An error in an include belongs to the include's file, and the shader says why it did not cook.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/flat.hlsl", tree.dir), transmute([]byte)string(SHADER_SOURCE)) == nil)
	broken_include := "#define COLOR float4(1, 0, 0, 1)\nstatic const float bad = ;\n"
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/color.hlsli", tree.dir), transmute([]byte)broken_include) == nil)
	testing.expect(t, !cook(options, {.Shader}).ok)
	expect_error(t, &errors, "flat.hlsl: vs_6_6 did not compile, because a file that it includes has errors")
}

@(test)
shaders_without_dxc_do_not_cook :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/flat.hlsl", SHADER_SOURCE}})
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook(tree_options(tree), {.Shader}).ok)
	expect_error(t, &errors, "the cooker has no --dxc")
}
