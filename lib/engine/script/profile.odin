package script

import "core:c"
import "core:log"

import "cinnabar:core/luau"
import "cinnabar:core/profile"

// Callback_Zone is what begin_callback replaced, for end_callback.
@(private)
Callback_Zone :: struct {
	depth: int,
	base:  int,
}

// begin_callback opens the zone of a callback of a behaviour class. The scripts' own zones nest in it, and
// end_callback closes the ones that the callback left open.
@(private)
begin_callback :: proc(r: ^Runtime, class: profile.Name, kind: profile.Callback) -> Callback_Zone {
	p := &r.platform.profile
	z := Callback_Zone{profile.depth(p), r.profile_base}
	profile.begin(p, class, u16(kind))
	r.profile_base = profile.depth(p)
	return z
}

@(private)
end_callback :: proc(r: ^Runtime, z: Callback_Zone) {
	p := &r.platform.profile
	if profile.depth(p) > r.profile_base && !r.warned_unbalanced {
		log.warn("script: a callback ended with a Profile.begin open, so the profiler closed it. Call Profile.finish before the callback returns or yields.")
		r.warned_unbalanced = true
	}
	profile.close_to(p, z.depth + 1)
	profile.end(p)
	r.profile_base = z.base
}

// callback_kind is the zone detail of a method that call_method calls. Any other method is an event handler.
@(private)
callback_kind :: proc(method: cstring) -> profile.Callback {
	switch method {
	case "awake":
		return .Awake
	case "start":
		return .Start
	case "update":
		return .Update
	case "fixed_update":
		return .Fixed_Update
	case "on_enable":
		return .On_Enable
	case "on_disable":
		return .On_Disable
	case "on_destroy":
		return .On_Destroy
	case "on_reload":
		return .On_Reload
	}
	return .Event
}

// waiter_class is the class whose coroutine a waiter runs, or the name of coroutines that no behaviour started.
@(private)
waiter_class :: proc(r: ^Runtime, w: ^Waiter) -> profile.Name {
	if i := instance_at(r, w.owner); i != nil {
		return i.profile_class
	}
	return r.coroutine_name
}

// register_profile defines Profile.begin, Profile.finish and Profile.zone. Without the profiler they do nothing but
// call zone's function.
@(private)
register_profile :: proc(r: ^Runtime) {
	r.coroutine_name = profile.name(&r.platform.profile, "coroutine", .Script)
	define(r, "Profile.begin", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		profile.begin(&r.platform.profile, profile.name(&r.platform.profile, checkodinstring(L, 1), .User))
		return 0
	})
	define(r, "Profile.finish", proc(L: ^luau.State) -> c.int {
		finish_user_zone(runtime_of(L))
		return 0
	})
	define(r, "Profile.zone", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		name := checkodinstring(L, 1)
		luau.L_checktype(L, 2, .FUNCTION)
		profile.begin(&r.platform.profile, profile.name(&r.platform.profile, name, .User))
		luau.call(L, luau.gettop(L) - 2, luau.MULTRET)
		finish_user_zone(r)
		return luau.gettop(L) - 1
	})
}

// finish_user_zone closes the script's innermost zone, but never the zone of the callback that runs.
@(private = "file")
finish_user_zone :: proc(r: ^Runtime) {
	p := &r.platform.profile
	if profile.depth(p) > r.profile_base {
		profile.end(p)
	}
}
