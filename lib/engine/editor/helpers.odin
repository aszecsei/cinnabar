package editor

import "core:math"
import "core:math/linalg"

import "cinnabar:engine/debug"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"
import "cinnabar:engine/volume"

// The viewport's helpers (see docs/editor.md#viewport): the shapes of lights, volumes and cameras, as debug lines, for
// the selection or for every entity, as Viewport_Settings.helpers says.

// A helper of an entity that is not selected is grey and faint. A selected light's is its color, made bright.
@(private = "file")
UNSELECTED :: [4]f32{0.6, 0.6, 0.6, 0.5}
@(private = "file")
VOLUME_COLOR :: [4]f32{0.3, 0.8, 1, 1}
@(private = "file")
CAMERA_COLOR :: [4]f32{1, 1, 1, 1}
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

// draw_helpers draws the helpers of this frame into d, while an editor is linked. Call it before the frame draws d's
// lines, while editing. Hidden entities have none.
draw_helpers :: proc(e: ^Editor, w: ^ecs.World, d: ^debug.Draw) {
	mode := e.viewport.settings.helpers
	if !active(e) || mode == .None {
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
			draw_entity_helpers(w, d, entity, pose, selected)
		}
	}
}

@(private = "file")
is_selected :: proc(e: ^Editor, entity: ecs.Entity) -> bool {
	for s in e.viewport.selection {
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
draw_entity_helpers :: proc(w: ^ecs.World, d: ^debug.Draw, entity: ecs.Entity, pose: ecs.Transform, selected: bool) {
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
	if c := ecs.get(w, entity, render.Camera); c != nil {
		color := selected ? CAMERA_COLOR : UNSELECTED
		fov := c.vertical_fov > 0 ? c.vertical_fov : render.DEFAULT_VERTICAL_FOV
		half_y := math.tan(fov / 2) * FRUSTUM_LENGTH
		half_x := half_y * FRUSTUM_ASPECT
		center := forward * FRUSTUM_LENGTH
		corners := [4][3]f32 {
			center - right * half_x - up * half_y,
			center + right * half_x - up * half_y,
			center + right * half_x + up * half_y,
			center - right * half_x + up * half_y,
		}
		for k in 0 ..< 4 {
			debug.line(d, at, ecs.position_offset(at, corners[k]), color)
			debug.line(d, ecs.position_offset(at, corners[k]), ecs.position_offset(at, corners[(k + 1) % 4]), color)
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
}

// Icon is an entity's icon in the viewport, which picks it: at its presented position, in its light's color.
Icon :: struct {
	entity:   ecs.Entity,
	position: ecs.World_Position,
	kind:     Icon_Kind,
	color:    [3]f32,
}

// icon_instances lists the icons of the entities that have one: lights, volumes and cameras, leaving out the hidden
// ones. An entity with more than one of them has the first in Icon_Kind's order.
icon_instances :: proc(w: ^ecs.World, shown: Visibility, allocator := context.allocator) -> []Icon {
	icons := make([dynamic]Icon, allocator)
	it := ecs.world_iter(w)
	for entity in ecs.world_next(&it) {
		if !is_visible(shown, entity) {
			continue
		}
		icon := Icon {
			entity = entity,
			color  = {1, 1, 1},
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

// icons_shown is whether the viewport shows the icons.
@(private)
icons_shown :: proc(e: ^Editor) -> bool {
	return active(e) && e.viewport.settings.show_icons
}
