package render

import "base:intrinsics"
import "core:math/linalg"

import "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// Caster tracking (see docs/rendering/gpu-scene.md#caster-tracking): which slots' shadows changed since the frame
// before, for the shadow caches, the atlas's (shadow_cache.odin) and the virtual shadow map's. The frame's own view
// finds them in build_scene, from its items, before they are sorted into bins. A slot's shadow is its items that cast
// shadows: their bounds, as a sphere in the world, and a signature of what they draw.
//
// A caster is static or dynamic. A static caster stays in the caches until it changes, which drops it at once. A
// dynamic caster changes without a change being reported each frame: it moved in the last SHADOW_STILL_FRAMES, or its
// items change their shape by themselves (skinned meshes, billboards, mesh particles, materials whose depth reads the
// time). Each view draws its dynamic casters within its dynamic shadow distance live every frame, over its caches,
// and bakes the farther ones into them, which a report every SHADOW_FAR_REFRESH frames refreshes.

// A still caster whose sphere moves or grows by more than this many meters from where the caches took it is a change.
SHADOW_SPHERE_EPSILON :: 0.001

// A caster that moved within this many frames is dynamic.
SHADOW_STILL_FRAMES :: 30
// A dynamic caster reports where it is every this many frames, staggered by its slot.
SHADOW_FAR_REFRESH :: 8

// Caster_Sphere is a caster's bounds in the world.
Caster_Sphere :: struct {
	center: ecs.World_Position,
	radius: f32,
}

// Caster_Slot is a slot's shadow, as the tracking last saw it. reported is where the caches took it last: at its last
// change or report. inherent is whether its items change their shape by themselves, and unbounded whether they have no
// bounds on the CPU (mesh particles with an unbounded emitter), so it is live in every view. volatile is whether it is a dynamic caster. moved is
// the last frame that its pose changed.
Caster_Slot :: struct {
	sphere:    Caster_Sphere,
	reported:  Caster_Sphere,
	signature: u64,
	casts:     bool,
	inherent:  bool,
	unbounded: bool,
	volatile:  bool,
	moved:     u64,
}

// Caster_Change is a change of a slot's shadow: where it was, if it cast, and where it is, if it casts. A report is a
// dynamic caster's refresh, which a cache that holds it baked takes on a budget. Any other change drops what it covers
// at once.
Caster_Change :: struct {
	slot:   u32,
	old:    Maybe(Caster_Sphere),
	new:    Maybe(Caster_Sphere),
	report: bool,
}

// Caster_Tracking is the casters' state between frames, in the Gpu_Scene: each slot's shadow, and the changes of the
// scene frame frame, which every view of that frame reads.
Caster_Tracking :: struct {
	slots:   [MAX_INSTANCES]Caster_Slot,
	changes: [dynamic]Caster_Change,
	frame:   u64,
}

// Caster_Bounds is what a slot's items cast this frame, as build_scene gathers them: a box around their spheres,
// relative to the render origin, and their signature.
@(private)
Caster_Bounds :: struct {
	low, high: [3]f32,
	signature: u64,
	casts:     bool,
	inherent:  bool,
	unbounded: bool,
	// An instance set's item is among them: a new version of the set changes its cells, not the slot's sphere (see
	// residency_changed_cells).
	cells:     bool,
}

// caster_bounds gathers each slot's items that cast shadows, below high. sets gives each ITEM_INSTANCED item's set's
// sphere about its instances, and the largest scale of their axes, in the set's space, with which set it is. The
// signature holds each item's mesh's generation, from mesh_generations by the item's mesh index, and its pipeline's.
@(private)
caster_bounds :: proc(
	records: []Instance_Record,
	items: []Cull_Item,
	pipelines: []Material_Pipeline,
	sets: []Set_Bounds,
	mesh_generations: []u32,
	high: u32,
	allocator := context.allocator,
) -> []Caster_Bounds {
	bounds := make([]Caster_Bounds, high, allocator)
	for item in items {
		if item.flags & ITEM_CASTS_SHADOWS == 0 ||
		   item.flags & ITEM_VIEW_MODEL != 0 ||
		   item.instance >= high {
			continue
		}
		b := &bounds[item.instance]
		rows := records[item.instance].rows
		scale := max(
			linalg.length([3]f32{rows[0].x, rows[1].x, rows[2].x}),
			linalg.length([3]f32{rows[0].y, rows[1].y, rows[2].y}),
			linalg.length([3]f32{rows[0].z, rows[1].z, rows[2].z}),
		)
		local, radius := item.sphere.xyz, item.sphere.w
		set_guid: format.Guid
		switch {
		case item.flags & ITEM_INSTANCED != 0 && int(item.entry) < len(sets):
			// The set's instances, each with the submesh's sphere at its scale.
			set := sets[item.entry]
			set_guid = set.guid
			b.cells = true
			radius = set.radius + (linalg.length(local) + radius) * set.max_scale
			local = set.center
		case item.flags & ITEM_BILLBOARD != 0:
			// It turns about its position, as culling takes it.
			radius = linalg.length(local) + radius
			local = {}
		}
		center: [3]f32
		for row, k in rows {
			center[k] = row.x * local.x + row.y * local.y + row.z * local.z + row.w
		}
		reach := max(radius, 0) * scale + item.bound
		pipeline := &pipelines[item.bin]
		// A mesh particles' item has a sphere (see particle_sphere), unless its emitter's modules leave it none.
		unbounded := item.flags & ITEM_PARTICLES != 0 && radius < 0
		if !b.casts {
			b.low, b.high = center - reach, center + reach
		} else {
			b.low, b.high = linalg.min(b.low, center - reach), linalg.max(b.high, center + reach)
		}
		b.casts = true
		b.unbounded ||= unbounded
		b.inherent ||=
			item.flags & (ITEM_PARTICLES | ITEM_SKINNED | ITEM_BILLBOARD) != 0 || pipeline.animated
		// The signature is what the items draw, but not where: their place in the frame's lists changes from frame to frame.
		generation: u32
		if item.flags & (ITEM_SURFACE | ITEM_RIBBON) == 0 &&
		   int(item.mesh) < len(mesh_generations) {
			generation = mesh_generations[item.mesh]
		}
		b.signature = signature_add(b.signature, u64(generation) | u64(pipeline.generation) << 32)
		guid := transmute([2]u64)set_guid
		b.signature = signature_add(b.signature, guid[0])
		b.signature = signature_add(b.signature, guid[1])
		b.signature = signature_add(b.signature, u64(item.first) | u64(item.count) << 32)
		b.signature = signature_add(b.signature, u64(item.bin) | u64(item.flags) << 32)
		b.signature = signature_add(
			b.signature,
			u64(transmute(u32)item.bound) | u64(item.list) << 32,
		)
		b.signature = signature_add(
			b.signature,
			u64(transmute(u32)item.sphere.x) | u64(transmute(u32)item.sphere.y) << 32,
		)
		b.signature = signature_add(
			b.signature,
			u64(transmute(u32)item.sphere.z) | u64(transmute(u32)item.sphere.w) << 32,
		)
	}
	return bounds
}

// Set_Bounds is an instance set's sphere about its instances' positions and the largest scale of their axes, in the
// set's space, which caster_bounds takes for its items, and which set it is.
@(private)
Set_Bounds :: struct {
	guid:      format.Guid,
	center:    [3]f32,
	radius:    f32,
	max_scale: f32,
}

@(private = "file")
signature_add :: proc(h: u64, value: u64) -> u64 {
	// FNV-1a over the value's bytes, which starts from the offset basis.
	h := h == 0 ? 0xcbf29ce484222325 : h
	for i in 0 ..< 8 {
		h = (h ~ ((value >> uint(i * 8)) & 0xff)) * 0x100000001b3
	}
	return h
}

// track_casters takes the frame's bounds of each slot below high and gives the frame's changes: a slot that starts or
// stops casting, or whose items change what they draw; a slot that turns dynamic, whose old place leaves the caches, or
// static again, whose place joins them; a static slot whose sphere moved from where the caches took it, unless it is an
// instance set's, whose changed cells say where; and each dynamic slot's report, every SHADOW_FAR_REFRESH frames, staggered by
// its slot. A slot's moved is set before this, when its pose changed this frame.
@(private)
track_casters :: proc(
	t: ^Caster_Tracking,
	bounds: []Caster_Bounds,
	origin: ecs.World_Position,
	frame: u64,
) {
	clear(&t.changes)
	t.frame = frame
	for &c, i in t.slots[:len(bounds)] {
		slot := u32(i)
		b := bounds[i]
		if !c.casts && !b.casts {
			c = {
				moved = c.moved,
			}
			continue
		}
		sphere: Caster_Sphere
		if b.casts {
			half := (b.high - b.low) * 0.5
			sphere = {ecs.position_offset(origin, b.low + half), linalg.length(half)}
		}
		volatile := b.inherent || (c.moved != 0 && frame - c.moved < SHADOW_STILL_FRAMES)
		switch {
		case c.casts != b.casts || c.signature != b.signature:
			change := Caster_Change {
				slot = slot,
			}
			if c.casts {
				change.old = c.reported
			}
			if b.casts {
				change.new = sphere
			}
			append(&t.changes, change)
			c.reported = sphere
		case volatile != c.volatile:
			append(&t.changes, Caster_Change{slot = slot, old = c.reported, new = sphere})
			c.reported = sphere
		case volatile &&
		     (frame + u64(slot)) % SHADOW_FAR_REFRESH == 0 &&
		     (b.inherent || sphere != c.reported):
			append(
				&t.changes,
				Caster_Change{slot = slot, old = c.reported, new = sphere, report = true},
			)
			c.reported = sphere
		case !volatile && sphere_changed(sphere, c.reported):
			if !b.cells {
				append(&t.changes, Caster_Change{slot = slot, old = c.reported, new = sphere})
			}
			c.reported = sphere
		}
		if !b.casts {
			c = {
				moved = c.moved,
			}
			continue
		}
		c.sphere, c.signature, c.casts = sphere, b.signature, true
		c.inherent, c.unbounded, c.volatile = b.inherent, b.unbounded, volatile
	}
}

// sphere_changed is whether a sphere moved or changed its radius by more than SHADOW_SPHERE_EPSILON.
@(private = "file")
sphere_changed :: proc(a, b: Caster_Sphere) -> bool {
	d := ecs.position_sub_f64(a.center, b.center)
	return(
		d.x * d.x + d.y * d.y + d.z * d.z > SHADOW_SPHERE_EPSILON * SHADOW_SPHERE_EPSILON ||
		abs(a.radius - b.radius) > SHADOW_SPHERE_EPSILON \
	)
}

// add_cell_changes adds to the frame's changes, for each slot that draws an instance set whose cells changed, a change
// at each cell: the cell's sphere in the world at the slot's rows, the sphere of the set's mesh at the cell's largest
// scale, as caster_bounds takes the set. A slot that does not cast, or started to, has its change already.
@(private)
add_cell_changes :: proc(
	t: ^Caster_Tracking,
	cells: []Changed_Set_Cell,
	sets: []Instance_Set_Record,
	set_bounds: []Set_Bounds,
	records: []Instance_Record,
	origin: ecs.World_Position,
) {
	for cell in cells {
		for set, i in sets {
			if set_bounds[i].guid != cell.guid ||
			   set.flags & SET_CASTS_SHADOWS == 0 ||
			   int(set.slot) >= len(t.slots) ||
			   !t.slots[set.slot].casts {
				continue
			}
			rows := records[set.slot].rows
			scale := max(
				linalg.length([3]f32{rows[0].x, rows[1].x, rows[2].x}),
				linalg.length([3]f32{rows[0].y, rows[1].y, rows[2].y}),
				linalg.length([3]f32{rows[0].z, rows[1].z, rows[2].z}),
			)
			change := Caster_Change {
				slot = set.slot,
			}
			if old, ok := cell.old.?; ok {
				change.old = cell_sphere(old, set, rows, scale, origin)
			}
			if new, ok := cell.new.?; ok {
				change.new = cell_sphere(new, set, rows, scale, origin)
			}
			append(&t.changes, change)
		}
	}
}

@(private = "file")
cell_sphere :: proc(
	c: Set_Cell,
	set: Instance_Set_Record,
	rows: [3][4]f32,
	scale: f32,
	origin: ecs.World_Position,
) -> Caster_Sphere {
	radius := c.radius + (linalg.length(set.sphere.xyz) + set.sphere.w) * c.max_scale
	center: [3]f32
	for row, k in rows {
		center[k] = row.x * c.center.x + row.y * c.center.y + row.z * c.center.z + row.w
	}
	return {ecs.position_offset(origin, center), radius * scale + set.bound}
}

// caster_moved records that a slot's pose changed this frame.
@(private)
caster_moved :: proc "contextless" (t: ^Caster_Tracking, slot: u32, frame: u64) {
	t.slots[slot].moved = frame
}

// caster_live is whether a view draws a slot's shadow live over its caches: a dynamic caster within distance of the
// camera, or one without bounds, at any distance.
caster_live :: proc(c: Caster_Slot, camera: ecs.World_Position, distance: f32) -> bool {
	if !c.casts || !c.volatile {
		return false
	}
	if c.unbounded {
		return true
	}
	return linalg.length(ecs.position_sub(c.sphere.center, camera)) - c.sphere.radius < distance
}

// Live_Slots is a bit for each slot that a view draws live.
Live_Slots :: [MAX_INSTANCES / 64]u64

// live_slots gives the slots below high that a view draws live, from where it looks and its dynamic shadow distance.
live_slots :: proc(
	t: ^Caster_Tracking,
	high: u32,
	camera: ecs.World_Position,
	distance: f32,
) -> (
	live: Live_Slots,
) {
	for c, slot in t.slots[:high] {
		if caster_live(c, camera, distance) {
			live[slot / 64] |= 1 << uint(slot % 64)
		}
	}
	return
}

slot_live :: proc "contextless" (live: ^Live_Slots, slot: u32) -> bool {
	return live[slot / 64] & (1 << (slot % 64)) != 0
}

// view_caster_changes are the changes that a view's caches take, from the frame's and from what it drew live in its
// last frame: a report of a slot that it draws live is left out, since its caches do not hold it, and a slot that turns
// live or turns baked is a change at once: the caches drop it where they hold it, or take it where it is.
view_caster_changes :: proc(
	t: ^Caster_Tracking,
	live, previous: ^Live_Slots,
	allocator := context.allocator,
) -> []Caster_Change {
	changes := make([dynamic]Caster_Change, allocator)
	for change in t.changes {
		if change.report && slot_live(live, change.slot) {
			continue
		}
		append(&changes, change)
	}
	for word in 0 ..< len(live) {
		flips := live[word] ~ previous[word]
		for flips != 0 {
			slot := u32(word * 64) + u32(intrinsics.count_trailing_zeros(flips))
			flips &= flips - 1
			// A slot that stopped casting is a change of the frame's already.
			c := t.slots[slot]
			if c.casts {
				append(&changes, Caster_Change{slot = slot, old = c.reported, new = c.sphere})
			}
		}
	}
	return changes[:]
}

// sphere_meets is whether a caster's sphere meets a sphere in the world.
sphere_meets :: proc(s: Caster_Sphere, center: ecs.World_Position, radius: f32) -> bool {
	reach := f64(s.radius) + f64(radius)
	d := ecs.position_sub_f64(s.center, center)
	return d.x * d.x + d.y * d.y + d.z * d.z <= reach * reach
}

#assert(size_of(Live_Slots) * 8 == MAX_INSTANCES)
