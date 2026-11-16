package host

import "base:runtime"
import "core:dynlib"
import win "core:sys/windows"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/layout"
import "cinnabar:core/testlog"

@(private = "file")
Reloaded_State :: struct {
	frame:  u64,
	// A procedure stored in the state, which on_reload does not register again.
	on_hit: proc(),
}

@(private = "file")
old_on_hit :: proc() {}

@(private = "file")
same_layout :: proc() -> u64 {
	return 1
}

@(private = "file")
reload_nothing :: proc(state: rawptr, platform: ^core.Platform_API) {}

@(private = "file")
audit_reloaded_state :: proc(
	state: rawptr,
	image: layout.Range,
	allocator: runtime.Allocator,
) -> []layout.Finding {
	return layout.audit(state, Reloaded_State, image, "Reloaded_State", allocator)
}

@(test)
a_reload_reports_a_procedure_left_in_the_state :: proc(t: ^testing.T) {
	// The audit logs its finding as an error.
	context.logger = testlog.expected_errors()
	// The test executable plays the old DLL: old_on_hit is in its image.
	old := Game_Module {
		lib = dynlib.Library(win.GetModuleHandleW(nil)),
		api = {layout_hash = same_layout},
	}
	next := Game_Module {
		version = 1,
		api = {
			layout_hash = same_layout,
			on_reload = reload_nothing,
			pointer_audit = audit_reloaded_state,
		},
	}
	state := Reloaded_State {
		frame  = 12,
		on_hit = old_on_hit,
	}
	game := old
	kept := game_swap(&game, next, &state)
	testing.expect_value(t, kept, rawptr(&state))

	findings := audit_reload(old, game, kept)
	testing.expect_value(t, len(findings), 1)
	if len(findings) == 1 {
		testing.expect_value(t, findings[0].path, "Reloaded_State.on_hit")
		testing.expect_value(t, findings[0].address, uintptr(rawptr(old_on_hit)))
	}

	state.on_hit = nil
	testing.expect_value(t, len(audit_reload(old, game, kept)), 0)
}
