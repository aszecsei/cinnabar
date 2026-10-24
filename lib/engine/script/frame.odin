package script

import "core:c"
import "core:reflect"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/luau"
import "cinnabar:engine/ecs"

// begin_phase starts the script phase: it sets Time and Input for this frame. Call it before resuming scripts, and
// end_phase after.
begin_phase :: proc(r: ^Runtime, dt: time.Duration, input: core.Input) {
	r.bindings.ctx = context
	r.frame += 1
	r.input = input
	r.commands = {}
	L := r.L

	luau.getref(L, r.time_table)
	luau.setreadonly(L, -1, false)
	set_number(L, "delta", time.duration_seconds(dt))
	set_number(L, "real_time", r.platform.time_seconds())
	set_number(L, "frame", f64(r.frame))
	if r.world != nil {
		clock := &r.world.clock
		set_number(L, "time", time.duration_seconds(clock.time))
		set_number(L, "fixed_delta", 1 / f64(clock.tick_rate))
		set_number(L, "alpha", f64(clock.alpha))
	}
	luau.setreadonly(L, -1, true)
	luau.pop(L, 1)

	luau.getref(L, r.input_table)
	luau.setreadonly(L, -1, false)
	push_vector(L, {input.mouse_position.x, input.mouse_position.y, 0})
	luau.rawsetfield(L, -2, "mouse_position")
	push_vector(L, {input.mouse_delta.x, input.mouse_delta.y, 0})
	luau.rawsetfield(L, -2, "mouse_delta")
	set_number(L, "scroll", f64(input.scroll))
	luau.setreadonly(L, -1, true)
	luau.pop(L, 1)
}

// end_phase runs the collector's step for the frame and returns the scripts' structural changes, such as
// entity:destroy, for ecs.apply. They are in frame memory.
end_phase :: proc(r: ^Runtime) -> []ecs.Commands {
	step(r)
	if r.commands.data.allocator.procedure == nil {
		return nil
	}
	buffers := make([]ecs.Commands, 1, frame(r))
	buffers[0] = r.commands
	r.commands = {}
	return buffers
}

@(private = "file")
set_number :: proc(L: ^luau.State, key: cstring, value: f64) {
	luau.pushnumber(L, value)
	luau.rawsetfield(L, -2, key)
}

// create_frame_values makes the Time, Input and Key tables. Time and Input change every frame, so they are in
// format.script_mutable_globals, and the compiler reads their fields each time. Key never changes.
@(private)
create_frame_values :: proc(r: ^Runtime) {
	L := r.L
	luau.newtable(L)
	luau.pushvalue(L, -1)
	r.time_table = luau.ref(L, -1)
	luau.pop(L, 1)
	set_path(r, "Time")

	luau.newtable(L)
	luau.pushvalue(L, -1)
	r.input_table = luau.ref(L, -1)
	luau.pop(L, 1)
	set_path(r, "Input")

	luau.newtable(L)
	for name, i in reflect.enum_field_names(core.Key) {
		if i == 0 {
			continue
		}
		buffer: [32]u8
		luau.pushnumber(L, f64(reflect.enum_field_values(core.Key)[i]))
		luau.rawsetfield(L, -2, cstring_of(r, script_name(name, buffer[:])))
	}
	set_path(r, "Key")
}

@(private)
register_frame :: proc(r: ^Runtime) {
	define(r, "Input.is_down", proc(L: ^luau.State) -> c.int {
		luau.pushboolean(L, b32(check_key(L, 1) in runtime_of(L).input.down))
		return 1
	})
	define(r, "Input.was_pressed", proc(L: ^luau.State) -> c.int {
		luau.pushboolean(L, b32(check_key(L, 1) in runtime_of(L).input.pressed))
		return 1
	})
	define(r, "Input.was_released", proc(L: ^luau.State) -> c.int {
		luau.pushboolean(L, b32(check_key(L, 1) in runtime_of(L).input.released))
		return 1
	})
}

@(private = "file")
check_key :: proc(L: ^luau.State, idx: c.int) -> core.Key {
	n := luau.L_checkinteger(L, idx)
	if n <= 0 || n > c.int(max(core.Key)) {
		luau.L_argerrorL(L, idx, "a Key value expected")
	}
	return core.Key(n)
}
