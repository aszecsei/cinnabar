package editor

import "core:math"
import "core:math/linalg"

import "cinnabar:engine/ai"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/debug"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/nav"
import "cinnabar:engine/physics"
import "cinnabar:engine/render"
import "cinnabar:engine/scene"
import "cinnabar:engine/volume"

// The viewport's helpers (see docs/editor/viewport.md#viewport): the shapes of lights, volumes, reflection probes and cameras,
// as debug lines, for the selection or for every entity, as Viewport_Settings.helpers says. A selected navigation
// volume draws its navmeshes, and the Navigation Path tool's points draw the paths between them (see
// docs/ai/navigation.md#drawing). A selected perceiver draws its cone, and while the game plays, its last rays and what
// it remembers (see docs/ai/perception.md#drawing). A selected agent of the crowd draws its radius, and while the game
// plays, its corridor, its corners, its neighbors and its velocities.

// A helper of an entity that is not selected is grey and faint. A selected light's is its color, made bright.
@(private = "file")
UNSELECTED :: [4]f32{0.6, 0.6, 0.6, 0.5}
@(private = "file")
VOLUME_COLOR :: [4]f32{0.3, 0.8, 1, 1}
@(private = "file")
CAMERA_COLOR :: [4]f32{1, 1, 1, 1}
// A reflection probe's boxes, and their handles (see box_handle_vertices): the influence box, its fade inside it, and
// the projection box.
@(private)
PROBE_COLORS := [link.Box_Handle_Kind][4]f32 {
	.Influence  = {1, 0.85, 0.3, 1},
	.Blend      = {1, 0.85, 0.3, 0.45},
	.Projection = {0.85, 0.45, 1, 1},
}
// A collider's shape, and a sensor's.
@(private = "file")
COLLIDER_COLOR :: [4]f32{0.4, 1, 0.4, 1}
@(private = "file")
SENSOR_COLOR :: [4]f32{1, 0.8, 0.3, 1}
// A directional light's arrow, an area light's normal, and a camera's frustum, in meters.
@(private = "file")
ARROW_LENGTH :: 2
@(private = "file")
NORMAL_LENGTH :: 0.5
@(private = "file")
FRUSTUM_LENGTH :: 1
// The frustum's shape: a 16:9 frame.
@(private = "file")
FRUSTUM_ASPECT :: 16.0 / 9.0
// The Navigation Path tool's points, as small spheres.
@(private = "file")
PROBE_COLOR :: [4]f32{1, 1, 1, 1}
@(private = "file")
PROBE_RADIUS :: 0.08
// A perceiver's cone, the rays of its last sight check, clear and blocked, and the last positions of what it remembers:
// seen now, heard now, and neither, as small spheres.
@(private = "file")
CONE_COLOR :: [4]f32{1, 0.55, 0.2, 1}
@(private = "file")
RAY_CLEAR :: [4]f32{0.3, 1, 0.3, 1}
@(private = "file")
RAY_BLOCKED :: [4]f32{1, 0.25, 0.25, 1}
@(private = "file")
SEEN_COLOR :: [4]f32{0.3, 1, 0.3, 1}
@(private = "file")
HEARD_COLOR :: [4]f32{1, 0.9, 0.3, 1}
@(private = "file")
REMEMBERED_COLOR :: [4]f32{0.6, 0.6, 0.6, 1}
@(private = "file")
MEMORY_RADIUS :: 0.15
// A crowd agent's avoidance radius, at its feet.
@(private = "file")
AGENT_RADIUS_COLOR :: [4]f32{0.3, 0.6, 1, 1}

// draw_helpers draws the helpers of this frame into d, while a linked editor is in Edit. Call it before the frame draws
// d's lines. Hidden entities have none. In Play and Paused, only the selected perceivers and crowd agents draw, with
// what they perceive and how they move.
// The lines are the frame's, which every scene view draws, so the open scene view with the lowest number chooses them
// for all, and with none open there are none.
draw_helpers :: proc(e: ^Editor, w: ^ecs.World, d: ^debug.Draw) {
	index, has_scene_view := scene_viewport(e)
	if !active(e) || !has_scene_view {
		return
	}
	if !editing(e) {
		if e.session.view.viewports[index].settings.helpers == .None {
			return
		}
		for entity in e.session.view.selection {
			if !ecs.is_alive(w, entity) {
				continue
			}
			pose, ok := ecs.presented(w, entity)
			if !ok {
				continue
			}
			if p := ecs.get(w, entity, ai.Perceiver); p != nil {
				draw_perceiver(e, d, entity, p^, pose)
			}
			if e.nav != nil && ecs.has(w, entity, nav.Nav_Agent) {
				nav.draw_agent(e.nav, w, d, entity, pose.position)
			}
		}
		return
	}
	draw_nav_probe(e, d)
	mode := e.session.view.viewports[index].settings.helpers
	if mode == .None {
		return
	}
	shown := visibility(e, w)
	it := ecs.world_iter(w)
	for entity in ecs.world_next(&it) {
		selected := is_selected(e, entity)
		if (mode == .Selected && !selected) || !is_visible(shown, entity) {
			continue
		}
		if pose, ok := ecs.presented(w, entity); ok {
			draw_entity_helpers(e, w, d, entity, pose, selected)
		}
	}
}

// draw_nav_probe draws the Navigation Path tool's points, and with a start and a goal, the path between them for each
// agent type whose navmeshes are loaded, each in its color, faint when partial.
@(private = "file")
draw_nav_probe :: proc(e: ^Editor, d: ^debug.Draw) {
	probe := e.session.view.nav_probe[:]
	for p in probe {
		debug.sphere(d, p, PROBE_RADIUS, PROBE_COLOR)
	}
	if e.nav == nil || len(probe) != 2 {
		return
	}
	drawn: bit_set[0 ..< 64]
	for &m in e.nav.frame {
		agent := m.id.agent
		if agent < 64 && int(agent) in drawn {
			continue
		}
		if agent < 64 {
			drawn += {int(agent)}
		}
		draw_probe_path(e, d, probe[0], probe[1], agent)
	}
}

@(private = "file")
draw_probe_path :: proc(e: ^Editor, d: ^debug.Draw, start, goal: ecs.World_Position, agent: nav.Agent_Type) {
	path := nav.find_path(e.nav, start, goal, agent, allocator = e.platform.frame_allocator)
	color := nav.agent_color(agent)
	if path.status == .Partial {
		color.a *= 0.4
	}
	nav.draw_corners(d, path.corners, color)
}

// draw_perceiver draws a perceiver's cone from its eye: the circle at its range and four edges, or a sphere for a cone
// wider than a half sphere. While the game plays, it draws the rays of its last sight check and the last positions of
// what it remembers too.
@(private = "file")
draw_perceiver :: proc(e: ^Editor, d: ^debug.Draw, entity: ecs.Entity, p: ai.Perceiver, pose: ecs.Transform) {
	eye, forward := ai.eye_of(p, pose)
	right := linalg.normalize0(linalg.quaternion128_mul_vector3(pose.rotation, [3]f32{1, 0, 0}))
	up := linalg.normalize0(linalg.quaternion128_mul_vector3(pose.rotation, [3]f32{0, 1, 0}))
	reach := max(p.sight_range, 0)
	half := math.to_radians(clamp(p.half_angle, 0, 180))
	if half >= math.PI / 2 {
		debug.sphere(d, eye, reach, CONE_COLOR)
	} else {
		end := ecs.position_offset(eye, forward * reach * math.cos(half))
		radius := reach * math.sin(half)
		debug.circle(d, end, right, up, radius, CONE_COLOR)
		for k in 0 ..< 4 {
			angle := f32(k) * math.PI / 2
			edge := (right * math.cos(angle) + up * math.sin(angle)) * radius
			debug.line(d, eye, ecs.position_offset(end, edge), CONE_COLOR)
		}
	}
	m := ai.perception_debug(e.ai, entity) if e.ai != nil else nil
	if m == nil {
		return
	}
	for r in m.rays[:m.ray_count] {
		debug.line(d, m.eye, r.to, RAY_BLOCKED if r.blocked else RAY_CLEAR)
	}
	for entry in m.entries[:m.count] {
		color := SEEN_COLOR if entry.seen else HEARD_COLOR if entry.heard else REMEMBERED_COLOR
		debug.sphere(d, entry.position, MEMORY_RADIUS, color)
	}
}

@(private = "file")
is_selected :: proc(e: ^Editor, entity: ecs.Entity) -> bool {
	for s in e.session.view.selection {
		if s == entity {
			return true
		}
	}
	return false
}

// light_color is a light's helper color: its color, scaled so its brightest channel is 1, or grey when not selected.
@(private = "file")
light_color :: proc(color: [3]f32, selected: bool) -> [4]f32 {
	if !selected {
		return UNSELECTED
	}
	c := color != {} ? color : {1, 1, 1}
	c /= max(c.r, c.g, c.b, 1e-6)
	return {c.r, c.g, c.b, 1}
}

@(private = "file")
draw_entity_helpers :: proc(e: ^Editor, w: ^ecs.World, d: ^debug.Draw, entity: ecs.Entity, pose: ecs.Transform, selected: bool) {
	right := linalg.quaternion128_mul_vector3(pose.rotation, [3]f32{1, 0, 0})
	up := linalg.quaternion128_mul_vector3(pose.rotation, [3]f32{0, 1, 0})
	forward := linalg.quaternion128_mul_vector3(pose.rotation, [3]f32{0, 0, 1})
	at := pose.position
	range_of :: proc(r: f32) -> f32 {
		return r > 0 ? r : render.DEFAULT_LIGHT_RANGE
	}
	size_of_area :: proc(s: f32) -> f32 {
		return s > 0 ? s : render.DEFAULT_AREA_SIZE
	}
	if l := ecs.get(w, entity, render.Point_Light); l != nil {
		debug.sphere(d, at, range_of(l.range), light_color(l.color, selected))
	}
	if l := ecs.get(w, entity, render.Spot_Light); l != nil {
		color := light_color(l.color, selected)
		outer := l.outer_angle > 0 ? l.outer_angle : render.DEFAULT_SPOT_OUTER
		inner := l.inner_angle > 0 ? min(l.inner_angle, outer) : outer
		reach := range_of(l.range)
		end := ecs.position_offset(at, forward * reach * math.cos(outer))
		radius := reach * math.sin(outer)
		debug.circle(d, end, right, up, radius, color)
		for k in 0 ..< 4 {
			angle := f32(k) * math.PI / 2
			edge := (right * math.cos(angle) + up * math.sin(angle)) * radius
			debug.line(d, at, ecs.position_offset(end, edge), color)
		}
		if inner < outer {
			faint := color
			faint.a *= 0.5
			debug.circle(d, ecs.position_offset(at, forward * reach * math.cos(inner)), right, up, reach * math.sin(inner), faint)
		}
	}
	if l := ecs.get(w, entity, render.Directional_Light); l != nil {
		debug.arrow(d, at, ecs.position_offset(at, forward * ARROW_LENGTH), light_color(l.color, selected))
	}
	if l := ecs.get(w, entity, render.Quad_Light); l != nil {
		color := light_color(l.color, selected)
		hx, hy := right * size_of_area(l.width) / 2, up * size_of_area(l.height) / 2
		corners := [4][3]f32{-hx - hy, hx - hy, hx + hy, -hx + hy}
		for k in 0 ..< 4 {
			debug.line(d, ecs.position_offset(at, corners[k]), ecs.position_offset(at, corners[(k + 1) % 4]), color)
		}
		debug.arrow(d, at, ecs.position_offset(at, forward * NORMAL_LENGTH), color)
	}
	if l := ecs.get(w, entity, render.Disk_Light); l != nil {
		color := light_color(l.color, selected)
		debug.circle(d, at, right * size_of_area(l.width) / 2, up * size_of_area(l.height) / 2, 1, color)
		debug.arrow(d, at, ecs.position_offset(at, forward * NORMAL_LENGTH), color)
	}
	if l := ecs.get(w, entity, render.Line_Light); l != nil {
		color := light_color(l.color, selected)
		half := right * size_of_area(l.length) / 2
		a, b := ecs.position_offset(at, -half), ecs.position_offset(at, half)
		debug.line(d, a, b, color)
		if l.radius > 0 {
			debug.circle(d, a, up, forward, l.radius, color)
			debug.circle(d, b, up, forward, l.radius, color)
		}
	}
	if c := ecs.get(w, entity, physics.Collider); c != nil {
		draw_collider(e, d, c^, pose, selected)
	}
	if c := ecs.get(w, entity, physics.Character); c != nil {
		draw_character(d, c^, pose, selected)
	}
	if e.nav != nil && selected {
		id := ecs.get(w, entity, scene.Scene_Entity)
		if id != nil && ecs.has(w, entity, nav.Nav_Mesh_Volume) {
			nav.draw_volume(e.nav, d, id.id)
		}
		// A selected agent's path from where it stands to the tool's goal.
		probe := e.session.view.nav_probe[:]
		if np := ecs.get(w, entity, nav.Nav_Path); np != nil && len(probe) == 2 {
			draw_probe_path(e, d, pose.position, probe[1], np.agent)
		}
	}
	if p := ecs.get(w, entity, ai.Perceiver); p != nil && selected {
		draw_perceiver(e, d, entity, p^, pose)
	}
	if a := ecs.get(w, entity, nav.Nav_Agent); a != nil && selected {
		debug.circle(d, pose.position, {1, 0, 0}, {0, 0, 1}, a.radius, AGENT_RADIUS_COLOR)
	}
	if j, _, ok := physics.joint_of(w, entity); ok {
		draw_joint(w, d, j^, pose, selected)
	}
	if v := ecs.get(w, entity, volume.Volume); v != nil {
		color := selected ? VOLUME_COLOR : UNSELECTED
		blend := color
		blend.a *= 0.4
		extent :: proc(e: f32) -> f32 {
			return e > 0 ? e : volume.DEFAULT_EXTENT
		}
		scale := linalg.abs(pose.scale)
		switch v.shape {
		case .Global:
		case .Box:
			half := [3]f32{extent(v.extents.x), extent(v.extents.y), extent(v.extents.z)} * scale
			debug.box(d, at, half, pose.rotation, color)
			if v.blend_distance > 0 {
				debug.box(d, at, half + v.blend_distance, pose.rotation, blend)
			}
		case .Sphere:
			radius := extent(v.extents.x) * max(scale.x, scale.y, scale.z)
			debug.sphere(d, at, radius, color)
			if v.blend_distance > 0 {
				debug.sphere(d, at, radius + v.blend_distance, blend)
			}
		}
	}
	if p := ecs.get(w, entity, render.Reflection_Probe); p != nil {
		// As the renderer takes them (see render.reflection_probe_records): the fade is inside the influence box.
		extent, projection := render.reflection_probe_extents(p^, pose.scale)
		blend := render.reflection_probe_blend(p^, extent)
		influence := selected ? PROBE_COLORS[.Influence] : UNSELECTED
		debug.box(d, at, extent, pose.rotation, influence)
		if blend > 0 {
			fade := influence
			fade.a *= 0.4
			debug.box(d, at, extent - blend, pose.rotation, fade)
		}
		if p.box_projection {
			debug.box(d, at, projection, pose.rotation, selected ? PROBE_COLORS[.Projection] : UNSELECTED)
		}
	}
	if c := ecs.get(w, entity, render.Camera); c != nil {
		color := selected ? CAMERA_COLOR : UNSELECTED
		fov := c.vertical_fov > 0 ? c.vertical_fov : render.DEFAULT_VERTICAL_FOV
		half_y := math.tan(fov / 2) * FRUSTUM_LENGTH
		// An orthographic camera shows a box: as wide at the camera as ahead of it.
		orthographic := c.projection == .Orthographic
		if orthographic {
			half_y = (c.orthographic_height > 0 ? c.orthographic_height : render.DEFAULT_ORTHOGRAPHIC_HEIGHT) / 2
		}
		half_x := half_y * FRUSTUM_ASPECT
		center := forward * FRUSTUM_LENGTH
		corners := [4][3]f32 {
			-right * half_x - up * half_y,
			right * half_x - up * half_y,
			right * half_x + up * half_y,
			-right * half_x + up * half_y,
		}
		for k in 0 ..< 4 {
			from := orthographic ? ecs.position_offset(at, corners[k]) : at
			debug.line(d, from, ecs.position_offset(at, center + corners[k]), color)
			debug.line(d, ecs.position_offset(at, center + corners[k]), ecs.position_offset(at, center + corners[(k + 1) % 4]), color)
			if orthographic {
				debug.line(d, from, ecs.position_offset(at, corners[(k + 1) % 4]), color)
			}
		}
	}
}

// Icon_Kind is the glyph of an entity's icon. Matches ICON_* in icons.hlsl.
Icon_Kind :: enum u32 {
	Point_Light,
	Spot_Light,
	Directional_Light,
	Area_Light,
	Volume,
	Camera,
	Reflection_Probe,
}

// Icon is an entity's icon in the viewport, which picks it: at its presented position, in its light's color. A
// reflection probe's is a sphere that reflects its cube of the renderer's array, -1 before its first capture.
Icon :: struct {
	entity:   ecs.Entity,
	position: ecs.World_Position,
	kind:     Icon_Kind,
	color:    [3]f32,
	cube:     i32,
}

// icon_instances lists the icons of the entities that have one: lights, volumes, cameras and reflection probes, leaving
// out the hidden ones. An entity with more than one of them has the first in Icon_Kind's order. A probe's cube is the
// renderer's, without which (nil) it has none.
icon_instances :: proc(
	w: ^ecs.World,
	shown: Visibility,
	allocator := context.allocator,
	renderer: ^render.Renderer = nil,
) -> []Icon {
	icons := make([dynamic]Icon, allocator)
	it := ecs.world_iter(w)
	for entity in ecs.world_next(&it) {
		if !is_visible(shown, entity) {
			continue
		}
		icon := Icon {
			entity = entity,
			color  = {1, 1, 1},
			cube   = -1,
		}
		switch {
		case ecs.has(w, entity, render.Point_Light):
			icon.kind, icon.color = .Point_Light, ecs.get(w, entity, render.Point_Light).color
		case ecs.has(w, entity, render.Spot_Light):
			icon.kind, icon.color = .Spot_Light, ecs.get(w, entity, render.Spot_Light).color
		case ecs.has(w, entity, render.Directional_Light):
			icon.kind, icon.color = .Directional_Light, ecs.get(w, entity, render.Directional_Light).color
		case ecs.has(w, entity, render.Quad_Light):
			icon.kind, icon.color = .Area_Light, ecs.get(w, entity, render.Quad_Light).color
		case ecs.has(w, entity, render.Disk_Light):
			icon.kind, icon.color = .Area_Light, ecs.get(w, entity, render.Disk_Light).color
		case ecs.has(w, entity, render.Line_Light):
			icon.kind, icon.color = .Area_Light, ecs.get(w, entity, render.Line_Light).color
		case ecs.has(w, entity, volume.Volume):
			icon.kind = .Volume
		case ecs.has(w, entity, render.Camera):
			icon.kind = .Camera
		case ecs.has(w, entity, render.Reflection_Probe):
			icon.kind = .Reflection_Probe
			if renderer != nil {
				if cube, ok := render.reflection_probe_state(renderer, entity).cube.?; ok {
					icon.cube = cube.index
				}
			}
		case:
			continue
		}
		pose, ok := ecs.presented(w, entity)
		if !ok {
			continue
		}
		icon.position = pose.position
		if icon.color == {} {
			icon.color = {1, 1, 1}
		}
		append(&icons, icon)
	}
	return icons[:]
}

// icons_shown is whether a viewport shows the icons: while editing, when the editor asks for them.
@(private)
icons_shown :: proc(e: ^Editor, viewport := 0) -> bool {
	return editing(e) && e.session.view.viewports[viewport].settings.show_icons
}

// draw_collider draws a collider's shape as the simulation has it, at its offset and rotation in the entity (see
// docs/physics/design.md#the-editor).
@(private = "file")
draw_collider :: proc(e: ^Editor, d: ^debug.Draw, c: physics.Collider, pose: ecs.Transform, selected: bool) {
	color := UNSELECTED
	if selected {
		color = c.sensor ? SENSOR_COLOR : COLLIDER_COLOR
	}
	rotation := pose.rotation * c.rotation
	at := ecs.position_offset(pose.position, linalg.quaternion128_mul_vector3(pose.rotation, c.offset * pose.scale))
	kind, size := physics.collider_size(c, pose.scale)
	switch kind {
	case .Box:
		debug.box(d, at, size, rotation, color)
	case .Sphere:
		debug.sphere(d, at, size.x, color)
	case .Capsule, .Cylinder:
		draw_upright(d, at, rotation, size.x, size.y, kind == .Capsule, color)
	case .Mesh, .Convex_Hull:
		// The mesh's bounds, if it is loaded: its triangles would be too many lines.
		if e.assets == nil {
			return
		}
		h, loaded := asset.find(e.assets, c.mesh)
		if !loaded {
			return
		}
		data, _ := asset.data(e.assets, h)
		if blob, ok := format.mesh_view(data); ok {
			center := ecs.position_offset(at, linalg.quaternion128_mul_vector3(rotation, blob.bounds.center * size))
			debug.box(d, center, (blob.bounds.max - blob.bounds.min) * 0.5 * size, rotation, color)
		}
	}
}

// draw_upright draws a capsule or a cylinder along its rotation's y: its radius, and the half height of the cylinder
// between its caps.
@(private = "file")
draw_upright :: proc(d: ^debug.Draw, at: ecs.World_Position, rotation: quaternion128, radius, half: f32, capsule: bool, color: [4]f32) {
	right := linalg.quaternion128_mul_vector3(rotation, [3]f32{1, 0, 0})
	up := linalg.quaternion128_mul_vector3(rotation, [3]f32{0, 1, 0})
	forward := linalg.quaternion128_mul_vector3(rotation, [3]f32{0, 0, 1})
	top, bottom := ecs.position_offset(at, up * half), ecs.position_offset(at, -up * half)
	debug.circle(d, top, right, forward, radius, color)
	debug.circle(d, bottom, right, forward, radius, color)
	for side in ([4][3]f32{right, -right, forward, -forward}) {
		debug.line(d, ecs.position_offset(top, side * radius), ecs.position_offset(bottom, side * radius), color)
	}
	if capsule {
		debug.sphere(d, top, radius, color)
		debug.sphere(d, bottom, radius, color)
	}
}

// draw_character draws a character's capsule, which stands on its entity's position, upright and unscaled (see
// docs/physics/design.md#the-editor).
@(private = "file")
draw_character :: proc(d: ^debug.Draw, c: physics.Character, pose: ecs.Transform, selected: bool) {
	radius, height := physics.character_size(c)
	up := linalg.quaternion128_mul_vector3(pose.rotation, [3]f32{0, 1, 0})
	at := ecs.position_offset(pose.position, up * height * 0.5)
	draw_upright(d, at, pose.rotation, radius, height * 0.5 - radius, true, COLLIDER_COLOR if selected else UNSELECTED)
}

// The axes of a joint's frame, in meters.
@(private = "file")
JOINT_AXES :: 0.25

// draw_joint draws a joint's frame as axes, its x the hinge's or the slider's axis, and a line to its other body's
// entity (see docs/physics/design.md#the-editor).
@(private = "file")
draw_joint :: proc(w: ^ecs.World, d: ^debug.Draw, j: physics.Joint, pose: ecs.Transform, selected: bool) {
	frame := ecs.Transform {
		position = ecs.position_offset(pose.position, linalg.quaternion128_mul_vector3(pose.rotation, j.offset * pose.scale)),
		rotation = pose.rotation * j.rotation,
		scale    = 1,
	}
	if !selected {
		debug.sphere(d, frame.position, 0.03, UNSELECTED)
		return
	}
	debug.axes(d, frame, JOINT_AXES)
	if j.body_b != 0 && ecs.is_alive(w, j.body_b) {
		if other, ok := ecs.presented(w, j.body_b); ok {
			debug.line(d, frame.position, other.position, COLLIDER_COLOR)
		}
	}
}
