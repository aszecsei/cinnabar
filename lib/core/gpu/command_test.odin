package gpu

import "core:mem/virtual"
import "core:testing"

@(private = "file")
TARGET :: Texture{index = 0, generation = 1}
@(private = "file")
SMALL_TARGET :: Texture{index = 1, generation = 1}
@(private = "file")
DEPTH :: Texture{index = 2, generation = 1}
@(private = "file")
SAMPLED :: Texture{index = 3, generation = 1}
@(private = "file")
MULTI :: Texture{index = 4, generation = 1}
@(private = "file")
INDICES :: Buffer{index = 0, generation = 1}
@(private = "file")
PLAIN :: Buffer{index = 1, generation = 1}
@(private = "file")
INDIRECT :: Buffer{index = 2, generation = 1}
@(private = "file")
COLOR_PIPELINE :: Pipeline{index = 0, generation = 1}
@(private = "file")
DEPTH_PIPELINE :: Pipeline{index = 1, generation = 1}
@(private = "file")
COMPUTE_PIPELINE :: Pipeline{index = 2, generation = 1}

@(private = "file")
RESOURCES :: Resources {
	texture = proc(texture: Texture) -> (Texture_Desc, bool) {
		switch texture {
		case TARGET:
			return {size = {64, 64}, format = FRAME_TARGET_FORMAT, usage = {.Render_Target}}, true
		case SMALL_TARGET:
			return {size = {32, 32}, format = FRAME_TARGET_FORMAT, usage = {.Render_Target}}, true
		case DEPTH:
			return {size = {64, 64}, format = .D32_Float, usage = {.Depth_Stencil}}, true
		case SAMPLED:
			return {size = {64, 64}, format = .RGBA8_Unorm, usage = {.Sampled}}, true
		case MULTI:
			return {size = {64, 64}, format = FRAME_TARGET_FORMAT, usage = {.Sampled, .Render_Target}}, true
		}
		return {}, false
	},
	buffer = proc(buffer: Buffer) -> (Buffer_Desc, bool) {
		switch buffer {
		case INDICES:
			return {size = 64, usage = {.Index}}, true
		case PLAIN:
			return {size = 64}, true
		case INDIRECT:
			return {size = 96, usage = {.Storage, .Indirect}}, true
		}
		return {}, false
	},
	pipeline = proc(pipeline: Pipeline) -> (Pipeline_Info, bool) {
		switch pipeline {
		case COLOR_PIPELINE:
			return pipeline_info({colors = {{format = FRAME_TARGET_FORMAT}}}), true
		case DEPTH_PIPELINE:
			return pipeline_info({colors = {{format = FRAME_TARGET_FORMAT}}, depth_format = .D32_Float}), true
		case COMPUTE_PIPELINE:
			return {kind = .Compute}, true
		}
		return {}, false
	},
}

@(test)
packets_round_trip :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)

	cb := command_buffer(virtual.arena_allocator(&arena))
	cmd_begin_marker(&cb, "frame")
	cmd_begin_pass(&cb, {{texture = TARGET, load = .Clear, clear = {0.25, 0.5, 0.75, 1}}})
	cmd_end_pass(&cb)
	cmd_end_marker(&cb)

	it := packet_iterator(cb)
	kinds: [dynamic; 8]Packet_Kind
	for p in next_packet(&it) {
		append(&kinds, p.kind)
		#partial switch p.kind {
		case .Begin_Marker:
			testing.expect_value(t, marker_label(p), "frame")
		case .Begin_Pass:
			pass := payload(p, Begin_Pass)
			testing.expect_value(t, pass.color_count, 1)
			testing.expect_value(t, pass.colors[0].texture, TARGET)
			testing.expect_value(t, pass.colors[0].load, Load_Op.Clear)
			testing.expect_value(t, pass.colors[0].clear, [4]f32{0.25, 0.5, 0.75, 1})
		}
	}
	testing.expect_value(t, len(kinds), 4)
	testing.expect_value(t, kinds[0], Packet_Kind.Begin_Marker)
	testing.expect_value(t, kinds[3], Packet_Kind.End_Marker)
}

@(test)
packets_span_chunks :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)

	COUNT :: 1000
	cb := command_buffer(virtual.arena_allocator(&arena))
	for _ in 0 ..< COUNT {
		cmd_begin_pass(&cb, {{texture = TARGET}})
		cmd_end_pass(&cb)
	}
	testing.expect(t, cb.first != cb.last, "expected more than one chunk")

	count := 0
	it := packet_iterator(cb)
	for p in next_packet(&it) {
		testing.expect_value(t, p.kind, count % 2 == 0 ? Packet_Kind.Begin_Pass : Packet_Kind.End_Pass)
		count += 1
	}
	testing.expect_value(t, count, 2 * COUNT)
}

@(test)
empty_buffer_has_no_packets :: proc(t: ^testing.T) {
	cb := command_buffer({})
	it := packet_iterator(cb)
	_, ok := next_packet(&it)
	testing.expect(t, !ok)
	err, _ := validate(cb, RESOURCES)
	testing.expect_value(t, err, Validation_Error.None)
}

@(test)
long_labels_are_truncated :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)

	long: [MAX_LABEL_LENGTH + 10]byte
	cb := command_buffer(virtual.arena_allocator(&arena))
	cmd_begin_marker(&cb, string(long[:]))
	it := packet_iterator(cb)
	p, _ := next_packet(&it)
	testing.expect_value(t, len(marker_label(p)), MAX_LABEL_LENGTH)
}

@(test)
push_constants_round_trip :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)

	constants := [3]u32{7, 8, 9}
	cb := command_buffer(virtual.arena_allocator(&arena))
	cmd_push_constants(&cb, &constants)
	it := packet_iterator(cb)
	p, _ := next_packet(&it)
	data := push_constants_data(p)
	testing.expect_value(t, len(data), size_of(constants))
	testing.expect_value(t, (^[3]u32)(raw_data(data))^, constants)
}

@(test)
pool_handles :: proc(t: ^testing.T) {
	pool: Pool(Buffer, int)
	pool_init(&pool, 2)
	defer pool_destroy(&pool)

	a := pool_add(&pool, 1)
	b := pool_add(&pool, 2)
	testing.expect_value(t, pool_add(&pool, 3), Buffer{})
	testing.expect_value(t, pool_get(&pool, a)^, 1)

	item, ok := pool_remove(&pool, a)
	testing.expect(t, ok && item == 1)
	testing.expect(t, pool_get(&pool, a) == nil, "removed handle is still valid")
	testing.expect_value(t, pool_add(&pool, 3), Buffer{})

	pool_free(&pool, a.index)
	c := pool_add(&pool, 4)
	testing.expect_value(t, c.index, a.index)
	testing.expect(t, pool_get(&pool, a) == nil, "stale handle matches a reused slot")
	testing.expect_value(t, pool_get(&pool, c)^, 4)
	testing.expect_value(t, pool_get(&pool, b)^, 2)
	testing.expect(t, pool_get(&pool, Buffer{}) == nil, "nil handle is valid")
}

@(test)
validate_rules :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	Case :: struct {
		record: proc(cb: ^Command_Buffer),
		err:    Validation_Error,
		packet: int,
	}
	cases := []Case {
		{
			proc(cb: ^Command_Buffer) {
				cmd_begin_marker(cb, "outer")
				cmd_begin_pass(cb, {{texture = TARGET}})
				cmd_begin_marker(cb, "inner")
				cmd_end_marker(cb)
				cmd_end_pass(cb)
				cmd_end_marker(cb)
			},
			.None,
			6,
		},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_begin_pass(cb, {{texture = TARGET}})}, .Nested_Pass, 1},
		{proc(cb: ^Command_Buffer) {cmd_end_pass(cb)}, .End_Pass_Outside_Pass, 0},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}})}, .Unclosed_Pass, 1},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {})}, .Bad_Attachment_Count, 0},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = {}}})}, .Invalid_Texture, 0},
		{proc(cb: ^Command_Buffer) {cmd_end_marker(cb)}, .End_Marker_Without_Begin, 0},
		{proc(cb: ^Command_Buffer) {cmd_begin_marker(cb, "a")}, .Unclosed_Marker, 1},
		{
			proc(cb: ^Command_Buffer) {cmd_begin_marker(cb, "a"); cmd_begin_pass(cb, {{texture = TARGET}}); cmd_end_marker(cb)},
			.Marker_Crosses_Pass,
			2,
		},
		{
			proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_begin_marker(cb, "a"); cmd_end_pass(cb)},
			.Marker_Crosses_Pass,
			2,
		},
		{
			proc(cb: ^Command_Buffer) {
				constants := [4]u32{1, 2, 3, 4}
				cmd_begin_pass(cb, {{texture = TARGET}}, {texture = DEPTH})
				cmd_set_pipeline(cb, DEPTH_PIPELINE)
				cmd_push_constants(cb, &constants)
				cmd_set_index_buffer(cb, INDICES, .U16)
				cmd_set_viewport(cb, {0, 0}, {32, 32})
				cmd_set_scissor(cb, {0, 0}, {32, 32})
				cmd_draw(cb, 3)
				cmd_draw_indexed(cb, 3)
				cmd_end_pass(cb)
				cmd_set_pipeline(cb, COMPUTE_PIPELINE)
				cmd_dispatch(cb, {1, 1, 1})
			},
			.None,
			11,
		},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = SAMPLED}})}, .Bad_Attachment_Usage, 0},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}, {texture = TARGET})}, .Bad_Attachment_Usage, 0},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}, {texture = SMALL_TARGET}})}, .Attachment_Size_Mismatch, 0},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {}, {texture = DEPTH}); cmd_end_pass(cb)}, .None, 2},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_set_pipeline(cb, {})}, .Invalid_Pipeline, 1},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_set_pipeline(cb, COMPUTE_PIPELINE)}, .Wrong_Pipeline_Kind, 1},
		{proc(cb: ^Command_Buffer) {cmd_set_pipeline(cb, COLOR_PIPELINE)}, .Wrong_Pipeline_Kind, 0},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_set_pipeline(cb, DEPTH_PIPELINE)}, .Pipeline_Pass_Mismatch, 1},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_draw(cb, 3)}, .No_Pipeline, 1},
		{
			proc(cb: ^Command_Buffer) {
				cmd_begin_pass(cb, {{texture = TARGET}})
				cmd_set_pipeline(cb, COLOR_PIPELINE)
				cmd_end_pass(cb)
				cmd_begin_pass(cb, {{texture = TARGET}})
				cmd_draw(cb, 3)
			},
			.No_Pipeline,
			4,
		},
		{proc(cb: ^Command_Buffer) {cmd_set_pipeline(cb, COMPUTE_PIPELINE); cmd_draw(cb, 3)}, .Draw_Outside_Pass, 1},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_dispatch(cb, {1, 1, 1})}, .Dispatch_Inside_Pass, 1},
		{proc(cb: ^Command_Buffer) {cmd_dispatch(cb, {1, 1, 1})}, .No_Pipeline, 0},
		{
			proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_set_pipeline(cb, COLOR_PIPELINE); cmd_draw_indexed(cb, 3)},
			.No_Index_Buffer,
			2,
		},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_set_index_buffer(cb, PLAIN, .U16)}, .Bad_Buffer_Usage, 1},
		{proc(cb: ^Command_Buffer) {cmd_set_index_buffer(cb, INDICES, .U16)}, .State_Outside_Pass, 0},
		{proc(cb: ^Command_Buffer) {cmd_set_scissor(cb, {}, {1, 1})}, .State_Outside_Pass, 0},
		{proc(cb: ^Command_Buffer) {cmd_set_pass_constants(cb, {buffer = {index = 9, generation = 1}})}, .Invalid_Buffer, 0},
	}
	for c, i in cases {
		cb := command_buffer(allocator)
		c.record(&cb)
		err, packet := validate(cb, RESOURCES)
		testing.expectf(t, err == c.err && packet == c.packet, "case %d: got %v at %d, want %v at %d", i, err, packet, c.err, c.packet)
	}
}

@(test)
barriers_split_into_packets :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)

	COUNT :: MAX_PACKET_BARRIERS + 10
	buffers: [COUNT]Buffer_Barrier
	textures: [COUNT]Texture_Barrier
	for i in 0 ..< COUNT {
		buffers[i] = {buffer = {index = u32(i), generation = 1}, access_after = {.Shader_Resource}}
		textures[i] = {texture = {index = u32(i), generation = 1}, layout_after = .Shader_Resource}
	}
	cb := command_buffer(virtual.arena_allocator(&arena))
	cmd_barriers(&cb, buffers[:], textures[:])

	packets := 0
	got_buffers, got_textures: [dynamic]u32
	got_buffers.allocator, got_textures.allocator = cb.allocator, cb.allocator
	it := packet_iterator(cb)
	for p in next_packet(&it) {
		packets += 1
		b, tx := barrier_data(p)
		testing.expect(t, len(b) + len(tx) <= MAX_PACKET_BARRIERS)
		for x in b {
			append(&got_buffers, x.buffer.index)
		}
		for x in tx {
			testing.expect_value(t, x.layout_after, Texture_Layout.Shader_Resource)
			append(&got_textures, x.texture.index)
		}
	}
	testing.expect_value(t, packets, 3)
	testing.expect_value(t, len(got_buffers), COUNT)
	testing.expect_value(t, len(got_textures), COUNT)
	for i in 0 ..< min(COUNT, len(got_buffers), len(got_textures)) {
		testing.expect_value(t, got_buffers[i], u32(i))
		testing.expect_value(t, got_textures[i], u32(i))
	}
}

@(test)
validate_barriers :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	Case :: struct {
		buffers:  []Buffer_Barrier,
		textures: []Texture_Barrier,
		err:      Validation_Error,
	}
	TO_SAMPLED :: Texture_Barrier {
		texture       = SAMPLED,
		sync_after    = {.Pixel_Shading},
		access_after  = {.Shader_Resource},
		layout_after  = .Shader_Resource,
	}
	cases := []Case {
		{textures = {TO_SAMPLED}, err = .None},
		{buffers = {{buffer = INDICES, sync_after = {.Index_Input}, access_after = {.Index_Buffer}}}, err = .None},
		{buffers = {{buffer = PLAIN, sync_after = {.Index_Input}, access_after = {.Index_Buffer}}}, err = .Bad_Barrier},
		{buffers = {{buffer = PLAIN, access_after = {.Shader_Resource}}}, err = .Bad_Barrier},
		{buffers = {{buffer = {index = 9, generation = 1}}}, err = .Invalid_Buffer},
		{textures = {{texture = {index = 9, generation = 1}, layout_after = .Shader_Resource}}, err = .Invalid_Texture},
		{textures = {{texture = SAMPLED, layout_after = .Render_Target}}, err = .Bad_Barrier},
		{textures = {{texture = SAMPLED, layout_before = .Shader_Resource}}, err = .Bad_Barrier},
		{textures = {{texture = TARGET, sync_after = {.Render_Target}, access_after = {.Shader_Resource}, layout_after = .Render_Target}}, err = .Bad_Barrier},
		{textures = {{texture = DEPTH, sync_after = {.Depth_Stencil}, access_after = {.Depth_Stencil_Write}, layout_after = .Depth_Stencil_Write}}, err = .None},
	}
	for c, i in cases {
		cb := command_buffer(allocator)
		cmd_barriers(&cb, c.buffers, c.textures)
		err, _ := validate(cb, RESOURCES)
		testing.expectf(t, err == c.err, "case %d: got %v, want %v", i, err, c.err)
	}

	inside := command_buffer(allocator)
	cmd_begin_pass(&inside, {{texture = TARGET}})
	cmd_barriers(&inside, nil, {TO_SAMPLED})
	cmd_end_pass(&inside)
	err, packet := validate(inside, RESOURCES)
	testing.expect_value(t, err, Validation_Error.Barrier_Inside_Pass)
	testing.expect_value(t, packet, 1)
}

@(test)
validate_tracks_layouts :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	layouts: Layout_Tracker
	layout_tracker_init(&layouts)
	defer layout_tracker_destroy(&layouts)
	track_layout(&layouts, MULTI, .Render_Target)

	TO_SAMPLED :: Texture_Barrier {
		texture       = MULTI,
		sync_before   = {.Render_Target},
		sync_after    = {.Pixel_Shading},
		access_before = {.Render_Target},
		access_after  = {.Shader_Resource},
		layout_before = .Render_Target,
		layout_after  = .Shader_Resource,
	}
	TO_TARGET :: Texture_Barrier {
		texture       = MULTI,
		sync_before   = {.Pixel_Shading},
		sync_after    = {.Render_Target},
		access_before = {.Shader_Resource},
		access_after  = {.Render_Target},
		layout_before = .Shader_Resource,
		layout_after  = .Render_Target,
	}

	mismatch := command_buffer(allocator)
	cmd_barriers(&mismatch, nil, {TO_TARGET})
	err, _ := validate(mismatch, RESOURCES, &layouts)
	testing.expect_value(t, err, Validation_Error.Layout_Mismatch)

	sampled_pass := command_buffer(allocator)
	cmd_barriers(&sampled_pass, nil, {TO_SAMPLED})
	cmd_begin_pass(&sampled_pass, {{texture = MULTI}})
	cmd_end_pass(&sampled_pass)
	err, _ = validate(sampled_pass, RESOURCES, &layouts)
	testing.expect_value(t, err, Validation_Error.Attachment_Layout)

	back := command_buffer(allocator)
	cmd_barriers(&back, nil, {TO_TARGET})
	cmd_begin_pass(&back, {{texture = MULTI}})
	cmd_end_pass(&back)
	err, _ = validate(back, RESOURCES, &layouts)
	testing.expect_value(t, err, Validation_Error.None)

	// Undefined as the layout before is valid in any layout.
	discard := command_buffer(allocator)
	cmd_barriers(&discard, nil, {{texture = MULTI, sync_after = {.Pixel_Shading}, access_after = {.Shader_Resource}, layout_after = .Shader_Resource}})
	err, _ = validate(discard, RESOURCES, &layouts)
	testing.expect_value(t, err, Validation_Error.None)
	layout, _ := tracked_layout(&layouts, MULTI)
	testing.expect_value(t, layout, Texture_Layout.Shader_Resource)
}

@(test)
validate_split_passes :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	LOADED :: Color_Attachment{texture = TARGET, load = .Load}
	Case :: struct {
		record: proc(cb: ^Command_Buffer),
		err:    Validation_Error,
	}
	cases := []Case {
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}, flags = {.Suspending}); cmd_end_pass(cb)}, .None},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {LOADED}, flags = {.Resuming}); cmd_end_pass(cb)}, .None},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET, load = .Clear}}, flags = {.Resuming}); cmd_end_pass(cb)}, .Bad_Resume},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET, store = .Discard}}, flags = {.Suspending}); cmd_end_pass(cb)}, .Bad_Suspend},
		{
			proc(cb: ^Command_Buffer) {cmd_begin_marker(cb, "a"); cmd_begin_pass(cb, {LOADED}, flags = {.Resuming}); cmd_end_pass(cb); cmd_end_marker(cb)},
			.Bad_Resume,
		},
		{
			proc(cb: ^Command_Buffer) {cmd_begin_marker(cb, "a"); cmd_begin_pass(cb, {{texture = TARGET}}, flags = {.Suspending}); cmd_end_pass(cb); cmd_end_marker(cb)},
			.Bad_Suspend,
		},
	}
	for c, i in cases {
		cb := command_buffer(allocator)
		c.record(&cb)
		err, _ := validate(cb, RESOURCES)
		testing.expectf(t, err == c.err, "case %d: got %v, want %v", i, err, c.err)
	}

	first := command_buffer(allocator)
	cmd_begin_pass(&first, {{texture = TARGET, load = .Clear}}, {texture = DEPTH, load = .Clear}, {.Suspending})
	cmd_end_pass(&first)
	middle := command_buffer(allocator)
	cmd_begin_pass(&middle, {LOADED}, {texture = DEPTH, load = .Load}, {.Resuming, .Suspending})
	cmd_end_pass(&middle)
	last := command_buffer(allocator)
	cmd_begin_pass(&last, {LOADED}, {texture = DEPTH, load = .Load}, {.Resuming})
	cmd_end_pass(&last)
	no_depth := command_buffer(allocator)
	cmd_begin_pass(&no_depth, {LOADED}, flags = {.Resuming})
	cmd_end_pass(&no_depth)
	plain := command_buffer(allocator)
	cmd_begin_pass(&plain, {{texture = TARGET}})
	cmd_end_pass(&plain)

	Chain :: struct {
		buffers: []Command_Buffer,
		err:     Validation_Error,
		buffer:  int,
	}
	chains := []Chain {
		{{plain, first, middle, last, plain}, .None, 5},
		{{first, last}, .None, 2},
		{{middle, last}, .Bad_Resume, 0},
		{{first, middle}, .Bad_Suspend, 1},
		{{first, plain}, .Bad_Suspend, 0},
		{{first, no_depth}, .Bad_Resume, 1},
	}
	for c, i in chains {
		err, buffer, _ := validate_submission(c.buffers, RESOURCES)
		testing.expectf(t, err == c.err && buffer == c.buffer, "chain %d: got %v in %d, want %v in %d", i, err, buffer, c.err, c.buffer)
	}
}

@(test)
validate_indirect_and_queues :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	Case :: struct {
		record: proc(cb: ^Command_Buffer),
		queue:  Queue,
		err:    Validation_Error,
	}
	cases := []Case {
		// INDIRECT holds 96 bytes: four indexed records, or a count at offset 92.
		{
			proc(cb: ^Command_Buffer) {
				cmd_begin_pass(cb, {{texture = TARGET}})
				cmd_set_pipeline(cb, COLOR_PIPELINE)
				cmd_set_index_buffer(cb, INDICES, .U16)
				cmd_draw_indexed_indirect(cb, INDIRECT, 0, 3, INDIRECT, 92)
				cmd_draw_indirect(cb, INDIRECT, 16, 4)
				cmd_end_pass(cb)
				cmd_set_pipeline(cb, COMPUTE_PIPELINE)
				cmd_dispatch_indirect(cb, INDIRECT, 84)
			},
			.Graphics,
			.None,
		},
		{
			proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_set_pipeline(cb, COLOR_PIPELINE); cmd_draw_indirect(cb, INDIRECT, 0, 5)},
			.Graphics,
			.Bad_Indirect,
		},
		{
			proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_set_pipeline(cb, COLOR_PIPELINE); cmd_draw_indirect(cb, INDIRECT, 2, 1)},
			.Graphics,
			.Bad_Indirect,
		},
		{
			proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_set_pipeline(cb, COLOR_PIPELINE); cmd_draw_indirect(cb, PLAIN, 0, 1)},
			.Graphics,
			.Bad_Buffer_Usage,
		},
		{
			proc(cb: ^Command_Buffer) {
				cmd_begin_pass(cb, {{texture = TARGET}})
				cmd_set_pipeline(cb, COLOR_PIPELINE)
				cmd_draw_indirect(cb, INDIRECT, 0, 1, INDIRECT, 96)
			},
			.Graphics,
			.Bad_Indirect,
		},
		{
			proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_set_pipeline(cb, COLOR_PIPELINE); cmd_draw_indexed_indirect(cb, INDIRECT, 0, 1)},
			.Graphics,
			.No_Index_Buffer,
		},
		{proc(cb: ^Command_Buffer) {cmd_set_pipeline(cb, COMPUTE_PIPELINE); cmd_draw_indirect(cb, INDIRECT, 0, 1)}, .Graphics, .Draw_Outside_Pass},
		{proc(cb: ^Command_Buffer) {cmd_dispatch_indirect(cb, INDIRECT)}, .Graphics, .No_Pipeline},
		{proc(cb: ^Command_Buffer) {cmd_set_pipeline(cb, COMPUTE_PIPELINE); cmd_dispatch_indirect(cb, INDIRECT, 88)}, .Graphics, .Bad_Indirect},
		{proc(cb: ^Command_Buffer) {cmd_set_pipeline(cb, COMPUTE_PIPELINE); cmd_dispatch_indirect(cb, INDIRECT)}, .Compute, .None},
		{proc(cb: ^Command_Buffer) {cmd_begin_pass(cb, {{texture = TARGET}}); cmd_end_pass(cb)}, .Compute, .Wrong_Queue},
		{
			proc(cb: ^Command_Buffer) {
				barrier := Buffer_Barrier {
					buffer        = INDIRECT,
					sync_before   = {.Compute_Shading},
					access_before = {.Unordered_Access},
					sync_after    = {.Execute_Indirect},
					access_after  = {.Indirect_Argument},
				}
				cmd_barriers(cb, {barrier}, nil)
			},
			.Compute,
			.None,
		},
		{
			proc(cb: ^Command_Buffer) {cmd_barriers(cb, {{buffer = INDIRECT, sync_before = {.Pixel_Shading}, access_before = {.Shader_Resource}}}, nil)},
			.Compute,
			.Bad_Barrier,
		},
		{
			proc(cb: ^Command_Buffer) {
				cmd_barriers(cb, nil, {{texture = TARGET, sync_after = {.Render_Target}, access_after = {.Render_Target}, layout_after = .Render_Target}})
			},
			.Compute,
			.Bad_Barrier,
		},
		{
			proc(cb: ^Command_Buffer) {cmd_barriers(cb, {{buffer = PLAIN, sync_after = {.Execute_Indirect}, access_after = {.Indirect_Argument}}}, nil)},
			.Graphics,
			.Bad_Barrier,
		},
	}
	for c, i in cases {
		cb := command_buffer(allocator)
		c.record(&cb)
		err, _ := validate(cb, RESOURCES, queue = c.queue)
		testing.expectf(t, err == c.err, "case %d: got %v, want %v", i, err, c.err)
	}
}
