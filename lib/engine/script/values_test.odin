package script

import "core:testing"

import "cinnabar:core/luau"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

@(private = "file")
ALL_KINDS :: Value_Kinds {
	.Nil,
	.Number,
	.Boolean,
	.String,
	.Vector,
	.Entity,
	.Position,
	.Asset,
	.Light,
}

// Each member of a Value goes to Luau and comes back as itself, through push_value and check_value.
@(test)
a_value_comes_back_from_luau_as_itself :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	r := &f.runtime
	L := r.L
	values := []Value {
		nil,
		f64(2.5),
		true,
		"door",
		"",
		[3]f32{1, 2, 3},
		ecs.Entity(77),
		ecs.World_Position{{1 << 40, -3, 5}},
		format.Guid{0 = 1, 1 = 2},
		Light_Value{.Cutscene, 42},
	}
	for v in values {
		top := luau.gettop(L)
		push_value(r, L, v)
		testing.expect_value(t, luau.gettop(L), top + 1)
		back, ok := check_value(r, L, -1, ALL_KINDS)
		testing.expectf(t, ok, "%v did not come back", v)
		testing.expect_value(t, value_kind(back), value_kind(v))
		testing.expect_value(t, back, v)
		luau.settop(L, top)
	}
}

// The nil entity and the zero GUID push nil, as push_entity and push_asset do.
@(test)
the_nil_entity_and_the_zero_guid_push_nil :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	r := &f.runtime
	L := r.L
	for v in ([]Value{ecs.Entity(0), format.Guid{}}) {
		push_value(r, L, v)
		testing.expect(t, luau.isnil(L, -1))
		luau.pop(L, 1)
	}
}

// check_value reads only the kinds that it accepts, nil among them, and raises no error for the rest.
@(test)
check_value_refuses_the_kinds_it_does_not_accept :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	r := &f.runtime
	L := r.L
	values := []Value {
		nil,
		f64(1),
		false,
		"x",
		[3]f32{},
		ecs.Entity(5),
		ecs.World_Position{},
		format.Guid{0 = 9},
		Light_Value{.Cutscene, 1},
	}
	for v in values {
		kind := value_kind(v)
		push_value(r, L, v)
		_, ok := check_value(r, L, -1, ALL_KINDS - {kind})
		testing.expectf(t, !ok, "%v was read without its kind", v)
		_, ok = check_value(r, L, -1, {kind})
		testing.expectf(t, ok, "%v was not read with its kind", v)
		luau.pop(L, 1)
	}
	// A quaternion is a userdata, but not a position.
	push_quaternion(L, 1)
	_, ok := check_value(r, L, -1, ALL_KINDS)
	testing.expect(t, !ok)
	luau.pop(L, 1)
}

// An action's argument is pushed only when its kind is the parameter's.
@(test)
an_action_argument_is_pushed_only_for_its_parameter_kind :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	r := &f.runtime
	L := r.L
	top := luau.gettop(L)
	testing.expect(t, push_action_value(r, L, "number", f64(3)))
	testing.expect(t, push_action_value(r, L, "position", ecs.World_Position{}))
	testing.expect_value(t, luau.gettop(L), top + 2)
	testing.expect(t, !push_action_value(r, L, "number", "3"))
	testing.expect(t, !push_action_value(r, L, "entity", nil))
	testing.expect(t, !push_action_value(r, L, "asset", format.Guid{0 = 1}))
	testing.expect_value(t, luau.gettop(L), top + 2)
	luau.settop(L, top)
}
