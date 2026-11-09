package render

import "core:log"
import "core:math"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// The voxel cones (see docs/rendering/global-illumination.md#voxel-cones): voxel cone tracing after Crassin et al.,
// "Interactive Indirect Illumination Using Voxel Cone Tracing", on a clipmap of 3D textures around the camera, as
// NVIDIA's VXGI keeps it, with no ray queries. Each level of the clipmap is a box of res^3 voxels, each level's voxels
// twice the size of the one before's, whose cells are of World_Position, so a render-origin rebase moves nothing. The
// rasterizer voxelizes the scene's opaque surfaces into a level when its box moves and in turn otherwise; each frame
// lights every level's voxels, with shadows and a bounce traced through the voxels themselves, and filters each level
// into the next; and each pixel gathers its light with cones through them.

// The clipmap's limits. Match gi_voxel.hlsli.
VOXEL_MAX_LEVELS :: 8
VOXEL_MAX_CONES :: 16
VOXEL_GROUP :: 4
// A level's box moves in steps of this many of its voxels, when the camera is more than that from its middle, and its
// first voxel is a multiple of it, so its box covers whole voxels of the next level's.
VOXEL_SNAP :: 8
// The voxels' surfaces: albedo, normal, emission and the mask of the half-size cubes that they cover, each in an
// R32_Uint texture (see gi_voxel.hlsli), and the light that they send out, premultiplied by their opacity.
VOXEL_ATTRIBUTE_FORMAT :: gpu.Format.R32_Uint
VOXEL_RADIANCE_FORMAT :: gpu.Format.RGBA16_Float
// A voxel's bytes in every texture: four attributes and the radiance.
VOXEL_BYTES :: 4 * 4 + 8
// The tangents of the half angles of the cone along a reflection and of the shadows' cones.
VOXEL_SPECULAR_APERTURE :: 0.12
VOXEL_SHADOW_APERTURE :: 0.03
// A voxelization view's level of detail is as fine as half its voxel, at every distance: its distances are all this far,
// which no point in the scene is, so the mesh shader path's error over the distance is the error alone.
VOXEL_LOD_NEAR :: 1e9

// Gi_Voxel_Params are the voxel cones at a level. Level 0's voxels are 2^voxel meters, and there are levels of res^3
// voxels. cones are the diffuse cones that each pixel traces (see voxel_cones). The pixels' histories hold at most
// history_frames frames.
Gi_Voxel_Params :: struct {
	res:            u32,
	levels:         u32,
	voxel:          i32,
	cones:          u32,
	history_frames: f32,
}

@(rodata)
GI_VOXEL_PARAMS := [Quality_Level]Gi_Voxel_Params {
	.Low    = {res = 64, levels = 5, voxel = -2, cones = 4, history_frames = 12},
	.Medium = {res = 96, levels = 5, voxel = -3, cones = 6, history_frames = 10},
	.High   = {res = 128, levels = 5, voxel = -3, cones = 6, history_frames = 8},
	.Ultra  = {res = 128, levels = 6, voxel = -3, cones = 9, history_frames = 8},
}

// The engine's voxel cone shaders, by their .meta files.
GI_VOXEL_CLEAR_SHADER :: #load("../content/shaders/gi_voxel_clear.hlsl.meta", string)
GI_VOXEL_INJECT_SHADER :: #load("../content/shaders/gi_voxel_inject.hlsl.meta", string)
GI_VOXEL_FILTER_SHADER :: #load("../content/shaders/gi_voxel_filter.hlsl.meta", string)
GI_VOXEL_GATHER_SHADER :: #load("../content/shaders/gi_voxel_gather.hlsl.meta", string)

Voxel_Texture :: enum {
	Albedo,
	Normal,
	Emission,
	Radiance,
	Mask,
}

// Voxel_Level matches Voxel_Level in gi_voxel.hlsli.
Voxel_Level :: struct {
	min:    [4]f32,
	uvw:    [4]f32,
	phase:  [4]i32,
	reads:  [4]u32,
	writes: [4]u32,
	mask:   [4]u32,
}

// Voxel_Grid matches Voxel_Grid in gi_voxel.hlsli.
Voxel_Grid :: struct {
	levels:            [VOXEL_MAX_LEVELS]Voxel_Level,
	cones:             [VOXEL_MAX_CONES][4]f32,
	level_count:       u32,
	res:               u32,
	sampler_index:     u32,
	cone_count:        u32,
	cone_aperture:     f32,
	specular_aperture: f32,
	shadow_aperture:   f32,
	frame:             u32,
	lights:            u32,
	lights_offset:     u32,
	light_count:       u32,
	padding:           u32,
}

// Voxel_Push matches Voxel_Push in gi_voxel_pass.hlsli and gi_voxel_gather.hlsl. level is the level that a pass
// writes, or the filter's source; view_output is the Gi_Probes debug view's write view, or 0.
@(private = "file")
Voxel_Push :: struct {
	shadow_atlas: u32,
	shadow_mask:  u32,
	grid:         u32,
	grid_offset:  u32,
	level:        u32,
	view_output:  u32,
	padding:      [2]u32,
}

// Voxel_Box is a level's box between frames: its first cell, of World_Position, and whether its voxels hold the
// surfaces there.
Voxel_Box :: struct {
	anchor:    [3]i64,
	placed:    bool,
	voxelized: bool,
}

// Gi_Voxel is the voxel cones' state between frames, in Gi_Passes: their pipelines, the levels' textures, made for a
// level's parameters, each level's box, and the level that voxelizes next in turn.
Gi_Voxel :: struct {
	clear:    Shader_Pipeline,
	inject:   Shader_Pipeline,
	filter:   Shader_Pipeline,
	gather:   Shader_Pipeline,
	sampler:  gpu.Sampler,
	params:   Gi_Voxel_Params,
	textures: [VOXEL_MAX_LEVELS][Voxel_Texture]gpu.Texture,
	boxes:    [VOXEL_MAX_LEVELS]Voxel_Box,
	turn:     u32,
	frame:    u32,
	// Whether the last frame that wanted the voxel cones had them, for note_voxel_fallback.
	running:  bool,
}

// Voxel_View is one of the views that voxelize a level, along an axis: its projection and planes, relative to the
// camera, and what its frame constants tell the voxelization.
Voxel_View :: struct {
	level:           u32,
	view_projection: matrix[4, 4]f32,
	planes:          [6][4]f32,
	min:             [3]f32,
	size:            f32,
	phase:           [3]i32,
	writes:          [4]u32,
}

// Gi_Voxel_Frame is one frame's voxel cones, in frame memory. views are the voxelization's, which add_scene_passes
// draws from first_view on.
@(private)
Gi_Voxel_Frame :: struct {
	frame:      ^Frame,
	params:     Gi_Voxel_Params,
	grid:       Voxel_Grid,
	upload:     gpu.Upload,
	lights:     gpu.Upload,
	textures:   [VOXEL_MAX_LEVELS][Voxel_Texture]Texture,
	voxelize:   [VOXEL_MAX_LEVELS]bool,
	views:      []Voxel_View,
	first_view: int,
}

gi_voxel_init :: proc(v: ^Gi_Voxel) {
	v.clear = shader_pipeline(GI_VOXEL_CLEAR_SHADER)
	v.inject = shader_pipeline(GI_VOXEL_INJECT_SHADER)
	v.filter = shader_pipeline(GI_VOXEL_FILTER_SHADER)
	v.gather = shader_pipeline(GI_VOXEL_GATHER_SHADER)
}

gi_voxel_destroy :: proc(v: ^Gi_Voxel, platform: ^core.Platform_API) {
	for p in ([]^Shader_Pipeline{&v.clear, &v.inject, &v.filter, &v.gather}) {
		destroy_shader_pipeline(p, platform)
	}
	destroy_voxel_storage(v, platform)
	if v.sampler != {} {
		platform.gpu_destroy_sampler(v.sampler)
		v.sampler = {}
	}
}

@(private = "file")
destroy_voxel_storage :: proc(v: ^Gi_Voxel, platform: ^core.Platform_API) {
	for &level in v.textures {
		for &t in level {
			if t != {} {
				platform.gpu_destroy_texture(t)
				t = {}
			}
		}
	}
	v.params = {}
	v.boxes = {}
}

// sync_gi_voxel_pipelines makes the voxel cones' pipelines, on every device.
@(private)
sync_gi_voxel_pipelines :: proc(r: ^Renderer, force: bool) {
	v := &r.gi.voxel
	assets := r.residency.assets
	sync_compute_pipeline(&v.clear, r.platform, assets, {label = "gi voxel clear"}, force)
	sync_compute_pipeline(&v.inject, r.platform, assets, {label = "gi voxel inject"}, force)
	sync_compute_pipeline(&v.filter, r.platform, assets, {label = "gi voxel filter"}, force)
	sync_compute_pipeline(&v.gather, r.platform, assets, {label = "gi voxel gather"}, force)
}

// gi_voxel_ready is whether the voxel cones' pipelines have compiled.
@(private)
gi_voxel_ready :: proc(r: ^Renderer) -> bool {
	v := &r.gi.voxel
	for p in ([]^Shader_Pipeline{&v.clear, &v.inject, &v.filter, &v.gather}) {
		if !pipeline_ready(r.platform, p) {
			return false
		}
	}
	return true
}

// voxel_bytes is the memory that the levels' textures take at a level's parameters.
voxel_bytes :: proc(params: Gi_Voxel_Params) -> int {
	return int(params.res) * int(params.res) * int(params.res) * int(params.levels) * VOXEL_BYTES
}

// voxel_snap is a cell rounded down to a multiple of VOXEL_SNAP.
voxel_snap :: proc(cell: [3]i64) -> [3]i64 {
	return {cell.x & ~i64(VOXEL_SNAP - 1), cell.y & ~i64(VOXEL_SNAP - 1), cell.z & ~i64(VOXEL_SNAP - 1)}
}

// place_voxel_box moves a level's box to have the camera near its middle, when the camera is more than VOXEL_SNAP
// voxels from it, and gives whether it moved. Its first cell is a multiple of VOXEL_SNAP. A box that moves holds no
// surfaces until it voxelizes again.
place_voxel_box :: proc(box: ^Voxel_Box, camera: ecs.World_Position, exponent: i32, res: u32) -> bool {
	cell := split_cell(camera, exponent)
	half := i64(res / 2)
	if box.placed {
		offset := cell - (box.anchor + half)
		if max(abs(offset.x), abs(offset.y), abs(offset.z)) <= VOXEL_SNAP {
			return false
		}
	}
	box.anchor = voxel_snap(cell - half)
	box.placed = true
	box.voxelized = false
	return true
}

// voxel_phase is the texel of a box's first voxel: its cell modulo res.
voxel_phase :: proc(anchor: [3]i64, res: u32) -> (phase: [3]i32) {
	n := i64(res)
	for axis in 0 ..< 3 {
		phase[axis] = i32(((anchor[axis] % n) + n) % n)
	}
	return
}

// voxel_schedule is the levels that voxelize this frame: each whose box holds no surfaces, and the next in turn, which
// keeps moving objects in every level within levels frames.
voxel_schedule :: proc(boxes: []Voxel_Box, turn: ^u32) -> (voxelize: [VOXEL_MAX_LEVELS]bool) {
	for box, l in boxes {
		voxelize[l] = !box.voxelized
	}
	for _ in 0 ..< len(boxes) {
		l := int(turn^) % len(boxes)
		turn^ = (turn^ + 1) % u32(len(boxes))
		if !voxelize[l] {
			voxelize[l] = true
			break
		}
	}
	return
}

// voxel_cones are the diffuse cones around +z, each with its weight, which is its cosine over the sum of every cone's,
// and the tangent of their half angle. Each set covers the hemisphere: a cone along the normal and rings around it. The
// rings lean less than a cone's width from the surface: a cone whose edge lies along the surface samples the surface's
// own voxels once it is wide, and a wall facing an open courtyard saw a third of the sky that it does.
voxel_cones :: proc(count: u32) -> (cones: [VOXEL_MAX_CONES][4]f32, aperture: f32) {
	Ring :: struct {
		count: int,
		angle: f32,
	}
	rings: []Ring
	switch count {
	case 4:
		rings, aperture = {{3, 55}}, math.tan(f32(math.PI / 6))
	case 9:
		rings, aperture = {{4, 32}, {4, 64}}, math.tan(f32(math.PI / 8))
	case:
		rings, aperture = {{5, 55}}, math.tan(f32(math.PI / 6))
	}
	cones[0] = {0, 0, 1, 1}
	n := 1
	total: f32 = 1
	for ring, r in rings {
		theta := ring.angle * math.RAD_PER_DEG
		for i in 0 ..< ring.count {
			// Each ring turns by half a step from the one before, so the rings' cones do not line up.
			phi := (f32(i) + 0.5 * f32(r)) / f32(ring.count) * math.TAU
			cones[n] = {math.sin(theta) * math.cos(phi), math.sin(theta) * math.sin(phi), math.cos(theta), math.cos(theta)}
			total += math.cos(theta)
			n += 1
		}
	}
	for i in 0 ..< n {
		cones[i].w /= total
	}
	return
}

// voxel_view_projection maps a level's box, relative to the camera, to clip space, looking along an axis: the two
// others across, x and y in [-1, 1], and the axis in [0, 1] as depth.
voxel_view_projection :: proc(min: [3]f32, extent: f32, axis: int) -> (m: matrix[4, 4]f32) {
	across := [3][2]int{{1, 2}, {2, 0}, {0, 1}}
	u, v := across[axis][0], across[axis][1]
	m[0, u] = 2 / extent
	m[0, 3] = -2 * min[u] / extent - 1
	m[1, v] = 2 / extent
	m[1, 3] = -2 * min[v] / extent - 1
	m[2, axis] = 1 / extent
	m[2, 3] = -min[axis] / extent
	m[3, 3] = 1
	return
}

// voxel_box_planes are a box's six faces as planes relative to the camera, each facing in, so a sphere inside or across
// one tests at least its negative radius.
voxel_box_planes :: proc(min: [3]f32, extent: f32) -> (planes: [6][4]f32) {
	for axis in 0 ..< 3 {
		n: [3]f32
		n[axis] = 1
		planes[axis * 2] = {n.x, n.y, n.z, -min[axis]}
		planes[axis * 2 + 1] = {-n.x, -n.y, -n.z, min[axis] + extent}
	}
	return
}

// ensure_voxel_storage makes the levels' textures for a level's parameters. New textures hold no surfaces.
@(private = "file")
ensure_voxel_storage :: proc(r: ^Renderer, params: Gi_Voxel_Params) {
	v := &r.gi.voxel
	platform := r.platform
	if v.sampler == {} {
		v.sampler = platform.gpu_create_sampler({filter = .Linear, address = .Repeat, label = "gi voxel sampler"})
	}
	if v.params == params && v.textures[0][.Radiance] != {} {
		return
	}
	destroy_voxel_storage(v, platform)
	labels := [Voxel_Texture]string {
		.Albedo   = "gi voxel albedo",
		.Normal   = "gi voxel normal",
		.Emission = "gi voxel emission",
		.Radiance = "gi voxel radiance",
		.Mask     = "gi voxel mask",
	}
	for l in 0 ..< int(params.levels) {
		for kind in Voxel_Texture {
			format := kind == .Radiance ? VOXEL_RADIANCE_FORMAT : VOXEL_ATTRIBUTE_FORMAT
			desc := gpu.Texture_Desc {
				size   = {params.res, params.res},
				depth  = params.res,
				format = format,
				usage  = {.Sampled, .Storage},
				label  = labels[kind],
			}
			v.textures[l][kind] = platform.gpu_create_texture(desc, nil)
		}
	}
	v.params = params
}

// begin_gi_voxels places the levels' boxes and decides which voxelize, before the scene's views are made, which draw
// them. It gives nil without the voxel cones this frame: before their pipelines compile, or without room in the upload
// ring. The boxes keep whether they hold surfaces until the passes run.
@(private)
begin_gi_voxels :: proc(f: ^Frame, settings: Gi_Settings) -> ^Gi_Voxel_Frame {
	r := f.renderer
	platform := r.platform
	if settings.technique != .Voxel_Cones || !gi_voxel_ready(r) {
		return nil
	}
	params := GI_VOXEL_PARAMS[settings.level]
	upload, upload_ok := platform.gpu_upload(size_of(Voxel_Grid), 16)
	lights_upload, lights_ok := platform.gpu_upload(GI_MAX_PROBE_LIGHTS * 4, 16)
	if !upload_ok || !lights_ok {
		return nil
	}
	ensure_voxel_storage(r, params)
	v := &r.gi.voxel
	if v.textures[params.levels - 1][.Radiance] == {} {
		return nil
	}
	g := f.graph
	vf := new(Gi_Voxel_Frame, platform.frame_allocator)
	vf.frame, vf.params, vf.upload, vf.lights = f, params, upload, lights_upload
	grid := &vf.grid
	extent: f32
	for l in 0 ..< int(params.levels) {
		exponent := params.voxel + i32(l)
		box := &v.boxes[l]
		place_voxel_box(box, f.view.position, exponent, params.res)
		size := math.pow(2, f32(exponent))
		extent = size * f32(params.res)
		min := split_window_min(box.anchor, f.view.position, exponent)
		phase := voxel_phase(box.anchor, params.res)
		reads, writes: [4]u32
		for kind in Voxel_Texture {
			t := v.textures[l][kind]
			if kind != .Mask {
				reads[int(kind)], writes[int(kind)] = gpu.read_index(t), gpu.write_index(t)
			}
			vf.textures[l][kind] = import_texture(g, t, .Storage)
		}
		mask := v.textures[l][.Mask]
		// p * scale + bias is the texel of p, over res, wrapping: (p - min) / size + phase.
		scale := 1 / extent
		grid.levels[l] = {
			min    = {min.x, min.y, min.z, size},
			uvw    = {(f32(phase.x) - min.x / size) / f32(params.res), (f32(phase.y) - min.y / size) / f32(params.res), (f32(phase.z) - min.z / size) / f32(params.res), scale},
			phase  = {phase.x, phase.y, phase.z, 0},
			reads  = reads,
			writes = writes,
			mask   = {gpu.read_index(mask), gpu.write_index(mask), 0, 0},
		}
	}
	vf.voxelize = voxel_schedule(v.boxes[:params.levels], &v.turn)
	views := make([dynamic]Voxel_View, platform.frame_allocator)
	for l in 0 ..< int(params.levels) {
		// A level holds surfaces once it voxelizes, this frame or before.
		if vf.voxelize[l] || v.boxes[l].voxelized {
			grid.levels[l].phase.w = 1
		}
		if !vf.voxelize[l] {
			continue
		}
		level := grid.levels[l]
		min := level.min.xyz
		size := level.min.w
		box := size * f32(params.res)
		for axis in 0 ..< 3 {
			append(
				&views,
				Voxel_View {
					level = u32(l),
					view_projection = voxel_view_projection(min, box, axis),
					planes = voxel_box_planes(min, box),
					min = min,
					size = size,
					phase = level.phase.xyz,
					writes = {level.writes.x, level.writes.y, level.writes.z, level.mask.y},
				},
			)
		}
	}
	vf.views = views[:]
	lights := probe_lights(f, extent)
	copy(lights_upload.data, ([^]byte)(raw_data(lights))[:len(lights) * 4])
	v.frame += 1
	cones, aperture := voxel_cones(params.cones)
	grid^ = {
		levels            = grid.levels,
		cones             = cones,
		level_count       = params.levels,
		res               = params.res,
		sampler_index     = gpu.sampler_index(v.sampler),
		cone_count        = params.cones,
		cone_aperture     = aperture,
		specular_aperture = VOXEL_SPECULAR_APERTURE,
		shadow_aperture   = VOXEL_SHADOW_APERTURE,
		frame             = v.frame,
		lights            = gpu.read_index(lights_upload.buffer),
		lights_offset     = lights_upload.offset,
		light_count       = u32(len(lights)),
	}
	(^Voxel_Grid)(raw_data(upload.data))^ = grid^
	return vf
}

// voxel_view_constants gives a voxelization view's frame constants their projection, the level that it draws, and a
// level of detail whose error is at most half a voxel, at every distance.
@(private)
voxel_view_constants :: proc(c: ^Frame_Constants, view: Voxel_View, res: u32) {
	c.view_projection = view.view_projection
	c.previous_view_projection = view.view_projection
	c.cluster_view_projection = view.view_projection
	c.lod_near = VOXEL_LOD_NEAR
	c.lod_scale = VOXEL_LOD_NEAR * 2 / view.size
	c.voxel_draw = 1
	c.voxel_res = res
	c.voxel_size = view.size
	c.voxel_min = view.min
	c.voxel_phase = view.phase
	c.voxel_albedo, c.voxel_normal, c.voxel_emission, c.voxel_mask = view.writes[0], view.writes[1], view.writes[2], view.writes[3]
}

// add_gi_voxel_passes adds the voxel cones' passes after the prepass and sets Frame.gi_diffuse and Frame.gi_specular,
// or gives false without them this frame: the clear and the voxelization of the levels that voxelize, on the graphics
// queue, then on the compute queue each level's injection, finest first, the filter of each level into the next, and
// the gather.
@(private)
add_gi_voxel_passes :: proc(f: ^Frame) -> bool {
	gf := f.gi
	vf := gf.voxel
	if vf == nil {
		return false
	}
	sf := f.scene_frame
	// The injection reads the camera's frame constants.
	if sf == nil || len(sf.view_constants) == 0 {
		return false
	}
	g := f.graph
	params := vf.params
	step :: proc(vf: ^Gi_Voxel_Frame, pass: Voxel_Pass, level: u32 = 0) -> ^Voxel_Step {
		return new_clone(Voxel_Step{vf, pass, level}, vf.frame.renderer.platform.frame_allocator)
	}
	// Each level that voxelizes empties first, so a frame without draws leaves it empty, as its scene is.
	for l in 0 ..< int(params.levels) {
		if !vf.voxelize[l] {
			continue
		}
		p := add_compute_pass(g, "gi voxel clear", run_voxel_pass, step(vf, .Clear, u32(l)))
		write(g, p, vf.textures[l][.Albedo])
		write(g, p, vf.textures[l][.Normal])
		write(g, p, vf.textures[l][.Emission])
		write(g, p, vf.textures[l][.Mask])
	}
	// The levels count as voxelized once the frame executes, so a frame that fails voxelizes them again.
	on_executed(g, proc(data: rawptr) {
			vf := (^Gi_Voxel_Frame)(data)
			v := &vf.frame.renderer.gi.voxel
			for l in 0 ..< int(vf.params.levels) {
				if vf.voxelize[l] {
					v.boxes[l].voxelized = true
				}
			}
		}, vf)
	if len(sf.items) > 0 && len(vf.views) > 0 {
		p := add_render_pass(g, "gi voxelize", draw_voxel_views, vf)
		rasterize_size(g, p, {params.res * 2, params.res * 2})
		for l in 0 ..< int(params.levels) {
			if vf.voxelize[l] {
				write(g, p, vf.textures[l][.Albedo])
				write(g, p, vf.textures[l][.Normal])
				write(g, p, vf.textures[l][.Emission])
				write(g, p, vf.textures[l][.Mask])
			}
		}
		declare_scene_draws(f, p)
	}
	for l in 0 ..< int(params.levels) {
		p := add_compute_pass(g, "gi voxel inject", run_voxel_pass, step(vf, .Inject, u32(l)), queue = .Compute)
		declare_cloud_shadow(f, p)
		for k in 0 ..< int(params.levels) {
			read(g, p, vf.textures[k][.Mask])
			if k == l {
				read(g, p, vf.textures[k][.Albedo])
				read(g, p, vf.textures[k][.Normal])
				read(g, p, vf.textures[k][.Emission])
				write(g, p, vf.textures[k][.Radiance])
			} else if k > l {
				read(g, p, vf.textures[k][.Radiance])
			}
		}
	}
	for l in 0 ..< int(params.levels) - 1 {
		if vf.grid.levels[l].phase.w == 0 {
			continue
		}
		p := add_compute_pass(g, "gi voxel filter", run_voxel_pass, step(vf, .Filter, u32(l)), queue = .Compute)
		read(g, p, vf.textures[l][.Radiance])
		write(g, p, vf.textures[l + 1][.Radiance])
	}
	if f.debug_view == .Gi_Probes {
		gf.probe_view = create_texture(g, {size = f.size, format = GI_FORMAT, label = "gi probe view"})
	}
	p := add_compute_pass(g, "gi voxel gather", run_voxel_pass, step(vf, .Gather), queue = .Compute)
	read(g, p, f.depth)
	read(g, p, f.normals)
	read(g, p, f.velocity)
	read(g, p, gf.diffuse.previous)
	read(g, p, gf.specular.previous)
	for l in 0 ..< int(params.levels) {
		read(g, p, vf.textures[l][.Albedo])
		read(g, p, vf.textures[l][.Mask])
		read(g, p, vf.textures[l][.Radiance])
	}
	write(g, p, gf.diffuse.current)
	write(g, p, gf.specular.current)
	if gf.probe_view != 0 {
		write(g, p, gf.probe_view)
	}
	declare_gather_specular(f, p)
	f.gi_diffuse, f.gi_specular = gf.diffuse.current, gf.specular.current
	return true
}

// note_voxel_fallback warns when a frame that wants the voxel cones takes the screen cascades after a frame that had
// them, which changes the whole frame's indirect light with nothing moving. It warns once, until they run again.
@(private)
note_voxel_fallback :: proc(f: ^Frame, ran: bool) {
	r := f.renderer
	v := &r.gi.voxel
	if ran || f.gi.settings.technique != .Voxel_Cones {
		v.running = ran
		return
	}
	if !v.running {
		return
	}
	v.running = false
	reason := "the upload ring has no room"
	if !gi_voxel_ready(r) {
		reason = "their pipelines are not ready"
	}
	log.warnf("gi: the voxel cones gave way to the screen cascades: %s", reason)
}

@(private = "file")
Voxel_Pass :: enum {
	Clear,
	Inject,
	Filter,
	Gather,
}

// Voxel_Step is one voxel pass's data, in frame memory.
@(private = "file")
Voxel_Step :: struct {
	voxels: ^Gi_Voxel_Frame,
	pass:   Voxel_Pass,
	level:  u32,
}

@(private = "file")
draw_voxel_views :: proc(ctx: ^Pass_Context) {
	vf := (^Gi_Voxel_Frame)(ctx.data)
	f := vf.frame
	size := vf.params.res * 2
	gpu.cmd_set_viewport(ctx.cb, {0, 0}, {f32(size), f32(size)})
	gpu.cmd_set_scissor(ctx.cb, {0, 0}, {i32(size), i32(size)})
	for i in 0 ..< len(vf.views) {
		draw_scene_view(f, ctx.cb, vf.first_view + i, .Voxelize)
	}
}

// run_voxel_pass dispatches a voxel pass: a thread for each voxel of a level, of the next level's voxels that a level
// covers, or of each pixel. The clear, the injection and the filter take the camera's frame constants, and the gather
// the global illumination's.
@(private = "file")
run_voxel_pass :: proc(ctx: ^Pass_Context) {
	step := (^Voxel_Step)(ctx.data)
	vf := step.voxels
	f := vf.frame
	v := &f.renderer.gi.voxel
	g := ctx.graph
	push := Voxel_Push {
		grid        = gpu.read_index(vf.upload.buffer),
		grid_offset = vf.upload.offset,
		level       = step.level,
	}
	res := vf.params.res
	voxel_groups := [3]u32{(res + VOXEL_GROUP - 1) / VOXEL_GROUP, (res + VOXEL_GROUP - 1) / VOXEL_GROUP, (res + VOXEL_GROUP - 1) / VOXEL_GROUP}
	switch step.pass {
	case .Clear, .Inject, .Filter:
		pipeline := v.clear.pipeline
		groups := voxel_groups
		#partial switch step.pass {
		case .Inject:
			pipeline = v.inject.pipeline
		case .Filter:
			pipeline = v.filter.pipeline
			half := res / 2
			groups = {(half + VOXEL_GROUP - 1) / VOXEL_GROUP, (half + VOXEL_GROUP - 1) / VOXEL_GROUP, (half + VOXEL_GROUP - 1) / VOXEL_GROUP}
		}
		gpu.cmd_set_pipeline(ctx.cb, pipeline)
		gpu.cmd_set_pass_constants(ctx.cb, f.scene_frame.view_constants[VIEW_CAMERA])
		gpu.cmd_push_constants(ctx.cb, &push)
		gpu.cmd_dispatch(ctx.cb, groups)
	case .Gather:
		gf := f.gi
		c := gather_constants(ctx, f)
		c.velocity = gpu.read_index(gpu_texture(g, f.velocity))
		c.history_diffuse = gpu.read_index(gpu_texture(g, gf.diffuse.previous))
		c.history_specular = gpu.read_index(gpu_texture(g, gf.specular.previous))
		c.out_diffuse = gpu.write_index(gpu_texture(g, gf.diffuse.current))
		c.out_specular = gpu.write_index(gpu_texture(g, gf.specular.current))
		c.frame = v.frame
		c.max_frames = vf.params.history_frames
		if gf.probe_view != 0 {
			push.view_output = gpu.write_index(gpu_texture(g, gf.probe_view))
		}
		gpu.cmd_set_pipeline(ctx.cb, v.gather.pipeline)
		if upload_gi_constants(ctx, f, c) {
			gpu.cmd_push_constants(ctx.cb, &push)
			gpu.cmd_dispatch(ctx.cb, groups(f.size, POST_GROUP_SIZE))
		}
	}
}
