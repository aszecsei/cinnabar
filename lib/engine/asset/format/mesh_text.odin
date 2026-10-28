package asset_format

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

// A .mesh file is level geometry that the editor builds, as polygon faces with parametric texture mappings (see
// docs/content/kinds/meshes.md#mesh-files). The cooker and the game read it with mesh_text_parse, and the editor's
// MeshFile reads and writes the same lines.
MESH_EXTENSION :: ".mesh"

// The version on a mesh file's first line, `mesh 1`. A change that old loaders cannot read changes it.
MESH_TEXT_VERSION :: 1

// A mesh has at most this many material slots: render.MAX_MATERIAL_SLOTS, which the renderer asserts.
MESH_MAX_SLOTS :: 8

// The scale of a mapping that a file does not give: one texture repeat per meter.
MESH_DEFAULT_SCALE :: 1.0

// Mesh_Mapping is how a face's texture lies on it: two axes in the mesh's space, the scale in meters per texture
// repeat, the shift in repeats and the rotation in degrees. UVs derive from it at bake (see mesh_bake).
Mesh_Mapping :: struct {
	u_axis:   [3]f32,
	v_axis:   [3]f32,
	scale:    [2]f32,
	shift:    [2]f32,
	rotation: f32,
}

// Mesh_Face is a polygon of three or more vertex indices, clockwise seen from its front.
Mesh_Face :: struct {
	slot:    u32,
	corners: []u32,
	mapping: Mesh_Mapping,
	// The line of its `f` line in the file, for problems, or 0 for a face that no file gave.
	line:    int,
}

// Mesh_Edge is a sharp edge between two vertices: normals do not smooth across it.
Mesh_Edge :: struct {
	a, b: u32,
}

// Mesh_Source is a parsed .mesh file. A slot that names no material is zero.
Mesh_Source :: struct {
	materials: [MESH_MAX_SLOTS]Guid,
	vertices:  [][3]f32,
	faces:     []Mesh_Face,
	sharp:     []Mesh_Edge,
}

// Mesh_Problem is an error or a warning in a mesh file or its bake, at a line from 1, or 0 for the whole file.
Mesh_Problem :: struct {
	line:    int,
	message: string,
	error:   bool,
}

// mesh_text_parse reads a mesh file. The mesh and the messages are in allocator. ok is false when any problem is an
// error: a malformed line, a face of fewer than three indices, or an index that no vertex has. A face without a `map`
// line gets a world-aligned mapping. A word that the parser does not know is a warning, so a file from a newer editor
// still cooks.
mesh_text_parse :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	mesh: Mesh_Source,
	problems: []Mesh_Problem,
	ok: bool,
) {
	p := Mesh_Parser {
		allocator = allocator,
		problems  = make([dynamic]Mesh_Problem, allocator),
		vertices  = make([dynamic][3]f32, allocator),
		faces     = make([dynamic]Parsed_Face, allocator),
		sharp     = make([dynamic]Mesh_Edge, allocator),
	}
	rest := text
	header := false
	for raw in strings.split_lines_iterator(&rest) {
		p.line += 1
		trimmed := strings.trim_space(raw)
		if trimmed == "" || trimmed[0] == '#' {
			continue
		}
		if !header {
			header = true
			if trimmed != fmt.tprintf("mesh %d", MESH_TEXT_VERSION) {
				mesh_problem(&p, true, "a mesh file starts with `mesh %d`", MESH_TEXT_VERSION)
				break
			}
			continue
		}
		word, _, argument := strings.partition(trimmed, " ")
		fields := strings.fields(strings.trim_space(argument), context.temp_allocator)
		switch word {
		case "material":
			parse_material(&p, fields)
		case "v":
			parse_vertex(&p, fields)
		case "f":
			parse_face(&p, fields)
		case "map":
			parse_map(&p, fields)
		case "e":
			parse_edge(&p, fields)
		case:
			mesh_problem(&p, false, "the line %q is unknown, so it is ignored", word)
		}
	}
	if !header {
		mesh_problem(&p, true, "a mesh file starts with `mesh %d`", MESH_TEXT_VERSION)
	}
	for &f in p.faces {
		p.line = f.face.line
		for c in f.face.corners {
			if int(c) >= len(p.vertices) {
				mesh_problem(
					&p,
					true,
					"the face uses vertex %d, and the file has %d",
					c,
					len(p.vertices),
				)
				break
			}
		}
		if !f.mapped {
			f.face.mapping = mesh_world_mapping(
				mesh_face_normal(p.vertices[:], f.face.corners),
				MESH_DEFAULT_SCALE,
			)
		}
	}
	for e in p.sharp {
		if int(e.a) >= len(p.vertices) || int(e.b) >= len(p.vertices) {
			p.line = 0
			mesh_problem(
				&p,
				true,
				"the sharp edge %d %d uses a vertex the file does not have",
				e.a,
				e.b,
			)
		}
	}
	ok = true
	for problem in p.problems {
		ok &&= !problem.error
	}
	faces := make([]Mesh_Face, len(p.faces), allocator)
	for f, i in p.faces {
		faces[i] = f.face
	}
	mesh = {
		materials = p.materials,
		vertices  = p.vertices[:],
		faces     = faces,
		sharp     = p.sharp[:],
	}
	return mesh, p.problems[:], ok
}

@(private = "file")
Mesh_Parser :: struct {
	allocator: mem.Allocator,
	line:      int,
	problems:  [dynamic]Mesh_Problem,
	materials: [MESH_MAX_SLOTS]Guid,
	vertices:  [dynamic][3]f32,
	faces:     [dynamic]Parsed_Face,
	sharp:     [dynamic]Mesh_Edge,
}

@(private = "file")
Parsed_Face :: struct {
	face:   Mesh_Face,
	mapped: bool,
}

@(private = "file")
mesh_problem :: proc(p: ^Mesh_Parser, error: bool, format: string, args: ..any) {
	append(
		&p.problems,
		Mesh_Problem {
			line = p.line,
			message = fmt.aprintf(format, ..args, allocator = p.allocator),
			error = error,
		},
	)
}

@(private = "file")
parse_material :: proc(p: ^Mesh_Parser, fields: []string) {
	if len(fields) != 2 {
		mesh_problem(p, true, "a material line is `material <slot> $<guid>`")
		return
	}
	slot, slot_ok := strconv.parse_uint(fields[0], 10)
	if !slot_ok || slot >= MESH_MAX_SLOTS {
		mesh_problem(p, true, "a material slot is 0 to %d, not %q", MESH_MAX_SLOTS - 1, fields[0])
		return
	}
	guid, guid_ok := parse_asset(fields[1])
	if !guid_ok {
		mesh_problem(
			p,
			true,
			"a material is 32 hex digits after $, or $0 for none, not %q",
			fields[1],
		)
		return
	}
	p.materials[slot] = guid
}

@(private = "file")
parse_asset :: proc(text: string) -> (guid: Guid, ok: bool) {
	if text == "$0" {
		return {}, true
	}
	if len(text) < 1 || text[0] != '$' {
		return
	}
	return guid_parse(text[1:])
}

@(private = "file")
parse_vertex :: proc(p: ^Mesh_Parser, fields: []string) {
	v, ok := parse_floats(fields, 3)
	if !ok {
		mesh_problem(p, true, "a vertex is `v <x> <y> <z>` in meters")
		return
	}
	append(&p.vertices, [3]f32{v[0], v[1], v[2]})
}

@(private = "file")
parse_face :: proc(p: ^Mesh_Parser, fields: []string) {
	if len(fields) < 4 {
		mesh_problem(
			p,
			true,
			"a face is `f <slot> <v0> <v1> <v2> ...`, with three or more vertices",
		)
		return
	}
	slot, slot_ok := strconv.parse_uint(fields[0], 10)
	if !slot_ok || slot >= MESH_MAX_SLOTS {
		mesh_problem(
			p,
			true,
			"a face's material slot is 0 to %d, not %q",
			MESH_MAX_SLOTS - 1,
			fields[0],
		)
		return
	}
	corners := make([]u32, len(fields) - 1, p.allocator)
	for text, i in fields[1:] {
		index, index_ok := strconv.parse_uint(text, 10)
		if !index_ok || index > uint(max(u32)) {
			mesh_problem(p, true, "a face's vertex is an index from 0, not %q", text)
			return
		}
		corners[i] = u32(index)
	}
	append(&p.faces, Parsed_Face{face = {slot = u32(slot), corners = corners, line = p.line}})
}

@(private = "file")
parse_map :: proc(p: ^Mesh_Parser, fields: []string) {
	if len(p.faces) == 0 || p.faces[len(p.faces) - 1].mapped {
		mesh_problem(p, true, "a map line follows the face it maps")
		return
	}
	v, ok := parse_floats(fields, 11)
	if !ok {
		mesh_problem(
			p,
			true,
			"a map is `map <ux uy uz> <vx vy vz> <su sv> <tu tv> <rotation>`, 11 numbers",
		)
		return
	}
	if v[6] == 0 || v[7] == 0 {
		mesh_problem(p, true, "a map's scale is meters per repeat, and cannot be 0")
		return
	}
	f := &p.faces[len(p.faces) - 1]
	f.face.mapping = {
		u_axis   = {v[0], v[1], v[2]},
		v_axis   = {v[3], v[4], v[5]},
		scale    = {v[6], v[7]},
		shift    = {v[8], v[9]},
		rotation = v[10],
	}
	f.mapped = true
}

@(private = "file")
parse_edge :: proc(p: ^Mesh_Parser, fields: []string) {
	if len(fields) != 3 || fields[2] != "sharp" {
		mesh_problem(p, true, "an edge is `e <a> <b> sharp`")
		return
	}
	a, a_ok := strconv.parse_uint(fields[0], 10)
	b, b_ok := strconv.parse_uint(fields[1], 10)
	if !a_ok || !b_ok || a == b || a > uint(max(u32)) || b > uint(max(u32)) {
		mesh_problem(
			p,
			true,
			"an edge joins two different vertices by index, not %q and %q",
			fields[0],
			fields[1],
		)
		return
	}
	append(&p.sharp, Mesh_Edge{u32(a), u32(b)})
}

// parse_floats reads exactly count numbers.
@(private = "file")
parse_floats :: proc(fields: []string, count: int) -> (values: [11]f32, ok: bool) {
	if len(fields) != count {
		return
	}
	for text, i in fields {
		f, f_ok := strconv.parse_f32(text)
		if !f_ok || math.is_nan(f) || math.is_inf(f) {
			return
		}
		values[i] = f
	}
	return values, true
}

// mesh_text_write writes a mesh as mesh_text_parse reads it: the materials, the vertices, each face with its map
// line, then the sharp edges. Numbers are written so that an f32 reads back exactly.
mesh_text_write :: proc(mesh: Mesh_Source, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintfln(&b, "mesh %d", MESH_TEXT_VERSION)
	for guid, slot in mesh.materials {
		if guid != {} {
			buffer: [32]u8
			fmt.sbprintfln(&b, "material %d $%s", slot, guid_format(guid, &buffer))
		}
	}
	for &v in mesh.vertices {
		strings.write_string(&b, "v")
		write_floats(&b, v[:])
		strings.write_byte(&b, '\n')
	}
	for f in mesh.faces {
		fmt.sbprintf(&b, "f %d", f.slot)
		for c in f.corners {
			fmt.sbprintf(&b, " %d", c)
		}
		strings.write_string(&b, "\nmap")
		m := f.mapping
		write_floats(&b, m.u_axis[:])
		write_floats(&b, m.v_axis[:])
		write_floats(&b, m.scale[:])
		write_floats(&b, m.shift[:])
		write_floats(&b, {m.rotation})
		strings.write_byte(&b, '\n')
	}
	for e in mesh.sharp {
		fmt.sbprintfln(&b, "e %d %d sharp", e.a, e.b)
	}
	return strings.to_string(b)
}

@(private = "file")
write_floats :: proc(b: ^strings.Builder, values: []f32) {
	for v in values {
		strings.write_byte(b, ' ')
		write_float(b, v)
	}
}

// write_float writes the shortest decimal that reads back as the same f32, without an exponent, so that 1 is "1"
// and 0.5 is "0.5", as the editor writes them.
@(private = "file")
write_float :: proc(b: ^strings.Builder, v: f32) {
	buffer: [64]u8
	text := strconv.write_float(buffer[:], f64(v), 'f', -1, 32)
	strings.write_string(b, strings.trim_prefix(text, "+"))
}

// mesh_face_normal is a face's plane normal from Newell's method, which gives a bent n-gon its average plane: unit, or
// zero for a face that has no area.
mesh_face_normal :: proc "contextless" (vertices: [][3]f32, corners: []u32) -> [3]f32 {
	n: [3]f32
	for c, i in corners {
		if int(c) >= len(vertices) {
			return {}
		}
		next := corners[(i + 1) % len(corners)]
		if int(next) >= len(vertices) {
			return {}
		}
		p, q := vertices[c], vertices[next]
		n.x += (p.y - q.y) * (p.z + q.z)
		n.y += (p.z - q.z) * (p.x + q.x)
		n.z += (p.x - q.x) * (p.y + q.y)
	}
	length := math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
	if length < 1e-12 {
		return {}
	}
	return n / length
}

// mesh_world_mapping is the mapping of a face by its normal's nearest world axis, at a scale, as Hammer gives new
// faces: a floor's u runs along +x and its v along -z, a side wall's along +z and -y, and a front wall's along +x and
// -y, so neighbors across a right angle share a seam. Faces that face the opposite ways share axes, so that the
// texture's lines meet across every face of a box on the grid.
mesh_world_mapping :: proc "contextless" (normal: [3]f32, scale: f32) -> Mesh_Mapping {
	m := Mesh_Mapping {
		scale = {scale, scale},
	}
	ax, ay, az := abs(normal.x), abs(normal.y), abs(normal.z)
	switch {
	case ay >= ax && ay >= az:
		m.u_axis, m.v_axis = {1, 0, 0}, {0, 0, -1}
	case ax >= az:
		m.u_axis, m.v_axis = {0, 0, 1}, {0, -1, 0}
	case:
		m.u_axis, m.v_axis = {1, 0, 0}, {0, -1, 0}
	}
	return m
}
