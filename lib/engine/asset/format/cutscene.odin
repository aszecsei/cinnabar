package asset_format

import "core:math"
import "core:mem"

import "cinnabar:core/layout"

// A cutscene is a .cutscene text file: bindings, the entities that it possesses or spawns, and tracks on one time axis,
// each with sections of keyed channels, a clip, a sound or a sub-sequence (see docs/content/kinds/cutscenes.md). Every
// time is a whole number of ticks.
CUTSCENE_EXTENSION :: ".cutscene"

// A tick is 1/60000 s, so a frame at 24, 25, 30, 48, 50 or 60 fps is a whole number of ticks, and an i32 holds about
// 9.9 hours.
CUTSCENE_TICKS_PER_SECOND :: 60000
// A track's binding or a binding's parent when it has none.
CUTSCENE_NONE :: max(u32)
// Sub-sequences nest at most this deep.
CUTSCENE_MAX_DEPTH :: 8
// The display frame rates that a cutscene can have.
CUTSCENE_RATES :: [?]u32{24, 25, 30, 48, 50, 60}

// The most records of each table.
MAX_CUTSCENE_BINDINGS :: 1024
MAX_CUTSCENE_TRACKS :: 1024
MAX_CUTSCENE_SECTIONS :: 8192
MAX_CUTSCENE_CHANNELS :: 65536
MAX_CUTSCENE_KEYS :: 1 << 20
MAX_CUTSCENE_SKIP_RANGES :: 256
MAX_CUTSCENE_GUIDS :: 65536
MAX_CUTSCENE_CONSTRAINTS :: 8192

// CUTSCENE_TANGENT_WEIGHT is the weight of a tangent of a key that is not weighted: a third of the segment, which makes
// a Bezier segment a cubic Hermite curve, whose time is linear in its parameter.
CUTSCENE_TANGENT_WEIGHT :: 1.0 / 3.0

// Cutscene_Clock is the clock that a cutscene's time follows: the game's, which its time scale and pause change, or
// real time.
Cutscene_Clock :: enum u32 {
	Game,
	Real,
}

// Cutscene_Skip is which parts of a cutscene a player can skip (see docs/cinematics/skipping.md#the-policy).
Cutscene_Skip :: enum u32 {
	// Any time: a skip goes to the end.
	Anywhere,
	// No time.
	None,
	// The times in the skip ranges: a skip goes to the end of the range that holds the time.
	Ranges,
}

// Cutscene_Skip_Range is a part of a cutscene that a player can skip, [start, end) on the cutscene's time. A skip in it
// goes to its end.
Cutscene_Skip_Range :: struct {
	start: i32,
	end:   i32,
}

Cutscene_Binding_Kind :: enum u32 {
	// An entity that already exists in a loaded scene.
	Possessed,
	// An entity that the cutscene spawns from a prefab and despawns when it ends.
	Spawned,
}

// Cutscene_Policy is what a player does when a possessed binding's entity is missing.
Cutscene_Policy :: enum u32 {
	// The cutscene fails, naming the binding.
	Required,
	// The binding's tracks do nothing.
	Optional,
}

Cutscene_Track_Kind :: enum u32 {
	Transform,
	Property,
	Animation,
	Camera_Cut,
	Audio,
	Event,
	Sub_Sequence,
	Presentation,
}

// Cutscene_Finish is what a track leaves when the cutscene ends: the fields as they were before it, or as it set them.
Cutscene_Finish :: enum u32 {
	Restore,
	Keep,
}

// Cutscene_Space is what a transform track's keyed position and rotation are from (see
// docs/cinematics/tracks.md#transform-tracks).
Cutscene_Space :: enum u32 {
	// The binding's own pose before the cutscene first wrote it.
	Relative,
	// The track's origin, a World_Position, with no rotation.
	Absolute,
	// Another binding's pose at each evaluation, so the entity rides it.
	Relative_To,
}

// Cutscene_Interp is how a key's value goes to the next key's (see docs/cinematics/tracks.md#curves).
Cutscene_Interp :: enum u8 {
	// The key's value holds until the next key.
	Constant,
	Linear,
	// A Bezier curve from the key's out tangent to the next key's in tangent, each a slope and a weight.
	Bezier,
	// A Bezier curve whose tangents the evaluator computes from the keys' neighbours, so it does not overshoot.
	Auto,
}

Cutscene_Key_Flag :: enum u8 {
	// The in and out tangents are set apart. Without it they are one, and the editor moves them together.
	Broken,
	// The tangents have their own weights. Without it both are CUTSCENE_TANGENT_WEIGHT.
	Weighted,
	// An evaluation that crosses the key moves the entity at once, with no interpolation from its last pose. Only a
	// transform track's keys teleport.
	Teleport,
}
Cutscene_Key_Flags :: bit_set[Cutscene_Key_Flag;u8]

Cutscene_Section_Flag :: enum u32 {
	// The section adds its value to the value of the sections below it, or to the field's own value, and does not blend
	// over it.
	Additive,
	// Past the end of the asset that the section plays, its time starts again from the start. Without it, the time
	// holds at the end. Only a kind that plays an asset's time takes it (cutscene_track_plays).
	Loop,
	// A camera cut section that blends out to gameplay blends out at a skip that ends in it too. Without it, the skip
	// cuts back to gameplay.
	Blend_On_Skip,
}
Cutscene_Section_Flags :: bit_set[Cutscene_Section_Flag;u32]

// Cutscene_Root_Motion is what an animation section does with its clip's root motion (see
// docs/cinematics/tracks.md#animation-tracks).
Cutscene_Root_Motion :: enum u32 {
	// The root moves in the mesh, and a transform track places the entity.
	Bake,
	// The track moves the entity by it, as a transform track would, and the clip plays in place.
	Apply,
	// The clip plays in place, and the entity does not move by it, for a clip beside a transform track that moves the
	// entity.
	In_Place,
}

Cutscene_Channel_Flag :: enum u32 {
	// The keys' values are indexes into the blob's GUIDs, for a property track that keys an asset field.
	Guids,
}
Cutscene_Channel_Flags :: bit_set[Cutscene_Channel_Flag;u32]

// Cutscene_Suspend is a system that stops acting on a binding's entities while a cutscene holds it (see
// docs/cinematics/possession.md).
Cutscene_Suspend :: enum u8 {
	// The behaviours stop, as if their enabled were false: on_disable runs, and on_enable when the cutscene ends.
	Behaviours,
	// The Agent stops thinking and acting, and keeps its blackboard.
	AI,
	// The Nav_Agent leaves its crowd and stops its move.
	Navigation,
	// A dynamic body is kinematic, and a character leaves the simulation.
	Physics,
}
Cutscene_Suspend_Set :: bit_set[Cutscene_Suspend;u8]

// CUTSCENE_SUSPEND_ALL is what a binding suspends when neither it nor the cutscene says.
CUTSCENE_SUSPEND_ALL :: Cutscene_Suspend_Set{.Behaviours, .AI, .Navigation, .Physics}

// CUTSCENE_SUSPEND_NAMES are the names of the systems in the text.
CUTSCENE_SUSPEND_NAMES := [Cutscene_Suspend]string {
	.Behaviours = "behaviours",
	.AI         = "ai",
	.Navigation = "navigation",
	.Physics    = "physics",
}

Cutscene_Binding_Flag :: enum u8 {
	// A body that physics suspension made kinematic keeps its last velocity when it is dynamic again.
	Keep_Velocity,
}
Cutscene_Binding_Flags :: bit_set[Cutscene_Binding_Flag;u8]

// CUTSCENE_INPUT_CONTEXT is the input context that a cutscene pushes when its text does not name one.
CUTSCENE_INPUT_CONTEXT :: "cutscene"
// The longest name of an input context, as core.INPUT_ACTION_NAME_CAPACITY.
CUTSCENE_INPUT_CONTEXT_CAPACITY :: 24

Cutscene_Track_Flag :: enum u32 {
	// The track does nothing.
	Muted,
}
Cutscene_Track_Flags :: bit_set[Cutscene_Track_Flag;u32]

// Cutscene_Blend_Curve is the shape of a camera cut section's blend from and to gameplay. It is camera.Curve's.
Cutscene_Blend_Curve :: enum u8 {
	Linear,
	Smooth,
	Ease_In,
	Ease_Out,
}

// Cutscene_Constraint_Kind is what a camera constraint does (see docs/cinematics/tracks.md#camera-cut-tracks).
Cutscene_Constraint_Kind :: enum u32 {
	// The camera turns to face its target, at an offset in the target's space.
	Look_At,
	// The camera keeps an offset in its target's space.
	Follow,
	// The camera's lens focuses on its target.
	Focus,
}

// Cutscene_Constraint is a camera constraint, on a camera cut section, which applies to its camera while it shows, or
// on a camera binding, which applies while no section's constraint of the same kind does: exactly one of section and
// binding is an index, and the other is CUTSCENE_NONE. target is a binding's index, offset is in meters in the target's
// space, and damping is the ticks over which the constraint takes hold from the section's start (0 for at once). A
// Focus constraint has no offset or damping.
Cutscene_Constraint :: struct {
	kind:    Cutscene_Constraint_Kind,
	section: u32,
	binding: u32,
	target:  u32,
	offset:  [3]f32,
	damping: i32,
}
#assert(size_of(Cutscene_Constraint) == 32)

// Cutscene_Binding_Use is whether a kind of track acts on a binding.
Cutscene_Binding_Use :: enum u32 {
	Required,
	None,
	Optional,
}

// cutscene_track_binding is whether a kind of track takes a binding. Master tracks, such as camera cuts, take none.
cutscene_track_binding :: proc "contextless" (kind: Cutscene_Track_Kind) -> Cutscene_Binding_Use {
	switch kind {
	case .Transform, .Property, .Animation:
		return .Required
	case .Camera_Cut, .Sub_Sequence, .Presentation:
		return .None
	case .Audio, .Event:
		return .Optional
	}
	return .None
}

// cutscene_track_asset is the kind of asset that each section of a kind of track names, or .None for a kind whose
// sections name none.
cutscene_track_asset :: proc "contextless" (kind: Cutscene_Track_Kind) -> Asset_Kind {
	#partial switch kind {
	case .Animation:
		return .Animation
	case .Audio:
		return .Audio
	case .Sub_Sequence:
		return .Cutscene
	}
	return .None
}

// cutscene_track_plays is whether the sections of a kind of track play their asset's time, from an offset in it, at a
// speed, looping or holding past its end.
cutscene_track_plays :: proc "contextless" (kind: Cutscene_Track_Kind) -> bool {
	return kind == .Animation
}

cutscene_rate_valid :: proc "contextless" (rate: u32) -> bool {
	for r in CUTSCENE_RATES {
		if r == rate {
			return true
		}
	}
	return false
}

// Cutscene_Binding is an entity that tracks act on. A possessed binding has its scene's GUID in asset and the scene ID
// of its entity, folded from a path for an entity in a prefab instance (scene_path_id_of). A spawned binding has its
// prefab's GUID in asset, its parent binding's index or CUTSCENE_NONE, and its start transform: position in
// World_Position units (2^-24 m), from the parent when it has one. suspend is what stops acting on its entities while
// the cutscene holds it, the cutscene's default already applied.
Cutscene_Binding :: struct {
	id:        u32,
	kind:      Cutscene_Binding_Kind,
	name:      Slice,
	name_hash: u32,
	policy:    Cutscene_Policy,
	parent:    u32,
	suspend:   Cutscene_Suspend_Set,
	flags:     Cutscene_Binding_Flags,
	reserved:  u16,
	asset:     Guid,
	entity:    u64,
	position:  [3]i64,
	rotation:  [4]f32,
	scale:     [3]f32,
	reserved2: u32,
}
#assert(size_of(Cutscene_Binding) == 112)

// Cutscene_Track is a track: its kind, its binding's index or CUTSCENE_NONE, and its sections, which follow those of
// the tracks before it. A property track names the field that it animates: its component's stable ID, and the field's
// dotted name and the name's scene_field_hash. The other kinds have zeros there. A transform track has its space: for
// Absolute, its origin in World_Position units (2^-24 m), and for Relative_To, the index of the binding that it is
// relative to. The other kinds, and the other spaces, have Relative, a zero origin and CUTSCENE_NONE there.
Cutscene_Track :: struct {
	id:            u32,
	kind:          Cutscene_Track_Kind,
	name:          Slice,
	binding:       u32,
	flags:         Cutscene_Track_Flags,
	finish:        Cutscene_Finish,
	first_section: u32,
	section_count: u32,
	space:         Cutscene_Space,
	component:     u64,
	field_hash:    u64,
	field:         Slice,
	relative:      u32,
	reserved:      u32,
	origin:        [3]i64,
}
#assert(size_of(Cutscene_Track) == 96)

// Cutscene_Section is a span of a track, in ticks on the cutscene's time, with its eases, its weight, its pre-roll and
// post-roll (the ticks before its start and after its end that it holds its first and last values for), the asset that
// its track's kind names (zero for a kind that names none), and its channels. A section of a kind that plays its
// asset's time (cutscene_track_plays) has the ticks into the asset that it starts at, and the asset's time per the
// cutscene's time, above 0. An animation section has what it does with its clip's root motion. The other kinds have
// zeros there. A camera cut section has its camera's binding index, and its blends from and to gameplay in ticks with
// their curves; the other kinds have CUTSCENE_NONE and zeros there.
Cutscene_Section :: struct {
	id:            u32,
	start:         i32,
	end:           i32,
	ease_in:       i32,
	ease_out:      i32,
	weight:        f32,
	pre_roll:      i32,
	post_roll:     i32,
	asset:         Guid,
	first_channel: u32,
	channel_count: u32,
	flags:         Cutscene_Section_Flags,
	offset:        i32,
	speed:         f32,
	root_motion:   Cutscene_Root_Motion,
	camera:        u32,
	blend_in:      i32,
	blend_out:     i32,
	blend_curves:  [2]Cutscene_Blend_Curve,
	reserved:      u16,
}
#assert(size_of(Cutscene_Section) == 88)

// Cutscene_Channel is a named curve of a section, whose meaning its track's kind gives.
Cutscene_Channel :: struct {
	name:      Slice,
	name_hash: u32,
	first_key: u32,
	key_count: u32,
	flags:     Cutscene_Channel_Flags,
}
#assert(size_of(Cutscene_Channel) == 24)

// Cutscene_Key is a key of a channel, at a time in ticks from its section's start. Only a Bezier key has tangents of
// its own: slopes in value per second, and, when it is weighted, weights, the part of the segment's duration that each
// handle reaches, from 0 to 1. Other keys have zeros there, and a key that is not weighted has tangents of
// CUTSCENE_TANGENT_WEIGHT.
Cutscene_Key :: struct {
	time:       i32,
	value:      f32,
	interp:     Cutscene_Interp,
	flags:      Cutscene_Key_Flags,
	reserved:   u16,
	in_slope:   f32,
	in_weight:  f32,
	out_slope:  f32,
	out_weight: f32,
}
#assert(size_of(Cutscene_Key) == 28)

// Cutscene_Blob is the start of a cutscene blob (see docs/content/blobs-and-loading.md#blob-format). The tables are
// flat: each track's sections, each section's channels and each channel's keys follow those before them.
// input_context is the name of the input context that the cutscene pushes while it plays, empty for none, and
// hide_ui the GUIDs of the UI documents that it hides. skip is the skip policy, skip_ranges its ranges in time order
// when it is Ranges, and skip_fade the length in ticks of a skip's fade out and of its fade in.
Cutscene_Blob :: struct {
	header:        Blob_Header,
	length:        i32,
	rate:          u32,
	clock:         Cutscene_Clock,
	range_start:   i32,
	range_end:     i32,
	skip:          Cutscene_Skip,
	bindings:      Slice,
	tracks:        Slice,
	sections:      Slice,
	channels:      Slice,
	keys:          Slice,
	// The path relative to the content root, prefixed with the root's name, such as "game/cutscenes/intro.cutscene".
	source_path:   Slice,
	input_context: Slice,
	hide_ui:       Slice,
	skip_ranges:   Slice,
	skip_fade:     i32,
	reserved:      u32,
	// The assets that the keys of channels with the Guids flag name, by index.
	guids:         Slice,
	// The camera constraints, those of sections and of bindings.
	constraints:   Slice,
}
#assert(size_of(Cutscene_Blob) % align_of(Cutscene_Binding) == 0)

cutscene_layout :: proc() -> u64 {
	h := layout.hash(Cutscene_Blob)
	h ~= layout.hash(Cutscene_Binding) * 31
	h ~= layout.hash(Cutscene_Track) * 961
	h ~= layout.hash(Cutscene_Section) * 29791
	h ~= layout.hash(Cutscene_Channel) * 923521
	h ~= layout.hash(Cutscene_Key) * 28629151
	h ~= layout.hash(Cutscene_Skip_Range) * 887503681
	h ~= layout.hash(Cutscene_Constraint) * 27512614111
	return h
}

// cutscene_view checks a cutscene blob: its header, its layout, that its slices are inside it, and every record, so
// that a reader can index the tables without checks of its own.
cutscene_view :: proc(data: []byte) -> (blob: ^Cutscene_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Cutscene ||
	   header.layout != cutscene_layout() ||
	   len(data) < size_of(Cutscene_Blob) {
		return
	}
	blob = (^Cutscene_Blob)(raw_data(data))
	inside :: proc(data: []byte, s: Slice, size, align: int) -> bool {
		return(
			u64(s.offset) + u64(s.size) <= u64(len(data)) &&
			int(s.size) % size == 0 &&
			int(s.offset) % align == 0 \
		)
	}
	if !inside(data, blob.bindings, size_of(Cutscene_Binding), align_of(Cutscene_Binding)) ||
	   !inside(data, blob.tracks, size_of(Cutscene_Track), align_of(Cutscene_Track)) ||
	   !inside(data, blob.sections, size_of(Cutscene_Section), align_of(Cutscene_Section)) ||
	   !inside(data, blob.channels, size_of(Cutscene_Channel), align_of(Cutscene_Channel)) ||
	   !inside(data, blob.keys, size_of(Cutscene_Key), align_of(Cutscene_Key)) ||
	   !inside(data, blob.source_path, 1, 1) ||
	   !inside(data, blob.input_context, 1, 1) ||
	   !inside(data, blob.hide_ui, size_of(Guid), 1) ||
	   !inside(data, blob.guids, size_of(Guid), 1) ||
	   !inside(
			   data,
			   blob.constraints,
			   size_of(Cutscene_Constraint),
			   align_of(Cutscene_Constraint),
		   ) ||
	   !inside(
			   data,
			   blob.skip_ranges,
			   size_of(Cutscene_Skip_Range),
			   align_of(Cutscene_Skip_Range),
		   ) {
		return nil, false
	}
	bindings := cutscene_bindings(data, blob)
	tracks := cutscene_tracks(data, blob)
	sections := cutscene_sections(data, blob)
	channels := cutscene_channels(data, blob)
	keys := cutscene_keys(data, blob)
	if len(bindings) > MAX_CUTSCENE_BINDINGS ||
	   len(tracks) > MAX_CUTSCENE_TRACKS ||
	   len(sections) > MAX_CUTSCENE_SECTIONS ||
	   len(channels) > MAX_CUTSCENE_CHANNELS ||
	   len(keys) > MAX_CUTSCENE_KEYS ||
	   len(cutscene_constraints(data, blob)) > MAX_CUTSCENE_CONSTRAINTS ||
	   len(cutscene_guids(data, blob)) > MAX_CUTSCENE_GUIDS {
		return nil, false
	}
	if blob.length <= 0 ||
	   !cutscene_rate_valid(blob.rate) ||
	   blob.clock > .Real ||
	   blob.range_start < 0 ||
	   blob.range_start >= blob.range_end ||
	   blob.range_end > blob.length ||
	   blob.skip > .Ranges ||
	   blob.skip_fade < 0 {
		return nil, false
	}
	skip_ranges := cutscene_skip_ranges(data, blob)
	if len(skip_ranges) > MAX_CUTSCENE_SKIP_RANGES ||
	   (blob.skip != .Ranges && len(skip_ranges) > 0) {
		return nil, false
	}
	for r, i in skip_ranges {
		if r.start < 0 ||
		   r.start >= r.end ||
		   r.end > blob.length ||
		   (i > 0 && r.start < skip_ranges[i - 1].end) {
			return nil, false
		}
	}
	for b, i in bindings {
		if b.kind > .Spawned ||
		   b.policy > .Optional ||
		   transmute(u8)b.suspend & ~transmute(u8)CUTSCENE_SUSPEND_ALL != 0 ||
		   b.flags - {.Keep_Velocity} != {} ||
		   !inside(data, b.name, 1, 1) ||
		   b.asset == {} {
			return nil, false
		}
		switch b.kind {
		case .Possessed:
			if b.entity == 0 || b.parent != CUTSCENE_NONE {
				return nil, false
			}
		case .Spawned:
			if b.parent != CUTSCENE_NONE &&
			   (b.parent >= u32(i) || bindings[b.parent].kind != .Spawned) {
				return nil, false
			}
		}
	}
	next_section := u32(0)
	cut_track: Maybe(Cutscene_Track)
	for tr in tracks {
		if tr.kind == .Camera_Cut {
			if _, twice := cut_track.?; twice {
				return nil, false
			}
			cut_track = tr
		}
		if tr.kind > .Presentation ||
		   tr.finish > .Keep ||
		   tr.flags - {.Muted} != {} ||
		   !inside(data, tr.name, 1, 1) ||
		   !inside(data, tr.field, 1, 1) ||
		   (tr.kind == .Property) !=
			   (tr.component != 0 && tr.field.size > 0 && tr.field_hash != 0) ||
		   (tr.kind != .Property && (tr.component != 0 || tr.field_hash != 0)) ||
		   tr.first_section != next_section ||
		   u64(tr.first_section) + u64(tr.section_count) > u64(len(sections)) ||
		   tr.space > .Relative_To ||
		   tr.reserved != 0 ||
		   (tr.kind != .Transform && tr.space != .Relative) ||
		   (tr.space != .Absolute && tr.origin != {}) ||
		   (tr.space == .Relative_To) != (tr.relative != CUTSCENE_NONE) ||
		   (tr.space == .Relative_To &&
				   (tr.relative >= u32(len(bindings)) || tr.relative == tr.binding)) {
			return nil, false
		}
		for axis in tr.origin {
			if abs(axis) > WORLD_POSITION_LIMIT {
				return nil, false
			}
		}
		switch cutscene_track_binding(tr.kind) {
		case .Required:
			if tr.binding >= u32(len(bindings)) {
				return nil, false
			}
		case .None:
			if tr.binding != CUTSCENE_NONE {
				return nil, false
			}
		case .Optional:
			if tr.binding != CUTSCENE_NONE && tr.binding >= u32(len(bindings)) {
				return nil, false
			}
		}
		next_section += tr.section_count
		wants_asset := cutscene_track_asset(tr.kind) != .None
		track_sections := sections[tr.first_section:][:tr.section_count]
		for s, j in track_sections {
			if !cutscene_cut_valid(tr.kind, track_sections, j, len(bindings)) {
				return nil, false
			}
			if s.start < 0 ||
			   s.start >= s.end ||
			   s.end > blob.length ||
			   s.ease_in < 0 ||
			   s.ease_out < 0 ||
			   i64(s.ease_in) + i64(s.ease_out) > i64(s.end) - i64(s.start) ||
			   s.pre_roll < 0 ||
			   s.post_roll < 0 ||
			   !(s.weight >= 0 && s.weight <= 1) ||
			   (s.asset != {}) != wants_asset ||
			   s.flags - {.Additive, .Loop, .Blend_On_Skip} != {} ||
			   (.Additive in s.flags && !cutscene_track_additive(tr.kind)) ||
			   s.root_motion > .In_Place ||
			   (s.root_motion != .Bake && tr.kind != .Animation) {
				return nil, false
			}
			if cutscene_track_plays(tr.kind) {
				if s.offset < 0 || !(s.speed > 0) || math.is_inf(s.speed) {
					return nil, false
				}
			} else if s.offset != 0 || s.speed != 0 || .Loop in s.flags {
				return nil, false
			}
		}
	}
	if next_section != u32(len(sections)) {
		return nil, false
	}
	for c in cutscene_constraints(data, blob) {
		on_section, on_binding := c.section != CUTSCENE_NONE, c.binding != CUTSCENE_NONE
		camera := c.binding
		if on_section {
			cut, has_cut := cut_track.?
			if !has_cut ||
			   c.section < cut.first_section ||
			   c.section - cut.first_section >= cut.section_count {
				return nil, false
			}
			camera = sections[c.section].camera
		}
		if c.kind > .Focus ||
		   on_section == on_binding ||
		   camera >= u32(len(bindings)) ||
		   c.target >= u32(len(bindings)) ||
		   c.target == camera ||
		   c.damping < 0 ||
		   (c.kind == .Focus && (c.offset != {} || c.damping != 0)) {
			return nil, false
		}
		for axis in c.offset {
			if math.is_nan(axis) || math.is_inf(axis) {
				return nil, false
			}
		}
	}
	next_channel := u32(0)
	for tr in tracks {
		for s in sections[tr.first_section:][:tr.section_count] {
			if s.first_channel != next_channel ||
			   u64(s.first_channel) + u64(s.channel_count) > u64(len(channels)) {
				return nil, false
			}
			next_channel += s.channel_count
			for c in channels[s.first_channel:][:s.channel_count] {
				if !inside(data, c.name, 1, 1) ||
				   c.key_count == 0 ||
				   c.flags - {.Guids} != {} ||
				   (.Guids in c.flags && tr.kind != .Property) {
					return nil, false
				}
			}
		}
	}
	if next_channel != u32(len(channels)) {
		return nil, false
	}
	next_key := u32(0)
	guid_count := len(cutscene_guids(data, blob))
	for tr in tracks {
		for s in sections[tr.first_section:][:tr.section_count] {
			duration := s.end - s.start
			for c in channels[s.first_channel:][:s.channel_count] {
				if c.first_key != next_key ||
				   u64(c.first_key) + u64(c.key_count) > u64(len(keys)) {
					return nil, false
				}
				next_key += c.key_count
				for k, j in keys[c.first_key:][:c.key_count] {
					if !cutscene_key_valid(k) ||
					   k.time > duration ||
					   (j > 0 && k.time <= keys[int(c.first_key) + j - 1].time) ||
					   (.Teleport in k.flags && tr.kind != .Transform) {
						return nil, false
					}
					// A GUID key holds its value, a whole index into the GUIDs.
					if .Guids in c.flags &&
					   (k.interp != .Constant ||
							   k.value < 0 ||
							   k.value != math.floor(k.value) ||
							   int(k.value) >= guid_count) {
						return nil, false
					}
				}
			}
		}
	}
	if next_key != u32(len(keys)) {
		return nil, false
	}
	return blob, true
}

// cutscene_key_valid checks a key on its own: a time from 0, a known interpolation and flags, finite numbers, weights
// from 0 to 1 for a weighted key and 0 for the others, one slope for a key whose tangents are not broken, and no
// tangents for a key that is not a Bezier key. Any key can teleport.
cutscene_key_valid :: proc "contextless" (k: Cutscene_Key) -> bool {
	finite :: proc "contextless" (x: f32) -> bool {
		return !math.is_nan(x) && !math.is_inf(x)
	}
	if k.time < 0 ||
	   k.interp > .Auto ||
	   k.flags - {.Broken, .Weighted, .Teleport} != {} ||
	   k.reserved != 0 ||
	   !finite(k.value) ||
	   !finite(k.in_slope) ||
	   !finite(k.out_slope) ||
	   !(k.in_weight >= 0 && k.in_weight <= 1) ||
	   !(k.out_weight >= 0 && k.out_weight <= 1) {
		return false
	}
	if k.interp != .Bezier &&
	   (k.flags - {.Teleport} != {} || k.in_slope != 0 || k.out_slope != 0) {
		return false
	}
	if .Broken not_in k.flags && k.in_slope != k.out_slope {
		return false
	}
	if .Weighted not_in k.flags && (k.in_weight != 0 || k.out_weight != 0) {
		return false
	}
	return true
}

// cutscene_cut_valid checks what a section has for a camera cut. A camera cut section names a camera binding, has a
// weight of 1 and no eases, rolls, channels or additive flag, starts at or after the section before it ends, and blends
// in only from gameplay, after a gap or as the first section, and out only to it, before a gap or as the last one; a
// blend in fits in the section. Blend_On_Skip needs a blend out. The other kinds' sections have none of the camera's
// fields.
cutscene_cut_valid :: proc "contextless" (
	kind: Cutscene_Track_Kind,
	sections: []Cutscene_Section,
	index: int,
	binding_count: int,
) -> bool {
	s := sections[index]
	if s.reserved != 0 {
		return false
	}
	if kind != .Camera_Cut {
		return(
			s.camera == CUTSCENE_NONE &&
			s.blend_in == 0 &&
			s.blend_out == 0 &&
			s.blend_curves == {} &&
			.Blend_On_Skip not_in s.flags \
		)
	}
	after_gap := index == 0 || sections[index - 1].end < s.start
	before_gap := index == len(sections) - 1 || sections[index + 1].start > s.end
	return(
		s.camera < u32(binding_count) &&
		s.weight == 1 &&
		s.ease_in == 0 &&
		s.ease_out == 0 &&
		s.pre_roll == 0 &&
		s.post_roll == 0 &&
		s.channel_count == 0 &&
		.Additive not_in s.flags &&
		(index == 0 || s.start >= sections[index - 1].end) &&
		s.blend_in >= 0 &&
		s.blend_out >= 0 &&
		s.blend_in <= s.end - s.start &&
		(s.blend_in == 0 || after_gap) &&
		(s.blend_out == 0 || before_gap) &&
		s.blend_curves[0] <= .Ease_Out &&
		s.blend_curves[1] <= .Ease_Out &&
		(.Blend_On_Skip not_in s.flags || s.blend_out > 0) \
	)
}

// cutscene_track_additive is whether a kind of track takes additive sections.
cutscene_track_additive :: proc "contextless" (kind: Cutscene_Track_Kind) -> bool {
	return kind == .Transform || kind == .Property
}

cutscene_bindings :: proc "contextless" (
	data: []byte,
	blob: ^Cutscene_Blob,
) -> []Cutscene_Binding {
	bytes := blob_bytes(data, blob.bindings)
	return ([^]Cutscene_Binding)(raw_data(bytes))[:len(bytes) / size_of(Cutscene_Binding)]
}

cutscene_tracks :: proc "contextless" (data: []byte, blob: ^Cutscene_Blob) -> []Cutscene_Track {
	bytes := blob_bytes(data, blob.tracks)
	return ([^]Cutscene_Track)(raw_data(bytes))[:len(bytes) / size_of(Cutscene_Track)]
}

cutscene_sections :: proc "contextless" (
	data: []byte,
	blob: ^Cutscene_Blob,
) -> []Cutscene_Section {
	bytes := blob_bytes(data, blob.sections)
	return ([^]Cutscene_Section)(raw_data(bytes))[:len(bytes) / size_of(Cutscene_Section)]
}

cutscene_channels :: proc "contextless" (
	data: []byte,
	blob: ^Cutscene_Blob,
) -> []Cutscene_Channel {
	bytes := blob_bytes(data, blob.channels)
	return ([^]Cutscene_Channel)(raw_data(bytes))[:len(bytes) / size_of(Cutscene_Channel)]
}

cutscene_keys :: proc "contextless" (data: []byte, blob: ^Cutscene_Blob) -> []Cutscene_Key {
	bytes := blob_bytes(data, blob.keys)
	return ([^]Cutscene_Key)(raw_data(bytes))[:len(bytes) / size_of(Cutscene_Key)]
}

// cutscene_guids is the assets that GUID keys name, by index.
cutscene_guids :: proc "contextless" (data: []byte, blob: ^Cutscene_Blob) -> []Guid {
	bytes := blob_bytes(data, blob.guids)
	return ([^]Guid)(raw_data(bytes))[:len(bytes) / size_of(Guid)]
}

// cutscene_constraints is the camera constraints of sections and of bindings.
cutscene_constraints :: proc "contextless" (
	data: []byte,
	blob: ^Cutscene_Blob,
) -> []Cutscene_Constraint {
	bytes := blob_bytes(data, blob.constraints)
	return ([^]Cutscene_Constraint)(raw_data(bytes))[:len(bytes) / size_of(Cutscene_Constraint)]
}

// cutscene_cut_track is a cutscene's camera cut track, of which it has at most one, in a blob that cutscene_view
// checked.
cutscene_cut_track :: proc "contextless" (
	data: []byte,
	blob: ^Cutscene_Blob,
) -> (
	track: Cutscene_Track,
	ok: bool,
) {
	for tr in cutscene_tracks(data, blob) {
		if tr.kind == .Camera_Cut {
			return tr, true
		}
	}
	return
}

// cutscene_hide_ui is the GUIDs of the UI documents that a cutscene hides while it plays.
cutscene_hide_ui :: proc "contextless" (data: []byte, blob: ^Cutscene_Blob) -> []Guid {
	bytes := blob_bytes(data, blob.hide_ui)
	return ([^]Guid)(raw_data(bytes))[:len(bytes) / size_of(Guid)]
}

// cutscene_skip_ranges is the parts of a cutscene that a player can skip, in time order, when its skip is Ranges.
cutscene_skip_ranges :: proc "contextless" (
	data: []byte,
	blob: ^Cutscene_Blob,
) -> []Cutscene_Skip_Range {
	bytes := blob_bytes(data, blob.skip_ranges)
	return ([^]Cutscene_Skip_Range)(raw_data(bytes))[:len(bytes) / size_of(Cutscene_Skip_Range)]
}

// cutscene_skip_target is where a skip at a time goes: the end of the cutscene's range when it skips anywhere, the end
// of the skip range that holds the time when it skips in ranges, within the cutscene's range. False when the time
// cannot be skipped, or a skip would not move it.
cutscene_skip_target :: proc "contextless" (
	data: []byte,
	blob: ^Cutscene_Blob,
	t: i32,
) -> (
	target: i32,
	ok: bool,
) {
	switch blob.skip {
	case .Anywhere:
		target = blob.range_end
	case .None:
		return
	case .Ranges:
		found := false
		for r in cutscene_skip_ranges(data, blob) {
			if t >= r.start && t < r.end {
				target, found = r.end, true
				break
			}
		}
		if !found {
			return
		}
	}
	target = min(target, blob.range_end)
	return target, target > t
}

// cutscene_track_sections is a track's sections, in a blob that cutscene_view checked.
cutscene_track_sections :: proc "contextless" (
	data: []byte,
	blob: ^Cutscene_Blob,
	track: Cutscene_Track,
) -> []Cutscene_Section {
	return cutscene_sections(data, blob)[track.first_section:][:track.section_count]
}

// cutscene_section_channels is a section's channels, in a blob that cutscene_view checked.
cutscene_section_channels :: proc "contextless" (
	data: []byte,
	blob: ^Cutscene_Blob,
	section: Cutscene_Section,
) -> []Cutscene_Channel {
	return cutscene_channels(data, blob)[section.first_channel:][:section.channel_count]
}

// cutscene_channel_keys is a channel's keys, in a blob that cutscene_view checked.
cutscene_channel_keys :: proc "contextless" (
	data: []byte,
	blob: ^Cutscene_Blob,
	channel: Cutscene_Channel,
) -> []Cutscene_Key {
	return cutscene_keys(data, blob)[channel.first_key:][:channel.key_count]
}

// Cutscene_Binding_Contents is a binding as cutscene_write takes it. parent is a binding's index or CUTSCENE_NONE.
Cutscene_Binding_Contents :: struct {
	id:          u32,
	kind:        Cutscene_Binding_Kind,
	name:        string,
	policy:      Cutscene_Policy,
	parent:      u32,
	asset:       Guid,
	entity:      u64,
	position:    [3]i64,
	rotation:    [4]f32,
	scale:       [3]f32,
	suspend:     Cutscene_Suspend_Set,
	flags:       Cutscene_Binding_Flags,
	// The constraints on a camera binding.
	constraints: []Cutscene_Constraint_Contents,
}

// Cutscene_Constraint_Contents is a camera constraint as cutscene_write takes it, on the section or the binding that
// holds it. target is a binding's index.
Cutscene_Constraint_Contents :: struct {
	kind:    Cutscene_Constraint_Kind,
	target:  u32,
	offset:  [3]f32,
	damping: i32,
}

Cutscene_Channel_Contents :: struct {
	name:  string,
	flags: Cutscene_Channel_Flags,
	keys:  []Cutscene_Key,
}

Cutscene_Section_Contents :: struct {
	id:           u32,
	start:        i32,
	end:          i32,
	ease_in:      i32,
	ease_out:     i32,
	weight:       f32,
	pre_roll:     i32,
	post_roll:    i32,
	asset:        Guid,
	flags:        Cutscene_Section_Flags,
	// For a kind that plays its asset's time: ticks into the asset, and its time per the cutscene's time.
	offset:       i32,
	speed:        f32,
	root_motion:  Cutscene_Root_Motion,
	// For a camera cut: the camera's binding index, the blends from and to gameplay in ticks, and their curves, in and
	// out. The blob has CUTSCENE_NONE as the camera of the other kinds' sections.
	camera:       u32,
	blend_in:     i32,
	blend_out:    i32,
	blend_curves: [2]Cutscene_Blend_Curve,
	constraints:  []Cutscene_Constraint_Contents,
	channels:     []Cutscene_Channel_Contents,
}

// Cutscene_Track_Contents is a track as cutscene_write takes it. binding is a binding's index or CUTSCENE_NONE.
Cutscene_Track_Contents :: struct {
	id:        u32,
	kind:      Cutscene_Track_Kind,
	name:      string,
	binding:   u32,
	flags:     Cutscene_Track_Flags,
	finish:    Cutscene_Finish,
	// A property track's component and the dotted name of its field. The blob holds the name's hash too.
	component: u64,
	field:     string,
	// A transform track's space, its origin in World_Position units for Absolute, and the index of the binding that it
	// is relative to for Relative_To. The blob has CUTSCENE_NONE there for the other spaces.
	space:     Cutscene_Space,
	origin:    [3]i64,
	relative:  u32,
	sections:  []Cutscene_Section_Contents,
}

Cutscene_Contents :: struct {
	guid:          Guid,
	key:           u64,
	length:        i32,
	rate:          u32,
	clock:         Cutscene_Clock,
	range_start:   i32,
	range_end:     i32,
	bindings:      []Cutscene_Binding_Contents,
	tracks:        []Cutscene_Track_Contents,
	source_path:   string,
	input_context: string,
	hide_ui:       []Guid,
	skip:          Cutscene_Skip,
	skip_ranges:   []Cutscene_Skip_Range,
	skip_fade:     i32,
	guids:         []Guid,
}

// cutscene_write builds a cutscene blob, flattening its tracks' sections, channels and keys.
cutscene_write :: proc(contents: Cutscene_Contents, allocator := context.allocator) -> []byte {
	section_count, channel_count, key_count, constraint_count := 0, 0, 0, 0
	for b in contents.bindings {
		constraint_count += len(b.constraints)
	}
	for tr in contents.tracks {
		section_count += len(tr.sections)
		for s in tr.sections {
			channel_count += len(s.channels)
			constraint_count += len(s.constraints)
			for c in s.channels {
				key_count += len(c.keys)
			}
		}
	}
	buffer := make([dynamic]byte, size_of(Cutscene_Blob), allocator)
	bindings := reserve_bytes(
		&buffer,
		len(contents.bindings) * size_of(Cutscene_Binding),
		align_of(Cutscene_Binding),
	)
	tracks := reserve_bytes(
		&buffer,
		len(contents.tracks) * size_of(Cutscene_Track),
		align_of(Cutscene_Track),
	)
	sections := reserve_bytes(
		&buffer,
		section_count * size_of(Cutscene_Section),
		align_of(Cutscene_Section),
	)
	channels := reserve_bytes(
		&buffer,
		channel_count * size_of(Cutscene_Channel),
		align_of(Cutscene_Channel),
	)
	keys := reserve_bytes(&buffer, key_count * size_of(Cutscene_Key), align_of(Cutscene_Key))
	constraints := reserve_bytes(
		&buffer,
		constraint_count * size_of(Cutscene_Constraint),
		align_of(Cutscene_Constraint),
	)
	constraint_index := 0
	add_constraint :: proc(
		buffer: ^[dynamic]byte,
		at: Slice,
		index: ^int,
		c: Cutscene_Constraint_Contents,
		section, binding: u32,
	) {
		record := Cutscene_Constraint {
			kind    = c.kind,
			section = section,
			binding = binding,
			target  = c.target,
			offset  = c.offset,
			damping = c.damping,
		}
		mem.copy(
			&buffer[int(at.offset) + index^ * size_of(Cutscene_Constraint)],
			&record,
			size_of(record),
		)
		index^ += 1
	}
	for b, i in contents.bindings {
		record := Cutscene_Binding {
			id        = b.id,
			kind      = b.kind,
			name      = append_bytes(&buffer, transmute([]byte)b.name),
			name_hash = animation_graph_hash(b.name),
			policy    = b.policy,
			parent    = b.parent,
			asset     = b.asset,
			entity    = b.entity,
			position  = b.position,
			rotation  = b.rotation,
			scale     = b.scale,
			suspend   = b.suspend,
			flags     = b.flags,
		}
		mem.copy(
			&buffer[int(bindings.offset) + i * size_of(Cutscene_Binding)],
			&record,
			size_of(record),
		)
		for c in b.constraints {
			add_constraint(&buffer, constraints, &constraint_index, c, CUTSCENE_NONE, u32(i))
		}
	}
	section_index, channel_index, key_index := 0, 0, 0
	for tr, i in contents.tracks {
		record := Cutscene_Track {
			id            = tr.id,
			kind          = tr.kind,
			name          = append_bytes(&buffer, transmute([]byte)tr.name),
			binding       = tr.binding,
			flags         = tr.flags,
			finish        = tr.finish,
			first_section = u32(section_index),
			section_count = u32(len(tr.sections)),
			component     = tr.component,
			field         = append_bytes(&buffer, transmute([]byte)tr.field),
			field_hash    = scene_field_hash(tr.field) if tr.field != "" else 0,
			space         = tr.space,
			relative      = tr.relative if tr.space == .Relative_To else CUTSCENE_NONE,
			origin        = tr.origin,
		}
		mem.copy(
			&buffer[int(tracks.offset) + i * size_of(Cutscene_Track)],
			&record,
			size_of(record),
		)
		for s in tr.sections {
			section := Cutscene_Section {
				id            = s.id,
				start         = s.start,
				end           = s.end,
				ease_in       = s.ease_in,
				ease_out      = s.ease_out,
				weight        = s.weight,
				pre_roll      = s.pre_roll,
				post_roll     = s.post_roll,
				asset         = s.asset,
				first_channel = u32(channel_index),
				channel_count = u32(len(s.channels)),
				flags         = s.flags,
				offset        = s.offset,
				speed         = s.speed,
				root_motion   = s.root_motion,
				camera        = s.camera if tr.kind == .Camera_Cut else CUTSCENE_NONE,
				blend_in      = s.blend_in,
				blend_out     = s.blend_out,
				blend_curves  = s.blend_curves,
			}
			for c in s.constraints {
				add_constraint(
					&buffer,
					constraints,
					&constraint_index,
					c,
					u32(section_index),
					CUTSCENE_NONE,
				)
			}
			mem.copy(
				&buffer[int(sections.offset) + section_index * size_of(Cutscene_Section)],
				&section,
				size_of(section),
			)
			section_index += 1
			for c in s.channels {
				channel := Cutscene_Channel {
					name      = append_bytes(&buffer, transmute([]byte)c.name),
					name_hash = animation_graph_hash(c.name),
					first_key = u32(key_index),
					key_count = u32(len(c.keys)),
					flags     = c.flags,
				}
				mem.copy(
					&buffer[int(channels.offset) + channel_index * size_of(Cutscene_Channel)],
					&channel,
					size_of(channel),
				)
				channel_index += 1
				if len(c.keys) > 0 {
					mem.copy(
						&buffer[int(keys.offset) + key_index * size_of(Cutscene_Key)],
						raw_data(c.keys),
						len(c.keys) * size_of(Cutscene_Key),
					)
				}
				key_index += len(c.keys)
			}
		}
	}
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	input_context := append_bytes(&buffer, transmute([]byte)contents.input_context)
	hide_ui := append_bytes(&buffer, mem.slice_to_bytes(contents.hide_ui))
	guids := append_bytes(&buffer, mem.slice_to_bytes(contents.guids))
	skip_ranges := reserve_bytes(
		&buffer,
		len(contents.skip_ranges) * size_of(Cutscene_Skip_Range),
		align_of(Cutscene_Skip_Range),
	)
	if len(contents.skip_ranges) > 0 {
		mem.copy(
			&buffer[skip_ranges.offset],
			raw_data(contents.skip_ranges),
			len(contents.skip_ranges) * size_of(Cutscene_Skip_Range),
		)
	}
	blob := Cutscene_Blob {
		header = {
			magic = BLOB_MAGIC,
			kind = .Cutscene,
			layout = cutscene_layout(),
			key = contents.key,
			guid = contents.guid,
		},
		length = contents.length,
		rate = contents.rate,
		clock = contents.clock,
		range_start = contents.range_start,
		range_end = contents.range_end,
		bindings = bindings,
		tracks = tracks,
		sections = sections,
		channels = channels,
		keys = keys,
		source_path = source_path,
		input_context = input_context,
		hide_ui = hide_ui,
		skip = contents.skip,
		skip_ranges = skip_ranges,
		skip_fade = contents.skip_fade,
		guids = guids,
		constraints = constraints,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
