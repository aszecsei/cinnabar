// Package gpu_null is a GPU backend that validates command buffers and executes nothing.
// It runs headless tests and catches code that only one real backend accepts.
package gpu_null

import "core:log"
import "core:mem"
import "core:sync"
import "core:time"

import "cinnabar:core/gpu"

// Stands in for vsync, so a host on this backend does not spin.
FRAME_TIME :: time.Second / 60
UPLOAD_RING_SIZE :: 4 * mem.Megabyte

@(private = "file")
Pipeline_Entry :: struct {
	info:  gpu.Pipeline_Info,
	scope: gpu.Scope,
}

// Accel_Entry keeps the geometry buffers of a bottom-level structure, so validation sees when one is destroyed.
@(private = "file")
Accel_Entry :: struct {
	info:           gpu.Accel_Info,
	scope:          gpu.Scope,
	geometry_count: int,
	geometries:     [gpu.MAX_ACCEL_GEOMETRIES][2]gpu.Buffer,
}

@(private = "file")
state: struct {
	frame_start:   time.Tick,
	frame_target:  gpu.Texture,
	buffers:       gpu.Pool(gpu.Buffer, gpu.Buffer_Desc),
	textures:      gpu.Pool(gpu.Texture, gpu.Texture_Desc),
	samplers:      gpu.Pool(gpu.Sampler, gpu.Sampler_Desc),
	pipelines:     gpu.Pool(gpu.Pipeline, Pipeline_Entry),
	accels:        gpu.Pool(gpu.Accel_Struct, Accel_Entry),
	upload_buffer: gpu.Buffer,
	upload_memory: []byte,
	upload_offset: int,
	layouts:       gpu.Layout_Tracker,
}

init :: proc(window: rawptr, size: [2]i32) -> bool {
	state = {
		frame_start = time.tick_now(),
	}
	gpu.pool_init(&state.buffers, gpu.MAX_BUFFERS)
	gpu.pool_init(&state.textures, gpu.MAX_TEXTURES)
	gpu.pool_init(&state.samplers, gpu.MAX_SAMPLERS)
	gpu.pool_init(&state.pipelines, gpu.MAX_PIPELINES)
	gpu.pool_init(&state.accels, gpu.MAX_ACCEL_STRUCTS)
	gpu.layout_tracker_init(&state.layouts)
	state.frame_target = gpu.pool_add(&state.textures, frame_target_desc(size))
	gpu.track_layout(&state.layouts, state.frame_target, .Render_Target)
	state.upload_buffer = gpu.pool_add(&state.buffers, gpu.Buffer_Desc{size = UPLOAD_RING_SIZE, scope = .Permanent})
	state.upload_memory = make([]byte, UPLOAD_RING_SIZE)
	return true
}

shutdown :: proc() {
	delete(state.upload_memory)
	gpu.layout_tracker_destroy(&state.layouts)
	gpu.pool_destroy(&state.buffers)
	gpu.pool_destroy(&state.textures)
	gpu.pool_destroy(&state.samplers)
	gpu.pool_destroy(&state.pipelines)
	gpu.pool_destroy(&state.accels)
}

// The null backend validates every optional feature's commands, so it reports all of them.
FEATURES :: gpu.Features{.Mesh_Shaders, .Ray_Query, .Ray_Tracing_Pipeline}

features :: proc() -> gpu.Features {
	return FEATURES
}

frame_target :: proc() -> gpu.Texture {
	return state.frame_target
}

begin_frame :: proc(size: [2]i32) {
	if elapsed := time.tick_since(state.frame_start); elapsed < FRAME_TIME {
		time.sleep(FRAME_TIME - elapsed)
	}
	state.frame_start = time.tick_now()
	gpu.pool_get(&state.textures, state.frame_target)^ = frame_target_desc(size)
	gpu.track_layout(&state.layouts, state.frame_target, .Render_Target)
	state.upload_offset = 0
}

// submit returns false if any command buffer breaks a rule. It then drops all of them.
// Nothing runs, so the queues and waits only affect validation.
submit :: proc(buffers: []gpu.Command_Buffer, queue := gpu.Queue.Graphics, wait_for := gpu.Queues{}) -> bool {
	if err, buffer, packet := gpu.validate_submission(buffers, RESOURCES, &state.layouts, queue); err != .None {
		log.errorf("gpu: command buffer %d, packet %d: %v", buffer, packet, err)
		return false
	}
	return true
}

// end_frame checks that the game left the frame target in the render target layout.
end_frame :: proc() {
	if layout, _ := gpu.tracked_layout(&state.layouts, state.frame_target); layout != .Render_Target {
		log.errorf("gpu: the frame target ends the frame in the %v layout", layout)
	}
}

create_buffer :: proc(desc: gpu.Buffer_Desc, data: []byte) -> gpu.Buffer {
	if err := gpu.validate_buffer_desc(desc, data); err != .None {
		log.errorf("gpu: buffer %q: %v", desc.label, err)
		return {}
	}
	return gpu.pool_add(&state.buffers, gpu.Buffer_Desc{size = desc.size, usage = desc.usage, scope = desc.scope})
}

create_texture :: proc(desc: gpu.Texture_Desc, data: []byte) -> gpu.Texture {
	if err := gpu.validate_texture_desc(desc, data); err != .None {
		log.errorf("gpu: texture %q: %v", desc.label, err)
		return {}
	}
	stored := desc
	stored.label = ""
	texture := gpu.pool_add(&state.textures, stored)
	if texture != {} {
		gpu.track_layout(&state.layouts, texture, gpu.initial_layout(desc.usage, data != nil))
	}
	return texture
}

create_sampler :: proc(desc: gpu.Sampler_Desc) -> gpu.Sampler {
	stored := desc
	stored.label = ""
	return gpu.pool_add(&state.samplers, stored)
}

create_graphics_pipeline :: proc(desc: gpu.Graphics_Pipeline_Desc) -> gpu.Pipeline {
	if err := gpu.validate_graphics_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return {}
	}
	if len(desc.mesh) > 0 && .Mesh_Shaders not_in FEATURES {
		log.errorf("gpu: pipeline %q: mesh shaders are not supported", desc.label)
		return {}
	}
	return gpu.pool_add(&state.pipelines, Pipeline_Entry{gpu.pipeline_info(desc), desc.scope})
}

create_compute_pipeline :: proc(desc: gpu.Compute_Pipeline_Desc) -> gpu.Pipeline {
	if err := gpu.validate_compute_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return {}
	}
	return gpu.pool_add(&state.pipelines, Pipeline_Entry{{kind = .Compute}, desc.scope})
}

create_ray_tracing_pipeline :: proc(desc: gpu.Ray_Tracing_Pipeline_Desc) -> gpu.Pipeline {
	if err := gpu.validate_ray_tracing_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return {}
	}
	return gpu.pool_add(&state.pipelines, Pipeline_Entry{{kind = .Ray_Tracing}, desc.scope})
}

update_ray_tracing_pipeline :: proc(pipeline: gpu.Pipeline, desc: gpu.Ray_Tracing_Pipeline_Desc) -> bool {
	if err := gpu.validate_ray_tracing_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return false
	}
	return update_pipeline(pipeline, {kind = .Ray_Tracing}, desc.label)
}

// An update must keep the pipeline's attachment formats, as in the real backends. Nothing compiles, so the new
// version is ready at once.
update_graphics_pipeline :: proc(pipeline: gpu.Pipeline, desc: gpu.Graphics_Pipeline_Desc) -> bool {
	if err := gpu.validate_graphics_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return false
	}
	return update_pipeline(pipeline, gpu.pipeline_info(desc), desc.label)
}

update_compute_pipeline :: proc(pipeline: gpu.Pipeline, desc: gpu.Compute_Pipeline_Desc) -> bool {
	if err := gpu.validate_compute_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return false
	}
	return update_pipeline(pipeline, {kind = .Compute}, desc.label)
}

@(private = "file")
update_pipeline :: proc(pipeline: gpu.Pipeline, info: gpu.Pipeline_Info, label: string) -> bool {
	entry, ok := gpu.pool_lookup(&state.pipelines, pipeline)
	if !ok {
		log.errorf("gpu: pipeline %q: update of an invalid handle", label)
		return false
	}
	if entry.info != info {
		log.errorf("gpu: pipeline %q: an update must keep the attachment formats. Create a new pipeline instead.", label)
		return false
	}
	return true
}

// Nothing runs on a GPU, so destroyed slots are free at once.
destroy_buffer :: proc(buffer: gpu.Buffer) {
	if _, ok := gpu.pool_remove(&state.buffers, buffer); ok {
		gpu.pool_free(&state.buffers, buffer.index)
	}
}

destroy_texture :: proc(texture: gpu.Texture) {
	assert(texture != state.frame_target, "gpu: the frame target cannot be destroyed")
	if _, ok := gpu.pool_remove(&state.textures, texture); ok {
		gpu.pool_free(&state.textures, texture.index)
		gpu.untrack_layout(&state.layouts, texture)
	}
}

destroy_sampler :: proc(sampler: gpu.Sampler) {
	if _, ok := gpu.pool_remove(&state.samplers, sampler); ok {
		gpu.pool_free(&state.samplers, sampler.index)
	}
}

create_accel :: proc(desc: gpu.Accel_Struct_Desc) -> gpu.Accel_Struct {
	if err := gpu.validate_accel_desc(desc); err != .None {
		log.errorf("gpu: acceleration structure %q: %v", desc.label, err)
		return {}
	}
	entry := Accel_Entry {
		info           = gpu.accel_info(desc),
		scope          = desc.scope,
		geometry_count = len(desc.geometries),
	}
	for g, i in desc.geometries {
		_, vertices_ok := gpu.pool_lookup(&state.buffers, g.vertices)
		_, indices_ok := gpu.pool_lookup(&state.buffers, g.indices)
		if !vertices_ok || (g.indices != {} && !indices_ok) {
			log.errorf("gpu: acceleration structure %q: geometry %d has an invalid buffer", desc.label, i)
			return {}
		}
		entry.geometries[i] = {g.vertices, g.indices}
	}
	return gpu.pool_add(&state.accels, entry)
}

destroy_accel :: proc(accel: gpu.Accel_Struct) {
	if _, ok := gpu.pool_remove(&state.accels, accel); ok {
		gpu.pool_free(&state.accels, accel.index)
	}
}

// Nothing is built, so a reference only has to be unique.
accel_reference :: proc(accel: gpu.Accel_Struct) -> u64 {
	return u64(accel.index) << 32 | u64(accel.generation)
}

destroy_pipeline :: proc(pipeline: gpu.Pipeline) {
	if _, ok := gpu.pool_remove(&state.pipelines, pipeline); ok {
		gpu.pool_free(&state.pipelines, pipeline.index)
	}
}

destroy_scope :: proc(scope: gpu.Scope) -> (count: int) {
	assert(scope != .Permanent, "gpu: the Permanent scope belongs to core")
	for i in 0 ..< state.buffers.count {
		if buffer, ok := gpu.pool_handle(&state.buffers, i); ok && state.buffers.items[i].scope == scope {
			destroy_buffer(buffer)
			count += 1
		}
	}
	for i in 0 ..< state.textures.count {
		if texture, ok := gpu.pool_handle(&state.textures, i); ok && state.textures.items[i].scope == scope {
			destroy_texture(texture)
			count += 1
		}
	}
	for i in 0 ..< state.samplers.count {
		if sampler, ok := gpu.pool_handle(&state.samplers, i); ok && state.samplers.items[i].scope == scope {
			destroy_sampler(sampler)
			count += 1
		}
	}
	for i in 0 ..< state.accels.count {
		if accel, ok := gpu.pool_handle(&state.accels, i); ok && state.accels.items[i].scope == scope {
			destroy_accel(accel)
			count += 1
		}
	}
	for i in 0 ..< state.pipelines.count {
		if pipeline, ok := gpu.pool_handle(&state.pipelines, i); ok && state.pipelines.items[i].scope == scope {
			destroy_pipeline(pipeline)
			count += 1
		}
	}
	return
}

// upload returns false when the frame's upload ring is full.
upload :: proc(size, align: int) -> (gpu.Upload, bool) {
	for {
		offset := sync.atomic_load(&state.upload_offset)
		start := mem.align_forward_int(offset, align)
		if start + size > len(state.upload_memory) {
			return {}, false
		}
		if _, ok := sync.atomic_compare_exchange_weak(&state.upload_offset, offset, start + size); ok {
			return {data = state.upload_memory[start:][:size], buffer = state.upload_buffer, offset = u32(start)}, true
		}
	}
}

@(private = "file")
frame_target_desc :: proc(size: [2]i32) -> gpu.Texture_Desc {
	return {size = {u32(max(size.x, 1)), u32(max(size.y, 1))}, format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}, scope = .Permanent}
}

@(private)
RESOURCES :: gpu.Resources {
	texture = proc(texture: gpu.Texture) -> (gpu.Texture_Desc, bool) {
		return gpu.pool_lookup(&state.textures, texture)
	},
	buffer = proc(buffer: gpu.Buffer) -> (gpu.Buffer_Desc, bool) {
		return gpu.pool_lookup(&state.buffers, buffer)
	},
	pipeline = proc(pipeline: gpu.Pipeline) -> (gpu.Pipeline_Info, bool) {
		entry, ok := gpu.pool_lookup(&state.pipelines, pipeline)
		return entry.info, ok
	},
	accel = proc(accel: gpu.Accel_Struct) -> (gpu.Accel_Info, bool) {
		entry, ok := gpu.pool_lookup(&state.accels, accel)
		for buffers in entry.geometries[:entry.geometry_count] {
			_, vertices_ok := gpu.pool_lookup(&state.buffers, buffers[0])
			_, indices_ok := gpu.pool_lookup(&state.buffers, buffers[1])
			entry.info.inputs_valid &&= vertices_ok && (buffers[1] == {} || indices_ok)
		}
		return entry.info, ok
	},
}
