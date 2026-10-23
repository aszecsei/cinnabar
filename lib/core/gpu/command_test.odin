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
INDICES :: Buffer{index = 0, generation = 1}
@(private = "file")
PLAIN :: Buffer{index = 1, generation = 1}
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
		}
		return {}, false
	},
	buffer = proc(buffer: Buffer) -> (Buffer_Desc, bool) {
		switch buffer {
		case INDICES:
			return {size = 64, usage = {.Index}}, true
		case PLAIN:
			return {size = 64}, true
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
