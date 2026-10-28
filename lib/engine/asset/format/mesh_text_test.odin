package asset_format

import "core:math/linalg"
import "core:strings"
import "core:testing"

// BOX is a 1 m box on the origin's corner, as the cooker's mesh template writes it: each face clockwise from its
// front, with a world-aligned mapping, and the top's edges sharp.
@(private = "file")
BOX :: `# A box.
mesh 1
material 0 $00112233445566778899aabbccddeeff
v 0 0 0
v 1 0 0
v 1 0 1
v 0 0 1
v 0 1 0
v 1 1 0
v 1 1 1
v 0 1 1
f 0 0 1 2 3
map 1 0 0 0 0 -1 1 1 0 0 0
f 0 4 7 6 5
map 1 0 0 0 0 -1 1 1 0 0 0
f 0 0 4 5 1
map 1 0 0 0 -1 0 1 1 0 0 0
f 0 2 6 7 3
map 1 0 0 0 -1 0 1 1 0 0 0
f 0 3 7 4 0
map 0 0 1 0 -1 0 1 1 0 0 0
f 0 1 5 6 2
map 0 0 1 0 -1 0 1 1 0 0 0
e 4 5 sharp
e 5 6 sharp
e 6 7 sharp
e 7 4 sharp
`

@(test)
mesh_files_parse :: proc(t: ^testing.T) {
	mesh, problems, ok := mesh_text_parse(BOX, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, mesh.materials[0], guid_parse(TEST_GUID) or_else {})
	testing.expect_value(t, mesh.materials[1], Guid{})
	testing.expect_value(t, len(mesh.vertices), 8)
	testing.expect_value(t, mesh.vertices[6], [3]f32{1, 1, 1})
	testing.expect_value(t, len(mesh.faces), 6)
	top := mesh.faces[1]
	testing.expect_value(t, top.slot, 0)
	testing.expect_value(t, top.line, 14)
	testing.expect_value(t, len(top.corners), 4)
	testing.expect_value(t, top.corners[1], 7)
	testing.expect_value(t, top.mapping.u_axis, [3]f32{1, 0, 0})
	testing.expect_value(t, top.mapping.v_axis, [3]f32{0, 0, -1})
	testing.expect_value(t, top.mapping.scale, [2]f32{1, 1})
	testing.expect_value(t, len(mesh.sharp), 4)
	testing.expect_value(t, mesh.sharp[3], Mesh_Edge{7, 4})
}

@(test)
mesh_files_round_trip :: proc(t: ^testing.T) {
	mesh, _, ok := mesh_text_parse(BOX, context.temp_allocator)
	testing.expect(t, ok)
	text := mesh_text_write(mesh, context.temp_allocator)
	// The writer drops the comment and writes the same lines, in the same order.
	testing.expect_value(t, text, strings.trim_prefix(BOX, "# A box.\n"))
	again, _, again_ok := mesh_text_parse(text, context.temp_allocator)
	testing.expect(t, again_ok)
	testing.expect_value(t, len(again.faces), len(mesh.faces))
	for f, i in mesh.faces {
		testing.expect_value(t, again.faces[i].mapping, f.mapping)
	}

	// Numbers write so that an f32 reads back exactly, without an exponent.
	odd := Mesh_Source {
		vertices = {{0.1, 1.0 / 3.0, -2.5e-7}, {123456.78, 0, 0}, {0, 0, 0}},
		faces    = {
			{
				corners = {0, 1, 2},
				mapping = {
					u_axis = {1, 0, 0},
					v_axis = {0, 1, 0},
					scale = {0.25, 0.5},
					shift = {0.125, -0.375},
					rotation = 15,
				},
			},
		},
	}
	text = mesh_text_write(odd, context.temp_allocator)
	testing.expect(t, strings.contains(text, "v 0.1 0.33333334 -0.00000025\n"))
	testing.expect(t, strings.contains(text, "map 1 0 0 0 1 0 0.25 0.5 0.125 -0.375 15\n"))
	parsed, _, parsed_ok := mesh_text_parse(text, context.temp_allocator)
	testing.expect(t, parsed_ok)
	testing.expect_value(t, parsed.vertices[0], odd.vertices[0])
	testing.expect_value(t, parsed.faces[0].mapping, odd.faces[0].mapping)
}

@(test)
mesh_file_problems_name_their_lines :: proc(t: ^testing.T) {
	find :: proc(problems: []Mesh_Problem, line: int) -> (Mesh_Problem, bool) {
		for p in problems {
			if p.line == line {
				return p, true
			}
		}
		return {}, false
	}
	text := "mesh 1\nv 0 0 0\nv 1 0 0\nv 1 1 0\nf 0 0 1\nf 9 0 1 2\nf 0 0 1 7\nmap 1 0 0 0 1 0 1 1 0 0\nv 0 1 x\nhinge 0 1\nf 0 0 1 2\n"
	mesh, problems, ok := mesh_text_parse(text, context.temp_allocator)
	testing.expect(t, !ok)
	// Two indices, a slot of 9, a vertex that is not there, a map of 10 numbers, a vertex that is not a number.
	for line in ([]int{5, 6, 7, 8, 9}) {
		p, found := find(problems, line)
		testing.expectf(t, found && p.error, "line %d should be an error: %v", line, problems)
	}
	unknown, found := find(problems, 10)
	testing.expect(t, found && !unknown.error)
	// The faces that parsed are kept, and the last one, without a map line, got a world-aligned mapping by its normal.
	testing.expect_value(t, len(mesh.faces), 2)
	last := mesh.faces[1]
	testing.expect_value(t, last.mapping, mesh_world_mapping({0, 0, 1}, MESH_DEFAULT_SCALE))
	testing.expect_value(t, last.mapping.u_axis, [3]f32{1, 0, 0})

	_, problems, ok = mesh_text_parse("scene 1\n", context.temp_allocator)
	testing.expect(t, !ok && len(problems) == 1 && problems[0].line == 1)
	_, problems, ok = mesh_text_parse("", context.temp_allocator)
	testing.expect(t, !ok && len(problems) == 1)
	_, problems, ok = mesh_text_parse(
		"mesh 1\nmap 1 0 0 0 1 0 1 1 0 0 0\n",
		context.temp_allocator,
	)
	testing.expect(t, !ok && len(problems) == 1 && problems[0].line == 2)
}

@(test)
world_mappings_follow_the_normal :: proc(t: ^testing.T) {
	floor := mesh_world_mapping({0.1, 0.9, 0.2}, 2)
	testing.expect_value(t, floor.u_axis, [3]f32{1, 0, 0})
	testing.expect_value(t, floor.v_axis, [3]f32{0, 0, -1})
	testing.expect_value(t, floor.scale, [2]f32{2, 2})
	side := mesh_world_mapping({-1, 0, 0}, 1)
	testing.expect_value(t, side.u_axis, [3]f32{0, 0, 1})
	testing.expect_value(t, side.v_axis, [3]f32{0, -1, 0})
	front := mesh_world_mapping({0, 0.2, 0.9}, 1)
	testing.expect_value(t, front.u_axis, [3]f32{1, 0, 0})
	testing.expect_value(t, front.v_axis, [3]f32{0, -1, 0})
	// The axes are perpendicular to the normal's nearest axis, so the texture never collapses.
	for n in ([][3]f32{{0, 1, 0}, {1, 0, 0}, {0, 0, 1}, {0, -1, 0}}) {
		m := mesh_world_mapping(n, 1)
		testing.expect_value(t, linalg.dot(m.u_axis, n), 0)
		testing.expect_value(t, linalg.dot(m.v_axis, n), 0)
	}
}

@(test)
face_normals_face_out_of_a_clockwise_face :: proc(t: ^testing.T) {
	mesh, _, ok := mesh_text_parse(BOX, context.temp_allocator)
	testing.expect(t, ok)
	expected := [][3]f32{{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}}
	for f, i in mesh.faces {
		testing.expect_value(t, mesh_face_normal(mesh.vertices, f.corners), expected[i])
	}
	testing.expect_value(t, mesh_face_normal(mesh.vertices, {0, 1, 1}), [3]f32{})
	testing.expect_value(t, mesh_face_normal(mesh.vertices, {0, 1, 99}), [3]f32{})
}
