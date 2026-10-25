package render

import "core:mem/virtual"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/ecs"
import "cinnabar:engine/volume"

@(private = "file")
Grain :: struct {
	amount: volume.Value(f32),
}

@(private = "file")
Calls :: struct {
	names:   [8]string,
	amounts: [8]f32,
	count:   int,
}

@(private = "file")
note :: proc(f: ^Frame, name: string, settings: rawptr) {
	calls := (^Calls)(f.data)
	calls.names[calls.count], calls.amounts[calls.count] = name, (^Grain)(settings).amount.value
	calls.count += 1
}

@(test)
post_effects_run_in_order_where_their_volumes_reach :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	platform := core.Platform_API {
		frame_allocator = virtual.arena_allocator(&arena),
		memory_reserve = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit = proc(ptr: rawptr, size: int) -> bool {
			return virtual.commit(ptr, uint(size)) == nil
		},
		memory_release = proc(ptr: rawptr, size: int) {
			virtual.release(ptr, uint(size))
		},
	}
	w := new(ecs.World)
	defer free(w)
	testing.expect(t, ecs.init(w, &platform))
	defer ecs.destroy(w)
	ecs.register_engine_components(&w.registry)
	volume.register_components(&w.registry)
	register_components(&w.registry)
	ecs.register_component(&w.registry, Grain, ecs.Component_Id(900))
	r := new(Renderer)
	defer free(r)
	volume.register(&r.volumes, w)

	late := proc(f: ^Frame, settings: rawptr) {note(f, "late", settings)}
	early := proc(f: ^Frame, settings: rawptr) {note(f, "early", settings)}
	other := proc(f: ^Frame, settings: rawptr) {note(f, "other", settings)}
	testing.expect(t, register_post_effect(r, w, "late", .Before_Tone_Mapping, Grain, Grain{amount = {value = 1}}, late, order = 5))
	testing.expect(t, register_post_effect(r, w, "early", .Before_Tone_Mapping, Grain, Grain{amount = {value = 1}}, early))
	testing.expect(t, register_post_effect(r, w, "other", .After_Temporal_Aa, Grain, Grain{amount = {value = 1}}, other))

	calls: Calls
	pf: Post_Frame
	f := Frame{renderer = r, post = &pf, data = &calls}
	run :: proc(f: ^Frame, w: ^ecs.World, point: Post_Point) {
		f.post.effect_settings = resolve_settings(f.renderer, w, {}).effects
		add_post_effects(f, point)
	}

	// No volume carries the settings, so nothing runs.
	pf.effects = true
	run(&f, w, .Before_Tone_Mapping)
	testing.expect_value(t, calls.count, 0)

	e := ecs.spawn(w)
	ecs.add(w, e, ecs.TRANSFORM_IDENTITY)
	ecs.add(w, e, volume.Volume{shape = .Global, weight = 0.5})
	ecs.add(w, e, Grain{amount = {true, 3}})
	run(&f, w, .Before_Tone_Mapping)
	testing.expect_value(t, calls.count, 2)
	testing.expect_value(t, calls.names[0], "early")
	testing.expect_value(t, calls.names[1], "late")
	// Halfway from the default to the volume's.
	testing.expect_value(t, calls.amounts[0], 2)

	// The viewport can turn the effects off.
	pf.effects = false
	run(&f, w, .After_Temporal_Aa)
	testing.expect_value(t, calls.count, 2)
	pf.effects = true
	run(&f, w, .After_Temporal_Aa)
	testing.expect_value(t, calls.names[2], "other")
}
