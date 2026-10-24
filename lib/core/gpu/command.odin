package gpu

import "base:runtime"
import "core:log"
import "core:mem"
import "core:slice"

import "cinnabar:core/layout"

// Packets never span chunks, so MAX_PACKET_SIZE must fit in one chunk.
CHUNK_SIZE :: 64 * mem.Kilobyte
MAX_PACKET_SIZE :: 1024
PACKET_ALIGN :: 4

MAX_COLOR_ATTACHMENTS :: 8
MAX_LABEL_LENGTH :: 255
// The root constant size that Vulkan guarantees for push constants.
MAX_PUSH_CONSTANTS_SIZE :: 128
// cmd_barriers splits longer lists into several packets.
MAX_PACKET_BARRIERS :: 48

Packet_Kind :: enum u16 {
	Begin_Pass,
	End_Pass,
	Begin_Marker,
	End_Marker,
	Set_Pipeline,
	Push_Constants,
	Set_Pass_Constants,
	Set_Index_Buffer,
	Set_Viewport,
	Set_Scissor,
	Draw,
	Draw_Indexed,
	Dispatch,
	Barriers,
	Draw_Indirect,
	Draw_Indexed_Indirect,
	Dispatch_Indirect,
	Draw_Mesh,
	Draw_Mesh_Indirect,
	Build_Accel,
	Dispatch_Rays,
}

// size includes the header and the padding after the payload.
Packet_Header :: struct {
	kind: Packet_Kind,
	size: u16,
}

Load_Op :: enum u8 {
	Load,
	Clear,
	Discard,
}

Store_Op :: enum u8 {
	Store,
	Discard,
}

Color_Attachment :: struct {
	texture: Texture,
	load:    Load_Op,
	store:   Store_Op,
	clear:   [4]f32,
}

// A nil texture means the pass has no depth attachment.
Depth_Attachment :: struct {
	texture: Texture,
	load:    Load_Op,
	store:   Store_Op,
	clear:   f32,
}

// A split pass is one pass recorded as pieces in consecutive command buffers of one submission. Each piece but
// the last suspends the pass, and each piece but the first resumes it. See docs/gpu.md#split-passes.
Pass_Flag :: enum u8 {
	// The pass continues in the next command buffer. The piece must end its command buffer and store its attachments.
	Suspending,
	// The pass continues from the previous command buffer. The piece must start its command buffer, load its
	// attachments, and have the same attachments as the suspended piece.
	Resuming,
}

Pass_Flags :: bit_set[Pass_Flag;u8]

// A pass begins with the viewport and scissor set to the attachment size, and with no pipeline,
// pass constants or index buffer bound. End_Pass clears the bindings again. Each piece of a split pass does the same.
Begin_Pass :: struct {
	color_count: u32,
	colors:      [MAX_COLOR_ATTACHMENTS]Color_Attachment,
	depth:       Depth_Attachment,
	flags:       Pass_Flags,
}

End_Pass :: struct {}

// The label's bytes follow the payload.
Begin_Marker :: struct {
	length: u16,
}

End_Marker :: struct {}

Set_Pipeline :: struct {
	pipeline: Pipeline,
}

// The constants' bytes follow the payload. They go to the root constants at offset 0.
Push_Constants :: struct {
	size: u16,
}

// The root CBV. offset is a multiple of PASS_CONSTANTS_ALIGN.
Set_Pass_Constants :: struct {
	buffer: Buffer,
	offset: u32,
}

Index_Format :: enum u8 {
	U16,
	U32,
}

Set_Index_Buffer :: struct {
	buffer: Buffer,
	offset: u32,
	format: Index_Format,
}

Set_Viewport :: struct {
	position:  [2]f32,
	size:      [2]f32,
	min_depth: f32,
	max_depth: f32,
}

Set_Scissor :: struct {
	position: [2]i32,
	size:     [2]i32,
}

Draw :: struct {
	vertex_count:   u32,
	instance_count: u32,
	first_vertex:   u32,
	first_instance: u32,
}

Draw_Indexed :: struct {
	index_count:    u32,
	instance_count: u32,
	first_index:    u32,
	vertex_offset:  i32,
	first_instance: u32,
}

Dispatch :: struct {
	groups: [3]u32,
}

// Draw_Indirect runs up to max_count draws whose records start at offset in arguments. With a count buffer, the
// u32 at count_offset in it caps the number of draws. Both buffers need the Indirect usage. The draw kinds share
// this payload. Their records are Draw_Indirect_Args or Draw_Indexed_Indirect_Args.
Draw_Indirect :: struct {
	arguments:    Buffer,
	offset:       u32,
	max_count:    u32,
	count:        Buffer,
	count_offset: u32,
}

// Draw_Mesh launches mesh shader groups, or amplification shader groups if the pipeline has an amplification shader.
// Draw_Mesh_Indirect uses the Draw_Indirect payload with Draw_Mesh_Indirect_Args records.
Draw_Mesh :: struct {
	groups: [3]u32,
}

// The record at offset is a Dispatch_Indirect_Args.
Dispatch_Indirect :: struct {
	arguments: Buffer,
	offset:    u32,
}

// Build_Accel builds or updates an acceleration structure from its inputs. A bottom-level structure reads the geometry
// in its description. A top-level structure reads count Accel_Instance records at offset in instances.
// Builds occur only outside a render pass.
Build_Accel :: struct {
	accel:     Accel_Struct,
	instances: Buffer,
	offset:    u32,
	count:     u32,
	// Update refits the structure from its last build. It needs Allow_Update.
	update:    b32,
}

// Dispatch_Rays launches the bound ray tracing pipeline's ray generation shader once per element of size.
Dispatch_Rays :: struct {
	size: [3]u32,
}

Buffer_Barrier :: struct {
	buffer:        Buffer,
	sync_before:   Syncs,
	sync_after:    Syncs,
	access_before: Accesses,
	access_after:  Accesses,
}

Texture_Barrier :: struct {
	texture:       Texture,
	sync_before:   Syncs,
	sync_after:    Syncs,
	access_before: Accesses,
	access_after:  Accesses,
	layout_before: Texture_Layout,
	layout_after:  Texture_Layout,
}

// Acceleration structures have only the Accel_Read and Accel_Write accesses.
Accel_Barrier :: struct {
	accel:         Accel_Struct,
	sync_before:   Syncs,
	sync_after:    Syncs,
	access_before: Accesses,
	access_after:  Accesses,
}

// The barriers follow the payload: buffer_count Buffer_Barriers, texture_count Texture_Barriers, then accel_count
// Accel_Barriers. Barriers occur only outside a render pass.
Barriers :: struct {
	buffer_count:  u16,
	texture_count: u16,
	accel_count:   u16,
	_:             u16,
}

// Format lists every packet type, so format_hash changes when any packet layout changes.
// Add new packet types here.
@(private = "file")
Packet_Format :: struct {
	header:             Packet_Header,
	begin_pass:         Begin_Pass,
	end_pass:           End_Pass,
	begin_marker:       Begin_Marker,
	end_marker:         End_Marker,
	set_pipeline:       Set_Pipeline,
	push_constants:     Push_Constants,
	set_pass_constants: Set_Pass_Constants,
	set_index_buffer:   Set_Index_Buffer,
	set_viewport:       Set_Viewport,
	set_scissor:        Set_Scissor,
	draw:               Draw,
	draw_indexed:       Draw_Indexed,
	dispatch:           Dispatch,
	barriers:           Barriers,
	buffer_barrier:     Buffer_Barrier,
	texture_barrier:    Texture_Barrier,
	draw_indirect:      Draw_Indirect,
	dispatch_indirect:  Dispatch_Indirect,
	draw_args:          Draw_Indirect_Args,
	draw_indexed_args:  Draw_Indexed_Indirect_Args,
	dispatch_args:      Dispatch_Indirect_Args,
	draw_mesh:          Draw_Mesh,
	draw_mesh_args:     Draw_Mesh_Indirect_Args,
	build_accel:        Build_Accel,
	dispatch_rays:      Dispatch_Rays,
	accel_barrier:      Accel_Barrier,
	accel_instance:     Accel_Instance,
}

#assert(size_of(Packet_Header) + size_of(Begin_Pass) <= MAX_PACKET_SIZE)
#assert(size_of(Packet_Header) + size_of(Begin_Marker) + MAX_LABEL_LENGTH <= MAX_PACKET_SIZE)
#assert(size_of(Packet_Header) + size_of(Push_Constants) + MAX_PUSH_CONSTANTS_SIZE <= MAX_PACKET_SIZE)
#assert(size_of(Packet_Header) + size_of(Barriers) + MAX_PACKET_BARRIERS * size_of(Texture_Barrier) <= MAX_PACKET_SIZE)
#assert(size_of(Buffer_Barrier) <= size_of(Texture_Barrier) && size_of(Accel_Barrier) <= size_of(Texture_Barrier))
#assert(size_of(Chunk) + MAX_PACKET_SIZE <= CHUNK_SIZE)

// format_hash identifies the packet format. The host refuses a game DLL with a different hash.
format_hash :: proc() -> u64 {
	return layout.hash(Packet_Format)
}

@(private)
Chunk :: struct {
	next: ^Chunk,
	used: int,
}

@(private)
chunk_data :: proc(chunk: ^Chunk) -> []byte {
	return ([^]byte)(chunk)[size_of(Chunk):CHUNK_SIZE]
}

// A Command_Buffer is a packet stream in chunks from its allocator, normally frame memory.
// It has no destroy procedure: its memory is freed with the allocator's memory.
Command_Buffer :: struct {
	allocator: runtime.Allocator,
	first:     ^Chunk,
	last:      ^Chunk,
}

command_buffer :: proc(allocator: runtime.Allocator) -> Command_Buffer {
	return {allocator = allocator}
}

cmd_begin_pass :: proc(cb: ^Command_Buffer, colors: []Color_Attachment, depth: Depth_Attachment = {}, flags: Pass_Flags = {}) {
	packet := Begin_Pass {
		color_count = u32(len(colors)),
		depth       = depth,
		flags       = flags,
	}
	copy(packet.colors[:], colors)
	push(cb, .Begin_Pass, packet)
}

cmd_end_pass :: proc(cb: ^Command_Buffer) {
	push(cb, .End_Pass, End_Pass{})
}

// The label is copied into the command buffer. Labels longer than MAX_LABEL_LENGTH are truncated.
cmd_begin_marker :: proc(cb: ^Command_Buffer, label: string) {
	truncated := label[:min(len(label), MAX_LABEL_LENGTH)]
	push(cb, .Begin_Marker, Begin_Marker{length = u16(len(truncated))}, transmute([]byte)truncated)
}

cmd_end_marker :: proc(cb: ^Command_Buffer) {
	push(cb, .End_Marker, End_Marker{})
}

cmd_set_pipeline :: proc(cb: ^Command_Buffer, pipeline: Pipeline) {
	push(cb, .Set_Pipeline, Set_Pipeline{pipeline})
}

// cmd_push_constants copies the constants into the command buffer. Shaders declare them with CN_PUSH_CONSTANTS.
cmd_push_constants :: proc(cb: ^Command_Buffer, constants: ^$T) {
	#assert(size_of(T) <= MAX_PUSH_CONSTANTS_SIZE && size_of(T) % 4 == 0)
	push(cb, .Push_Constants, Push_Constants{size = size_of(T)}, ([^]byte)(constants)[:size_of(T)])
}

// cmd_set_pass_constants binds an upload as the root CBV. Shaders declare it with CN_PASS_CONSTANTS.
cmd_set_pass_constants :: proc(cb: ^Command_Buffer, upload: Upload) {
	assert(upload.offset % PASS_CONSTANTS_ALIGN == 0, "gpu: pass constants must be aligned to PASS_CONSTANTS_ALIGN")
	push(cb, .Set_Pass_Constants, Set_Pass_Constants{upload.buffer, upload.offset})
}

cmd_set_index_buffer :: proc(cb: ^Command_Buffer, buffer: Buffer, format: Index_Format, offset: u32 = 0) {
	push(cb, .Set_Index_Buffer, Set_Index_Buffer{buffer, offset, format})
}

cmd_set_viewport :: proc(cb: ^Command_Buffer, position, size: [2]f32, min_depth: f32 = 0, max_depth: f32 = 1) {
	push(cb, .Set_Viewport, Set_Viewport{position, size, min_depth, max_depth})
}

cmd_set_scissor :: proc(cb: ^Command_Buffer, position, size: [2]i32) {
	push(cb, .Set_Scissor, Set_Scissor{position, size})
}

cmd_draw :: proc(cb: ^Command_Buffer, vertex_count: u32, instance_count: u32 = 1, first_vertex: u32 = 0, first_instance: u32 = 0) {
	push(cb, .Draw, Draw{vertex_count, instance_count, first_vertex, first_instance})
}

cmd_draw_indexed :: proc(
	cb: ^Command_Buffer,
	index_count: u32,
	instance_count: u32 = 1,
	first_index: u32 = 0,
	vertex_offset: i32 = 0,
	first_instance: u32 = 0,
) {
	push(cb, .Draw_Indexed, Draw_Indexed{index_count, instance_count, first_index, vertex_offset, first_instance})
}

cmd_dispatch :: proc(cb: ^Command_Buffer, groups: [3]u32) {
	push(cb, .Dispatch, Dispatch{groups})
}

// cmd_draw_indirect runs Draw_Indirect_Args records from the arguments buffer. A nil count buffer runs max_count draws.
cmd_draw_indirect :: proc(cb: ^Command_Buffer, arguments: Buffer, offset, max_count: u32, count: Buffer = {}, count_offset: u32 = 0) {
	push(cb, .Draw_Indirect, Draw_Indirect{arguments, offset, max_count, count, count_offset})
}

// cmd_draw_indexed_indirect runs Draw_Indexed_Indirect_Args records with the bound index buffer.
cmd_draw_indexed_indirect :: proc(
	cb: ^Command_Buffer,
	arguments: Buffer,
	offset, max_count: u32,
	count: Buffer = {},
	count_offset: u32 = 0,
) {
	push(cb, .Draw_Indexed_Indirect, Draw_Indirect{arguments, offset, max_count, count, count_offset})
}

// cmd_draw_mesh needs a mesh pipeline.
cmd_draw_mesh :: proc(cb: ^Command_Buffer, groups: [3]u32) {
	push(cb, .Draw_Mesh, Draw_Mesh{groups})
}

// cmd_draw_mesh_indirect runs Draw_Mesh_Indirect_Args records with a mesh pipeline.
cmd_draw_mesh_indirect :: proc(cb: ^Command_Buffer, arguments: Buffer, offset, max_count: u32, count: Buffer = {}, count_offset: u32 = 0) {
	push(cb, .Draw_Mesh_Indirect, Draw_Indirect{arguments, offset, max_count, count, count_offset})
}

cmd_dispatch_indirect :: proc(cb: ^Command_Buffer, arguments: Buffer, offset: u32 = 0) {
	push(cb, .Dispatch_Indirect, Dispatch_Indirect{arguments, offset})
}

// cmd_barriers records barriers that the backend issues together. The render graph records all barriers.
cmd_barriers :: proc(cb: ^Command_Buffer, buffers: []Buffer_Barrier, textures: []Texture_Barrier, accels: []Accel_Barrier = nil) {
	buffers, textures, accels := buffers, textures, accels
	for len(buffers) > 0 || len(textures) > 0 || len(accels) > 0 {
		b := min(len(buffers), MAX_PACKET_BARRIERS)
		t := min(len(textures), MAX_PACKET_BARRIERS - b)
		a := min(len(accels), MAX_PACKET_BARRIERS - b - t)
		packet := Barriers {
			buffer_count  = u16(b),
			texture_count = u16(t),
			accel_count   = u16(a),
		}
		push(cb, .Barriers, packet, slice.to_bytes(buffers[:b]), slice.to_bytes(textures[:t]), slice.to_bytes(accels[:a]))
		buffers, textures, accels = buffers[b:], textures[t:], accels[a:]
	}
}

// cmd_dispatch_rays needs a ray tracing pipeline, outside a render pass.
cmd_dispatch_rays :: proc(cb: ^Command_Buffer, size: [3]u32) {
	push(cb, .Dispatch_Rays, Dispatch_Rays{size})
}

// cmd_build_accel builds a bottom-level acceleration structure from the geometry in its description.
cmd_build_accel :: proc(cb: ^Command_Buffer, accel: Accel_Struct, update := false) {
	push(cb, .Build_Accel, Build_Accel{accel = accel, update = b32(update)})
}

// cmd_build_top_accel builds a top-level acceleration structure from count Accel_Instance records at offset in
// instances. The offset is a multiple of 16. The instances may be in the upload ring.
cmd_build_top_accel :: proc(cb: ^Command_Buffer, accel: Accel_Struct, instances: Buffer, offset, count: u32, update := false) {
	push(cb, .Build_Accel, Build_Accel{accel, instances, offset, count, b32(update)})
}

@(private)
push :: proc(cb: ^Command_Buffer, kind: Packet_Kind, payload: $T, extra: ..[]byte) {
	#assert(align_of(T) <= PACKET_ALIGN)
	extra_size := 0
	for e in extra {
		extra_size += len(e)
	}
	size := mem.align_forward_int(size_of(Packet_Header) + size_of(T) + extra_size, PACKET_ALIGN)
	assert(size <= MAX_PACKET_SIZE)

	if cb.last == nil || len(chunk_data(cb.last)) - cb.last.used < size {
		ptr, err := mem.alloc(CHUNK_SIZE, align_of(Chunk), cb.allocator)
		if err != nil {
			log.panicf("gpu: command buffer chunk: %v", err)
		}
		chunk := (^Chunk)(ptr)
		chunk^ = {}
		if cb.last == nil {
			cb.first = chunk
		} else {
			cb.last.next = chunk
		}
		cb.last = chunk
	}

	dst := raw_data(chunk_data(cb.last)[cb.last.used:])
	header := Packet_Header{kind, u16(size)}
	payload := payload
	mem.copy(dst, &header, size_of(Packet_Header))
	mem.copy(&dst[size_of(Packet_Header)], &payload, size_of(T))
	offset := size_of(Packet_Header) + size_of(T)
	for e in extra {
		mem.copy(&dst[offset], raw_data(e), len(e))
		offset += len(e)
	}
	cb.last.used += size
}

// data is the payload, followed by any extra bytes and padding.
Packet :: struct {
	kind: Packet_Kind,
	data: []byte,
}

Packet_Iterator :: struct {
	chunk:  ^Chunk,
	offset: int,
}

packet_iterator :: proc(cb: Command_Buffer) -> Packet_Iterator {
	return {chunk = cb.first}
}

// Use it as `for packet in next_packet(&it)`.
next_packet :: proc(it: ^Packet_Iterator) -> (packet: Packet, ok: bool) {
	for it.chunk != nil && it.offset >= it.chunk.used {
		it.chunk = it.chunk.next
		it.offset = 0
	}
	if it.chunk == nil {
		return
	}
	data := chunk_data(it.chunk)[it.offset:]
	header := (^Packet_Header)(raw_data(data))^
	it.offset += int(header.size)
	return {header.kind, data[size_of(Packet_Header):header.size]}, true
}

payload :: proc(packet: Packet, $T: typeid) -> ^T {
	assert(len(packet.data) >= size_of(T))
	return (^T)(raw_data(packet.data))
}

marker_label :: proc(packet: Packet) -> string {
	marker := payload(packet, Begin_Marker)
	return string(packet.data[size_of(Begin_Marker):][:marker.length])
}

push_constants_data :: proc(packet: Packet) -> []byte {
	constants := payload(packet, Push_Constants)
	return packet.data[size_of(Push_Constants):][:constants.size]
}

barrier_data :: proc(packet: Packet) -> (buffers: []Buffer_Barrier, textures: []Texture_Barrier, accels: []Accel_Barrier) {
	barriers := payload(packet, Barriers)
	data := packet.data[size_of(Barriers):]
	buffers = slice.reinterpret([]Buffer_Barrier, data)[:barriers.buffer_count]
	data = data[int(barriers.buffer_count) * size_of(Buffer_Barrier):]
	textures = slice.reinterpret([]Texture_Barrier, data)[:barriers.texture_count]
	data = data[int(barriers.texture_count) * size_of(Texture_Barrier):]
	accels = slice.reinterpret([]Accel_Barrier, data)[:barriers.accel_count]
	return
}
