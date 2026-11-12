package cook

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

// nav_entity is a scene's entity with a Transform at a position in meters, a rotation about z in degrees, a scale and
// the text of more components.
@(private = "file")
nav_entity :: proc(id: u64, position: [3]f64, scale: [3]f32 = {1, 1, 1}, roll: f64 = 0, components := "component 65 Collider\n") -> string {
	raw := position * (1 << 24)
	half := math.to_radians(roll) / 2
	return fmt.tprintf(
		"entity %016x\ncomponent 1 Transform\n\tposition = [%d, %d, %d]\n\trotation = [0, 0, %v, %v]\n\tscale = [%v, %v, %v]\n%s\n",
		id, i64(math.round(raw.x)), i64(math.round(raw.y)), i64(math.round(raw.z)), math.sin(half), math.cos(half), scale.x, scale.y, scale.z, components,
	)
}

// nav_ramp is a slab of a length along x, 2 m across and 0.2 m thick, tilted up toward +x by an angle, whose top's lower
// edge is on the floor at x0 - length / 2 * cos(angle), and the middle of its top at (x0, y, z0).
@(private = "file")
nav_ramp :: proc(id: u64, x0, z0, length, degrees: f64) -> (text: string, middle: [3]f32) {
	angle := math.to_radians(degrees)
	top := length / 2 * math.sin(angle)
	center := [3]f64{x0 + 0.1 * math.sin(angle), top - 0.1 * math.cos(angle), z0}
	return nav_entity(id, center, {f32(length), 0.2, 2}, degrees), {f32(x0), f32(top), f32(z0)}
}

@(private = "file")
NAV_VOLUME :: "component 42 Volume\n\tshape = Box\n\textents = [10, 3, 10]\ncomponent 128 Nav_Mesh_Volume\n\tcell_size = 0.1\n\tcell_height = 0.1\n\ttile_size = 64\n"

@(private = "file")
NAV_AGENTS :: "nav.agents = Small, Large\n" +
	"nav.agent.Small.radius = 0.2\nnav.agent.Small.height = 1\nnav.agent.Small.step_height = 0.6\nnav.agent.Small.max_slope = 55\n" +
	"nav.agent.Large.radius = 0.6\nnav.agent.Large.height = 2\nnav.agent.Large.step_height = 0.3\nnav.agent.Large.max_slope = 30\n"

// The test level: a 20 m floor with its top at 0, a wall across it at z = 4 with a gap of 0.8 m, a box 0.5 m high, a
// ramp of 20 degrees and one of 50, inside a volume over it all.
@(private = "file")
nav_level :: proc() -> (scene: string, ramp20, ramp50: [3]f32) {
	ramp20_text, ramp50_text: string
	ramp20_text, ramp20 = nav_ramp(0x20, 2, -6, 6, 20)
	ramp50_text, ramp50 = nav_ramp(0x50, 5, 0, 4, 50)
	scene = strings.concatenate(
		{
			"scene 1\n\n",
			nav_entity(0x100, {0, 0, 0}, components = NAV_VOLUME),
			nav_entity(0x1, {0, -0.25, 0}, {20, 0.5, 20}),
			// The wall, from beyond the volume's edges, but for the gap from x = 2 to 2.8.
			nav_entity(0x2, {-4.25, 1, 4}, {12.5, 2, 0.3}),
			nav_entity(0x3, {6.65, 1, 4}, {7.7, 2, 0.3}),
			nav_entity(0x4, {-6, 0.25, -6}, {3, 0.5, 3}),
			ramp20_text,
			ramp50_text,
		},
		context.temp_allocator,
	)
	return
}

// nav_polygon_at finds the polygon whose surface is over or under a point, within 0.3 m of its height, by the polygons'
// detail triangles. It gives -1 for none.
@(private = "file")
nav_polygon_at :: proc(data: []byte, blob: ^format.Nav_Mesh_Blob, point: [3]f32) -> int {
	polygons := format.nav_mesh_polygons(data, blob)
	details := format.nav_mesh_details(data, blob)
	detail_vertices := format.nav_mesh_detail_vertices(data, blob)
	detail_triangles := format.nav_mesh_detail_triangles(data, blob)
	for tile in format.nav_mesh_tiles(data, blob) {
		for p in 0 ..< tile.polygon_count {
			d := details[tile.first_polygon + p]
			for triangle in detail_triangles[tile.first_detail_triangle + d.first_triangle:][:d.triangle_count] {
				v: [3][3]f32
				for k in 0 ..< 3 {
					v[k] = detail_vertices[tile.first_detail_vertex + d.first_vertex + u32(triangle[k])]
				}
				// Barycentric coordinates across, in x and z.
				denominator := (v[1].z - v[2].z) * (v[0].x - v[2].x) + (v[2].x - v[1].x) * (v[0].z - v[2].z)
				if abs(denominator) < 1e-9 {
					continue
				}
				a := ((v[1].z - v[2].z) * (point.x - v[2].x) + (v[2].x - v[1].x) * (point.z - v[2].z)) / denominator
				b := ((v[2].z - v[0].z) * (point.x - v[2].x) + (v[0].x - v[2].x) * (point.z - v[2].z)) / denominator
				c := 1 - a - b
				if a < -1e-4 || b < -1e-4 || c < -1e-4 {
					continue
				}
				if abs(a * v[0].y + b * v[1].y + c * v[2].y - point.y) <= 0.3 {
					return int(tile.first_polygon + p)
				}
			}
		}
	}
	_ = polygons
	return -1
}

// nav_reached is the polygons that an agent reaches from one, through its neighbors in its tile and its links across
// tiles.
@(private = "file")
nav_reached :: proc(data: []byte, blob: ^format.Nav_Mesh_Blob, start: int) -> map[int]bool {
	polygons := format.nav_mesh_polygons(data, blob)
	links := format.nav_mesh_links(data, blob)
	first := make([]u32, len(polygons), context.temp_allocator)
	for tile in format.nav_mesh_tiles(data, blob) {
		for p in 0 ..< tile.polygon_count {
			first[tile.first_polygon + p] = tile.first_polygon
		}
	}
	reached := make(map[int]bool, context.temp_allocator)
	if start < 0 {
		return reached
	}
	pending := make([dynamic]int, context.temp_allocator)
	append(&pending, start)
	reached[start] = true
	for len(pending) > 0 {
		p := pop(&pending)
		polygon := polygons[p]
		next := make([dynamic]int, context.temp_allocator)
		for k in 0 ..< int(polygon.vertex_count) {
			n := polygon.neighbors[k]
			if n != format.NAV_NONE && n & format.NAV_EXTERNAL == 0 {
				append(&next, int(first[p] + u32(n)))
			}
		}
		for l in links[polygon.first_link:][:polygon.link_count] {
			append(&next, int(l.polygon))
		}
		for q in next {
			if !reached[q] {
				reached[q] = true
				append(&pending, q)
			}
		}
	}
	return reached
}

@(private = "file")
nav_blob_of :: proc(t: ^testing.T, tree: Tree, scene: string, entity: u64, agent: string) -> (data: []byte, blob: ^format.Nav_Mesh_Blob, guid: format.Guid, ok: bool) {
	meta_text, err := os.read_entire_file(fmt.tprintf("%s/content/%s.meta", tree.dir, scene), context.temp_allocator)
	testing.expect(t, err == nil)
	meta, _ := format.meta_parse(string(meta_text), context.temp_allocator)
	guid, ok = format.meta_subasset(meta, format.NAV_MESH_KIND, nav_subasset_name(entity, agent))
	testing.expectf(t, ok, "%s has no navmesh for %016x and %s", scene, entity, agent)
	if !ok {
		return
	}
	data = tree_blob(t, tree, guid)
	blob, ok = format.nav_mesh_view(data)
	testing.expect(t, ok, "the navmesh does not check")
	return
}

@(test)
nav_meshes_bake_what_each_agent_type_walks_on :: proc(t: ^testing.T) {
	scene, ramp20, ramp50 := nav_level()
	tree := make_tree(t, {{"project.settings", NAV_AGENTS}, {"content/level.scene", scene}})
	defer remove_tree(tree)
	options := tree_options(tree)

	pass := cook(options, {.Scene, .Nav_Mesh})
	testing.expectf(t, pass.ok, "problems: %v", pass.problems.list)
	testing.expect_value(t, pass.cooked[.Scene], 1)
	testing.expect_value(t, pass.cooked[.Nav_Mesh], 2)
	// 20 m at 0.1 m cells is 200 cells, in tiles of 64: 4 by 4, for each type.
	testing.expect_value(t, pass.nav_tiles[.Cooked], 32)

	start := [3]f32{-2, 0, 0}
	box_top := [3]f32{-6, 0.5, -6}
	far_side := [3]f32{5, 0, 7}
	wall_top := [3]f32{-4, 2, 4}
	inside_wall := [3]f32{-4, 1, 4}
	for agent in ([]string{"Small", "Large"}) {
		data, blob, _, ok := nav_blob_of(t, tree, "level.scene", 0x100, agent)
		if !ok {
			return
		}
		testing.expect_value(t, format.nav_mesh_agent(data, blob).name, agent)
		testing.expect_value(t, blob.volume, 0x100)
		testing.expect_value(t, blob.tiles_x, 4)
		testing.expect_value(t, len(format.nav_mesh_links(data, blob)) > 0, true)
		from := nav_polygon_at(data, blob, start)
		testing.expectf(t, from >= 0, "%s: no polygon on the floor", agent)
		reached := nav_reached(data, blob, from)
		walks :: proc(data: []byte, blob: ^format.Nav_Mesh_Blob, reached: map[int]bool, point: [3]f32) -> bool {
			p := nav_polygon_at(data, blob, point)
			return p >= 0 && reached[p]
		}
		small := agent == "Small"
		testing.expectf(t, walks(data, blob, reached, ramp20), "%s: the 20 degree ramp", agent)
		testing.expectf(t, walks(data, blob, reached, ramp50) == small, "%s: the 50 degree ramp", agent)
		testing.expectf(t, walks(data, blob, reached, box_top) == small, "%s: the box's top, 0.5 m up", agent)
		testing.expectf(t, walks(data, blob, reached, far_side) == small, "%s: the far side of the gap", agent)
		testing.expectf(t, nav_polygon_at(data, blob, wall_top) < 0, "%s: a polygon on the wall's top", agent)
		testing.expectf(t, nav_polygon_at(data, blob, inside_wall) < 0, "%s: a polygon in the wall", agent)
	}

	// The scene's blob lists both, so its bundle holds them.
	level := tree_guid(t, tree, "level.scene")
	scene_data := tree_blob(t, tree, level)
	navs, navs_ok := format.scene_nav_meshes(scene_data, context.temp_allocator)
	testing.expect(t, navs_ok && len(navs) == 2)
	references, _ := format.blob_references(scene_data, context.temp_allocator)
	for n in navs {
		testing.expect(t, slice.contains(references, n.guid))
	}
	if len(navs) == 2 {
		testing.expect_value(t, navs[0].agent, "Small")
		testing.expect_value(t, navs[1].agent, "Large")
	}

	again := cook(options, {.Scene, .Nav_Mesh})
	testing.expect_value(t, again.current[.Scene], 1)
	testing.expect_value(t, again.current[.Nav_Mesh], 2)
	testing.expect_value(t, again.cooked[.Nav_Mesh], 0)
	testing.expect_value(t, again.nav_tiles[.Cooked], 0)
}

@(test)
nav_meshes_bake_the_same_on_one_thread_and_many :: proc(t: ^testing.T) {
	scene, _, _ := nav_level()
	parsed, _, ok := format.scene_parse(scene, context.temp_allocator)
	testing.expect(t, ok)
	s := nav_scene_make(parsed)
	agents, _ := format.nav_agents_parse(NAV_AGENTS, context.temp_allocator)
	quiet := Problems {
		list = make([dynamic]Problem, context.temp_allocator),
	}
	volumes := nav_volumes(&s, agents, "level.scene", &quiet)
	testing.expect_value(t, len(volumes), 1)
	if len(volumes) != 1 {
		return
	}
	source: Asset_Source
	meshes := make(map[format.Guid]Nav_Mesh_Source, context.temp_allocator)
	triangles := nav_collect(&s, volumes[0], 1, "", &meshes, &source, &quiet)
	plan := nav_plan({guid = {0 = 1}, volume = 0x100, agent = agents[0], settings = volumes[0].settings, bounds_min = volumes[0].bounds_min, bounds_max = volumes[0].bounds_max, triangles = triangles})
	one := nav_bake(&plan, nil, threads = 1)
	many := nav_bake(&plan, nil, threads = 8)
	testing.expect_value(t, one.baked, 16)
	testing.expect_value(t, many.baked, 16)
	testing.expect(t, len(one.blob) > 0 && slice.equal(one.blob, many.blob), "the bake on one thread and on 8 differ")
	// A bake that keeps every tile of the last gives the same blob too.
	previous, _ := mem.alloc_bytes(len(one.blob), format.BLOB_ALIGN, context.temp_allocator)
	copy(previous, one.blob)
	kept := nav_bake(&plan, previous)
	testing.expect_value(t, kept.reused, 16)
	testing.expect(t, slice.equal(one.blob, kept.blob), "the kept tiles differ from the baked ones")
}

@(test)
nav_meshes_bake_again_only_the_tiles_that_an_edit_reaches :: proc(t: ^testing.T) {
	// One agent type, of 0.4 m, so a tile's border is 0.7 m; tiles of 4 m from -10.
	volume := "component 42 Volume\n\tshape = Box\n\textents = [10, 3, 10]\ncomponent 128 Nav_Mesh_Volume\n\tcell_size = 0.1\n\ttile_size = 40\n"
	scene :: proc(volume: string, pillar_x: f64) -> string {
		return strings.concatenate({"scene 1\n\n", nav_entity(0x100, {0, 0, 0}, components = volume), nav_entity(0x1, {0, -0.25, 0}, {20, 0.5, 20}), nav_entity(0x2, {pillar_x, 1, -7}, {1, 2, 1})}, context.temp_allocator)
	}
	tree := make_tree(t, {{"content/level.scene", scene(volume, -7)}})
	defer remove_tree(tree)
	options := tree_options(tree)

	first := cook(options, {.Scene, .Nav_Mesh})
	testing.expectf(t, first.ok, "problems: %v", first.problems.list)
	testing.expect_value(t, first.nav_tiles[.Cooked], 25)
	_, _, guid, _ := nav_blob_of(t, tree, "level.scene", 0x100, format.NAV_DEFAULT_AGENT)

	// The pillar, 1 m across, moves from x = -7 to -6. Before and after, it reaches the tiles from -10 and from -6
	// across, which read to -5.3 and from -6.7, and the same two along z: 4 tiles.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/level.scene", tree.dir), transmute([]byte)scene(volume, -6)) == nil)
	moved := cook(options, {.Scene, .Nav_Mesh})
	testing.expectf(t, moved.ok, "problems: %v", moved.problems.list)
	testing.expect_value(t, moved.cooked[.Nav_Mesh], 1)
	testing.expect_value(t, moved.nav_tiles[.Cooked], 4)
	testing.expect_value(t, moved.nav_tiles[.Current], 21)
	_, _, again, _ := nav_blob_of(t, tree, "level.scene", 0x100, format.NAV_DEFAULT_AGENT)
	testing.expect_value(t, again, guid)
}

@(test)
nav_meshes_take_only_static_active_colliders :: proc(t: ^testing.T) {
	text := strings.concatenate(
		{
			"scene 1\n\n",
			nav_entity(0x100, {0, 0, 0}, components = NAV_VOLUME),
			// A static box: 12 triangles.
			nav_entity(0x1, {0, 0, 0}),
			nav_entity(0x2, {1, 0, 0}, components = "component 65 Collider\ncomponent 64 Rigid_Body\n"),
			nav_entity(0x3, {2, 0, 0}, components = "component 65 Collider\n\tsensor = true\n"),
			"entity 0000000000000004\nactive = false\ncomponent 1 Transform\ncomponent 65 Collider\n\n",
			nav_entity(0x5, {3, 0, 0}, components = "component 65 Collider\ncomponent 75 Character\n"),
			// Under a static body, a box counts; under a kinematic one, it does not.
			nav_entity(0x6, {4, 0, 0}, components = "component 64 Rigid_Body\n\tmotion = Static\n"),
			"entity 0000000000000007\nparent = @0000000000000006\ncomponent 2 Local_Transform\n\toffset = [0, 1, 0]\ncomponent 65 Collider\n\n",
			nav_entity(0x8, {5, 0, 0}, components = "component 64 Rigid_Body\n\tmotion = Kinematic\n"),
			"entity 0000000000000009\nparent = @0000000000000008\ncomponent 2 Local_Transform\ncomponent 65 Collider\n\n",
			// A child of an inactive entity is inactive.
			"entity 000000000000000a\nparent = @0000000000000004\ncomponent 2 Local_Transform\ncomponent 65 Collider\n\n",
		},
		context.temp_allocator,
	)
	parsed, _, ok := format.scene_parse(text, context.temp_allocator)
	testing.expect(t, ok)
	s := nav_scene_make(parsed)
	quiet := Problems {
		list = make([dynamic]Problem, context.temp_allocator),
	}
	volumes := nav_volumes(&s, {format.DEFAULT_NAV_AGENT}, "level.scene", &quiet)
	testing.expect_value(t, len(volumes), 1)
	if len(volumes) != 1 {
		return
	}
	source: Asset_Source
	meshes := make(map[format.Guid]Nav_Mesh_Source, context.temp_allocator)
	triangles := nav_collect(&s, volumes[0], 1, "", &meshes, &source, &quiet)
	testing.expect_value(t, len(triangles), 24)
	// The child at offset 1 above its parent at x = 4: a 1 m box from y = 0.5 to 1.5.
	high: f32 = 0
	for triangle in triangles {
		for v in triangle {
			high = max(high, v.y)
		}
	}
	testing.expect_value(t, high, 1.5)
}

@(test)
nav_meshes_take_mesh_colliders_and_prefab_instances :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/block.mesh", MESH_TEMPLATE}, {"content/floor.prefab", "scene 1\n\n" + "entity 0000000000000001\ncomponent 1 Transform\ncomponent 65 Collider\n\tsize = [8, 0.5, 8]\n"}})
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Mesh, .Scene})
	testing.expectf(t, pass.ok, "problems: %v", pass.problems.list)
	block := tree_guid(t, tree, "block.mesh")
	floor := tree_guid(t, tree, "floor.prefab")
	buffer, other: [32]u8
	// The template's box is from 0 to 1, so a box of it scaled by 4 across has its top at 1, around (2, 1, 2) from its
	// entity. A collider whose mesh is not cooked is left out, with a warning.
	scene := strings.concatenate(
		{
			"scene 2\n\n",
			nav_entity(0x100, {0, 0, 0}, components = NAV_VOLUME),
			fmt.tprintf("entity 0000000000000002\nprefab = $%s\ncomponent 1 Transform\n\tposition = [0, %d, 0]\n\n", format.guid_format(floor, &buffer), i64(-0.25 * (1 << 24))),
			nav_entity(0x3, {-6, 0, -6}, {4, 1, 4}, components = fmt.tprintf("component 65 Collider\n\tshape = Mesh\n\tmesh = $%s\n", format.guid_format(block, &other))),
			nav_entity(0x4, {6, 0, 6}, components = "component 65 Collider\n\tshape = Mesh\n\tmesh = $00112233445566778899aabbccddeeff\n"),
		},
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/level.scene", tree.dir), transmute([]byte)scene) == nil)
	baked := cook(options, {.Mesh, .Scene, .Nav_Mesh})
	testing.expect_value(t, baked.cooked[.Nav_Mesh], 1)
	warned := false
	for p in baked.problems.list {
		warned ||= strings.contains(p.text, "00112233445566778899aabbccddeeff is not cooked")
	}
	testing.expect(t, warned, "no warning of the mesh that is not cooked")

	data, blob, _, ok := nav_blob_of(t, tree, "level.scene", 0x100, format.NAV_DEFAULT_AGENT)
	if !ok {
		return
	}
	// The prefab's floor, 8 m across, has its top at 0, and the mesh's box its top at 1.
	testing.expect(t, nav_polygon_at(data, blob, {0, 0, 0}) >= 0, "no polygon on the prefab's floor")
	testing.expect(t, nav_polygon_at(data, blob, {-4, 1, -4}) >= 0, "no polygon on the mesh's top")
	level := tree_guid(t, tree, "level.scene")
	for a in baked.assets {
		if a.meta.guid == level {
			testing.expect(t, slice.contains(a.dependencies[:], block), "the mesh is not among the scene's dependencies")
		}
	}
}

@(test)
a_scene_without_a_volume_bakes_nothing :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/level.scene", "scene 1\n\n" + "entity 0000000000000001\ncomponent 1 Transform\ncomponent 65 Collider\n"}})
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Scene, .Nav_Mesh})
	testing.expectf(t, pass.ok, "problems: %v", pass.problems.list)
	testing.expect_value(t, pass.cooked[.Nav_Mesh] + pass.current[.Nav_Mesh], 0)
	meta, _ := os.read_entire_file(fmt.tprintf("%s/content/level.scene.meta", tree.dir), context.temp_allocator)
	testing.expect(t, !strings.contains(string(meta), "navmesh."))
}
