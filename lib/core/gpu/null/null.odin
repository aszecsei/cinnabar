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
state: struct {
	frame_start:   time.Tick,
	frame_target:  gpu.Texture,
	buffers:       gpu.Pool(gpu.Buffer, gpu.Buffer_Desc),
	textures:      gpu.Pool(gpu.Texture, gpu.Texture_Desc),
	samplers:      gpu.Pool(gpu.Sampler, gpu.Sampler_Desc),
	pipelines:     gpu.Pool(gpu.Pipeline, gpu.Pipeline_Info),
	upload_buffer: gpu.Buffer,
	upload_memory: []byte,
	upload_offset: int,
}

init :: proc(window: rawptr, size: [2]i32) -> bool {
	state = {
		frame_start = time.tick_now(),
	}
	gpu.pool_init(&state.buffers, gpu.MAX_BUFFERS)
	gpu.pool_init(&state.textures, gpu.MAX_TEXTURES)
	gpu.pool_init(&state.samplers, gpu.MAX_SAMPLERS)
	gpu.pool_init(&state.pipelines, gpu.MAX_PIPELINES)
	state.frame_target = gpu.pool_add(&state.textures, frame_target_desc(size))
	state.upload_buffer = gpu.pool_add(&state.buffers, gpu.Buffer_Desc{size = UPLOAD_RING_SIZE})
	state.upload_memory = make([]byte, UPLOAD_RING_SIZE)
	return true
}

shutdown :: proc() {
	delete(state.upload_memory)
	gpu.pool_destroy(&state.buffers)
	gpu.pool_destroy(&state.textures)
	gpu.pool_destroy(&state.samplers)
	gpu.pool_destroy(&state.pipelines)
}

features :: proc() -> gpu.Features {
	return {}
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
	state.upload_offset = 0
}

// submit returns false if any command buffer breaks a rule. It then drops all of them.
submit :: proc(buffers: []gpu.Command_Buffer) -> bool {
	for cb, i in buffers {
		if err, packet := gpu.validate(cb, RESOURCES); err != .None {
			log.errorf("gpu: command buffer %d, packet %d: %v", i, packet, err)
			return false
		}
	}
	return true
}

end_frame :: proc() {}

create_buffer :: proc(desc: gpu.Buffer_Desc, data: []byte) -> gpu.Buffer {
	if err := gpu.validate_buffer_desc(desc, data); err != .None {
		log.errorf("gpu: buffer %q: %v", desc.label, err)
		return {}
	}
	return gpu.pool_add(&state.buffers, gpu.Buffer_Desc{size = desc.size, usage = desc.usage})
}

create_texture :: proc(desc: gpu.Texture_Desc, data: []byte) -> gpu.Texture {
	if err := gpu.validate_texture_desc(desc, data); err != .None {
		log.errorf("gpu: texture %q: %v", desc.label, err)
		return {}
	}
	stored := desc
	stored.label = ""
	return gpu.pool_add(&state.textures, stored)
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
	return gpu.pool_add(&state.pipelines, gpu.pipeline_info(desc))
}

create_compute_pipeline :: proc(desc: gpu.Compute_Pipeline_Desc) -> gpu.Pipeline {
	if err := gpu.validate_compute_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return {}
	}
	return gpu.pool_add(&state.pipelines, gpu.Pipeline_Info{kind = .Compute})
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
	}
}

destroy_sampler :: proc(sampler: gpu.Sampler) {
	if _, ok := gpu.pool_remove(&state.samplers, sampler); ok {
		gpu.pool_free(&state.samplers, sampler.index)
	}
}

destroy_pipeline :: proc(pipeline: gpu.Pipeline) {
	if _, ok := gpu.pool_remove(&state.pipelines, pipeline); ok {
		gpu.pool_free(&state.pipelines, pipeline.index)
	}
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
	return {size = {u32(max(size.x, 1)), u32(max(size.y, 1))}, format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}}
}

@(private = "file")
RESOURCES :: gpu.Resources {
	texture = proc(texture: gpu.Texture) -> (gpu.Texture_Desc, bool) {
		return gpu.pool_lookup(&state.textures, texture)
	},
	buffer = proc(buffer: gpu.Buffer) -> (gpu.Buffer_Desc, bool) {
		return gpu.pool_lookup(&state.buffers, buffer)
	},
	pipeline = proc(pipeline: gpu.Pipeline) -> (gpu.Pipeline_Info, bool) {
		return gpu.pool_lookup(&state.pipelines, pipeline)
	},
}
