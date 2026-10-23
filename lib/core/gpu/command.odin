package gpu

import "base:runtime"
import "core:log"
import "core:mem"

import "cinnabar:core/layout"

// Packets never span chunks, so MAX_PACKET_SIZE must fit in one chunk.
CHUNK_SIZE :: 64 * mem.Kilobyte
MAX_PACKET_SIZE :: 1024
PACKET_ALIGN :: 4

MAX_COLOR_ATTACHMENTS :: 8
MAX_LABEL_LENGTH :: 255
// The root constant size that Vulkan guarantees for push constants.
MAX_PUSH_CONSTANTS_SIZE :: 128

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

// A pass begins with the viewport and scissor set to the attachment size, and with no pipeline,
// pass constants or index buffer bound. End_Pass clears the bindings again.
Begin_Pass :: struct {
	color_count: u32,
	colors:      [MAX_COLOR_ATTACHMENTS]Color_Attachment,
	depth:       Depth_Attachment,
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
}

#assert(size_of(Packet_Header) + size_of(Begin_Pass) <= MAX_PACKET_SIZE)
#assert(size_of(Packet_Header) + size_of(Begin_Marker) + MAX_LABEL_LENGTH <= MAX_PACKET_SIZE)
#assert(size_of(Packet_Header) + size_of(Push_Constants) + MAX_PUSH_CONSTANTS_SIZE <= MAX_PACKET_SIZE)
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

cmd_begin_pass :: proc(cb: ^Command_Buffer, colors: []Color_Attachment, depth: Depth_Attachment = {}) {
	packet := Begin_Pass {
		color_count = u32(len(colors)),
		depth       = depth,
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

@(private)
push :: proc(cb: ^Command_Buffer, kind: Packet_Kind, payload: $T, extra: []byte = nil) {
	#assert(align_of(T) <= PACKET_ALIGN)
	size := mem.align_forward_int(size_of(Packet_Header) + size_of(T) + len(extra), PACKET_ALIGN)
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
	mem.copy(&dst[size_of(Packet_Header) + size_of(T)], raw_data(extra), len(extra))
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
