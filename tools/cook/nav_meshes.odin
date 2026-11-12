// `cook navmeshes --cache <dir> --config dev|release --root <name>=<dir>...` bakes the navmeshes of the scenes in the
// content roots: one for each Nav_Mesh_Volume and agent type, from the static colliders inside the volume, with Recast,
// tile by tile (see docs/content/kinds/nav-meshes.md). The scenes' cook gives each navmesh its GUID and lists it in the
// scene's blob; this pass, which runs after the meshes cook, bakes it.
package cook

import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:slice"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Changing how the cooker bakes navmeshes changes this, which bakes every tile again.
NAV_COOK_VERSION :: "navmeshes 1"

// The project's settings, beside its content root, the root named game (see docs/overview/architecture.md#project-settings).
PROJECT_SETTINGS_FILE :: "project.settings"
PROJECT_USER_SETTINGS_FILE :: "project.user.settings"

// A World_Position unit is 2^-24 m, as lib/engine/ecs gives it.
@(private = "file")
POSITION_SCALE :: f32(1 << 24)

// The scene's hierarchy is at most this deep, as the world's is.
@(private = "file")
MAX_DEPTH :: 64

// Primitive colliders are triangulated with this many segments around their axis, and spheres with half as many rings.
@(private = "file")
SEGMENTS :: 16

// Recast's settings that do not depend on the agent or the volume: a region of fewer cells than the first goes, one of
// fewer than the second joins a neighbor, an edge is at most 12 m, a contour is at most 1.3 cells off the region's edge,
// and the detail mesh samples every 6 cells and is at most a cell high off the surface (see
// docs/content/kinds/nav-meshes.md#the-bake).
@(private = "file")
MIN_REGION_AREA :: 8 * 8
@(private = "file")
MERGE_REGION_AREA :: 20 * 20
@(private = "file")
MAX_EDGE_METERS :: 12
@(private = "file")
MAX_SIMPLIFICATION_ERROR :: 1.3
@(private = "file")
DETAIL_SAMPLE_CELLS :: 6

// Nav_Project is the project's agent types, from its settings, and the settings files that they came from, which a
// scene with a navigation volume records as its inputs, so a change to them bakes again.
Nav_Project :: struct {
	agents: []format.Nav_Agent,
	files:  []string,
}

// nav_project reads the project's agent types, once in a pass. The project is the folder above the root named game; a
// cook without one has the default agent type.
nav_project :: proc(options: Cook_Options, pass: ^Pass) -> Nav_Project {
	if project, read := pass.nav.?; read {
		return project
	}
	dir := ""
	for r in options.roots {
		if r.name == "game" {
			dir = filepath.dir(r.dir)
		}
	}
	text := strings.builder_make(context.temp_allocator)
	files := make([dynamic]string, context.temp_allocator)
	// The line of the text that each file starts after.
	starts := make([dynamic]int, context.temp_allocator)
	lines := 0
	if dir != "" {
		for name in ([]string{PROJECT_SETTINGS_FILE, PROJECT_USER_SETTINGS_FILE}) {
			path := fmt.tprintf("%s/%s", dir, name)
			data, err := os.read_entire_file(path, context.temp_allocator)
			if err != nil {
				continue
			}
			append(&files, path)
			append(&starts, lines)
			strings.write_string(&text, string(data))
			strings.write_byte(&text, '\n')
			lines += strings.count(string(data), "\n") + 1
		}
	}
	agents, problems := format.nav_agents_parse(strings.to_string(text), context.temp_allocator)
	for p in problems {
		file := 0
		for start, i in starts {
			if p.line > start {
				file = i
			}
		}
		report_warning(&pass.problems, files[file], p.line - starts[file], 0, "%s", p.text)
	}
	pass.nav = Nav_Project{agents, files[:]}
	return pass.nav.?
}

// scene_nav_meshes gives a scene's navmeshes their GUIDs, which its .meta file keeps, and the list that its blob holds:
// one for each active Nav_Mesh_Volume on a box Volume and each agent type that it bakes for, by entity and then by the
// agent types' order. A scene with a volume records the project's settings files as its inputs. It reports the
// volumes' problems, and fails only when the .meta file cannot be written.
scene_nav_meshes :: proc(options: Cook_Options, pass: ^Pass, index: int, flat: format.Scene) -> (navs: []format.Scene_Nav_Mesh, ok: bool) {
	a := &pass.assets[index]
	wanted := make([dynamic]Subasset, context.temp_allocator)
	Reference :: struct {
		entity: u64,
		agent:  string,
	}
	references := make([dynamic]Reference, context.temp_allocator)
	if nav_has_volume(flat) {
		project := nav_project(options, pass)
		s := nav_scene_make(flat)
		for v in nav_volumes(&s, project.agents, a.path, &pass.problems) {
			for k in v.agents {
				append(&wanted, Subasset{kind = .Nav_Mesh, name = nav_subasset_name(v.entity, project.agents[k].name)})
				append(&references, Reference{v.entity, project.agents[k].name})
			}
		}
		for f in project.files {
			if size, modified, stamped := file_stamp(f); stamped {
				append(&a.inputs, Input_Stamp{strings.clone(f, context.temp_allocator), size, modified})
			}
		}
	}
	if !assign_subassets(options.roots[a.root].dir, a, wanted[:], pass.force[a.meta.guid], &pass.problems) {
		return nil, false
	}
	navs = make([]format.Scene_Nav_Mesh, len(references), context.temp_allocator)
	for r, i in references {
		guid, _ := nav_mesh_guid(a^, wanted[i].name)
		navs[i] = {r.entity, strings.clone(r.agent, context.temp_allocator), guid}
	}
	return navs, true
}

// nav_mesh_guid is the GUID of a scene's navmesh of a name: the one that the scene's cook in this pass gave it, or
// else the one in its .meta file, which a pass that did not cook the scene read.
nav_mesh_guid :: proc(a: Asset_Source, name: string) -> (format.Guid, bool) {
	for s in a.subassets {
		if s.kind == .Nav_Mesh && s.name == name {
			return s.guid, true
		}
	}
	return format.meta_subasset(a.meta, format.NAV_MESH_KIND, name)
}

// cook_nav_meshes bakes the navmeshes of the scenes that the pass looks at. A navmesh whose key is its blob's is up to
// date. Otherwise its tiles whose keys are the old blob's are kept, and the others bake, on a thread for each core. It
// reports every failure, and returns false if any.
cook_nav_meshes :: proc(options: Cook_Options, pass: ^Pass) -> bool {
	scenes := make([dynamic]int, context.temp_allocator)
	for a, i in pass.assets {
		if a.kind != .Scene || a.carried != nil || a.owner != {} || asset_failed(a.result) {
			continue
		}
		has_nav_mesh := false
		for s in a.subassets {
			has_nav_mesh ||= s.kind == .Nav_Mesh
		}
		for s in a.meta.subassets {
			has_nav_mesh ||= s.kind == format.NAV_MESH_KIND
		}
		if has_nav_mesh {
			append(&scenes, i)
		}
	}
	if len(scenes) == 0 {
		return true
	}
	out_dir := config_dir(options)
	if !make_output_dir(pass, out_dir, {}) {
		return false
	}
	project := nav_project(options, pass)
	meshes := make(map[format.Guid]Nav_Mesh_Source, context.temp_allocator)
	ok := true
	step_begin(pass, .Nav_Mesh, "", len(scenes))
	for i in scenes {
		defer step_advance(pass)
		a := &pass.assets[i]
		// The scene's cook reported what is wrong with its file and its volumes.
		flat, flat_ok := scene_flat(pass, i)
		if !flat_ok {
			continue
		}
		s := nav_scene_make(flat)
		quiet := Problems {
			list = make([dynamic]Problem, context.temp_allocator),
		}
		for v in nav_volumes(&s, project.agents, a.path, &quiet) {
			margin: f32 = 0
			for k in v.agents {
				margin = max(margin, nav_border_meters(project.agents[k], v.settings))
			}
			triangles := nav_collect(&s, v, margin, out_dir, &meshes, a, &pass.problems)
			for k in v.agents {
				agent := project.agents[k]
				name := nav_subasset_name(v.entity, agent.name)
				guid, found := nav_mesh_guid(a^, name)
				if !found {
					report_warning(&pass.problems, a.path, 0, 0, "the navmesh %s has no GUID yet: cook the scene, and then its navmeshes", name)
					continue
				}
				plan := nav_plan({guid = guid, volume = v.entity, anchor = v.anchor, agent = agent, agent_index = u32(k), settings = v.settings, bounds_min = v.bounds_min, bounds_max = v.bounds_max, triangles = triangles})
				buffer: [32]u8
				output := fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(guid, &buffer))
				if cooked_key(output, .Nav_Mesh, format.nav_mesh_layout()) == plan.key && !pass.force[a.meta.guid] {
					count_subassets(pass, .Nav_Mesh, .Current)
					pass.nav_tiles[.Current] += len(plan.tiles)
					continue
				}
				result := nav_bake(&plan, nav_read_blob(output))
				pass.nav_tiles[.Cooked] += result.baked
				pass.nav_tiles[.Current] += result.reused
				if result.failed > 0 {
					report_error(&pass.problems, a.path, 0, 0, "the navmesh %s: Recast could not bake %d of its tiles", name, result.failed)
					count_subassets(pass, .Nav_Mesh, .Failed)
					ok = false
					continue
				}
				if !write_blob(output, result.blob) {
					count_subassets(pass, .Nav_Mesh, .Failed)
					ok = false
					continue
				}
				count_subassets(pass, .Nav_Mesh, .Cooked)
			}
		}
	}
	return ok
}

// nav_subasset_name is a navmesh's name in its scene's .meta file: its volume's scene ID and its agent type.
nav_subasset_name :: proc(entity: u64, agent: string) -> string {
	return fmt.tprintf("%016x.%s", entity, agent)
}

// Nav_Pose is an entity's pose in the world, as propagation gives it: a World_Position's raw value, a rotation and a
// scale.
Nav_Pose :: struct {
	position: [3]i64,
	rotation: quaternion128,
	scale:    [3]f32,
}

// Nav_Scene is a flat scene with its entities by scene ID, and their poses and activity, which it works out once.
Nav_Scene :: struct {
	flat:   format.Scene,
	index:  map[u64]int,
	poses:  []Maybe(Nav_Pose),
	active: []Maybe(bool),
}

nav_scene_make :: proc(flat: format.Scene) -> Nav_Scene {
	s := Nav_Scene {
		flat   = flat,
		index  = make(map[u64]int, len(flat.entities), context.temp_allocator),
		poses  = make([]Maybe(Nav_Pose), len(flat.entities), context.temp_allocator),
		active = make([]Maybe(bool), len(flat.entities), context.temp_allocator),
	}
	for e, i in flat.entities {
		s.index[e.id] = i
	}
	return s
}

@(private = "file")
nav_has_volume :: proc(flat: format.Scene) -> bool {
	for &e in flat.entities {
		if scene_component(&e, format.SCENE_NAV_MESH_VOLUME_ID) != nil {
			return true
		}
	}
	return false
}

// scene_component is an entity's component of a stable ID, or nil.
scene_component :: proc(e: ^format.Scene_Entity, id: u64) -> ^format.Scene_Component {
	for &c in e.components {
		if c.id == id {
			return &c
		}
	}
	return nil
}

// read_component sets the fields of value that a scene's component writes, as the scene loader does: by their names,
// over value, which holds the registered defaults. A value of another kind than its field's is left out.
read_component :: proc(c: ^format.Scene_Component, value: ^$T) {
	for field in reflect.struct_fields_zipped(T) {
		h := format.scene_field_hash(field.name)
		for f in c.fields {
			if f.hash == h {
				read_field(rawptr(uintptr(value) + field.offset), field.type, f.value)
			}
		}
	}
}

@(private = "file")
read_field :: proc(target: rawptr, type: ^reflect.Type_Info, v: format.Scene_Value) {
	number := v.kind == .Number && v.count == 1
	switch type.id {
	case f32:
		if number {
			(^f32)(target)^ = f32(v.floats[0])
		}
	case u32:
		if number && v.floats[0] >= 0 {
			(^u32)(target)^ = u32(v.floats[0])
		}
	case u8:
		if number && v.floats[0] >= 0 {
			(^u8)(target)^ = u8(v.floats[0])
		}
	case bool:
		if v.kind == .Bool {
			(^bool)(target)^ = v.ints[0] != 0
		}
	case [3]f32:
		if v.kind == .Number && v.count == 3 {
			(^[3]f32)(target)^ = {f32(v.floats[0]), f32(v.floats[1]), f32(v.floats[2])}
		}
	case quaternion128:
		// x, y, z, w, as the files write them.
		if v.kind == .Number && v.count == 4 {
			(^quaternion128)(target)^ = quaternion(real = f32(v.floats[3]), imag = f32(v.floats[0]), jmag = f32(v.floats[1]), kmag = f32(v.floats[2]))
		}
	case format.Guid:
		if v.kind == .Asset {
			(^format.Guid)(target)^ = v.asset
		}
	case:
		e, is_enum := reflect.type_info_base(type).variant.(reflect.Type_Info_Enum)
		if !is_enum || v.kind != .Name {
			return
		}
		for name, i in e.names {
			if name != v.text {
				continue
			}
			switch type.size {
			case 1:
				(^u8)(target)^ = u8(e.values[i])
			case 2:
				(^u16)(target)^ = u16(e.values[i])
			case 4:
				(^u32)(target)^ = u32(e.values[i])
			}
		}
	}
}

// The fields of a Local_Transform, and of a Transform besides its position, with their defaults.
@(private = "file")
Nav_Local :: struct {
	offset:   [3]f32,
	rotation: quaternion128,
	scale:    [3]f32,
}

@(private = "file")
LOCAL_IDENTITY :: Nav_Local {
	rotation = format.DEFAULT_ROTATION,
	scale    = format.DEFAULT_SCALE,
}

// nav_pose is an entity's pose: a root's Transform, and a child's Local_Transform composed onto its parent's pose, as
// propagation composes them. A child without a Local_Transform keeps its Transform.
nav_pose :: proc(s: ^Nav_Scene, i: int, depth := 0) -> Nav_Pose {
	if p, found := s.poses[i].?; found {
		return p
	}
	e := &s.flat.entities[i]
	pose := Nav_Pose {
		rotation = format.DEFAULT_ROTATION,
		scale    = format.DEFAULT_SCALE,
	}
	if c := scene_component(e, format.SCENE_TRANSFORM_ID); c != nil {
		rest := LOCAL_IDENTITY
		read_component(c, &rest)
		pose.rotation, pose.scale = rest.rotation, rest.scale
		for f in c.fields {
			// A position is three integers, the raw value.
			if f.name == "position" && f.value.kind == .Number && f.value.count == 3 && f.value.integer & 0b111 == 0b111 {
				pose.position = {f.value.ints[0], f.value.ints[1], f.value.ints[2]}
			}
		}
	}
	parent, has_parent := s.index[e.parent]
	if local := scene_component(e, format.SCENE_LOCAL_TRANSFORM_ID); local != nil && has_parent && e.parent != 0 && depth < MAX_DEPTH {
		l := LOCAL_IDENTITY
		read_component(local, &l)
		above := nav_pose(s, parent, depth + 1)
		delta := linalg.quaternion_mul_vector3(above.rotation, l.offset * above.scale)
		pose = {
			position = above.position + {i64(math.round(delta.x * POSITION_SCALE)), i64(math.round(delta.y * POSITION_SCALE)), i64(math.round(delta.z * POSITION_SCALE))},
			rotation = above.rotation * l.rotation,
			scale    = above.scale * l.scale,
		}
	}
	s.poses[i] = pose
	return pose
}

// nav_active is whether an entity is active: it and each of its ancestors.
nav_active :: proc(s: ^Nav_Scene, i: int, depth := 0) -> bool {
	if a, found := s.active[i].?; found {
		return a
	}
	e := &s.flat.entities[i]
	active := e.active
	if parent, found := s.index[e.parent]; found && e.parent != 0 && active && depth < MAX_DEPTH {
		active = nav_active(s, parent, depth + 1)
	}
	s.active[i] = active
	return active
}

// nav_static is whether an entity's Collider is part of a static body: its own Rigid_Body's, or else the nearest
// ancestor's with one, is static, or none has one (see docs/physics/design.md#components).
nav_static :: proc(s: ^Nav_Scene, i: int) -> bool {
	current := i
	for _ in 0 ..< MAX_DEPTH {
		e := &s.flat.entities[current]
		if c := scene_component(e, format.SCENE_RIGID_BODY_ID); c != nil {
			body := format.DEFAULT_RIGID_BODY
			read_component(c, &body)
			return body.motion == .Static
		}
		parent, found := s.index[e.parent]
		if !found || e.parent == 0 {
			return true
		}
		current = parent
	}
	return true
}

// Nav_Volume is a Nav_Mesh_Volume that bakes: its entity, its settings, the agent types that it bakes for, by their
// index in the project's, and its box: its center as a raw World_Position, and its bounds along the world's axes,
// relative to the center.
Nav_Volume :: struct {
	entity:     u64,
	settings:   format.Nav_Mesh_Volume,
	agents:     []int,
	anchor:     [3]i64,
	bounds_min: [3]f32,
	bounds_max: [3]f32,
}

// nav_volumes finds the volumes of a scene that bake, by scene ID: each active entity with a Nav_Mesh_Volume and a box
// Volume. A volume of another shape, or one whose agents name a type that the project does not have, is a warning.
nav_volumes :: proc(s: ^Nav_Scene, agents: []format.Nav_Agent, path: string, problems: ^Problems) -> []Nav_Volume {
	result := make([dynamic]Nav_Volume, context.temp_allocator)
	for &e, i in s.flat.entities {
		c := scene_component(&e, format.SCENE_NAV_MESH_VOLUME_ID)
		if c == nil || !nav_active(s, i) {
			continue
		}
		settings := format.DEFAULT_NAV_MESH_VOLUME
		read_component(c, &settings)
		volume: format.Volume
		if vc := scene_component(&e, format.SCENE_VOLUME_ID); vc != nil {
			read_component(vc, &volume)
		}
		if scene_component(&e, format.SCENE_VOLUME_ID) == nil || volume.shape != .Box {
			report_warning(problems, path, 0, 0, "entity %016x: a Nav_Mesh_Volume bakes inside its entity's Volume, whose shape must be Box", e.id)
			continue
		}
		if len(agents) < 32 && settings.agents >> u32(len(agents)) != 0 {
			report_warning(problems, path, 0, 0, "entity %016x: the Nav_Mesh_Volume's agents name types past the %d that nav.agents gives", e.id, len(agents))
		}
		chosen := make([dynamic]int, context.temp_allocator)
		for _, k in agents {
			if format.nav_volume_agents(settings.agents, k) {
				append(&chosen, k)
			}
		}
		pose := nav_pose(s, i)
		extents: [3]f32
		for k in 0 ..< 3 {
			extents[k] = (volume.extents[k] > 0 ? volume.extents[k] : format.VOLUME_DEFAULT_EXTENT) * abs(pose.scale[k])
		}
		// The box's bounds along the world's axes: a rotated box bakes the box that holds it.
		axes := linalg.matrix3_from_quaternion(pose.rotation)
		half: [3]f32
		for row in 0 ..< 3 {
			for column in 0 ..< 3 {
				half[row] += abs(axes[row, column]) * extents[column]
			}
		}
		append(&result, Nav_Volume{entity = e.id, settings = settings, agents = chosen[:], anchor = pose.position, bounds_min = -half, bounds_max = half})
	}
	slice.sort_by(result[:], proc(a, b: Nav_Volume) -> bool {return a.entity < b.entity})
	return result[:]
}

// nav_settings is a volume's settings for the bake: its cell sizes and tiles, with 0 or less taking the defaults.
@(private = "file")
nav_settings :: proc(v: format.Nav_Mesh_Volume) -> (cell_size, cell_height: f32, tile_size: i32) {
	d := format.DEFAULT_NAV_MESH_VOLUME
	cell_size = v.cell_size > 0 ? max(v.cell_size, 0.01) : d.cell_size
	cell_height = v.cell_height > 0 ? max(v.cell_height, 0.01) : d.cell_height
	tile_size = v.tile_size > 0 ? clamp(i32(v.tile_size), 8, 1024) : i32(d.tile_size)
	return
}

// nav_border_meters is how far past a tile its bake reads triangles: an agent's radius, which erodes the edges, and three
// cells more, so the tiles' edges meet.
@(private = "file")
nav_border_meters :: proc(agent: format.Nav_Agent, v: format.Nav_Mesh_Volume) -> f32 {
	cell_size, _, _ := nav_settings(v)
	return f32(nav_border_cells(agent, cell_size)) * cell_size
}

@(private = "file")
nav_border_cells :: proc(agent: format.Nav_Agent, cell_size: f32) -> i32 {
	return i32(math.ceil(agent.radius / cell_size)) + 3
}

// Nav_Mesh_Source is a collider's mesh: its cooked collision data, which the pass reads once.
Nav_Mesh_Source :: struct {
	state:     enum u8 {
		Missing,
		No_Collision,
		Read,
	},
	positions: [][3]f32,
	triangles: [][3]u32,
}

// nav_collect gives the triangles of the static colliders that reach a volume, relative to its center, in the scene's
// order: those within its bounds, and margin past them across. A collider whose mesh is not cooked, or has no collision
// data, is a warning, and the mesh is one of the scene's dependencies.
nav_collect :: proc(s: ^Nav_Scene, v: Nav_Volume, margin: f32, out_dir: string, meshes: ^map[format.Guid]Nav_Mesh_Source, a: ^Asset_Source, problems: ^Problems) -> [][3][3]f32 {
	result := make([dynamic][3][3]f32, context.temp_allocator)
	low := v.bounds_min - {margin, 0, margin}
	high := v.bounds_max + {margin, 0, margin}
	local := make([dynamic][3][3]f32, context.temp_allocator)
	for &e, i in s.flat.entities {
		c := scene_component(&e, format.SCENE_COLLIDER_ID)
		if c == nil || scene_component(&e, format.SCENE_CHARACTER_ID) != nil || !nav_active(s, i) || !nav_static(s, i) {
			continue
		}
		collider := format.DEFAULT_COLLIDER
		read_component(c, &collider)
		if collider.sensor {
			continue
		}
		pose := nav_pose(s, i)
		d := pose.position - v.anchor
		center := [3]f32{f32(d.x), f32(d.y), f32(d.z)} / POSITION_SCALE
		center += linalg.quaternion_mul_vector3(pose.rotation, collider.offset * pose.scale)
		orientation := pose.rotation * collider.rotation
		scale := linalg.abs(pose.scale)
		clear(&local)
		switch collider.shape {
		case .Box:
			nav_box(&local, linalg.max(collider.size * scale * 0.5, 1e-3))
		case .Sphere:
			radius := max(collider.radius * max(scale.x, scale.y, scale.z), 1e-3)
			rings := make([dynamic][2]f32, context.temp_allocator)
			for k in 0 ..= SEGMENTS / 2 {
				angle := f32(k) * math.PI / (SEGMENTS / 2)
				append(&rings, [2]f32{radius * math.sin(angle), -radius * math.cos(angle)})
			}
			nav_lathe(&local, rings[:])
		case .Capsule:
			radius := max(collider.radius * max(scale.x, scale.z), 1e-3)
			half := max(collider.height * scale.y * 0.5 - radius, 1e-3)
			rings := make([dynamic][2]f32, context.temp_allocator)
			for k in 0 ..= SEGMENTS / 4 {
				angle := f32(k) * math.PI / (SEGMENTS / 2)
				append(&rings, [2]f32{radius * math.sin(angle), -half - radius * math.cos(angle)})
			}
			for k in SEGMENTS / 4 ..= SEGMENTS / 2 {
				angle := f32(k) * math.PI / (SEGMENTS / 2)
				append(&rings, [2]f32{radius * math.sin(angle), half - radius * math.cos(angle)})
			}
			nav_lathe(&local, rings[:])
		case .Cylinder:
			radius := max(collider.radius * max(scale.x, scale.z), 1e-3)
			half := max(collider.height * scale.y * 0.5, 1e-3)
			nav_lathe(&local, {{0, -half}, {radius, -half}, {radius, half}, {0, half}})
		case .Mesh, .Convex_Mesh:
			source := nav_mesh_source(meshes, out_dir, collider.mesh)
			if collider.mesh != {} && !slice.contains(a.dependencies[:], collider.mesh) {
				append(&a.dependencies, collider.mesh)
			}
			buffer: [32]u8
			switch source.state {
			case .Missing:
				report_warning(problems, a.path, 0, 0, "entity %016x: its Collider's mesh %s is not cooked, so its navmeshes leave it out", e.id, format.guid_format(collider.mesh, &buffer))
				continue
			case .No_Collision:
				report_warning(problems, a.path, 0, 0, "entity %016x: its Collider's mesh %s has no collision data, so its navmeshes leave it out: its collision import setting is false", e.id, format.guid_format(collider.mesh, &buffer))
				continue
			case .Read:
			}
			// A mirroring scale turns the triangles inside out, so they turn back.
			mirrored := pose.scale.x * pose.scale.y * pose.scale.z < 0
			for t in source.triangles {
				triangle: [3][3]f32
				for k in 0 ..< 3 {
					triangle[k] = linalg.quaternion_mul_vector3(collider.rotation, source.positions[t[k]] * pose.scale)
				}
				if mirrored {
					triangle[1], triangle[2] = triangle[2], triangle[1]
				}
				append(&local, triangle)
			}
			// The mesh's vertices are placed in the collider's rotation already.
			orientation = pose.rotation
		}
		for &t in local {
			placed: [3][3]f32
			low_t, high_t := [3]f32{max(f32), max(f32), max(f32)}, [3]f32{min(f32), min(f32), min(f32)}
			for k in 0 ..< 3 {
				placed[k] = center + linalg.quaternion_mul_vector3(orientation, t[k])
				low_t, high_t = linalg.min(low_t, placed[k]), linalg.max(high_t, placed[k])
			}
			if high_t.x >= low.x && low_t.x <= high.x && high_t.y >= low.y && low_t.y <= high.y && high_t.z >= low.z && low_t.z <= high.z {
				append(&result, placed)
			}
		}
	}
	return result[:]
}

@(private = "file")
nav_mesh_source :: proc(meshes: ^map[format.Guid]Nav_Mesh_Source, out_dir: string, guid: format.Guid) -> Nav_Mesh_Source {
	if source, found := meshes[guid]; found {
		return source
	}
	source: Nav_Mesh_Source
	buffer: [32]u8
	data := nav_read_blob(fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(guid, &buffer)))
	if blob, ok := format.mesh_view(data); ok && guid != {} {
		source.positions = format.mesh_collision_positions(data, blob)
		source.triangles = format.mesh_collision_triangles(data, blob)
		source.state = .Read if len(source.positions) > 0 && len(source.triangles) > 0 else .No_Collision
	}
	meshes[guid] = source
	return source
}

// nav_read_blob reads a cooked blob at the runtime's alignment, or gives nil.
nav_read_blob :: proc(path: string) -> []byte {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil
	}
	aligned, _ := mem.alloc_bytes(len(data), format.BLOB_ALIGN, context.temp_allocator)
	copy(aligned, data)
	return aligned
}

// nav_outward adds a triangle of a convex shape about the origin, wound so that its normal, by Recast's right-hand
// rule, points out: Recast marks a triangle walkable by its normal.
@(private = "file")
nav_outward :: proc(out: ^[dynamic][3][3]f32, a, b, c: [3]f32) {
	normal := linalg.cross(b - a, c - a)
	if linalg.length2(normal) < 1e-12 {
		return
	}
	if linalg.dot(normal, a + b + c) < 0 {
		append(out, [3][3]f32{a, c, b})
	} else {
		append(out, [3][3]f32{a, b, c})
	}
}

@(private = "file")
nav_box :: proc(out: ^[dynamic][3][3]f32, half: [3]f32) {
	corner :: proc(half: [3]f32, i: int) -> [3]f32 {
		return {i & 1 != 0 ? half.x : -half.x, i & 2 != 0 ? half.y : -half.y, i & 4 != 0 ? half.z : -half.z}
	}
	// Each face's corners, around it.
	FACES :: [6][4]int{{0, 2, 6, 4}, {1, 3, 7, 5}, {0, 1, 5, 4}, {2, 3, 7, 6}, {0, 1, 3, 2}, {4, 5, 7, 6}}
	for f in FACES {
		nav_outward(out, corner(half, f[0]), corner(half, f[1]), corner(half, f[2]))
		nav_outward(out, corner(half, f[0]), corner(half, f[2]), corner(half, f[3]))
	}
}

// nav_lathe turns rings of a radius at a height about y into triangles, closing the ends that have a radius.
@(private = "file")
nav_lathe :: proc(out: ^[dynamic][3][3]f32, rings: [][2]f32) {
	point :: proc(ring: [2]f32, segment: int) -> [3]f32 {
		angle := f32(segment % SEGMENTS) * 2 * math.PI / SEGMENTS
		return {ring.x * math.cos(angle), ring.y, ring.x * math.sin(angle)}
	}
	for k in 0 ..< len(rings) - 1 {
		for j in 0 ..< SEGMENTS {
			a, b := point(rings[k], j), point(rings[k], j + 1)
			c, d := point(rings[k + 1], j + 1), point(rings[k + 1], j)
			nav_outward(out, a, b, c)
			nav_outward(out, a, c, d)
		}
	}
	for ring in ([][2]f32{rings[0], rings[len(rings) - 1]}) {
		if ring.x <= 0 {
			continue
		}
		for j in 0 ..< SEGMENTS {
			nav_outward(out, {0, ring.y, 0}, point(ring, j), point(ring, j + 1))
		}
	}
}

// Nav_Bake_Input is what a navmesh bakes from: its GUID, its volume's scene ID, center, settings and bounds, its agent
// type and its index in the project's types, and the triangles that reach the volume, relative to its center.
Nav_Bake_Input :: struct {
	guid:        format.Guid,
	volume:      u64,
	anchor:      [3]i64,
	agent:       format.Nav_Agent,
	agent_index: u32,
	settings:   format.Nav_Mesh_Volume,
	bounds_min: [3]f32,
	bounds_max: [3]f32,
	triangles:  [][3][3]f32,
}

// Nav_Tile_Params is a tile's bake but its triangles: its place in the grid and Recast's settings. Every field is 4
// bytes, so it hashes without padding.
Nav_Tile_Params :: struct {
	x, z:                     u32,
	// Its first cell across, in the volume's grid.
	first_x, first_z:         i32,
	// The tile's bounds without the border, and Recast's heightfield's with it.
	bounds_min:               [3]f32,
	bounds_max:               [3]f32,
	heightfield_min:          [3]f32,
	heightfield_max:          [3]f32,
	width, height, border:    i32,
	cell_size, cell_height:   f32,
	walkable_slope:           f32,
	walkable_height:          i32,
	walkable_climb:           i32,
	walkable_radius:          i32,
	min_region_area:          i32,
	merge_region_area:        i32,
	max_edge_length:          i32,
	max_simplification_error: f32,
	detail_sample_distance:   f32,
	detail_sample_max_error:  f32,
}

#assert(size_of(Nav_Tile_Params) % 4 == 0 && align_of(Nav_Tile_Params) == 4)

// Nav_Tile_Plan is a tile to bake: its params, the triangles that reach it, by their index in the input, and its key.
Nav_Tile_Plan :: struct {
	params:    Nav_Tile_Params,
	triangles: []int,
	key:       u64,
}

// Nav_Plan is a navmesh's bake: its tiles and its key, which hashes theirs.
Nav_Plan :: struct {
	input:       Nav_Bake_Input,
	cell_size:   f32,
	cell_height: f32,
	tile_meters: f32,
	tiles_x:     u32,
	tiles_z:     u32,
	tiles:       []Nav_Tile_Plan,
	key:         u64,
}

// nav_plan lays a navmesh's tiles over its volume's bounds and gives each the triangles that reach it, with its border,
// and its key: the cooker's and Recast's versions, its params and its triangles, so an edit changes only the keys of the
// tiles that it reaches.
nav_plan :: proc(input: Nav_Bake_Input) -> Nav_Plan {
	cell_size, cell_height, tile_size := nav_settings(input.settings)
	agent := input.agent
	border := nav_border_cells(agent, cell_size)
	size := input.bounds_max - input.bounds_min
	cells_x := max(i32(math.ceil(size.x / cell_size)), 1)
	cells_z := max(i32(math.ceil(size.z / cell_size)), 1)
	plan := Nav_Plan {
		input       = input,
		cell_size   = cell_size,
		cell_height = cell_height,
		tile_meters = f32(tile_size) * cell_size,
		tiles_x     = u32((cells_x + tile_size - 1) / tile_size),
		tiles_z     = u32((cells_z + tile_size - 1) / tile_size),
	}
	tiles := make([]Nav_Tile_Plan, plan.tiles_x * plan.tiles_z, context.temp_allocator)
	pad := f32(border) * cell_size
	for &tile, i in tiles {
		p := &tile.params
		p.x, p.z = u32(i) % plan.tiles_x, u32(i) / plan.tiles_x
		p.first_x, p.first_z = i32(p.x) * tile_size, i32(p.z) * tile_size
		width := min(tile_size, cells_x - p.first_x)
		depth := min(tile_size, cells_z - p.first_z)
		p.bounds_min = {input.bounds_min.x + f32(p.first_x) * cell_size, input.bounds_min.y, input.bounds_min.z + f32(p.first_z) * cell_size}
		p.bounds_max = {input.bounds_min.x + f32(p.first_x + width) * cell_size, input.bounds_max.y, input.bounds_min.z + f32(p.first_z + depth) * cell_size}
		p.heightfield_min = p.bounds_min - {pad, 0, pad}
		p.heightfield_max = p.bounds_max + {pad, 0, pad}
		p.width, p.height, p.border = width + 2 * border, depth + 2 * border, border
		p.cell_size, p.cell_height = cell_size, cell_height
		p.walkable_slope = agent.max_slope
		p.walkable_height = i32(math.ceil(agent.height / cell_height))
		p.walkable_climb = i32(math.floor(agent.step_height / cell_height))
		p.walkable_radius = i32(math.ceil(agent.radius / cell_size))
		p.min_region_area = MIN_REGION_AREA
		p.merge_region_area = MERGE_REGION_AREA
		p.max_edge_length = i32(MAX_EDGE_METERS / cell_size)
		p.max_simplification_error = MAX_SIMPLIFICATION_ERROR
		p.detail_sample_distance = DETAIL_SAMPLE_CELLS * cell_size
		p.detail_sample_max_error = cell_height

		chosen := make([dynamic]int, context.temp_allocator)
		for t, k in input.triangles {
			low := linalg.min(linalg.min(t[0], t[1]), t[2])
			high := linalg.max(linalg.max(t[0], t[1]), t[2])
			if high.x >= p.heightfield_min.x && low.x <= p.heightfield_max.x && high.z >= p.heightfield_min.z && low.z <= p.heightfield_max.z &&
			   high.y >= p.bounds_min.y && low.y <= p.bounds_max.y {
				append(&chosen, k)
			}
		}
		tile.triangles = chosen[:]
		key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00", NAV_COOK_VERSION, RECAST_VERSION))
		key = hash.fnv64a(mem.ptr_to_bytes(p), key)
		for k in tile.triangles {
			key = hash.fnv64a(mem.ptr_to_bytes(&input.triangles[k]), key)
		}
		tile.key = key
	}
	plan.tiles = tiles

	header := struct #packed {
		guid:        format.Guid,
		anchor:      [3]i64,
		volume:      u64,
		bounds_min:  [3]f32,
		bounds_max:  [3]f32,
		radius:      f32,
		height:      f32,
		step:        f32,
		slope:       f32,
		cell_size:   f32,
		cell_height: f32,
		tile_meters: f32,
		tiles_x:     u32,
		tiles_z:     u32,
		agent_index: u32,
	}{input.guid, input.anchor, input.volume, input.bounds_min, input.bounds_max, agent.radius, agent.height, agent.step_height, agent.max_slope, cell_size, cell_height, plan.tile_meters, plan.tiles_x, plan.tiles_z, input.agent_index}
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%x\x00%s\x00", NAV_COOK_VERSION, format.nav_mesh_layout(), agent.name))
	key = hash.fnv64a(mem.ptr_to_bytes(&header), key)
	for &tile in tiles {
		key = hash.fnv64a(mem.ptr_to_bytes(&tile.key), key)
	}
	plan.key = key
	return plan
}

// Nav_Tile_Data is a baked tile's part of each of a navmesh blob's streams, with its polygons' links left out: they
// join tiles, so the assembly makes them.
Nav_Tile_Data :: struct {
	vertices:         [][3]f32,
	polygons:         []format.Nav_Polygon,
	details:          []format.Nav_Detail,
	detail_vertices:  [][3]f32,
	detail_triangles: [][4]u8,
}

// Nav_Bake_Result is a navmesh's blob, the tiles that baked and those kept from its old blob, and the tiles that Recast
// could not bake, which leave the blob nil.
Nav_Bake_Result :: struct {
	blob:   []byte,
	baked:  int,
	reused: int,
	failed: int,
}

@(private = "file")
Nav_Tile_Job :: struct {
	plan:  ^Nav_Plan,
	tile:  int,
	arena: virtual.Arena,
	data:  Nav_Tile_Data,
	ok:    bool,
}

// nav_bake bakes a navmesh's plan into its blob: the tiles of previous, an old blob of it, whose keys are the plan's are
// kept, and the others bake on threads threads, or one for each core with 0. The blob is the same on any number.
nav_bake :: proc(plan: ^Nav_Plan, previous: []byte, threads := 0, allocator := context.temp_allocator) -> (result: Nav_Bake_Result) {
	tiles := make([]Nav_Tile_Data, len(plan.tiles), context.temp_allocator)
	jobs := make([dynamic]Nav_Tile_Job, context.temp_allocator)
	old, has_old := format.nav_mesh_view(previous)
	for &tile, i in plan.tiles {
		if has_old && tile.params.x < old.tiles_x && tile.params.z < old.tiles_z {
			record := format.nav_mesh_tiles(previous, old)[tile.params.z * old.tiles_x + tile.params.x]
			if record.key == tile.key {
				tiles[i] = nav_tile_from_blob(previous, old, record)
				result.reused += 1
				continue
			}
		}
		append(&jobs, Nav_Tile_Job{plan = plan, tile = i})
	}
	// The costliest first, as parallel_for asks.
	slice.stable_sort_by(jobs[:], proc(a, b: Nav_Tile_Job) -> bool {
		return len(a.plan.tiles[a.tile].triangles) > len(b.plan.tiles[b.tile].triangles)
	})
	defer for &j in jobs {
		virtual.arena_destroy(&j.arena)
	}
	job_slice := jobs[:]
	parallel_for(len(job_slice), &job_slice, nav_tile_job, threads)
	for &j in jobs {
		if j.ok {
			tiles[j.tile] = j.data
			result.baked += 1
		} else {
			result.failed += 1
		}
	}
	if result.failed > 0 {
		return
	}
	result.blob = format.nav_mesh_write(nav_assemble(plan, tiles), allocator)
	return
}

@(private = "file")
nav_tile_job :: proc(data: rawptr, index: int) {
	job := &(^[]Nav_Tile_Job)(data)[index]
	tile := &job.plan.tiles[job.tile]
	_ = virtual.arena_init_growing(&job.arena)
	allocator := virtual.arena_allocator(&job.arena)
	// A tile that no triangle reaches is empty, and Recast need not say so.
	if len(tile.triangles) == 0 {
		job.ok = true
		return
	}
	vertices := make([]f32, 9 * len(tile.triangles), context.temp_allocator)
	indices := make([]i32, 3 * len(tile.triangles), context.temp_allocator)
	for t, k in tile.triangles {
		triangle := job.plan.input.triangles[t]
		for c in 0 ..< 3 {
			vertices[9 * k + 3 * c + 0] = triangle[c].x
			vertices[9 * k + 3 * c + 1] = triangle[c].y
			vertices[9 * k + 3 * c + 2] = triangle[c].z
			indices[3 * k + c] = i32(3 * k + c)
		}
	}
	p := tile.params
	input := Recast_Tile_In {
		vertices                 = raw_data(vertices),
		vertex_count             = i32(3 * len(tile.triangles)),
		triangles                = raw_data(indices),
		triangle_count           = i32(len(tile.triangles)),
		bounds_min               = p.heightfield_min,
		bounds_max               = p.heightfield_max,
		width                    = p.width,
		height                   = p.height,
		border                   = p.border,
		cell_size                = p.cell_size,
		cell_height              = p.cell_height,
		walkable_slope           = p.walkable_slope,
		walkable_height          = p.walkable_height,
		walkable_climb           = p.walkable_climb,
		walkable_radius          = p.walkable_radius,
		min_region_area          = p.min_region_area,
		merge_region_area        = p.merge_region_area,
		max_edge_length          = p.max_edge_length,
		max_simplification_error = p.max_simplification_error,
		detail_sample_distance   = p.detail_sample_distance,
		detail_sample_max_error  = p.detail_sample_max_error,
	}
	out: Recast_Tile_Out
	if cn_recast_bake_tile(&input, &out) != 0 {
		return
	}
	defer cn_recast_tile_free(&out)
	job.data = nav_tile_from_recast(&out, job.plan, p, allocator)
	job.ok = true
}

// nav_tile_from_recast copies a tile out of Recast's meshes. A vertex's place across is in the volume's grid of cells, so
// the tiles on each side of an edge give its vertices the same position.
@(private = "file")
nav_tile_from_recast :: proc(out: ^Recast_Tile_Out, plan: ^Nav_Plan, p: Nav_Tile_Params, allocator: mem.Allocator) -> (data: Nav_Tile_Data) {
	origin := plan.input.bounds_min
	data.vertices = make([][3]f32, out.vertex_count, allocator)
	for &v, i in data.vertices {
		cell := out.vertices[3 * i:][:3]
		v = {origin.x + f32(p.first_x + i32(cell[0])) * p.cell_size, origin.y + f32(cell[1]) * p.cell_height, origin.z + f32(p.first_z + i32(cell[2])) * p.cell_size}
	}
	stride := int(out.max_vertices)
	data.polygons = make([]format.Nav_Polygon, out.polygon_count, allocator)
	for &polygon, i in data.polygons {
		source := out.polygons[2 * stride * i:][:2 * stride]
		count := 0
		for j in 0 ..< min(stride, format.NAV_MAX_POLYGON_VERTICES) {
			if source[j] == RECAST_NULL_INDEX {
				break
			}
			polygon.vertices[j] = source[j]
			count += 1
		}
		for j in 0 ..< count {
			n := source[stride + j]
			switch {
			case n == RECAST_NULL_INDEX:
				polygon.neighbors[j] = format.NAV_NONE
			case n & RECAST_BORDER_EDGE != 0:
				polygon.neighbors[j] = format.NAV_EXTERNAL | (n & 0x3)
			case:
				polygon.neighbors[j] = n
			}
		}
		polygon.vertex_count = u8(count)
	}
	data.details = make([]format.Nav_Detail, out.polygon_count, allocator)
	for &d, i in data.details {
		m := out.detail_meshes[4 * i:][:4]
		d = {m[0], m[1], m[2], m[3]}
	}
	data.detail_vertices = slice.clone(mem.slice_data_cast([][3]f32, out.detail_vertices[:3 * out.detail_vertex_count]), allocator)
	data.detail_triangles = slice.clone(mem.slice_data_cast([][4]u8, out.detail_triangles[:4 * out.detail_triangle_count]), allocator)
	return
}

// nav_tile_from_blob is a tile of an old blob, which the bake keeps.
@(private = "file")
nav_tile_from_blob :: proc(data: []byte, blob: ^format.Nav_Mesh_Blob, tile: format.Nav_Tile) -> Nav_Tile_Data {
	polygons := slice.clone(format.nav_mesh_polygons(data, blob)[tile.first_polygon:][:tile.polygon_count], context.temp_allocator)
	for &p in polygons {
		p.first_link, p.link_count = 0, 0
	}
	return {
		vertices = format.nav_mesh_vertices(data, blob)[tile.first_vertex:][:tile.vertex_count],
		polygons = polygons,
		details = format.nav_mesh_details(data, blob)[tile.first_polygon:][:tile.polygon_count],
		detail_vertices = format.nav_mesh_detail_vertices(data, blob)[tile.first_detail_vertex:][:tile.detail_vertex_count],
		detail_triangles = format.nav_mesh_detail_triangles(data, blob)[tile.first_detail_triangle:][:tile.detail_triangle_count],
	}
}

// nav_assemble joins a navmesh's tiles into its blob's contents, and links each polygon's edges on its tile's border to
// the polygons across them that they overlap, at heights an agent steps between.
@(private = "file")
nav_assemble :: proc(plan: ^Nav_Plan, tiles: []Nav_Tile_Data) -> format.Nav_Mesh_Contents {
	records := make([]format.Nav_Tile, len(tiles), context.temp_allocator)
	vertices := make([dynamic][3]f32, context.temp_allocator)
	polygons := make([dynamic]format.Nav_Polygon, context.temp_allocator)
	details := make([dynamic]format.Nav_Detail, context.temp_allocator)
	detail_vertices := make([dynamic][3]f32, context.temp_allocator)
	detail_triangles := make([dynamic][4]u8, context.temp_allocator)
	for t, i in tiles {
		p := plan.tiles[i].params
		records[i] = {
			key                   = plan.tiles[i].key,
			x                     = p.x,
			z                     = p.z,
			bounds_min            = p.bounds_min,
			bounds_max            = p.bounds_max,
			first_vertex          = u32(len(vertices)),
			vertex_count          = u32(len(t.vertices)),
			first_polygon         = u32(len(polygons)),
			polygon_count         = u32(len(t.polygons)),
			first_detail_vertex   = u32(len(detail_vertices)),
			detail_vertex_count   = u32(len(t.detail_vertices)),
			first_detail_triangle = u32(len(detail_triangles)),
			detail_triangle_count = u32(len(t.detail_triangles)),
		}
		append(&vertices, ..t.vertices)
		append(&polygons, ..t.polygons)
		append(&details, ..t.details)
		append(&detail_vertices, ..t.detail_vertices)
		append(&detail_triangles, ..t.detail_triangles)
	}

	links := make([dynamic]format.Nav_Link, context.temp_allocator)
	agent := plan.input.agent
	climb := agent.step_height + plan.cell_height
	for tile in records {
		for pi in 0 ..< tile.polygon_count {
			polygon := &polygons[tile.first_polygon + pi]
			polygon.first_link = u32(len(links))
			for k in 0 ..< int(polygon.vertex_count) {
				n := polygon.neighbors[k]
				if n == format.NAV_NONE || n & format.NAV_EXTERNAL == 0 {
					continue
				}
				side := format.Nav_Side(n & 0x3)
				x, z := i64(tile.x), i64(tile.z)
				switch side {
				case .West:
					x -= 1
				case .North:
					z += 1
				case .East:
					x += 1
				case .South:
					z -= 1
				}
				if x < 0 || z < 0 || x >= i64(plan.tiles_x) || z >= i64(plan.tiles_z) {
					continue
				}
				other := records[z * i64(plan.tiles_x) + x]
				opposite := format.NAV_EXTERNAL | ((u16(side) + 2) % 4)
				a := vertices[tile.first_vertex + u32(polygon.vertices[k])]
				b := vertices[tile.first_vertex + u32(polygon.vertices[(k + 1) % int(polygon.vertex_count)])]
				for qi in 0 ..< other.polygon_count {
					q := polygons[other.first_polygon + qi]
					for m in 0 ..< int(q.vertex_count) {
						if q.neighbors[m] != opposite {
							continue
						}
						c := vertices[other.first_vertex + u32(q.vertices[m])]
						d := vertices[other.first_vertex + u32(q.vertices[(m + 1) % int(q.vertex_count)])]
						if t_min, t_max, overlaps := nav_edge_overlap(a, b, c, d, side, climb, plan.cell_size); overlaps && len(links) - int(polygon.first_link) < 255 {
							append(&links, format.Nav_Link{polygon = other.first_polygon + qi, edge = u8(k), t_min = t_min, t_max = t_max})
						}
					}
				}
			}
			polygon.link_count = u8(len(links) - int(polygon.first_link))
		}
	}
	input := plan.input
	return {
		guid = input.guid,
		key = plan.key,
		anchor = input.anchor,
		volume = input.volume,
		agent = input.agent,
		agent_index = input.agent_index,
		cell_size = plan.cell_size,
		cell_height = plan.cell_height,
		tile_size = plan.tile_meters,
		tiles_x = plan.tiles_x,
		tiles_z = plan.tiles_z,
		bounds_min = input.bounds_min,
		bounds_max = input.bounds_max,
		tiles = records,
		vertices = vertices[:],
		polygons = polygons[:],
		links = links[:],
		details = details[:],
		detail_vertices = detail_vertices[:],
		detail_triangles = detail_triangles[:],
	}
}

// nav_edge_overlap gives the part of the edge a to b that the edge c to d, on the next tile across side, overlaps, out of
// 255 from a, where the two are within climb of each other's height.
@(private = "file")
nav_edge_overlap :: proc(a, b, c, d: [3]f32, side: format.Nav_Side, climb, cell_size: f32) -> (t_min, t_max: u8, ok: bool) {
	// The edges run along u, on a line of w.
	u, w := 2, 0
	if side == .North || side == .South {
		u, w = 0, 2
	}
	if abs(a[w] - c[w]) > cell_size * 0.01 || abs(b[u] - a[u]) < 1e-6 || abs(d[u] - c[u]) < 1e-6 {
		return
	}
	low := max(min(a[u], b[u]), min(c[u], d[u]))
	high := min(max(a[u], b[u]), max(c[u], d[u]))
	if high - low < cell_size * 0.01 {
		return
	}
	along :: proc(p, q: [3]f32, u: int, at: f32) -> (t, y: f32) {
		t = (at - p[u]) / (q[u] - p[u])
		return t, p.y + (q.y - p.y) * t
	}
	t_low, y_low := along(a, b, u, low)
	t_high, y_high := along(a, b, u, high)
	_, other_low := along(c, d, u, low)
	_, other_high := along(c, d, u, high)
	if abs(y_low - other_low) > climb || abs(y_high - other_high) > climb {
		return
	}
	quantize :: proc(t: f32) -> u8 {
		return u8(clamp(math.round(t * 255), 0, 255))
	}
	return quantize(min(t_low, t_high)), quantize(max(t_low, t_high)), true
}
