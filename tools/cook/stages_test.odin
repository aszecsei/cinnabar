package cook

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

// A stage in centimeters, as Sponza is: a panel of a quad and a triangle, whose faces two GeomSubsets bind to two
// materials, one of them translucent, under an Xform that moves it.
@(private = "file")
PANEL_STAGE :: `#usda 1.0
(
    upAxis = "UP_AXIS"
    metersPerUnit = 0.01
    defaultPrim = "root"
)

def Xform "root"
{
    def Xform "shelf"
    {
        double3 xformOp:translate = (0, 0, 300)
        uniform token[] xformOpOrder = ["xformOp:translate"]

        def Mesh "panel" (
            prepend apiSchemas = ["MaterialBindingAPI"]
        )
        {
            int[] faceVertexCounts = [4, 3]
            int[] faceVertexIndices = [0, 1, 2, 3, 3, 2, 4]
            point3f[] points = [POINTS]
            uniform token subsetFamily:materialBind:familyType = "partition"

            def GeomSubset "stone_faces" (
                prepend apiSchemas = ["MaterialBindingAPI"]
            )
            {
                uniform token elementType = "face"
                uniform token familyName = "materialBind"
                int[] indices = [0]
                rel material:binding = </root/mtl/stone>
            }

            def GeomSubset "glass_faces" (
                prepend apiSchemas = ["MaterialBindingAPI"]
            )
            {
                uniform token elementType = "face"
                uniform token familyName = "materialBind"
                int[] indices = [1]
                rel material:binding = </root/mtl/glass>
            }
        }
    }

    def Scope "mtl"
    {
        def Material "stone"
        {
            token outputs:surface.connect = </root/mtl/stone/surface.outputs:surface>

            def Shader "surface"
            {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (0.5, 0.4, 0.3)
                float inputs:roughness = 0.7
                token outputs:surface
            }
        }

        def Material "glass"
        {
            token outputs:surface.connect = </root/mtl/glass/surface.outputs:surface>

            def Shader "surface"
            {
                uniform token info:id = "UsdPreviewSurface"
                float inputs:opacity = 0.3
                token outputs:surface
            }
        }
    }
}
`

// The panel's points, 1 m wide and 2 m tall, standing on the stage's up axis.
@(private = "file")
Y_UP_POINTS :: "(0, 0, 0), (100, 0, 0), (100, 100, 0), (0, 100, 0), (50, 200, 0)"
@(private = "file")
Z_UP_POINTS :: "(0, 0, 0), (100, 0, 0), (100, 0, 100), (0, 0, 100), (50, 0, 200)"

// panel_stage is PANEL_STAGE with its up axis and points. fmt would read the stage's braces as its own.
@(private = "file")
panel_stage :: proc(up, points: string) -> string {
	text, _ := strings.replace_all(PANEL_STAGE, "UP_AXIS", up, context.temp_allocator)
	text, _ = strings.replace_all(text, "POINTS", points, context.temp_allocator)
	return text
}

@(private = "file")
stage_mesh :: proc(t: ^testing.T, tree: Tree, meta: format.Meta, name: string) -> (data: []byte, blob: ^format.Mesh_Blob, ok: bool) {
	guid, found := format.meta_subasset(meta, format.MESH_KIND, name)
	testing.expectf(t, found, "the stage has no mesh %s", name)
	if !found {
		return
	}
	data = tree_blob(t, tree, guid)
	blob, ok = format.mesh_view(data)
	testing.expectf(t, ok, "%s did not cook into a mesh blob", name)
	return
}

@(private = "file")
stage_meta :: proc(t: ^testing.T, tree: Tree, path: string) -> format.Meta {
	text, err := os.read_entire_file(fmt.tprintf("%s/content/%s.meta", tree.dir, path), context.temp_allocator)
	testing.expect(t, err == nil)
	meta, ok := format.meta_parse(string(text), context.temp_allocator)
	testing.expect(t, ok)
	return meta
}

@(test)
a_stage_makes_meshes_material_instances_and_a_prefab :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/panel.usda", panel_stage("Y", Y_UP_POINTS)}})
	defer remove_tree(tree)
	options := tree_options(tree)

	pass := cook(options, {.Stage})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Stage], 1)
	testing.expect_value(t, pass.cooked[.Mesh], 1)
	meta := stage_meta(t, tree, "panel.usda")
	_, stone := format.meta_subasset(meta, format.MATERIAL_INSTANCE_KIND, "root/mtl/stone")
	_, glass := format.meta_subasset(meta, format.MATERIAL_INSTANCE_KIND, "root/mtl/glass")
	_, prefab := format.meta_subasset(meta, format.PREFAB_KIND, "stage")
	testing.expect(t, stone && glass && prefab)

	data, blob, ok := stage_mesh(t, tree, meta, "root/shelf/panel")
	if !ok {
		return
	}
	// The subsets are submeshes in name order, and the quad is two triangles.
	submeshes := format.mesh_submeshes(data, blob)
	testing.expect_value(t, len(submeshes), 2)
	if len(submeshes) == 2 {
		testing.expect_value(t, format.blob_string(data, submeshes[0].name), "glass_faces")
		testing.expect_value(t, submeshes[0].index_count, 3)
		testing.expect_value(t, format.blob_string(data, submeshes[1].name), "stone_faces")
		testing.expect_value(t, submeshes[1].index_count, 6)
	}
	// In meters, with x mirrored into the engine's axes. The Xform's move is the prefab's, not the mesh's.
	testing.expect_value(t, blob.bounds.min, [3]f32{-1, 0, 0})
	testing.expect_value(t, blob.bounds.max, [3]f32{0, 2, 0})

	// The generated texts cooked with the stage's passes: the translucent material is a transparent instance, and the
	// prefab places the panel 3 m along +z.
	again := cook(options, {.Stage, .Scene})
	testing.expect_value(t, again.current[.Stage], 1)
	testing.expect_value(t, again.cooked[.Mesh], 0)
	instance_text := ""
	prefab_text := ""
	for a in again.assets {
		if a.owner == {} {
			continue
		}
		if a.kind == .Material_Instance && strings.contains(string(a.source), "/root/mtl/glass") {
			instance_text = string(a.source)
		}
		if a.kind == .Prefab {
			prefab_text = string(a.source)
		}
	}
	transparent, _ := format.meta_parse(#load("../../lib/engine/content/materials/preview_surface_transparent.material.meta", string), context.temp_allocator)
	testing.expectf(t, strings.contains(instance_text, fmt.tprintf("parent = $%s", guid_text(transparent.guid))), "the glass is not transparent: %s", instance_text)
	testing.expect(t, strings.contains(instance_text, "opacity = 0.3"))
	testing.expectf(t, strings.contains(prefab_text, "offset = [0.0, 0.0, 3.0]"), "the panel is not 3 m along z: %s", prefab_text)
	testing.expect_value(t, again.cooked[.Prefab], 1)
}

@(test)
z_up_stages_turn_to_y_up :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/panel.usda", panel_stage("Z", Z_UP_POINTS)}})
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Stage})
	testing.expect(t, pass.ok)
	_, blob, ok := stage_mesh(t, tree, stage_meta(t, tree, "panel.usda"), "root/shelf/panel")
	if !ok {
		return
	}
	// The same panel as the Y-up stage's, standing 2 m tall on +y.
	testing.expect_value(t, blob.bounds.min, [3]f32{-1, 0, 0})
	testing.expect_value(t, blob.bounds.max, [3]f32{0, 2, 0})
}

@(test)
a_mesh_of_more_subsets_than_slots_is_split_into_parts :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "#usda 1.0\n(\n    upAxis = \"Y\"\n    metersPerUnit = 1\n)\n\ndef Mesh \"strip\"\n{")
	counts := make([]string, 10, context.temp_allocator)
	indices := make([]string, 30, context.temp_allocator)
	points := make([]string, 30, context.temp_allocator)
	for i in 0 ..< 10 {
		counts[i] = "3"
		for k in 0 ..< 3 {
			indices[i * 3 + k] = fmt.tprintf("%d", i * 3 + k)
		}
		points[i * 3] = fmt.tprintf("(%d, 0, 0)", i)
		points[i * 3 + 1] = fmt.tprintf("(%d, 0, 0)", i + 1)
		points[i * 3 + 2] = fmt.tprintf("(%d, 1, 0)", i)
	}
	fmt.sbprintfln(&b, "    int[] faceVertexCounts = [%s]", strings.join(counts, ", ", context.temp_allocator))
	fmt.sbprintfln(&b, "    int[] faceVertexIndices = [%s]", strings.join(indices, ", ", context.temp_allocator))
	fmt.sbprintfln(&b, "    point3f[] points = [%s]", strings.join(points, ", ", context.temp_allocator))
	for i in 0 ..< 10 {
		fmt.sbprintfln(&b, "    def GeomSubset \"s%d\" (\n        prepend apiSchemas = [\"MaterialBindingAPI\"]\n    )\n    {{", i)
		fmt.sbprintln(&b, "        uniform token elementType = \"face\"\n        uniform token familyName = \"materialBind\"")
		fmt.sbprintfln(&b, "        int[] indices = [%d]\n        rel material:binding = </m%d>\n    }}", i, i)
	}
	fmt.sbprintln(&b, "}")
	for i in 0 ..< 10 {
		fmt.sbprintfln(&b, "def Material \"m%d\"\n{{\n    token outputs:surface.connect = </m%d/s.outputs:surface>\n    def Shader \"s\"\n    {{\n        uniform token info:id = \"UsdPreviewSurface\"\n        token outputs:surface\n    }}\n}}", i, i)
	}
	tree := make_tree(t, {{"content/strip.usda", strings.to_string(b)}})
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Stage})
	testing.expect(t, pass.ok)
	meta := stage_meta(t, tree, "strip.usda")
	first_data, first, first_ok := stage_mesh(t, tree, meta, "strip#1")
	second_data, second, second_ok := stage_mesh(t, tree, meta, "strip#2")
	if !first_ok || !second_ok {
		return
	}
	testing.expect_value(t, len(format.mesh_submeshes(first_data, first)), STAGE_MAX_SLOTS)
	testing.expect_value(t, len(format.mesh_submeshes(second_data, second)), 2)
}

// Sponza's materials, as 3ds Max writes them: a texture's reader takes its primvar's name from an input of the
// NodeGraph that holds it, which the material references, and metallic reads a texture's rgb.
@(private = "file")
NODE_GRAPH_STAGE :: `#usda 1.0
(
    upAxis = "Y"
    metersPerUnit = 1
)

def Mesh "tile" (
    prepend apiSchemas = ["MaterialBindingAPI"]
)
{
    int[] faceVertexCounts = [3]
    int[] faceVertexIndices = [0, 1, 2]
    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
    texCoord2f[] primvars:st = [(0, 0), (1, 0), (0, 1)] (
        interpolation = "vertex"
    )
    rel material:binding = </mtl/metal>
}

def Scope "mtl"
{
    def Material "metal"
    {
        token outputs:surface.connect = </mtl/metal/surface.outputs:surface>

        def Shader "surface"
        {
            uniform token info:id = "UsdPreviewSurface"
            float inputs:metallic.connect = </mtl/metal/metalness.outputs:rgb>
            token outputs:surface
        }

        def NodeGraph "metalness" (
            prepend references = </mtl/metalness_graph>
        )
        {
        }
    }

    def NodeGraph "metalness_graph"
    {
        token inputs:frame:st = "st"
        float3 outputs:rgb.connect = </mtl/metalness_graph/texture.outputs:rgb>

        def Shader "texture"
        {
            uniform token info:id = "UsdUVTexture"
            asset inputs:file = @.downloads\metal.png@
            float2 inputs:st.connect = </mtl/metalness_graph/reader.outputs:result>
            float3 outputs:rgb
        }

        def Shader "reader"
        {
            uniform token info:id = "UsdPrimvarReader_float2"
            token inputs:varname.connect = </mtl/metalness_graph.inputs:frame:st>
            float2 outputs:result
        }
    }
}
`

@(test)
a_texture_through_a_node_graph_is_a_mask_of_its_red :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/tile.usda", NODE_GRAPH_STAGE}})
	defer remove_tree(tree)
	// In a folder whose name starts with a dot, as a sample's downloads are, which the scan skips.
	os.make_directory_all(fmt.tprintf("%s/content/.downloads", tree.dir))
	write_test_image(t, tree, ".downloads/metal.png", 8, 8)
	pass := cook(tree_options(tree), {.Stage})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Texture], 1)
	meta := stage_meta(t, tree, "tile.usda")
	guid, found := format.meta_subasset(meta, format.TEXTURE_KIND, ".downloads/metal.png@mask.r")
	testing.expectf(t, found, "no texture sub-asset: %v", meta.subassets)
	if !found {
		return
	}
	blob, ok := format.texture_view(tree_blob(t, tree, guid))
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, blob.usage, format.Texture_Usage.Mask)
	}
	// The image is not an asset of its own: the texture's GUID is the stage's.
	_, err := os.stat(fmt.tprintf("%s/content/.downloads/metal.png.meta", tree.dir), context.temp_allocator)
	testing.expect(t, err != nil)
	instance := ""
	for a in pass.assets {
		if a.kind == .Material_Instance && a.owner != {} {
			instance = string(a.source)
		}
	}
	testing.expectf(t, strings.contains(instance, fmt.tprintf("metallic_tex = $%s", guid_text(guid))), "the metallic texture is not set: %s", instance)
	testing.expect(t, strings.contains(instance, "has_metallic_tex = true"))
}

// A stage in centimeters with two point instancers, each with its own copy of the same prototype, as Jungle Ruins tiles
// its forests, and a ground that is a prim of its own. The second instancer hides one of its points.
@(private = "file")
INSTANCER_STAGE :: `#usda 1.0
(
    upAxis = "Y"
    metersPerUnit = 0.01
    defaultPrim = "root"
)

def Xform "root"
{
    def Mesh "ground"
    {
        int[] faceVertexCounts = [3]
        int[] faceVertexIndices = [0, 1, 2]
        point3f[] points = [(0, 0, 0), (1000, 0, 0), (0, 0, 1000)]
    }

    def PointInstancer "trees_a"
    {
        double3 xformOp:translate = (100, 0, 0)
        uniform token[] xformOpOrder = ["xformOp:translate"]
        rel prototypes = [</root/trees_a/Prototypes/tree>]
        int[] protoIndices = [0, 0, 0]
        point3f[] positions = [(0, 0, 0), (100, 0, 0), (0, 0, 100)]
        float3[] scales = [(1, 1, 1), (2, 2, 2), (1, 1, 1)]

        def Scope "Prototypes"
        {
            def Mesh "tree"
            {
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
                point3f[] points = [(0, 0, 0), (50, 0, 0), (0, 200, 0)]
            }
        }
    }

    def PointInstancer "trees_b"
    {
        rel prototypes = [</root/trees_b/Prototypes/tree>]
        int[] protoIndices = [0, 0]
        point3f[] positions = [(0, 0, -500), (0, 0, -600)]
        int64[] invisibleIds = [1]

        def Scope "Prototypes"
        {
            def Mesh "tree"
            {
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
                point3f[] points = [(0, 0, 0), (50, 0, 0), (0, 200, 0)]
            }
        }
    }
}
`

@(private = "file")
stage_set :: proc(t: ^testing.T, tree: Tree, meta: format.Meta, name: string) -> (data: []byte, blob: ^format.Instance_Set_Blob, ok: bool) {
	guid, found := format.meta_subasset(meta, format.INSTANCE_SET_KIND, name)
	testing.expectf(t, found, "the stage has no instance set %s", name)
	if !found {
		return
	}
	data = tree_blob(t, tree, guid)
	blob, ok = format.instance_set_view(data)
	testing.expectf(t, ok, "%s did not cook into an instance set blob", name)
	return
}

@(test)
point_instancers_are_instance_sets_of_shared_prototypes :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/forest.usda", INSTANCER_STAGE}})
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Stage})
	testing.expect(t, pass.ok)
	// The ground, and the trees' prototype once: the two copies are the same mesh.
	testing.expect_value(t, pass.cooked[.Mesh], 2)
	testing.expect_value(t, pass.cooked[.Instance_Set], 2)
	meta := stage_meta(t, tree, "forest.usda")
	_, has_ground := format.meta_subasset(meta, format.MESH_KIND, "root/ground")
	tree_mesh, has_tree := format.meta_subasset(meta, format.MESH_KIND, "prototypes/tree")
	testing.expect(t, has_ground && has_tree)
	for s in meta.subassets {
		testing.expectf(t, !strings.contains(s.name, "Prototypes"), "a prototype's prim is a sub-asset of its own: %s", s.name)
	}

	// The first instancer's three points, about it, in meters with x mirrored; the second's visible point.
	data, blob, ok := stage_set(t, tree, meta, "root/trees_a")
	if ok {
		testing.expect_value(t, blob.count, 3)
		testing.expect_value(t, blob.cell_count, 1)
		testing.expect_value(t, blob.max_scale, 2)
		wants := [3][3]f32{{0, 0, 0}, {-1, 0, 0}, {0, 0, 1}}
		for i in format.instance_set_instances(data, blob) {
			want := wants[i.point]
			testing.expectf(t, i.position == want, "point %d is at %v, not %v", i.point, i.position, want)
			testing.expect_value(t, f32(i.scale.y), i.point == 1 ? 2 : 1)
			testing.expect_value(t, i.rotation.w, 32767)
		}
	}
	data, blob, ok = stage_set(t, tree, meta, "root/trees_b")
	if ok {
		testing.expect_value(t, blob.count, 1)
		instances := format.instance_set_instances(data, blob)
		testing.expect_value(t, instances[0].point, 0)
		testing.expect_value(t, instances[0].position, [3]f32{0, 0, -5})
	}

	// Each instancer is an entity that draws the shared tree at its set, and the prototypes are not entities.
	again := cook(options, {.Stage, .Scene})
	testing.expect(t, again.ok)
	prefab_text := ""
	for a in again.assets {
		if a.owner != {} && a.kind == .Prefab {
			prefab_text = string(a.source)
		}
	}
	testing.expect_value(t, strings.count(prefab_text, "component 53 Instanced_Mesh_Renderer"), 2)
	testing.expect_value(t, strings.count(prefab_text, fmt.tprintf("mesh = $%s", guid_text(tree_mesh))), 2)
	testing.expect_value(t, strings.count(prefab_text, "component 33 Mesh_Renderer"), 1)
	testing.expectf(t, strings.contains(prefab_text, "offset = [-1.0, 0.0, 0.0]"), "trees_a is not 1 m along -x: %s", prefab_text)
	testing.expect(t, !strings.contains(prefab_text, "name = \"tree\""))
}

@(test)
skipped_point_instancers_cook_neither_sets_nor_prototypes :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/forest.usda", INSTANCER_STAGE}, {"content/forest.usda.meta", "guid = 0123456789abcdef0123456789abcdef\npoint_instancers = skip\n"}})
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Stage})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Mesh], 1)
	testing.expect_value(t, pass.cooked[.Instance_Set], 0)
}

@(test)
a_stage_without_its_layers_warns_and_cooks_nothing :: proc(t: ^testing.T) {
	stage := "#usda 1.0\n(\n    subLayers = [@./downloads/missing.usda@]\n)\n"
	tree := make_tree(t, {{"content/wrapper.usda", stage}})
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Stage})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Stage], 0)
	warned := false
	for p in pass.problems.list {
		warned ||= !p.error && strings.contains(p.text, "not cooked")
	}
	testing.expect(t, warned)
}

@(test)
a_malformed_stage_is_an_error :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/broken.usda", "#usda 1.0\ndef Mesh \"m\" {\n    int[] faceVertexCounts = [3\n"}})
	defer remove_tree(tree)
	errors: Errors
	defer release_errors(&errors)
	context.logger = capture_errors(&errors)
	pass := cook(tree_options(tree), {.Stage})
	testing.expect(t, !pass.ok)
	expect_error(t, &errors, "cannot read the stage")
}
