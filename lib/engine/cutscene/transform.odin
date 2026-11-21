package cutscene

import "core:log"
import "core:math"
import "core:math/linalg"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// Pose_Channel is a channel of a transform track: a number of the pose that it keys (see
// docs/cinematics/tracks.md#transform-tracks).
Pose_Channel :: enum u8 {
	Position_X,
	Position_Y,
	Position_Z,
	Rotation_X,
	Rotation_Y,
	Rotation_Z,
	Scale_X,
	Scale_Y,
	Scale_Z,
}

// POSE_CHANNEL_NAMES are the channels' names in the text and the blob.
POSE_CHANNEL_NAMES := [Pose_Channel]string {
	.Position_X = "position_x",
	.Position_Y = "position_y",
	.Position_Z = "position_z",
	.Rotation_X = "rotation_x",
	.Rotation_Y = "rotation_y",
	.Rotation_Z = "rotation_z",
	.Scale_X    = "scale_x",
	.Scale_Y    = "scale_y",
	.Scale_Z    = "scale_z",
}

// Pose_Part is a part of a pose that a transform track writes as one field: position, rotation or scale.
@(private)
Pose_Part :: enum u8 {
	Position,
	Rotation,
	Scale,
}

// Space_Pose is a pose in a track's space: an offset in meters and a rotation from the space's origin, and a scale.
@(private)
Space_Pose :: struct {
	position: [3]f32,
	rotation: quaternion128,
	scale:    [3]f32,
}

// Frame is where a track's space is in the world: an origin and a rotation.
@(private)
Frame :: struct {
	origin:   ecs.World_Position,
	rotation: quaternion128,
}

// Relative_Space is what a transform track relative to another binding found at its first evaluation for the blob.
Relative_Space :: union {
	Relative_Cycle,
	Relative_Start,
}

// Relative_Cycle is a track whose binding is relative to itself through the tracks relative to other bindings, which
// the cooker cannot see when two bindings resolve to one entity. The track does nothing.
Relative_Cycle :: struct {}

// Relative_Start is the binding's pose in the other binding's space before the cutscene moved either of them: what a
// channel that the track does not key holds, so the entity rides the other binding. It names the two bindings by their
// IDs, so a reload keeps it while the track still joins them.
Relative_Start :: struct {
	binding:  u32,
	relative: u32,
	position: [3]f32,
	rotation: quaternion128,
}

// Pose_Target is the entity a transform track writes and how: a root's Transform, or a child's Local_Transform, which
// is relative to its parent's Transform.
@(private)
Pose_Target :: struct {
	entity:    ecs.Entity,
	component: ecs.Component_Id,
	// For a child, its parent.
	parent:    Maybe(ecs.Entity),
	// The offsets of the position, the rotation and the scale in the component, and the position's size.
	offsets:   [Pose_Part]uintptr,
}

// transform_track is the transform kind's evaluate procedure. It blends the track's sections at the time into a pose
// in the track's space, and writes the parts of the pose that the track keys: a root's Transform, or a child's
// Local_Transform. It teleports the entity when the evaluation does not move forward, after a skip, on the real clock,
// or when it crosses a key marked teleport.
transform_track :: proc(ctx: ^Track_Context) {
	entity, bound := track_entity(ctx)
	if !bound {
		return
	}
	held := held_parts(ctx)
	target, ok := pose_target(ctx.world, entity)
	if held == {} || !ok {
		return
	}
	start: Relative_Start
	if ctx.track.space == .Relative_To {
		placed: bool
		start, placed = relative_space(ctx, target).(Relative_Start)
		if !placed {
			return
		}
		follow_relative(ctx)
	}
	own, has_own := own_pose(ctx, target)
	if !has_own {
		return
	}
	world_own := own_world(ctx.world, target, own)
	frame, has_frame := track_frame(ctx, world_own)
	if !has_frame {
		return
	}
	in_space := Space_Pose {
		rotation = 1,
		scale    = own.scale,
	}
	switch ctx.track.space {
	case .Relative:
	case .Absolute:
		in_space.position = ecs.position_sub(world_own.position, frame.origin)
		in_space.rotation = world_own.rotation
	case .Relative_To:
		in_space.position, in_space.rotation = start.position, start.rotation
	}
	blended, touched := blend_pose(ctx, in_space)
	out := own
	if .Scale in held {
		out.scale = blended.scale
	}
	if ctx.track.space == .Relative {
		// The space is the binding's own pose, in the field that the track writes.
		if touched[.Position] {
			delta := linalg.quaternion_mul_vector3(own.rotation, blended.position)
			switch p in own.position {
			case ecs.World_Position:
				out.position = ecs.position_offset(p, delta)
			case [3]f32:
				out.position = p + delta
			}
		}
		if touched[.Rotation] {
			out.rotation = own.rotation * blended.rotation
		}
	} else {
		world := world_own
		if touched[.Position] {
			world.position = ecs.position_offset(
				frame.origin,
				linalg.quaternion_mul_vector3(frame.rotation, blended.position),
			)
			// An axis that no section covers keeps its own value exactly, so far from the origin no rounding moves it.
			if ctx.track.space == .Absolute {
				for axis in 0 ..< 3 {
					if !touched_axis(ctx, Pose_Channel(axis)) {
						world.position.raw[axis] = world_own.position.raw[axis]
					}
				}
			}
		}
		if touched[.Rotation] {
			world.rotation = frame.rotation * blended.rotation
		}
		local := to_target(ctx.world, target, world)
		if touched[.Position] {
			out.position = local.position
		}
		if touched[.Rotation] {
			out.rotation = local.rotation
		}
	}
	write_pose(ctx, target, held, out)
	settle_pose(ctx.world, entity, teleports(ctx))
}

// Field_Pose is a pose as the field that a track writes holds it: a root's world position, or a child's offset from
// its parent, with its rotation and scale.
@(private)
Field_Pose :: struct {
	position: union #no_nil {
		ecs.World_Position,
		[3]f32,
	},
	rotation: quaternion128,
	scale:    [3]f32,
}

// World_Pose is a pose in the world, without its scale.
@(private)
World_Pose :: struct {
	position: ecs.World_Position,
	rotation: quaternion128,
}

// pose_target is how a track writes an entity: a child with a Local_Transform writes it, and a root its Transform.
@(private)
pose_target :: proc(w: ^ecs.World, entity: ecs.Entity) -> (target: Pose_Target, ok: bool) {
	if ecs.get_raw(w, entity, ecs.TRANSFORM_ID) == nil {
		return {}, false
	}
	target.entity = entity
	parent := (^ecs.Parent)(ecs.get_raw(w, entity, ecs.PARENT_ID))
	if parent != nil && ecs.get_raw(w, entity, ecs.LOCAL_TRANSFORM_ID) != nil {
		target.component = ecs.LOCAL_TRANSFORM_ID
		target.parent = parent.entity
		target.offsets = {
			.Position = offset_of(ecs.Local_Transform, offset),
			.Rotation = offset_of(ecs.Local_Transform, rotation),
			.Scale    = offset_of(ecs.Local_Transform, scale),
		}
		return target, true
	}
	target.component = ecs.TRANSFORM_ID
	target.offsets = {
		.Position = offset_of(ecs.Transform, position),
		.Rotation = offset_of(ecs.Transform, rotation),
		.Scale    = offset_of(ecs.Transform, scale),
	}
	return target, true
}

// own_pose reads the target's own pose: as it was before the cutscene first wrote it, or as it is.
@(private)
own_pose :: proc(ctx: ^Track_Context, target: Pose_Target) -> (pose: Field_Pose, ok: bool) {
	if _, child := target.parent.?; child {
		pose.position = base(
			ctx,
			target.entity,
			target.component,
			target.offsets[.Position],
			[3]f32,
		) or_return
	} else {
		pose.position = base(
			ctx,
			target.entity,
			target.component,
			target.offsets[.Position],
			ecs.World_Position,
		) or_return
	}
	pose.rotation = base(
		ctx,
		target.entity,
		target.component,
		target.offsets[.Rotation],
		quaternion128,
	) or_return
	pose.scale = base(
		ctx,
		target.entity,
		target.component,
		target.offsets[.Scale],
		[3]f32,
	) or_return
	return pose, true
}

// parent_pose is a child's parent's Transform, or the identity when the parent has none.
@(private)
parent_pose :: proc(w: ^ecs.World, parent: ecs.Entity) -> ecs.Transform {
	if p := (^ecs.Transform)(ecs.get_raw(w, parent, ecs.TRANSFORM_ID)); p != nil {
		return p^
	}
	return ecs.TRANSFORM_IDENTITY
}

// own_world is where a field pose is in the world.
@(private)
own_world :: proc(w: ^ecs.World, target: Pose_Target, own: Field_Pose) -> World_Pose {
	parent, child := target.parent.?
	if !child {
		return {own.position.(ecs.World_Position), own.rotation}
	}
	world := ecs.compose(
		parent_pose(w, parent),
		{offset = own.position.([3]f32), rotation = own.rotation, scale = own.scale},
	)
	return {world.position, world.rotation}
}

// to_target turns a pose in the world into the field's terms: a root's as it is, and a child's from its parent's
// Transform, the inverse of ecs.compose.
@(private)
to_target :: proc(w: ^ecs.World, target: Pose_Target, world: World_Pose) -> Field_Pose {
	parent, child := target.parent.?
	if !child {
		return {position = world.position, rotation = world.rotation}
	}
	p := parent_pose(w, parent)
	inverse := linalg.quaternion_inverse(p.rotation)
	offset := linalg.quaternion_mul_vector3(inverse, ecs.position_sub(world.position, p.position))
	for axis in 0 ..< 3 {
		if p.scale[axis] != 0 {
			offset[axis] /= p.scale[axis]
		}
	}
	return {position = offset, rotation = linalg.normalize(inverse * world.rotation)}
}

// track_frame is where the track's space is: the track's origin with no rotation, another binding's Transform, or the
// binding's own pose. False when the other binding is missing.
@(private)
track_frame :: proc(ctx: ^Track_Context, world_own: World_Pose) -> (frame: Frame, ok: bool) {
	switch ctx.track.space {
	case .Relative:
		return {world_own.position, world_own.rotation}, true
	case .Absolute:
		return {{ctx.track.origin}, 1}, true
	case .Relative_To:
		other := ctx_binding(ctx, ctx.track.relative) or_return
		pose := (^ecs.Transform)(ecs.get_raw(ctx.world, other, ecs.TRANSFORM_ID))
		if pose == nil {
			return {}, false
		}
		return {pose.position, pose.rotation}, true
	}
	return {}, false
}

// held_parts is the parts of the pose that the track keys in any section. It writes those, at every time, and leaves
// the others.
@(private)
held_parts :: proc(ctx: ^Track_Context) -> (held: bit_set[Pose_Part]) {
	for section in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		for channel in format.cutscene_section_channels(ctx.data, ctx.blob, section) {
			if c, ok := pose_channel(format.blob_string(ctx.data, channel.name)); ok {
				held += {part_of(c)}
			}
		}
	}
	return
}

// touched_axis is whether a section that covers the time keys a channel.
@(private)
touched_axis :: proc(ctx: ^Track_Context, want: Pose_Channel) -> bool {
	for section in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		if _, covers := sample_section(ctx, section, ctx.time); !covers {
			continue
		}
		for channel in format.cutscene_section_channels(ctx.data, ctx.blob, section) {
			if c, ok := pose_channel(format.blob_string(ctx.data, channel.name)); ok && c == want {
				return true
			}
		}
	}
	return false
}

// blend_pose blends the sections that cover the time over the binding's own pose in the track's space, as
// docs/cinematics/tracks.md#transform-tracks says: each position and scale channel by the sections' weights, the
// rotations by their normalized weights, and then the additive sections on top. It gives which parts a section covers.
@(private)
blend_pose :: proc(
	ctx: ^Track_Context,
	own: Space_Pose,
) -> (
	pose: Space_Pose,
	touched: [Pose_Part]bool,
) {
	own_euler := script.euler_of(own.rotation)
	positions, scales: [3]Blend(f32)
	added_position: [3]f32
	added_scale := [3]f32{1, 1, 1}
	added_rotation := quaternion128(1)
	rotation: quaternion128
	rotation_weight: f32
	for section in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		at := sample_section(ctx, section, ctx.time) or_continue
		additive := .Additive in section.flags
		euler := [3]f32{} if additive else own_euler
		rotated := false
		for channel in format.cutscene_section_channels(ctx.data, ctx.blob, section) {
			c := pose_channel(format.blob_string(ctx.data, channel.name)) or_continue
			v := curve_value(format.cutscene_channel_keys(ctx.data, ctx.blob, channel), at.local)
			i := int(c) % 3
			touched[part_of(c)] = true
			switch part_of(c) {
			case .Position:
				if additive {
					added_position[i] += v * at.weight
				} else {
					blend_add(&positions[i], v, at.weight)
				}
			case .Rotation:
				euler[i] = v
				rotated = true
			case .Scale:
				if additive {
					added_scale[i] *= 1 + (v - 1) * at.weight
				} else {
					blend_add(&scales[i], v, at.weight)
				}
			}
		}
		if !rotated {
			continue
		}
		q := script.quaternion_euler(euler)
		if additive {
			added_rotation = added_rotation * linalg.quaternion_slerp_f32(1, q, at.weight)
		} else if at.weight > 0 {
			if linalg.dot(rotation, q) < 0 {
				q = -q
			}
			rotation += q * quaternion(real = at.weight, imag = 0, jmag = 0, kmag = 0)
			rotation_weight += at.weight
		}
	}
	for i in 0 ..< 3 {
		pose.position[i] = blend_value(positions[i], own.position[i]) + added_position[i]
		pose.scale[i] = blend_value(scales[i], own.scale[i]) * added_scale[i]
	}
	pose.rotation = own.rotation
	if rotation_weight > 0 {
		// Under a weight of 1, the own rotation takes what the sections leave, on the sum's side.
		if rotation_weight < 1 {
			mine := own.rotation
			if linalg.dot(rotation, mine) < 0 {
				mine = -mine
			}
			rotation += mine * quaternion(real = 1 - rotation_weight, imag = 0, jmag = 0, kmag = 0)
		}
		length := math.sqrt(linalg.dot(rotation, rotation))
		if length > 1e-6 {
			pose.rotation = rotation * quaternion(real = 1 / length, imag = 0, jmag = 0, kmag = 0)
		}
	}
	pose.rotation = linalg.normalize(pose.rotation * added_rotation)
	return
}

// write_pose writes the parts of the pose that the track holds, each a field of its own, so the snapshot saves and
// restores each one.
@(private)
write_pose :: proc(
	ctx: ^Track_Context,
	target: Pose_Target,
	held: bit_set[Pose_Part],
	pose: Field_Pose,
) {
	if .Position in held {
		switch p in pose.position {
		case ecs.World_Position:
			write(ctx, target.entity, target.component, target.offsets[.Position], p)
		case [3]f32:
			write(ctx, target.entity, target.component, target.offsets[.Position], p)
		}
	}
	if .Rotation in held {
		write(ctx, target.entity, target.component, target.offsets[.Rotation], pose.rotation)
	}
	if .Scale in held {
		write(ctx, target.entity, target.component, target.offsets[.Scale], pose.scale)
	}
}

// settle_pose makes an entity's Transform follow what a track or a restore wrote at once: a child's Transform from its
// parent's and its Local_Transform, so a track relative to it sees it in the same tick. A teleport also sets the
// Previous_Transform of the entity and of each entity under it, whose Transforms it composes, so presentation does not
// interpolate across the move. Previous_Transform and a child's Transform follow from the fields that the snapshot
// holds, so they are written outside it.
settle_pose :: proc(w: ^ecs.World, entity: ecs.Entity, teleport: bool) {
	compose_one(w, entity)
	if teleport {
		teleport_tree(w, entity, 0)
	}
}

@(private)
compose_one :: proc(w: ^ecs.World, entity: ecs.Entity) {
	parent := (^ecs.Parent)(ecs.get_raw(w, entity, ecs.PARENT_ID))
	local := (^ecs.Local_Transform)(ecs.get_raw(w, entity, ecs.LOCAL_TRANSFORM_ID))
	pose := (^ecs.Transform)(ecs.get_raw(w, entity, ecs.TRANSFORM_ID))
	if parent == nil || local == nil || pose == nil {
		return
	}
	if p := (^ecs.Transform)(ecs.get_raw(w, parent.entity, ecs.TRANSFORM_ID)); p != nil {
		composed := ecs.compose(p^, local^)
		if composed != pose^ {
			pose^ = composed
			ecs.mark_changed(w, entity, ecs.TRANSFORM_ID)
		}
	}
}

@(private)
teleport_tree :: proc(w: ^ecs.World, entity: ecs.Entity, depth: int) {
	if depth > ecs.MAX_HIERARCHY_DEPTH {
		return
	}
	if depth > 0 {
		compose_one(w, entity)
	}
	if pose := (^ecs.Transform)(ecs.get_raw(w, entity, ecs.TRANSFORM_ID)); pose != nil {
		ecs.teleport(w, entity, pose^)
	}
	it := ecs.children_iter(w, entity)
	for child in ecs.children_next(&it) {
		teleport_tree(w, child, depth + 1)
	}
}

// teleports is whether this evaluation moves the entity at once: when it jumps (see jumps), when it crosses a cut of
// the camera cut track (see cut_fires), or when it crosses a key marked teleport.
@(private)
teleports :: proc(ctx: ^Track_Context) -> bool {
	if jumps(ctx) || cut_fires(ctx) {
		return true
	}
	for section in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		for channel in format.cutscene_section_channels(ctx.data, ctx.blob, section) {
			for key in format.cutscene_channel_keys(ctx.data, ctx.blob, channel) {
				if .Teleport in key.flags && fires(ctx, section.start + key.time) {
					return true
				}
			}
		}
	}
	return false
}

// jumps is whether this evaluation does not move on smoothly from the phase's last one: when it does not move forward
// (a seek, a backwards scrub, a reload, a pause or a skip's hold), at the first evaluation, in a skip's jump, and on the
// real clock (see docs/cinematics/evaluation.md#the-order-in-the-frame).
@(private)
jumps :: proc(ctx: ^Track_Context) -> bool {
	return(
		ctx.skipped ||
		ctx.wrapped ||
		ctx.clock == .Real ||
		ctx.from >= i64(ctx.time) ||
		ctx.from < i64(ctx.range_start) \
	)
}

// relative_space is what the track relative to another binding found at its first evaluation for the blob: a cycle,
// which it logs once, or where its binding starts in the other binding's space. The start comes from both bindings' own
// poses: as they were before the cutscene first wrote them, or as they are now. nil while the other binding is
// missing, which the next evaluation tries again.
@(private)
relative_space :: proc(ctx: ^Track_Context, target: Pose_Target) -> Relative_Space {
	e := ctx.evaluation
	if space, seen := e.spaces[{ctx.scope, ctx.track.id}]; seen {
		return space
	}
	if reaches_self(ctx) {
		log.errorf(
			"cutscene %s: the transform track %d %q does nothing: its binding is relative to itself through other bindings",
			format.blob_string(ctx.data, ctx.blob.source_path),
			ctx.track.id,
			format.blob_string(ctx.data, ctx.track.name),
		)
		e.spaces[{ctx.scope, ctx.track.id}] = Relative_Cycle{}
		return Relative_Cycle{}
	}
	own, has_own := own_pose(ctx, target)
	other, found := ctx_binding(ctx, ctx.track.relative)
	if !has_own || !found {
		return nil
	}
	other_target, has_target := pose_target(ctx.world, other)
	if !has_target {
		return nil
	}
	other_own, has_other := own_pose(ctx, other_target)
	if !has_other {
		return nil
	}
	world_own := own_world(ctx.world, target, own)
	from := own_world(ctx.world, other_target, other_own)
	inverse := linalg.quaternion_inverse(from.rotation)
	bindings := format.cutscene_bindings(ctx.data, ctx.blob)
	start := Relative_Start {
		binding  = bindings[ctx.track.binding].id,
		relative = bindings[ctx.track.relative].id,
		position = linalg.quaternion_mul_vector3(
			inverse,
			ecs.position_sub(world_own.position, from.position),
		),
		rotation = linalg.normalize(inverse * world_own.rotation),
	}
	e.spaces[{ctx.scope, ctx.track.id}] = start
	return start
}

// keep_spaces follows a reload: it keeps the start of each track that is still relative to the same two bindings, by
// their IDs, because the snapshot keeps the own poses that it came from, and forgets the rest, which the next
// evaluation finds again.
@(private)
keep_spaces :: proc(e: ^Evaluation, w: ^ecs.World, views: []Scope_View) {
	gone := make([dynamic]Scoped, w.platform.frame_allocator)
	for id, space in e.spaces {
		kept := false
		if start, placed := space.(Relative_Start); placed {
			for view in views {
				if view.scope != id.scope {
					continue
				}
				bindings := format.cutscene_bindings(view.data, view.blob)
				for track in format.cutscene_tracks(view.data, view.blob) {
					kept ||=
						track.id == id.id &&
						track.kind == .Transform &&
						track.space == .Relative_To &&
						bindings[track.binding].id == start.binding &&
						bindings[track.relative].id == start.relative
				}
			}
		}
		if !kept {
			append(&gone, id)
		}
	}
	for id in gone {
		delete_key(&e.spaces, id)
	}
}

// reaches_self is whether the track's own entity is reached from the entity that it is relative to, through the
// transform tracks relative to other bindings.
@(private)
reaches_self :: proc(ctx: ^Track_Context) -> bool {
	own, bound := track_entity(ctx)
	if !bound {
		return false
	}
	start, found := ctx_binding(ctx, ctx.track.relative)
	if !found {
		return false
	}
	tracks := format.cutscene_tracks(ctx.data, ctx.blob)
	seen := make(map[ecs.Entity]struct{}, ctx.world.platform.frame_allocator)
	queue := make([dynamic]ecs.Entity, ctx.world.platform.frame_allocator)
	append(&queue, start)
	seen[start] = {}
	for head := 0; head < len(queue); head += 1 {
		at := queue[head]
		if at == own {
			return true
		}
		for tr in tracks {
			if tr.kind != .Transform || tr.space != .Relative_To || .Muted in tr.flags {
				continue
			}
			from, from_ok := ctx_binding(ctx, tr.binding)
			to, to_ok := ctx_binding(ctx, tr.relative)
			if !from_ok || !to_ok || from != at {
				continue
			}
			if _, done := seen[to]; !done {
				seen[to] = {}
				append(&queue, to)
			}
		}
	}
	return false
}

// follow_relative evaluates the transform tracks of the binding that the track is relative to first, so the track sees
// that binding's pose at this time whatever the tracks' order. Evaluating a track twice writes the same values.
@(private)
follow_relative :: proc(ctx: ^Track_Context) {
	other, found := ctx_binding(ctx, ctx.track.relative)
	if !found {
		return
	}
	for tr in format.cutscene_tracks(ctx.data, ctx.blob) {
		if tr.kind != .Transform || .Muted in tr.flags || tr.id == ctx.track.id {
			continue
		}
		entity, bound := ctx_binding(ctx, tr.binding)
		if !bound || entity != other {
			continue
		}
		inner := ctx^
		inner.track = tr
		transform_track(&inner)
	}
}

// pose_channel is a channel's place in the pose, or false for a name that is not one of the nine.
pose_channel :: proc(name: string) -> (Pose_Channel, bool) {
	for n, c in POSE_CHANNEL_NAMES {
		if n == name {
			return c, true
		}
	}
	return {}, false
}

@(private)
part_of :: proc(c: Pose_Channel) -> Pose_Part {
	return Pose_Part(u8(c) / 3)
}
