package ui

import "cinnabar:core/gpu"
import "cinnabar:engine/render"

// The UI's shader, an engine asset, by the GUID in its .meta file.
@(private)
UI_SHADER :: #load("../content/shaders/ui.hlsl.meta", string)

// Push matches Push in ui.hlsl.
@(private = "file")
Push :: struct {
	instances:        u32,
	instances_offset: u32,
	sampler:          u32,
	padding:          u32,
	viewport:         [2]f32,
}

#assert(size_of(Push) <= 128)

UI_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	colors = {{format = render.UI_FORMAT, blend = .Premultiplied}},
	label  = "ui",
}

@(private = "file")
Ui_Pass :: struct {
	pipeline: gpu.Pipeline,
	count:    u32,
	push:     Push,
}

// sync_pipelines creates the UI's pipeline from its shader, and again when the cooker compiles the shader again. The
// game calls it each frame with its own, and with force after a code reload.
sync_pipelines :: proc(s: ^State, force := false) {
	render.sync_graphics_pipeline(&s.pipeline, s.platform, s.assets, {.Vertex, .Pixel}, UI_PIPELINE, force)
	if s.sampler == {} {
		s.sampler = s.platform.gpu_create_sampler({filter = .Linear, mip_filter = .Linear, address = .Clamp, label = "ui"})
	}
}

// add_passes lays out the documents at the frame's size and adds the pass that draws them into the UI layer, in one
// draw. The game calls it from its ui hook, which it may add its own passes to before or after.
add_passes :: proc(s: ^State, f: ^render.Frame) {
	layout(s, {f32(f.output_size.x), f32(f.output_size.y)})
	if s.pipeline.pipeline == {} {
		return
	}
	b := build_batch(s, s.platform.time_seconds(), s.platform.frame_allocator)
	if len(b.instances) == 0 {
		return
	}
	upload, ok := s.platform.gpu_upload(len(b.instances) * size_of(Instance), 16)
	if !ok {
		return
	}
	copy(([^]Instance)(raw_data(upload.data))[:len(b.instances)], b.instances[:])
	pass := new(Ui_Pass, s.platform.frame_allocator)
	pass^ = {
		pipeline = s.pipeline.pipeline,
		count = u32(len(b.instances)),
		push = {
			instances = gpu.read_index(upload.buffer),
			instances_offset = upload.offset,
			sampler = gpu.sampler_index(s.sampler),
			viewport = s.size,
		},
	}
	p := render.add_render_pass(f.graph, "ui", draw_ui, pass)
	render.color(f.graph, p, f.ui, .Load)
}

@(private = "file")
draw_ui :: proc(ctx: ^render.Pass_Context) {
	pass := (^Ui_Pass)(ctx.data)
	gpu.cmd_set_pipeline(ctx.cb, pass.pipeline)
	gpu.cmd_push_constants(ctx.cb, &pass.push)
	gpu.cmd_draw(ctx.cb, pass.count * 6)
}
