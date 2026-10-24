package script

import "core:strings"
import "core:testing"

@(test)
definitions_cover_components_and_game_bindings :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	text := definitions(&f.runtime, context.temp_allocator)
	expect :: proc(t: ^testing.T, text, fragment: string, loc := #caller_location) {
		testing.expectf(t, strings.contains(text, fragment), "the definitions have no %q", fragment, loc = loc)
	}
	expect(t, text, "declare extern type WorldPosition with")
	expect(t, text, "declare Health: HealthType")
	// Field types come from the Odin fields, enums as a union of their names. Hidden fields are left out.
	expect(t, text, "declare extern type HealthRef extends ComponentRef with\n\tvalue: number\n")
	expect(t, text, "\tmood: \"Calm\" | \"Angry\"\n")
	expect(t, text, "\ttarget: Entity?\n")
	expect(t, text, "\tdrift: vector\n")
	testing.expect(t, !strings.contains(text, "secret"))
	// get is overloaded for each component, and for behaviour classes.
	expect(t, text, "((Entity, HealthType) -> HealthRef?)")
	expect(t, text, "((Entity, TransformType) -> TransformRef?)")
	expect(t, text, "((Entity, { [any]: any }) -> any)")
	expect(t, text, "\tSpace: number,\n")
	// The game's bindings are declared, and the engine's come from engine.d.luau only once.
	expect(t, text, "declare Test: {\n\treport: (...any) -> ...any,\n}")
	testing.expect_value(t, strings.count(text, "declare Debug:"), 1)
	testing.expect(t, !strings.contains(text, "%!"), "a format string went wrong")
}
