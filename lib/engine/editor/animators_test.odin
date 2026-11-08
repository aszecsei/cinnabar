package editor

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/anim"
import anim_graph "cinnabar:engine/anim/graph"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"

@(private = "file")
GRAPH :: "44444444444444444444444444444444"
@(private = "file")
KEY :: 9

@(private = "file")
Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	editor:   Editor,
	assets:   asset.Assets,
	cache:    string,
	out:      [dynamic]byte,
	graph:    format.Guid,
}

@(private = "file")
clock: f64

// setup makes a world with the Animator, and a cache of a graph of two states, nodes 1 and 2, a transition, node 20,
// and a float, a bool and a trigger.
@(private = "file")
setup :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		time_seconds = proc() -> f64 {
			clock += 1
			return clock
		},
		gpu_release_preview_target = proc(id: int) {},
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
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	anim.register_components(&f.world.registry)

	cache, err := os.make_directory_temp("", "editor_animators_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	graph, parsed := format.guid_parse(GRAPH)
	testing.expect(t, parsed)
	f.graph = graph
	written := format.animation_graph_write({
		guid = graph,
		key = KEY,
		parameters = {{name = "speed", kind = .Float}, {name = "grounded", kind = .Bool}, {name = "look", kind = .Trigger}},
		clips = {{name = "c"}},
		states = {
			{name = "idle", node = 1, motion = .Clip, parameter = format.ANIMATION_GRAPH_NONE, points = {{clip = 0}}, speed = 1, loop = true, enter_event = format.ANIMATION_GRAPH_NONE, exit_event = format.ANIMATION_GRAPH_NONE},
			{name = "move", node = 2, motion = .Clip, parameter = format.ANIMATION_GRAPH_NONE, points = {{clip = 0}}, speed = 1, loop = true, enter_event = format.ANIMATION_GRAPH_NONE, exit_event = format.ANIMATION_GRAPH_NONE},
		},
		transitions = {{from = 0, to = 1, exit_time = 1, node = 20}},
	}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", f.cache, GRAPH), written) == nil)
	_, loaded := asset.load(&f.assets, graph)
	testing.expect(t, loaded)

	init(&f.editor, &f.platform, &f.assets)
	return f
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	destroy(&f.editor)
	asset.destroy(&f.assets)
	ecs.destroy(&f.world)
	_ = os.remove_all(f.cache)
	delete(f.cache)
	delete(f.out)
	virtual.arena_destroy(&f.frame)
	free(f)
}

// views polls once, with the given messages from the editor, and returns the Animator views that the game sent.
@(private = "file")
views :: proc(f: ^Fixture, incoming: ..link.Message) -> []link.Animator_View {
	encoded := make([dynamic]core.Editor_Message, context.temp_allocator)
	for m in incoming {
		bytes := make([dynamic]byte, context.temp_allocator)
		link.write_message(&bytes, m)
		header, _ := link.read_header(bytes[:])
		append(&encoded, core.Editor_Message{kind = header.kind, payload = bytes[link.HEADER_SIZE:]})
	}
	clear(&f.out)
	poll(&f.editor, &f.world, nil, 1, encoded[:], &f.out)
	found := make([dynamic]link.Animator_View, context.temp_allocator)
	rest := f.out[:]
	for len(rest) > 0 {
		header, _ := link.read_header(rest)
		message, ok := link.decode_message(header.kind, rest[link.HEADER_SIZE:][:header.length], context.temp_allocator)
		if view, is_view := message.(link.Animator_View); ok && is_view {
			append(&found, view)
		}
		rest = rest[link.HEADER_SIZE + int(header.length):]
	}
	return found[:]
}

// playing is an entity whose Animator has started its graph in its second state, fading from the first.
@(private = "file")
playing :: proc(f: ^Fixture) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.TRANSFORM_IDENTITY)
	a := anim.DEFAULT_ANIMATOR
	a.graph = f.graph
	a.instance.key = KEY
	a.instance.state, a.instance.source = 1, 0
	a.instance.transition = 20
	a.instance.fade, a.instance.fade_duration, a.instance.progress = 0.25, 0.5, 0.75
	a.instance.parameters[0], a.instance.parameters[1] = 2, 1
	ecs.add(&f.world, e, a)
	return e
}

@(test)
a_watched_animators_view_goes_out_when_it_changes :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	e := playing(f)

	list := views(f, link.Watch_Entity{u64(e)})
	testing.expect_value(t, len(list), 1)
	view := list[0]
	testing.expect_value(t, ecs.Entity(view.entity), e)
	testing.expect_value(t, format.Guid(view.graph), f.graph)
	// By the nodes of the text, not the blob's indices.
	testing.expect_value(t, view.state, 2)
	testing.expect_value(t, view.source, 1)
	testing.expect_value(t, view.transition, 20)
	testing.expect_value(t, view.fade, 0.25)
	testing.expect_value(t, view.fade_duration, 0.5)
	testing.expect_value(t, view.progress, 0.75)
	testing.expect_value(t, len(view.parameters), 3)
	testing.expect_value(t, view.parameters[0].name, "speed")
	testing.expect_value(t, view.parameters[0].value, 2)
	testing.expect_value(t, view.parameters[1].kind, link.Animator_Parameter_Kind.Bool)
	testing.expect_value(t, view.parameters[2].kind, link.Animator_Parameter_Kind.Trigger)
	testing.expect_value(t, view.parameters[2].value, 0)

	testing.expect_value(t, len(views(f)), 0)
	a := ecs.get(&f.world, e, anim.Animator)
	a.instance.source = anim_graph.NONE
	list = views(f)
	testing.expect_value(t, len(list), 1)
	// An interrupted fade fades from no one state.
	testing.expect_value(t, list[0].source, 0)
	testing.expect_value(t, list[0].fade, 0.25)

	// An entity that is not watched sends none.
	views(f, link.Unwatch_Entity{u64(e)})
	a.instance.progress = 0.9
	testing.expect_value(t, len(views(f)), 0)
}

@(test)
an_animator_that_goes_away_says_so_once :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	e := playing(f)
	testing.expect_value(t, len(views(f, link.Watch_Entity{u64(e)})), 1)

	// A new graph that has not started is not ready, whose key is not the instance's.
	a := ecs.get(&f.world, e, anim.Animator)
	a.instance.key = KEY + 1
	list := views(f)
	testing.expect_value(t, len(list), 1)
	testing.expect_value(t, list[0].graph, [16]u8{})
	testing.expect_value(t, ecs.Entity(list[0].entity), e)
	testing.expect_value(t, len(views(f)), 0)

	a.instance.key = KEY
	testing.expect_value(t, len(views(f)), 1)
	ecs.remove(&f.world, e, anim.Animator)
	testing.expect_value(t, views(f)[0].graph, [16]u8{})
	testing.expect_value(t, len(views(f)), 0)

	// An entity without one never sends any.
	plain := ecs.spawn(&f.world)
	testing.expect_value(t, len(views(f, link.Watch_Entity{u64(plain)})), 0)
}

@(test)
a_preview_plays_a_graph_whatever_the_mode_and_the_editor_sets_its_parameters :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	id: u32 = 1
	open := link.Open_Preview {
		id       = id,
		material = ([16]u8)(f.graph),
	}

	// Nothing goes out until it has started, which its first drawing does.
	testing.expect_value(t, len(views(f, open)), 0)
	p := &f.editor.session.previews[id]
	testing.expect(t, p.open)
	p.instance.key = KEY
	p.instance.state, p.instance.source = 1, anim_graph.NONE

	// The mode is Edit, and it plays. An entity of 0 says that the view is a preview's.
	list := views(f)
	testing.expect_value(t, len(list), 1)
	testing.expect_value(t, list[0].entity, 0)
	testing.expect_value(t, format.Guid(list[0].graph), f.graph)
	testing.expect_value(t, list[0].state, 2)
	testing.expect_value(t, len(views(f)), 0)

	// A float, a bool and a trigger, which shows until a tick sees it and can be reset.
	views(f, link.Set_Preview_Parameter{id, "speed", 5}, link.Set_Preview_Parameter{id, "grounded", 1})
	testing.expect_value(t, p.instance.parameters[0], 5)
	testing.expect_value(t, p.instance.parameters[1], 1)
	list = views(f, link.Set_Preview_Parameter{id, "look", 1})
	testing.expect_value(t, p.instance.triggers, 1 << 2)
	testing.expect_value(t, list[0].parameters[2].value, 1)
	views(f, link.Set_Preview_Parameter{id, "look", 0})
	testing.expect_value(t, p.instance.triggers, 0)

	// A preview that is not open, or a graph that has not started, is left alone.
	views(f, link.Set_Preview_Parameter{2, "speed", 9})
	testing.expect_value(t, f.editor.session.previews[2].instance.parameters[0], 0)
	p.instance.key = KEY + 1
	views(f, link.Set_Preview_Parameter{id, "speed", 9})
	testing.expect_value(t, p.instance.parameters[0], 5)

	// Restart gives it a new instance, which its next drawing starts.
	views(f, link.Restart_Preview{id})
	testing.expect_value(t, p.instance.key, 0)
	testing.expect_value(t, p.instance.parameters[0], 0)
}
