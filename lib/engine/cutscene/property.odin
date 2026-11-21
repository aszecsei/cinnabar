package cutscene

import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/scene"

// Property_Field is a property track's field, resolved from its component's stable ID and its name's hash (see
// docs/cinematics/tracks.md#property-tracks). It is plain data, so it outlives the frame that resolved it.
Property_Field :: struct {
	component:       ecs.Component_Id,
	offset:          u32,
	size:            u32,
	kind:            scene.Field_Kind,
	// For an enum, the kind of its integer.
	enum_base:       scene.Field_Kind,
	// A volume's setting: the track also sets its override flag, which is at override_offset, while a section covers
	// the time.
	has_override:    bool,
	override_offset: u32,
}

// Property_Target is what resolving a property track found, against the layout of its component then: its field, or
// nil when the track has a problem and does nothing. A new layout, after a code reload, resolves it again.
Property_Target :: struct {
	layout: u64,
	field:  Maybe(Property_Field),
}

// property_track is the property kind's evaluate procedure. It blends the track's sections at the time over the
// field's own value and writes the whole field once. Numbers and vectors blend by weight, and additive sections add on
// top. Integers, bools, enums and assets step: the section with the most weight wins, and the field's own value has
// what weight the sections leave.
property_track :: proc(ctx: ^Track_Context) {
	entity, bound := track_entity(ctx)
	target, resolved := property_target(ctx)
	if !bound || !resolved {
		return
	}
	field := Field{entity, target.component, target.offset, target.size}
	own: [MAX_FIELD_SIZE]byte
	if !field_base(ctx, field, own[:field.size]) {
		return
	}
	value := own
	covered: bool
	if continuous(target.kind) {
		covered = blend_continuous(ctx, target, own[:field.size], value[:field.size])
	} else {
		covered = blend_stepped(ctx, target, own[:field.size], value[:field.size])
	}
	write_field(ctx, field, value[:field.size])
	if target.has_override {
		flag := Field{entity, target.component, target.override_offset, 1}
		on: [1]byte
		if !field_base(ctx, flag, on[:]) {
			return
		}
		if covered {
			on[0] = 1
		}
		write_field(ctx, flag, on[:])
	}
}

// property_target is the track's field, resolved once for each blob and each layout of its component. A track that
// cannot animate its field logs why once, and does nothing.
@(private)
property_target :: proc(ctx: ^Track_Context) -> (Property_Field, bool) {
	e := ctx.evaluation
	info := ecs.registry_find(&ctx.world.registry, ecs.Component_Id(ctx.track.component))
	layout := info.layout if info != nil else 0
	if found, seen := e.targets[ctx.track.id]; seen && found.layout == layout {
		return found.field.?
	}
	field, problem := resolve_property(ctx, info)
	target := Property_Target {
		layout = layout,
	}
	if problem == "" {
		target.field = field
	} else {
		log.errorf(
			"cutscene %s: the property track %d %q does nothing: %s",
			format.blob_string(ctx.data, ctx.blob.source_path),
			ctx.track.id,
			format.blob_string(ctx.data, ctx.track.name),
			problem,
		)
	}
	e.targets[ctx.track.id] = target
	return target.field.?
}

// resolve_property finds the track's field in its component, and checks that it can animate and that every section's
// channels and keys suit it. It gives a problem, in the frame's memory, when they do not.
@(private)
resolve_property :: proc(
	ctx: ^Track_Context,
	info: ^ecs.Component_Info,
) -> (
	field: Property_Field,
	problem: string,
) {
	context.allocator = ctx.world.platform.frame_allocator
	name := format.blob_string(ctx.data, ctx.track.field)
	if info == nil {
		return {}, fmt.aprintf("no component has the ID %d", ctx.track.component)
	}
	found: ^scene.Field
	fields := scene.component_fields(info.type, context.allocator)
	for &f in fields {
		if format.scene_field_hash(f.name) == ctx.track.field_hash {
			found = &f
			break
		}
	}
	switch {
	case found == nil:
		return {}, fmt.aprintf("%s has no field %s that the inspector shows", info.name, name)
	case found.read_only:
		return {}, fmt.aprintf("%s.%s is read-only", info.name, name)
	}
	#partial switch found.kind {
	case .Quaternion:
		return {}, fmt.aprintf("%s.%s is a rotation, which a transform track animates", info.name, name)
	case .Entity, .Position, .F64:
		return {}, fmt.aprintf("%s.%s is a %v, which cannot animate", info.name, name, found.kind)
	}
	field = {
		component       = info.id,
		offset          = found.offset,
		size            = u32(field_size(found.kind, found.enum_base)),
		kind            = found.kind,
		enum_base       = found.enum_base,
		has_override    = found.has_override,
		override_offset = found.override_offset,
	}
	for section in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		if .Additive in section.flags &&
		   (found.kind == .Bool || found.kind == .Enum || found.kind == .Asset) {
			return {}, fmt.aprintf("section %d is additive, which a %v field cannot be", section.id, found.kind)
		}
		for channel in format.cutscene_section_channels(ctx.data, ctx.blob, section) {
			channel_name := format.blob_string(ctx.data, channel.name)
			if _, ok := channel_component(found.kind, channel_name); !ok {
				return {}, fmt.aprintf("section %d has a channel %s, but a %v field takes %s", section.id, channel_name, found.kind, channels_of(found.kind))
			}
			if (.Guids in channel.flags) != (found.kind == .Asset) {
				return {}, fmt.aprintf("section %d keys %s, but the field is a %v", section.id, "assets" if .Guids in channel.flags else "numbers", found.kind)
			}
			for k in format.cutscene_channel_keys(ctx.data, ctx.blob, channel) {
				if message := stepped_key_problem(found^, k.value); message != "" {
					return {}, fmt.aprintf("section %d: %s", section.id, message)
				}
			}
		}
	}
	return field, ""
}

// stepped_key_problem is why a key's value does not suit a field that steps, or "".
@(private)
stepped_key_problem :: proc(field: scene.Field, value: f32) -> string {
	#partial switch field.kind {
	case .Bool:
		if value != 0 && value != 1 {
			return "a bool's keys are 0 or 1"
		}
	case .Enum:
		for v in field.enum_values {
			if f64(v.value) == f64(value) {
				return ""
			}
		}
		return "an enum's keys are the values of its names"
	case .I8, .I16, .I32, .I64, .U8, .U16, .U32, .U64:
		if value != math.floor(value) {
			return "an integer's keys are whole numbers"
		}
	}
	return ""
}

// blend_continuous blends a number's or a vector's sections into value, from its own value. It gives whether any section
// covers the time.
@(private)
blend_continuous :: proc(
	ctx: ^Track_Context,
	target: Property_Field,
	own: []byte,
	value: []byte,
) -> (
	covered: bool,
) {
	n := int(target.size) / size_of(f32)
	base := ([^]f32)(raw_data(own))[:n]
	out := ([^]f32)(raw_data(value))[:n]
	blends: [3]Blend(f32)
	added: [3]f32
	for section in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		at := section_at(ctx.blob, section, ctx.time) or_continue
		covered = true
		for channel in format.cutscene_section_channels(ctx.data, ctx.blob, section) {
			c, _ := channel_component(target.kind, format.blob_string(ctx.data, channel.name))
			v := curve_value(format.cutscene_channel_keys(ctx.data, ctx.blob, channel), at.local)
			if .Additive in section.flags {
				added[c] += v * at.weight
			} else {
				blend_add(&blends[c], v, at.weight)
			}
		}
	}
	for i in 0 ..< n {
		out[i] = blend_value(blends[i], base[i]) + added[i]
	}
	return
}

// blend_stepped picks a stepped field's value: the absolute section with the most weight, the later one among equals,
// or the field's own value when the sections' weights leave it more. Additive sections add their values, by their
// weights and rounded, to an integer. It gives whether any section covers the time.
@(private)
blend_stepped :: proc(
	ctx: ^Track_Context,
	target: Property_Field,
	own: []byte,
	value: []byte,
) -> (
	covered: bool,
) {
	total: f32
	best: f32
	picked: Maybe(f32)
	added: f64
	for section in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		at := section_at(ctx.blob, section, ctx.time) or_continue
		covered = true
		for channel in format.cutscene_section_channels(ctx.data, ctx.blob, section) {
			v := curve_step(format.cutscene_channel_keys(ctx.data, ctx.blob, channel), at.local)
			if .Additive in section.flags {
				added += math.round(f64(v) * f64(at.weight))
			} else if at.weight > 0 {
				total += at.weight
				if at.weight >= best {
					best, picked = at.weight, v
				}
			}
		}
	}
	copy(value, own)
	if v, ok := picked.?; ok && best >= 1 - total {
		put_stepped(ctx, target, value, f64(v))
	}
	if added != 0 {
		put_stepped(ctx, target, value, f64(get_integer(value, integer_kind(target))) + added)
	}
	return
}

// put_stepped writes a stepped value into a field's bytes: a bool, an integer clamped to its kind, an enum's value, or
// the asset that a GUID key's index names.
@(private)
put_stepped :: proc(ctx: ^Track_Context, target: Property_Field, out: []byte, v: f64) {
	#partial switch target.kind {
	case .Bool:
		out[0] = 1 if v != 0 else 0
	case .Asset:
		guid := format.cutscene_guids(ctx.data, ctx.blob)[int(v)]
		mem.copy(raw_data(out), &guid, size_of(guid))
	case:
		put_integer(out, integer_kind(target), i64(clamp(v, -(1 << 62), 1 << 62)))
	}
}

// continuous is whether a field's kind blends between keys.
@(private)
continuous :: proc(kind: scene.Field_Kind) -> bool {
	return kind == .F32 || kind == .Vector2 || kind == .Vector3
}

// channel_component is which of a field's numbers a channel keys: value for a number and for every stepped kind, and
// x, y and z, or r, g and b, for a vector's.
@(private)
channel_component :: proc(kind: scene.Field_Kind, name: string) -> (int, bool) {
	#partial switch kind {
	case .Vector2, .Vector3:
		count := 2 if kind == .Vector2 else 3
		NAMES :: [2][3]string{{"x", "y", "z"}, {"r", "g", "b"}}
		for names in NAMES {
			for i in 0 ..< count {
				if names[i] == name {
					return i, true
				}
			}
		}
		return 0, false
	}
	return 0, name == "value"
}

@(private)
channels_of :: proc(kind: scene.Field_Kind) -> string {
	#partial switch kind {
	case .Vector2:
		return "x and y, or r and g"
	case .Vector3:
		return "x, y and z, or r, g and b"
	}
	return "value"
}

@(private)
integer_kind :: proc(target: Property_Field) -> scene.Field_Kind {
	return target.enum_base if target.kind == .Enum else target.kind
}

@(private)
field_size :: proc(kind, enum_base: scene.Field_Kind) -> int {
	#partial switch kind {
	case .Bool, .I8, .U8:
		return 1
	case .I16, .U16:
		return 2
	case .I32, .U32, .F32:
		return 4
	case .I64, .U64, .Vector2:
		return 8
	case .Vector3:
		return 12
	case .Asset:
		return size_of(format.Guid)
	case .Enum:
		return field_size(enum_base, .Bool)
	}
	return 0
}

@(private)
get_integer :: proc(src: []byte, kind: scene.Field_Kind) -> i64 {
	p := raw_data(src)
	#partial switch kind {
	case .I8:
		return i64((^i8)(p)^)
	case .I16:
		return i64((^i16)(p)^)
	case .I32:
		return i64((^i32)(p)^)
	case .I64:
		return (^i64)(p)^
	case .U8:
		return i64((^u8)(p)^)
	case .U16:
		return i64((^u16)(p)^)
	case .U32:
		return i64((^u32)(p)^)
	case .U64:
		return i64(min((^u64)(p)^, u64(max(i64))))
	}
	return 0
}

// put_integer writes an integer of a kind, clamped to the kind's range.
@(private)
put_integer :: proc(dst: []byte, kind: scene.Field_Kind, value: i64) {
	p := raw_data(dst)
	#partial switch kind {
	case .I8:
		(^i8)(p)^ = i8(clamp(value, i64(min(i8)), i64(max(i8))))
	case .I16:
		(^i16)(p)^ = i16(clamp(value, i64(min(i16)), i64(max(i16))))
	case .I32:
		(^i32)(p)^ = i32(clamp(value, i64(min(i32)), i64(max(i32))))
	case .I64:
		(^i64)(p)^ = value
	case .U8:
		(^u8)(p)^ = u8(clamp(value, 0, i64(max(u8))))
	case .U16:
		(^u16)(p)^ = u16(clamp(value, 0, i64(max(u16))))
	case .U32:
		(^u32)(p)^ = u32(clamp(value, 0, i64(max(u32))))
	case .U64:
		(^u64)(p)^ = u64(max(value, 0))
	}
}
