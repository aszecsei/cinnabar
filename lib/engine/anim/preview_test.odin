package anim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"

import "cinnabar:core"
import anim_graph "cinnabar:engine/anim/graph"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

@(private = "file")
SKIN :: "11111111111111111111111111111111"
@(private = "file")
IDLE :: "33333333333333333333333333333333"
@(private = "file")
WALK :: "22222222222222222222222222222222"

// A graph that plays apart from any entity, as the editor's preview plays one: it needs no world, it moves by the time
// that it is given, and a new blob keeps the parameters that the graph still has.
@(test)
preview_pose_plays_a_graph_apart_from_any_entity :: proc(t: ^testing.T) {
	guid :: proc(text: string) -> format.Guid {
		g, _ := format.guid_parse(text)
		return g
	}
	platform := core.Platform_API {
		frame_allocator = context.temp_allocator,
		heap_allocator  = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		file_read       = core.file_read,
		file_modified   = core.file_modified,
	}
	cache, err := os.make_directory_temp("", "anim_preview_test_*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(cache)
	defer os.remove_all(cache)
	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(cache))
	defer asset.destroy(&assets)

	write :: proc(t: ^testing.T, cache, name: string, data: []byte) {
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", cache, name), data) == nil)
	}
	write(t, cache, SKIN, format.skin_write({guid = guid(SKIN), key = 1, joints = {{name = "Root", parent = -1, inverse_bind = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}}, rotation = {0, 0, 0, 1}, scale = 1, sphere = {0, 0, 0, 1}}}}, context.temp_allocator))
	write(t, cache, WALK, format.animation_write({
		guid = guid(WALK),
		key = 2,
		skin = guid(SKIN),
		joint_count = 1,
		duration = 1,
		channels = {{joint = 0, path = .Translation, interpolation = .Linear, first_key = 0, key_count = 2, first_value = 0}},
		times = {0, 1},
		values = {0, 0, 0, 2, 0, 0},
	}, context.temp_allocator))
	write(t, cache, IDLE, format.animation_write({
		guid = guid(IDLE),
		key = 3,
		skin = guid(SKIN),
		joint_count = 1,
		duration = 1,
		channels = {{joint = 0, path = .Translation, interpolation = .Linear, first_key = 0, key_count = 1, first_value = 0}},
		times = {0},
		values = {0, 0, 0},
	}, context.temp_allocator))

	graph_blob :: proc(key: u64, parameter: string) -> []byte {
		written := format.animation_graph_write({
			guid = {},
			key = key,
			parameters = {{name = parameter, kind = .Float}},
			clips = {{name = "idle", clip = guid(IDLE)}, {name = "walk", clip = guid(WALK)}},
			states = {
				{name = "idle", node = 1, motion = .Clip, parameter = format.ANIMATION_GRAPH_NONE, points = {{clip = 0}}, speed = 1, loop = true, enter_event = format.ANIMATION_GRAPH_NONE, exit_event = format.ANIMATION_GRAPH_NONE},
				{name = "walk", node = 2, motion = .Clip, parameter = format.ANIMATION_GRAPH_NONE, points = {{clip = 1}}, speed = 1, loop = true, enter_event = format.ANIMATION_GRAPH_NONE, exit_event = format.ANIMATION_GRAPH_NONE},
			},
			transitions = {{from = 0, to = 1, conditions = {{parameter = 0, op = .Greater, value = 0.1}}, exit_time = -1, node = 20}},
		}, context.temp_allocator)
		// A blob is read at its alignment, as a file's read is.
		data, _ := runtime.mem_alloc_bytes(len(written), format.BLOB_ALIGN, context.temp_allocator)
		copy(data, written)
		return data
	}

	// The clips and the skin are not loaded until the first look, whose load is at once from a loose cache.
	inst: anim_graph.Instance
	data := graph_blob(4, "speed")
	palette, _, ok := preview_pose(&assets, data, &inst, 0, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(palette), 1)
	testing.expect_value(t, inst.key, 4)
	testing.expect_value(t, inst.state, 0)

	// It moves by what it is given, without a world.
	inst.parameters[0] = 1
	palette, _, ok = preview_pose(&assets, data, &inst, 0.25, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, inst.state, 1)
	testing.expect_value(t, inst.transition, 20)
	// The walk has moved its joint along x, a quarter of the way through.
	testing.expect(t, palette[0][0][3] > 0.1, "the pose moves with the clip")
	before := inst.progress
	preview_pose(&assets, data, &inst, 0.25, context.temp_allocator)
	testing.expect(t, inst.progress > before, "the state plays on")

	// A new blob starts it again, keeping the parameters that the graph still has.
	data = graph_blob(5, "speed")
	preview_pose(&assets, data, &inst, 0, context.temp_allocator)
	testing.expect_value(t, inst.key, 5)
	testing.expect_value(t, inst.parameters[0], 1)

	data = graph_blob(6, "pace")
	preview_pose(&assets, data, &inst, 0, context.temp_allocator)
	testing.expect_value(t, inst.parameters[0], 0)

	// A clip without an animation yet, as the template's has, leaves it not ready, and its instance alone.
	empty: anim_graph.Instance
	unset := format.animation_graph_write({
		key = 7,
		clips = {{name = "unset"}},
		states = {{name = "idle", node = 1, motion = .Clip, parameter = format.ANIMATION_GRAPH_NONE, points = {{clip = 0}}, speed = 1, loop = true, enter_event = format.ANIMATION_GRAPH_NONE, exit_event = format.ANIMATION_GRAPH_NONE}},
	}, context.temp_allocator)
	aligned, _ := runtime.mem_alloc_bytes(len(unset), format.BLOB_ALIGN, context.temp_allocator)
	copy(aligned, unset)
	_, _, ok = preview_pose(&assets, aligned, &empty, 0, context.temp_allocator)
	testing.expect(t, !ok)
	testing.expect_value(t, empty.key, 0)
}
