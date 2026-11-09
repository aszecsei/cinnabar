package editor

import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"

// The icons' pass (see docs/editor/viewport.md#viewport): before the pick, so a click on an icon picks its entity.

@(private)
ICONS_SHADER :: #load("../content/shaders/icons.hlsl.meta", string)

// An icon's diameter on screen, in pixels.
ICON_SIZE :: 32

// Icon_Instance matches Instance in icons.hlsl. cube is a reflection probe's cube of the probes' array, -1 for none.
@(private = "file")
Icon_Instance :: struct {
	position: [3]f32,
	kind:     u32,
	color:    [3]f32,
	id:       u32,
	cube:     i32,
	padding:  [3]u32,
}

// Icons_Constants matches Push in icons.hlsl. cubes is the reflection probes' cube array, 0 without it.
@(private = "file")
Icons_Constants :: struct {
	view_projection:  matrix[4, 4]f32,
	instances:        u32,
	instances_offset: u32,
	viewport:         [2]f32,
	size:             f32,
	cubes:            u32,
	cube_sampler:     u32,
	padding:          u32,
}

@(private = "file")
Icons_Pass :: struct {
	pipeline:  gpu.Pipeline,
	instances: gpu.Upload,
	count:     u32,
	constants: Icons_Constants,
}

@(private)
ICONS_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	colors        = {{format = render.DEBUG_FORMAT, blend = .Alpha}, {format = render.ID_FORMAT}},
	depth_format  = render.DEPTH_FORMAT,
	depth_compare = .Greater_Equal,
	depth_write   = true,
	label         = "editor icons",
}

// add_icons_pass draws the icons into the debug layer, and their IDs and depths into the frame's, when the viewport
// shows them.
@(private)
add_icons_pass :: proc(e: ^Editor, g: ^render.Graph, w: ^ecs.World, frame: Viewport_Frame) {
	v := &e.viewport
	if !icons_shown(e) || v.icons_pipeline.pipeline == {} {
		return
	}
	icons := icon_instances(w, visibility(e, w), e.platform.frame_allocator, e.renderer)
	if len(icons) == 0 {
		return
	}
	upload, ok := e.platform.gpu_upload(len(icons) * size_of(Icon_Instance), 16)
	if !ok {
		return
	}
	instances := ([^]Icon_Instance)(raw_data(upload.data))[:len(icons)]
	for icon, i in icons {
		color := icon.color / max(icon.color.r, icon.color.g, icon.color.b, 1e-6)
		instances[i] = {
			position = ecs.position_sub(icon.position, frame.view.position),
			kind     = u32(icon.kind),
			color    = color,
			id       = render.entity_id(icon.entity),
			cube     = icon.cube,
		}
	}
	cubes: render.Texture
	cubes_index, sampler: u32
	if e.renderer != nil {
		if texture, sampler_index, made := render.reflection_probe_cubes(e.renderer); made {
			// The probes' passes import it with the same resting use, so this is their node.
			cubes, cubes_index, sampler = render.import_texture(g, texture, .Storage), gpu.read_index(texture), sampler_index
		}
	}
	pass := new(Icons_Pass, e.platform.frame_allocator)
	pass^ = {
		pipeline = v.icons_pipeline.pipeline,
		instances = upload,
		count = u32(len(icons)),
		constants = {
			view_projection = render.view_projection(frame.view, f32(frame.size.x) / f32(max(frame.size.y, 1))),
			instances = gpu.read_index(upload.buffer),
			instances_offset = upload.offset,
			viewport = {f32(frame.size.x), f32(frame.size.y)},
			size = ICON_SIZE,
			cubes = cubes_index,
			cube_sampler = sampler,
		},
	}
	p := render.add_render_pass(g, "editor icons", draw_icons, pass)
	render.color(g, p, frame.target, .Load)
	render.color(g, p, frame.ids, .Load)
	render.depth(g, p, frame.depth, .Load)
	if cubes != 0 {
		render.read(g, p, cubes)
	}
}

@(private = "file")
draw_icons :: proc(ctx: ^render.Pass_Context) {
	pass := (^Icons_Pass)(ctx.data)
	gpu.cmd_set_pipeline(ctx.cb, pass.pipeline)
	gpu.cmd_push_constants(ctx.cb, &pass.constants)
	gpu.cmd_draw(ctx.cb, pass.count * 6)
}

#assert(size_of(Icon_Instance) == 48 && size_of(Icons_Constants) <= 128)

