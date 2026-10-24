package ecs

import "core:log"
import "core:math/linalg"

// Engine components have small explicit IDs. A hash of a name is practically never this small.
TRANSFORM_ID :: Component_Id(1)
LOCAL_TRANSFORM_ID :: Component_Id(2)
PARENT_ID :: Component_Id(3)
PREVIOUS_TRANSFORM_ID :: Component_Id(4)

MAX_HIERARCHY_DEPTH :: 64
// Entities per propagation job.
PROPAGATE_BATCH :: 1024

// Transform is the world-space pose. For a root it is the source of truth. For a child, propagation writes it from
// the parent's Transform and the child's Local_Transform.
Transform :: struct {
	position: World_Position,
	rotation: quaternion128,
	scale:    [3]f32,
}

// Local_Transform is a child's pose relative to its parent.
Local_Transform :: struct {
	offset:   [3]f32,
	rotation: quaternion128,
	scale:    [3]f32,
}

// Parent makes an entity a child. Change it only with add or command_add, so the world sees the new hierarchy.
// Despawning a parent despawns its children (see despawn).
Parent :: struct {
	entity: Entity,
}

// Previous_Transform is the Transform at the start of the current tick. Give it to every entity that moves in
// Fixed systems, and to its children, so presentation can interpolate them. See interpolate.
Previous_Transform :: distinct Transform

TRANSFORM_IDENTITY :: Transform {
	rotation = 1,
	scale    = 1,
}

LOCAL_TRANSFORM_IDENTITY :: Local_Transform {
	rotation = 1,
	scale    = 1,
}

// register_engine_components registers the components that the world itself uses. Call it from the game's
// component registration procedure.
register_engine_components :: proc(r: ^Registry) {
	register_component(r, Transform, TRANSFORM_ID)
	register_component(r, Local_Transform, LOCAL_TRANSFORM_ID)
	register_component(r, Parent, PARENT_ID)
	register_component(r, Previous_Transform, PREVIOUS_TRANSFORM_ID)
	register_component(r, Disabled, DISABLED_ID)
	register_component(r, Inactive, INACTIVE_ID)
}

// compose gives a child's world-space pose. A non-uniform parent scale is applied before the child's rotation, so
// it does not shear.
compose :: proc(parent: Transform, local: Local_Transform) -> Transform {
	return {
		position = position_offset(parent.position, linalg.quaternion_mul_vector3(parent.rotation, local.offset * parent.scale)),
		rotation = parent.rotation * local.rotation,
		scale = parent.scale * local.scale,
	}
}

// interpolate blends two poses. t = 0 gives previous, and t = 1 gives current.
interpolate :: proc(previous, current: Transform, t: f32) -> Transform {
	to := current.rotation
	// q and -q are the same rotation. Blending toward the nearer one takes the short way around.
	if linalg.dot(previous.rotation, to) < 0 {
		to = -to
	}
	return {
		position = position_lerp(previous.position, current.position, t),
		rotation = linalg.quaternion_nlerp(previous.rotation, to, t),
		scale = linalg.lerp(previous.scale, current.scale, t),
	}
}

// presented gives the pose to show for e: interpolated by the clock's alpha if e has a Previous_Transform.
presented :: proc(w: ^World, e: Entity) -> (pose: Transform, ok: bool) {
	current := (^Transform)(get_raw(w, e, TRANSFORM_ID))
	if current == nil {
		return {}, false
	}
	previous := (^Transform)(get_raw(w, e, PREVIOUS_TRANSFORM_ID))
	if previous == nil {
		return current^, true
	}
	return interpolate(previous^, current^, w.clock.alpha), true
}

// teleport moves an entity without interpolation: it sets the Previous_Transform too, if the entity has one.
teleport :: proc(w: ^World, e: Entity, pose: Transform) -> bool {
	current := (^Transform)(get_raw(w, e, TRANSFORM_ID))
	if current == nil {
		return false
	}
	current^ = pose
	if previous := (^Transform)(get_raw(w, e, PREVIOUS_TRANSFORM_ID)); previous != nil {
		previous^ = pose
	}
	return true
}

// snapshot_previous copies Transform to Previous_Transform at the start of a tick.
@(private)
snapshot_previous :: proc(w: ^World) {
	Copy :: struct {
		archetype: u32,
		chunk:     u32,
		from, to:  u32,
	}
	copies := make([dynamic]Copy, w.platform.frame_allocator)
	for index in 0 ..< w.archetype_count {
		a := archetype(w, index)
		from := column_index(a, TRANSFORM_ID) or_continue
		to := column_index(a, PREVIOUS_TRANSFORM_ID) or_continue
		for chunk in 0 ..< a.chunk_count {
			append(&copies, Copy{index, chunk, a.offsets[from], a.offsets[to]})
		}
	}
	parallel_for(w, len(copies), 8, proc(w: ^World, data: rawptr, first, count: int) {
		copies := (^[dynamic]Copy)(data)
		for c in copies[first:][:count] {
			a := archetype(w, c.archetype)
			rows := min(a.capacity, a.count - c.chunk * a.capacity)
			data := chunk_data(w, chunk_directory(w, c.archetype)[c.chunk])
			copy(([^]Transform)(&data[c.to])[:rows], ([^]Transform)(&data[c.from])[:rows])
		}
	}, &copies)
}

// propagate writes the Transform of every child, one hierarchy level at a time.
@(private)
propagate :: proc(w: ^World) {
	if registry_find(&w.registry, PARENT_ID) == nil {
		return
	}
	if w.hierarchy_dirty {
		rebuild_hierarchy(w)
	}
	children := ([^]Entity)(w.hierarchy.base)
	for depth in 0 ..< MAX_HIERARCHY_DEPTH {
		first, last := w.levels[depth], w.levels[depth + 1]
		level := children[first:last]
		parallel_for(w, len(level), PROPAGATE_BATCH, proc(w: ^World, data: rawptr, first, count: int) {
			for e in (^[]Entity)(data)[first:][:count] {
				propagate_one(w, e)
			}
		}, &level)
	}
}

@(private = "file")
propagate_one :: proc(w: ^World, e: Entity) {
	child := (^Transform)(get_raw(w, e, TRANSFORM_ID))
	local := (^Local_Transform)(get_raw(w, e, LOCAL_TRANSFORM_ID))
	parent := (^Parent)(get_raw(w, e, PARENT_ID))
	if child == nil || local == nil || parent == nil {
		return
	}
	if pose := (^Transform)(get_raw(w, parent.entity, TRANSFORM_ID)); pose != nil {
		child^ = compose(pose^, local^)
	}
}

// rebuild_hierarchy sorts every child by its depth. levels[d] is where the children at depth d + 1 start.
@(private)
rebuild_hierarchy :: proc(w: ^World) {
	w.hierarchy_dirty = false
	count := 0
	for index in 0 ..< w.archetype_count {
		a := archetype(w, index)
		if _, ok := column_index(a, PARENT_ID); ok {
			count += int(a.count)
		}
	}
	if !region_commit(&w.hierarchy, w.platform, count * size_of(Entity)) {
		panic("ecs: cannot commit the hierarchy")
	}

	found := make([]Entity, count, w.platform.frame_allocator)
	depths := make([]u8, count, w.platform.frame_allocator)
	per_depth: [MAX_HIERARCHY_DEPTH + 1]u32
	n := 0
	for index in 0 ..< w.archetype_count {
		a := archetype(w, index)
		if _, ok := column_index(a, PARENT_ID); !ok {
			continue
		}
		for row in 0 ..< a.count {
			e := entity_at(w, index, row)^
			depth := hierarchy_depth(w, e)
			if depth < 0 {
				log.errorf("ecs: the hierarchy above entity %x is a cycle or deeper than %d", u64(e), MAX_HIERARCHY_DEPTH)
			}
			// A child whose parent is not alive has depth 0. It is despawned at the next apply, and until then
			// propagation leaves it alone.
			if depth <= 0 {
				continue
			}
			found[n] = e
			depths[n] = u8(depth)
			per_depth[depth] += 1
			n += 1
		}
	}

	w.levels = {}
	for depth in 1 ..= MAX_HIERARCHY_DEPTH {
		w.levels[depth] = w.levels[depth - 1] + per_depth[depth]
	}
	next := w.levels
	children := ([^]Entity)(w.hierarchy.base)
	for e, i in found[:n] {
		slot := &next[depths[i] - 1]
		children[slot^] = e
		slot^ += 1
	}
}

// hierarchy_depth is 1 for a child of a root. It stops at a parent that is not alive, and returns -1 for a cycle.
@(private = "file")
hierarchy_depth :: proc(w: ^World, e: Entity) -> int {
	depth := 0
	current := e
	for {
		parent := (^Parent)(get_raw(w, current, PARENT_ID))
		if parent == nil || !is_alive(w, parent.entity) {
			return depth
		}
		depth += 1
		if depth > MAX_HIERARCHY_DEPTH {
			return -1
		}
		current = parent.entity
	}
}

@(private)
column_index :: proc(a: ^Archetype, id: Component_Id) -> (u32, bool) {
	for c, i in archetype_components(a) {
		if c == id {
			return u32(i), true
		}
	}
	return 0, false
}
