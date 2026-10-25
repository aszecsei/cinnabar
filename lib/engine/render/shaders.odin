package render

import "core:log"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

// Shader_Pipeline is a pipeline that compiles from a shader asset. A sync procedure creates it, and updates it when
// asset.poll swaps the shader's blob, so a shader change needs no code reload (see docs/rendering.md#gpu-residency).
// It holds handles only, so it can live in Game_State.
Shader_Pipeline :: struct {
	pipeline: gpu.Pipeline,
	guid:     format.Guid,
	shader:   asset.Handle,
	// The blob's version that the pipeline last compiled from.
	version:  u32,
	// The shader could not be used, which was logged once. A new blob tries again.
	failed:   bool,
}

// shader_pipeline is a pipeline of the shader whose .meta file's text this is. Sync it to create it.
shader_pipeline :: proc(meta: string) -> Shader_Pipeline {
	guid, ok := format.meta_guid(meta)
	if !ok {
		log.error("render: a shader's .meta file has no GUID")
	}
	return {guid = guid}
}

// sync_graphics_pipeline creates the pipeline the first time, and updates it when the shader's blob changes or force
// is set, as a code reload does with new descriptions. The blob gives desc's vertex, amplification, mesh and pixel
// stages, each that stages names. The draws with a pipeline that is not created yet are skipped.
sync_graphics_pipeline :: proc(
	p: ^Shader_Pipeline,
	platform: ^core.Platform_API,
	assets: ^asset.Assets,
	stages: format.Shader_Stages,
	desc: gpu.Graphics_Pipeline_Desc,
	force := false,
) {
	data, blob, ok := shader_blob(p, assets, stages, force)
	if !ok {
		return
	}
	d := desc
	d.vertex = format.shader_code(data, blob, .Vertex) if .Vertex in stages else nil
	d.amplification = format.shader_code(data, blob, .Amplification) if .Amplification in stages else nil
	d.mesh = format.shader_code(data, blob, .Mesh) if .Mesh in stages else nil
	d.pixel = format.shader_code(data, blob, .Pixel) if .Pixel in stages else nil
	if p.pipeline == {} || !platform.gpu_update_graphics_pipeline(p.pipeline, d) {
		// An update that changes the formats, the topology or the kind is refused, so the pipeline is made again.
		platform.gpu_destroy_pipeline(p.pipeline)
		p.pipeline = platform.gpu_create_graphics_pipeline(d)
	}
}

sync_compute_pipeline :: proc(p: ^Shader_Pipeline, platform: ^core.Platform_API, assets: ^asset.Assets, desc: gpu.Compute_Pipeline_Desc, force := false) {
	data, blob, ok := shader_blob(p, assets, {.Compute}, force)
	if !ok {
		return
	}
	d := desc
	d.compute = format.shader_code(data, blob, .Compute)
	if p.pipeline == {} || !platform.gpu_update_compute_pipeline(p.pipeline, d) {
		platform.gpu_destroy_pipeline(p.pipeline)
		p.pipeline = platform.gpu_create_compute_pipeline(d)
	}
}

sync_ray_tracing_pipeline :: proc(p: ^Shader_Pipeline, platform: ^core.Platform_API, assets: ^asset.Assets, desc: gpu.Ray_Tracing_Pipeline_Desc, force := false) {
	data, blob, ok := shader_blob(p, assets, {.Library}, force)
	if !ok {
		return
	}
	d := desc
	d.library = format.shader_code(data, blob, .Library)
	if p.pipeline == {} || !platform.gpu_update_ray_tracing_pipeline(p.pipeline, d) {
		platform.gpu_destroy_pipeline(p.pipeline)
		p.pipeline = platform.gpu_create_ray_tracing_pipeline(d)
	}
}

destroy_shader_pipeline :: proc(p: ^Shader_Pipeline, platform: ^core.Platform_API) {
	platform.gpu_destroy_pipeline(p.pipeline)
	p^ = {guid = p.guid}
}

// shader_blob loads the shader, and gives its blob when the pipeline needs to compile from it: when it has no
// pipeline yet, when the blob is new, or when force is set. A blob without one of the stages is an error.
@(private = "file")
shader_blob :: proc(p: ^Shader_Pipeline, assets: ^asset.Assets, stages: format.Shader_Stages, force: bool) -> (data: []byte, blob: ^format.Shader_Blob, ok: bool) {
	if asset.guid(assets, p.shader) != p.guid {
		handle, loaded := asset.load(assets, p.guid)
		if !loaded {
			if !p.failed {
				buffer: [32]u8
				log.errorf("render: the shader %s is not cooked", format.guid_format(p.guid, &buffer))
				p.failed = true
			}
			return
		}
		p.shader = handle
	}
	version := asset.version(assets, p.shader)
	if p.pipeline != {} && version == p.version && !force {
		return
	}
	if p.failed && version == p.version && !force {
		return
	}
	p.version = version
	data = asset.data(assets, p.shader) or_return
	blob, ok = format.shader_view(data)
	if !ok {
		buffer: [32]u8
		log.errorf("render: the asset %s is not a shader", format.guid_format(p.guid, &buffer))
		p.failed = true
		return nil, nil, false
	}
	missing := stages - format.shader_stages(data, blob)
	if missing != {} {
		log.errorf("render: %s has no %v stage", format.blob_string(data, blob.source_path), missing)
		p.failed = true
		return nil, nil, false
	}
	p.failed = false
	return data, blob, true
}
