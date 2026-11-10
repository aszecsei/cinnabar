package render

import "core:math"
import "core:math/linalg"
import "core:slice"

import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// The reflection probes (see docs/rendering/lighting-and-shadows.md#reflection-probes): Reflection_Technique.Probes.
// Each Reflection_Probe that holds a slot has a cube of one cube array, captured at its entity's position and
// prefiltered by roughness with the sky's cubemap's filter. The forward pass looks the probes up through the light
// clusters, which bin them as they bin the lights, with the pixel's own normal and roughness.
//
// A capture draws its six faces as views of the GPU scene, a budget of faces a frame, then makes the source cube's mips
// and prefilters it into the array's spare cube, which the probe takes from that frame's view on: the frame's lookups
// read the cube after its prefilter, and its faces look no probe up, so a probe's cube never changes while a frame
// reads it, and the array holds a cube more than the slots. With more probes than slots, the ones
// with the highest priority, then the nearest to the camera, keep theirs. A probe that is not captured yet has no record,
// so its pixels take the sky's cubemap.

// The engine's reflection probe shaders, by their .meta files. The prefilter is the sky cubemap's.
REFLECTION_PROBE_FACE_SHADER :: #load("../content/shaders/reflection_probe_face.hlsl.meta", string)
CUBE_DOWNSAMPLE_SHADER :: #load("../content/shaders/cube_downsample.hlsl.meta", string)

// The most slots that a level has.
MAX_REFLECTION_PROBES :: 64
// The probes that extraction considers in a frame, after which it takes no more.
MAX_REFLECTION_PROBE_CANDIDATES :: 1024
// A cluster's list of probes: its count, then at most MAX_CLUSTER_PROBES indices. Match material_reflections.hlsli and
// cluster_lights.hlsl.
MAX_CLUSTER_PROBES :: 7
REFLECTION_PROBE_CLUSTER_STRIDE :: 32
// A capture's views start this close to the probe.
REFLECTION_PROBE_NEAR :: 0.05
// A probe's own shadow view for the directional light covers at least, and at most, this far around it, in meters.
REFLECTION_PROBE_MIN_SHADOW :: 1
REFLECTION_PROBE_MAX_SHADOW :: 200

#assert(REFLECTION_PROBE_CLUSTER_STRIDE == (MAX_CLUSTER_PROBES + 1) * 4)

// The faces' axes, right, up and forward, in the order and the orientation that a TextureCube samples (see
// cube_direction in sky_directions.hlsli): a face's pixel at x, y looks along the cube's texel at x, y.
REFLECTION_PROBE_FACES :: [6][3][3]f32 {
	{{0, 0, -1}, {0, 1, 0}, {1, 0, 0}},
	{{0, 0, 1}, {0, 1, 0}, {-1, 0, 0}},
	{{1, 0, 0}, {0, 0, -1}, {0, 1, 0}},
	{{1, 0, 0}, {0, 0, 1}, {0, -1, 0}},
	{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}},
	{{-1, 0, 0}, {0, 1, 0}, {0, 0, -1}},
}

// Reflection_Probe_Record matches Reflection_Probe_Record in material_reflections.hlsli: a probe's position relative to
// the camera and its cube of the array, its axes in the world, its influence box's half size and fade, and its
// projection box's half size, 0 without box projection, and its intensity.
Reflection_Probe_Record :: struct {
	center:     [3]f32,
	cube:       u32,
	axes:       [3][4]f32,
	extent:     [3]f32,
	blend:      f32,
	projection: [3]f32,
	intensity:  f32,
}

#assert(size_of(Reflection_Probe_Record) == 96)

// Reflection_Probe_Key is what a probe's capture depends on: its pose and its fields.
Reflection_Probe_Key :: struct {
	position: ecs.World_Position,
	rotation: quaternion128,
	scale:    [3]f32,
	probe:    Reflection_Probe,
}

// Reflection_Probe_Candidate is a probe in a frame, before the slots: its entity, its key, and its distance from the
// camera, squared.
Reflection_Probe_Candidate :: struct {
	entity:    ecs.Entity,
	key:       Reflection_Probe_Key,
	distance2: f32,
}

// Reflection_Probe_Slot is a probe that holds a slot: its key this frame, its last finished capture, nil before its
// first, the frame it was last seen, and its distance and rank this frame. forced is a capture that the editor asked
// for (see capture_reflection_probe), which the next finished capture of the slot answers.
Reflection_Probe_Slot :: struct {
	used:      bool,
	entity:    ecs.Entity,
	key:       Reflection_Probe_Key,
	cube:      Maybe(Reflection_Probe_Cube),
	seen:      u64,
	distance2: f32,
	rank:      int,
	forced:    bool,
}

// Reflection_Probe_Cube is a slot's last finished capture: its cube of the array, the key at that capture's start, the
// frame that it finished, the host's time then (platform.time_seconds, 0 without it), and whether every one of its
// faces drew complete inputs (see reflection_probe_inputs_complete). A capture that is not complete is provisional, and
// captures again once a frame's inputs are complete.
Reflection_Probe_Cube :: struct {
	index:    i32,
	key:      Reflection_Probe_Key,
	frame:    u64,
	time:     f64,
	complete: bool,
}

// Reflection_Probe_Capture is the capture in flight: its slot and entity, the key that it captures, its faces drawn so
// far, and of those, the faces that frames with complete inputs drew. It is forced while its slot is, and a force starts
// it over, so no face of a forced capture was drawn before the force.
Reflection_Probe_Capture :: struct {
	slot:           int,
	entity:         ecs.Entity,
	key:            Reflection_Probe_Key,
	faces:          u32,
	complete_faces: u32,
}

// Reflection_Probe_Stats are the probes' counts, which the editor's Resource Monitor shows: the probes in the frame, the
// slots whose probe has a cube, of the level's slots, 0 without the probes, and the faces that the frame captures.
Reflection_Probe_Stats :: struct {
	probes:   u32,
	slots:    u32,
	capacity: u32,
	faces:    u32,
}

// Reflection_Probes is the probes' state between frames, in the Renderer.
Reflection_Probes :: struct {
	// Created again in renderer_reload.
	extractor:             Extractor,
	face:                  Shader_Pipeline,
	downsample:            Shader_Pipeline,
	// The textures, made for params, or not made when they could not be: the array of a cube for each slot and the
	// spare, and the source cube that a capture draws into.
	params:                Reflection_Params,
	made:                  bool,
	mips:                  u32,
	cubes:                 Sky_Cube_Texture,
	source:                Sky_Cube_Texture,
	// The capture's faces' clusters, a list for each face and one index list, and the camera's clusters' lists of
	// probes, which grow with the frame's size.
	face_clusters:         [6]gpu.Buffer,
	face_indices:          gpu.Buffer,
	face_counter:          gpu.Buffer,
	face_cluster_capacity: int,
	clusters:              gpu.Buffer,
	cluster_capacity:      int,
	slots:                 [MAX_REFLECTION_PROBES]Reflection_Probe_Slot,
	// The cube that no slot holds, which a finished capture prefilters into.
	spare:                 i32,
	// nil when no capture is in flight.
	capture:               Maybe(Reflection_Probe_Capture),
	frame:                 u64,
	stats:                 Reflection_Probe_Stats,
}

// Reflection_Probe_Frame is one frame's probes, in frame memory: the records of the probes with a cube, and this frame's
// share of the capture, faces first_face to first_face + face_count, whose views follow first_view, and, when it draws
// the last face, the cube that it prefilters into.
@(private)
Reflection_Probe_Frame :: struct {
	params:            Reflection_Params,
	mips:              u32,
	// The frame's ambient light, which a face's texels take where it drew nothing and the sky has no cubemap.
	ambient:           [4][4]f32,
	records:           []Reflection_Probe_Record,
	upload:            gpu.Upload,
	cubes:             Texture,
	clusters:          Buffer,
	capturing:         bool,
	// Whether the frame's inputs are complete, once its passes are added, which the capture records when the frame
	// executes.
	complete:          bool,
	center:            [3]f32,
	radius:            f32,
	first_face:        u32,
	face_count:        u32,
	finish:            bool,
	target:            u32,
	first_view:        int,
	// The probe's own shadow view for the first directional light that casts, and that light: -1 without one.
	shadow_view:       int,
	shadow_light:      int,
	// The faces' copy of the lights, their clusters' grid and constants, and the clusters, when there are punctual
	// lights.
	lights:            gpu.Upload,
	columns:           u32,
	rows:              u32,
	slice_scale:       f32,
	slice_bias:        f32,
	face_clustered:    bool,
	cluster_constants: [6]gpu.Upload,
	zero:              gpu.Upload,
	face_clusters:     [6]Buffer,
	face_indices:      Buffer,
	face_counter:      Buffer,
	source:            Texture,
	// What each face's forward pass reads for its indirect light, by face, once the passes are added, or nil for nothing.
	face_light:        [6]Reflection_Probe_Face_Light,
}

// Reflection_Probe_Face_Light is the textures that a capture's face reads for its indirect light (see
// add_reflection_probe_passes): the voxel cones' diffuse and specular light that the face's gather gives, or the
// ambient occlusion of its own depth, which scales capture_indirect's light.
Reflection_Probe_Face_Light :: union {
	Reflection_Probe_Voxel_Light,
	Reflection_Probe_Occlusion,
}

Reflection_Probe_Voxel_Light :: struct {
	diffuse:  Texture,
	specular: Texture,
}

Reflection_Probe_Occlusion :: struct {
	texture: Texture,
}

// Reflection_Probe_Step is one face's passes' data, in frame memory, or with face a mip, a downsample's.
@(private = "file")
Reflection_Probe_Step :: struct {
	frame: ^Frame,
	face:  u32,
	view:  int,
	scene: Texture,
	depth: Texture,
}

// Reflection_Probe_Face_Push matches Reflection_Probe_Face_Push in reflection_probe_face.hlsl.
@(private = "file")
Reflection_Probe_Face_Push :: struct {
	ambient:       [4][4]f32,
	scene:         u32,
	depth:         u32,
	output:        u32,
	face:          u32,
	size:          u32,
	sky:           u32,
	sky_mips:      f32,
	sampler_index: u32,
}

// Cube_Downsample_Push matches Cube_Downsample_Push in cube_downsample.hlsl.
@(private = "file")
Cube_Downsample_Push :: struct {
	source: u32,
	output: u32,
	size:   u32,
	block:  u32,
}

@(private)
reflection_probes_init :: proc(rp: ^Reflection_Probes, r: ^Renderer, w: ^ecs.World) {
	reflection_probes_register(rp, w)
	rp.face = shader_pipeline(REFLECTION_PROBE_FACE_SHADER)
	rp.downsample = shader_pipeline(CUBE_DOWNSAMPLE_SHADER)
	rp.face_counter = r.platform.gpu_create_buffer(
		{size = 4, usage = {.Storage}, label = "reflection probe face counter"},
		nil,
	)
}

// reflection_probes_register makes the probes' extractor, in init and after a code reload.
@(private)
reflection_probes_register :: proc(rp: ^Reflection_Probes, w: ^ecs.World) {
	rp.extractor = extractor(w, {ecs.read(w, Reflection_Probe)})
}

@(private)
reflection_probes_destroy :: proc(rp: ^Reflection_Probes, r: ^Renderer) {
	destroy_shader_pipeline(&rp.face, r.platform)
	destroy_shader_pipeline(&rp.downsample, r.platform)
	destroy_reflection_probe_textures(rp, r)
	for b in rp.face_clusters {
		r.platform.gpu_destroy_buffer(b)
	}
	for b in ([]gpu.Buffer{rp.face_indices, rp.face_counter, rp.clusters}) {
		r.platform.gpu_destroy_buffer(b)
	}
}

@(private)
sync_reflection_probe_pipelines :: proc(r: ^Renderer, force: bool) {
	rp := &r.reflection_probes
	assets := r.residency.assets
	sync_compute_pipeline(&rp.face, r.platform, assets, {label = "reflection probe face"}, force)
	sync_compute_pipeline(&rp.downsample, r.platform, assets, {label = "cube downsample"}, force)
}

// reflection_probe_stats are the last frame's probes' counts.
reflection_probe_stats :: proc(r: ^Renderer) -> Reflection_Probe_Stats {
	return r.reflection_probes.stats
}

// reflection_memory is the bytes that the reflections keep between frames, as the last frame left them: the probes'
// cubes, while they are made, and the screen-space or traced reflections' histories. The frame's transient textures
// are not counted.
reflection_memory :: proc(r: ^Renderer) -> u64 {
	rp := &r.reflection_probes
	bytes := stats_state(r).ssr.memory
	if rp.cubes.texture != {} {
		bytes += reflection_probe_memory(rp.params)
	}
	return bytes
}

// Reflection_Probe_State is what the renderer did with an entity's probe, which the editor's Properties panel shows:
// whether it holds a slot, its last finished capture, nil before its first, and whether a capture of it is in flight
// or asked for.
Reflection_Probe_State :: struct {
	slot:      bool,
	cube:      Maybe(Reflection_Probe_Cube),
	capturing: bool,
	forced:    bool,
}

// reflection_probe_state is the state of the probe on an entity: the zero state when it holds no slot, which is so for
// every probe while the reflections are off.
reflection_probe_state :: proc(r: ^Renderer, entity: ecs.Entity) -> Reflection_Probe_State {
	rp := &r.reflection_probes
	for &s, i in rp.slots[:min(int(rp.params.probes), MAX_REFLECTION_PROBES)] {
		if s.used && s.entity == entity {
			c, active := rp.capture.?
			return {
				slot = true,
				cube = s.cube,
				capturing = active && c.slot == i,
				forced = s.forced,
			}
		}
	}
	return {}
}

// reflection_probe_cubes is the probes' cube array, which a Reflection_Probe_Cube's index is a cube of, while it is
// made, and the sampler's index that the lookups read it with.
reflection_probe_cubes :: proc(r: ^Renderer) -> (texture: gpu.Texture, sampler: u32, made: bool) {
	texture = r.reflection_probes.cubes.texture
	return texture, gpu.sampler_index(r.post.sampler), texture != {}
}

// destroy_reflection_probe_textures frees the cubes, and with them every slot's capture.
@(private = "file")
destroy_reflection_probe_textures :: proc(rp: ^Reflection_Probes, r: ^Renderer) {
	for t in ([]^Sky_Cube_Texture{&rp.cubes, &rp.source}) {
		for view in t.views {
			r.platform.gpu_destroy_texture(view)
		}
		r.platform.gpu_destroy_texture(t.texture)
		t^ = {}
	}
	rp.made = false
	rp.slots = {}
	rp.capture = nil
}

// ensure_reflection_probes makes the cubes for a level's params, again when they change, which starts every probe over.
@(private = "file")
ensure_reflection_probes :: proc(r: ^Renderer, params: Reflection_Params) -> bool {
	rp := &r.reflection_probes
	if rp.params == params && rp.cubes.texture != {} {
		return true
	}
	if rp.params == params && rp.made {
		return false
	}
	destroy_reflection_probe_textures(rp, r)
	rp.params, rp.made, rp.mips = params, true, sky_cube_mips(params.face)
	rp.spare = i32(params.probes)
	cube_params := Sky_Cube_Params {
		face    = params.face,
		format  = params.format,
		samples = params.samples,
	}
	create, create_view := r.platform.gpu_create_texture, r.platform.gpu_create_texture_view
	if !make_sky_cube_texture(
		   &rp.cubes,
		   create,
		   create_view,
		   cube_params,
		   rp.mips,
		   "reflection probes",
		   params.probes + 1,
	   ) ||
	   !make_sky_cube_texture(
			   &rp.source,
			   create,
			   create_view,
			   cube_params,
			   rp.mips,
			   "reflection probe source",
		   ) {
		destroy_reflection_probe_textures(rp, r)
		rp.made = true
		return false
	}
	return true
}

// reflection_probe_memory is the bytes of a level's cubes: the array's, with its spare, and the source's.
reflection_probe_memory :: proc(params: Reflection_Params) -> u64 {
	mips := sky_cube_mips(params.face)
	texels: u64
	for mip in 0 ..< mips {
		face := u64(max(params.face >> mip, 1))
		texels += 6 * face * face
	}
	bytes := u64(gpu.format_size(params.format))
	return texels * bytes * u64(params.probes + 2)
}

// begin_reflection_probes readies the frame's probes, after begin_sky_cube and before the shadows, which give the
// capture its shadow view, and the scene's constants, which take the records and the capture's views: it extracts the
// probes, gives them their slots, plans the capture's share of this frame, and uploads the records of the probes that
// have a cube. The probes run with every technique but Off, with the Probes technique's parameters at the level: the
// screen-space reflections fall back to them. With Off, the cubes are freed. An extra view only reads the slots that the
// frame's own view left (see begin_extra_reflection_probes).
@(private)
begin_reflection_probes :: proc(
	f: ^Frame,
	w: ^ecs.World,
	hidden: []u32,
	settings: Reflection_Settings,
	ambient: Ambient,
) {
	r := f.renderer
	rp := &r.reflection_probes
	if f.extra {
		begin_extra_reflection_probes(f, settings, ambient)
		return
	}
	rp.stats = {}
	if settings.off || settings.technique == .Off {
		if rp.made {
			destroy_reflection_probe_textures(rp, r)
		}
		return
	}
	params := REFLECTION_PARAMS[.Probes][settings.level]
	if !ensure_reflection_probes(r, params) {
		return
	}
	platform := r.platform
	rp.frame += 1
	candidates := extract_reflection_probes(f, w, hidden)
	assign_reflection_probe_slots(rp, candidates, int(params.probes))

	pf := new(Reflection_Probe_Frame, platform.frame_allocator)
	f.reflection_probes = pf
	pf.params, pf.mips = params, rp.mips
	pf.ambient = ambient_constants(ambient)
	pf.shadow_view, pf.shadow_light = -1, -1
	pf.cubes = import_texture(f.graph, rp.cubes.texture, .Storage)
	if reflection_probe_pipelines_ready(r) {
		complete := reflection_probe_inputs_complete(f)
		if slot, first, count, ok := plan_reflection_probe_capture(rp, params.faces, complete); ok {
			key := rp.slots[slot].key
			pf.capturing, pf.first_face, pf.face_count = true, first, count
			pf.finish = first + count == 6
			pf.target = u32(rp.spare)
			pf.center = ecs.position_sub(key.position, f.view.position)
			extent, projection := reflection_probe_boxes(key)
			reach := linalg.length(
				[3]f32 {
					max(extent.x, projection.x),
					max(extent.y, projection.y),
					max(extent.z, projection.z),
				},
			)
			pf.radius = clamp(reach, REFLECTION_PROBE_MIN_SHADOW, REFLECTION_PROBE_MAX_SHADOW)
		}
	}
	// The frame that finishes a capture shows it: the probe's record takes the cube that the frame prefilters.
	finishing := pf.finish ? (rp.capture.?).slot : -1
	pf.records = reflection_probe_records(
		rp,
		f.view.position,
		platform.frame_allocator,
		finishing,
		i32(pf.target),
	)
	if len(pf.records) > 0 {
		ok: bool
		pf.upload, ok = upload_bytes(platform, slice.to_bytes(pf.records))
		if !ok {
			pf.records = nil
		}
	}
	for &s in rp.slots[:params.probes] {
		rp.stats.slots += u32(s.used && s.cube != nil)
	}
	rp.stats.probes = u32(len(candidates))
	rp.stats.capacity = params.probes
	rp.stats.faces = pf.face_count
}

// begin_extra_reflection_probes gives an extra view the probes that the frame's own view finished: their records relative
// to its position, which the clusters of its own bin. It extracts, ranks and captures nothing, counts nothing, and frees
// no cube, whatever its settings are.
@(private = "file")
begin_extra_reflection_probes :: proc(f: ^Frame, settings: Reflection_Settings, ambient: Ambient) {
	r := f.renderer
	rp := &r.reflection_probes
	if settings.off || settings.technique == .Off || rp.cubes.texture == {} {
		return
	}
	platform := r.platform
	pf := new(Reflection_Probe_Frame, platform.frame_allocator)
	f.reflection_probes = pf
	pf.params, pf.mips = rp.params, rp.mips
	pf.ambient = ambient_constants(ambient)
	pf.shadow_view, pf.shadow_light = -1, -1
	pf.cubes = import_texture(f.graph, rp.cubes.texture, .Storage)
	pf.records = reflection_probe_records(rp, f.view.position, platform.frame_allocator)
	if len(pf.records) > 0 {
		ok: bool
		pf.upload, ok = upload_bytes(platform, slice.to_bytes(pf.records))
		if !ok {
			pf.records = nil
		}
	}
}

@(private = "file")
reflection_probe_pipelines_ready :: proc(r: ^Renderer) -> bool {
	rp := &r.reflection_probes
	return(
		pipeline_ready(r.platform, &rp.face) &&
		pipeline_ready(r.platform, &rp.downsample) &&
		pipeline_ready(r.platform, &r.sky.cube.prefilter) \
	)
}

// reflection_probe_inputs_complete is whether a capture this frame draws the level as it stays: no asset streams to
// the GPU, every material that the scene draws has its textures resident and its own pipelines compiled, so no bin
// draws a stand-in, and the scene has an item to draw. Without an item, a capture draws only the sky. A material whose
// pipelines failed draws its stand-in until its shader changes, so a capture does not wait for it.
@(private)
reflection_probe_inputs_complete :: proc(f: ^Frame) -> bool {
	r := f.renderer
	sf := f.scene_frame
	if sf == nil || len(sf.items) == 0 || sf.waiting || resident_streaming(&r.residency) > 0 {
		return false
	}
	for index in sf.bin_pipelines {
		if material_status(r.platform, &r.materials.pipelines[index]) == .Compiling {
			return false
		}
	}
	return true
}

// extract_reflection_probes gives the frame's probes, but those of hidden entities, ranked: the highest priority first,
// then the nearest to the camera, then by entity, so the order is the same from frame to frame.
@(private = "file")
extract_reflection_probes :: proc(
	f: ^Frame,
	w: ^ecs.World,
	hidden: []u32,
) -> []Reflection_Probe_Candidate {
	r := f.renderer
	rp := &r.reflection_probes
	candidates := make([dynamic]Reflection_Probe_Candidate, r.platform.frame_allocator)
	it := ecs.query_iter(w, rp.extractor.query)
	for view in ecs.query_next(&it) {
		for e, i in ecs.entities(view) {
			if len(candidates) == MAX_REFLECTION_PROBE_CANDIDATES || is_hidden(hidden, e) {
				continue
			}
			// The pose as it is, not interpolated, so a probe that stands still keeps its key.
			pose := ecs.column(view, 0, ecs.Transform)[i]
			probe := ecs.column(view, EXTRACT_TERMS, Reflection_Probe)[i]
			// The nearest of the frame's views counts, so no view's probes are evicted by another's.
			distance2 := linalg.length2(ecs.position_sub(pose.position, f.view.position))
			if f.world != nil {
				for camera in f.world.cameras {
					distance2 = min(distance2, linalg.length2(ecs.position_sub(pose.position, camera)))
				}
			}
			append(
				&candidates,
				Reflection_Probe_Candidate {
					entity = e,
					key = {pose.position, pose.rotation, pose.scale, probe},
					distance2 = distance2,
				},
			)
		}
	}
	rank_reflection_probes(candidates[:])
	return candidates[:]
}

// rank_reflection_probes orders probes by priority, the highest first, then by distance, the nearest first, then by
// entity.
rank_reflection_probes :: proc(candidates: []Reflection_Probe_Candidate) {
	slice.sort_by(candidates, proc(a, b: Reflection_Probe_Candidate) -> bool {
		if a.key.probe.priority != b.key.probe.priority {
			return a.key.probe.priority > b.key.probe.priority
		}
		if a.distance2 != b.distance2 {
			return a.distance2 < b.distance2
		}
		return a.entity < b.entity
	})
}

// assign_reflection_probe_slots gives the first slots ranked probes slots, at most MAX_REFLECTION_PROBES, and keeps the
// others' slots until a ranked probe needs one: then the lowest ranked gives up its own. A slot whose probe is gone this
// frame is freed.
assign_reflection_probe_slots :: proc(
	rp: ^Reflection_Probes,
	candidates: []Reflection_Probe_Candidate,
	slots: int,
) {
	count := min(slots, MAX_REFLECTION_PROBES)
	find :: proc(rp: ^Reflection_Probes, e: ecs.Entity, count: int) -> int {
		for &s, i in rp.slots[:count] {
			if s.used && s.entity == e {
				return i
			}
		}
		return -1
	}
	for c, rank in candidates {
		if i := find(rp, c.entity, count); i >= 0 {
			s := &rp.slots[i]
			s.key, s.distance2, s.rank, s.seen = c.key, c.distance2, rank, rp.frame
		}
	}
	for &s, i in rp.slots[:count] {
		if s.used && s.seen != rp.frame {
			free_reflection_probe_slot(rp, i)
		}
	}
	wanted := min(len(candidates), count)
	for c, rank in candidates[:wanted] {
		if find(rp, c.entity, count) >= 0 {
			continue
		}
		slot := -1
		for &s, i in rp.slots[:count] {
			if !s.used {
				slot = i
				break
			}
		}
		if slot < 0 {
			// Every slot is used, so one holds a probe ranked past the wanted ones.
			for &s, i in rp.slots[:count] {
				if s.rank >= wanted && (slot < 0 || s.rank > rp.slots[slot].rank) {
					slot = i
				}
			}
			free_reflection_probe_slot(rp, slot)
		}
		rp.slots[slot] = {
			used      = true,
			entity    = c.entity,
			key       = c.key,
			seen      = rp.frame,
			distance2 = c.distance2,
			rank      = rank,
		}
	}
}

@(private = "file")
free_reflection_probe_slot :: proc(rp: ^Reflection_Probes, slot: int) {
	if c, active := rp.capture.?; active && c.slot == slot {
		rp.capture = nil
	}
	rp.slots[slot] = {}
}

// plan_reflection_probe_capture gives the capture's faces for this frame, at most faces of them, and starts a capture
// when none is in flight. A capture whose probe changed starts over, and one whose probe lost its slot ends. The next
// capture is, in order: a probe that the editor forced, the nearest first; a probe On_Load with no cube yet, the nearest
// first; any other probe with no cube yet; when the frame's inputs are complete, a probe whose capture is provisional,
// the nearest first; a probe On_Change whose key changed since its capture; then the Realtime probes, the longest since
// its capture first. A forced probe ends a capture in flight whose probe is not forced, which starts over later, and a
// forced probe's capture draws all six faces this frame, whatever faces is.
plan_reflection_probe_capture :: proc(
	rp: ^Reflection_Probes,
	faces: u32,
	complete: bool,
) -> (
	slot: int,
	first_face, face_count: u32,
	ok: bool,
) {
	if c, active := rp.capture.?; active {
		s := &rp.slots[c.slot]
		if !s.used || s.entity != c.entity {
			rp.capture = nil
		} else if s.key != c.key {
			rp.capture = Reflection_Probe_Capture {
				slot   = c.slot,
				entity = c.entity,
				key    = s.key,
			}
		}
	}
	count := min(int(rp.params.probes), MAX_REFLECTION_PROBES)
	if c, active := rp.capture.?; active && !rp.slots[c.slot].forced {
		for &s in rp.slots[:count] {
			if s.used && s.forced {
				rp.capture = nil
				break
			}
		}
	}
	if rp.capture == nil {
		best, best_class := -1, 5
		for &s, i in rp.slots[:count] {
			if !s.used {
				continue
			}
			cube, has_cube := s.cube.?
			class: int
			switch {
			case s.forced:
				class = -1
			case !has_cube && s.key.probe.update == .On_Load:
				class = 0
			case !has_cube:
				class = 1
			case complete && !cube.complete:
				class = 2
			case s.key.probe.update == .On_Change && s.key != cube.key:
				class = 3
			case s.key.probe.update == .Realtime:
				class = 4
			case:
				continue
			}
			better := class < best_class
			if class == best_class {
				b := &rp.slots[best]
				// A Realtime probe has a cube, so b does too.
				if class == 4 && cube.frame != (b.cube.?).frame {
					better = cube.frame < (b.cube.?).frame
				} else {
					better = s.distance2 < b.distance2
				}
			}
			if better {
				best, best_class = i, class
			}
		}
		if best < 0 {
			return
		}
		rp.capture = Reflection_Probe_Capture {
			slot   = best,
			entity = rp.slots[best].entity,
			key    = rp.slots[best].key,
		}
	}
	c := rp.capture.?
	budget := rp.slots[c.slot].forced ? 6 : max(faces, 1)
	return c.slot, c.faces, min(budget, 6 - c.faces), true
}

// capture_reflection_probe asks for a capture of the probe on an entity, which takes the next capture and draws all six
// faces in one frame, whatever the level's budget (see plan_reflection_probe_capture). It is false when the probe holds
// no slot, so it cannot be captured: the frame's probes give the slots, so a probe added this frame has one from the
// next.
capture_reflection_probe :: proc(r: ^Renderer, entity: ecs.Entity) -> bool {
	rp := &r.reflection_probes
	for &s, i in rp.slots[:min(int(rp.params.probes), MAX_REFLECTION_PROBES)] {
		if s.used && s.entity == entity {
			force_reflection_probe(rp, i)
			return true
		}
	}
	return false
}

// capture_reflection_probes asks for a capture of every probe that holds a slot, one a frame, and gives how many.
capture_reflection_probes :: proc(r: ^Renderer) -> int {
	rp := &r.reflection_probes
	count := 0
	for &s, i in rp.slots[:min(int(rp.params.probes), MAX_REFLECTION_PROBES)] {
		if s.used {
			force_reflection_probe(rp, i)
			count += 1
		}
	}
	return count
}

// force_reflection_probe forces a slot's probe. Its capture in flight starts over, as a change of its key does, so the
// capture that answers the force draws every face after it, and sees what changed before it.
@(private = "file")
force_reflection_probe :: proc(rp: ^Reflection_Probes, slot: int) {
	s := &rp.slots[slot]
	s.forced = true
	if c, active := rp.capture.?; active && c.slot == slot {
		rp.capture = Reflection_Probe_Capture {
			slot   = slot,
			entity = s.entity,
			key    = s.key,
		}
	}
}

// advance_reflection_probe_capture records that this frame drew face_count more of the capture's faces, with complete
// inputs or not, at the host's time. With the last, the probe takes the spare cube, which this frame prefilters,
// complete only if every face was, a forced capture of it is answered, and its old cube, or a cube that no slot holds,
// becomes the spare.
advance_reflection_probe_capture :: proc(
	rp: ^Reflection_Probes,
	face_count: u32,
	complete: bool,
	time: f64 = 0,
) {
	c, active := &rp.capture.?
	if !active {
		return
	}
	c.faces += face_count
	if complete {
		c.complete_faces += face_count
	}
	if c.faces < 6 {
		return
	}
	s := &rp.slots[c.slot]
	old, had_cube := s.cube.?
	s.cube = Reflection_Probe_Cube {
		index    = rp.spare,
		key      = c.key,
		frame    = rp.frame,
		time     = time,
		complete = c.complete_faces == 6,
	}
	s.forced = false
	rp.capture = nil
	if had_cube {
		rp.spare = old.index
		return
	}
	count := min(int(rp.params.probes), MAX_REFLECTION_PROBES)
	for index in 0 ..= i32(count) {
		held := false
		for &other in rp.slots[:count] {
			cube, has_cube := other.cube.?
			held ||= other.used && has_cube && cube.index == index
		}
		if !held {
			rp.spare = index
			return
		}
	}
}

// reflection_probe_boxes are a probe's influence box's and projection box's half sizes, with their defaults, scaled by
// its pose.
reflection_probe_boxes :: proc(key: Reflection_Probe_Key) -> (extent, projection: [3]f32) {
	return reflection_probe_extents(key.probe, key.scale)
}

// reflection_probe_extents are a probe's influence box's and projection box's half sizes for an entity's scale: 0
// takes DEFAULT_PROBE_EXTENT, and a projection of 0 takes the influence box's. The editor's helpers use them too.
reflection_probe_extents :: proc(
	p: Reflection_Probe,
	scale: [3]f32,
) -> (
	extent, projection: [3]f32,
) {
	for a in 0 ..< 3 {
		s := abs(scale[a])
		extent[a] = (p.extent[a] > 0 ? p.extent[a] : DEFAULT_PROBE_EXTENT) * s
		projection[a] = p.projection_extent[a] > 0 ? p.projection_extent[a] * s : extent[a]
	}
	return
}

// reflection_probe_blend is a probe's fade inside its influence box, in meters, which no half size is less than.
reflection_probe_blend :: proc(p: Reflection_Probe, extent: [3]f32) -> f32 {
	return min(max(p.blend_distance, 0), min(extent.x, extent.y, extent.z))
}

// reflection_probe_records are the records of the probes that have a cube, relative to the camera at origin, in their
// lookup's order: the highest priority first, then the smallest box, so a room's probe wins over the hall's around it,
// then by slot, so ties stay in the same order. The slot finishing, -1 for none, has the cube target, which the frame
// prefilters, whether or not it had a cube before.
reflection_probe_records :: proc(
	rp: ^Reflection_Probes,
	origin: ecs.World_Position,
	allocator := context.allocator,
	finishing := -1,
	target := i32(-1),
) -> []Reflection_Probe_Record {
	count := min(int(rp.params.probes), MAX_REFLECTION_PROBES)
	order := make([dynamic]int, 0, count, allocator)
	for &s, i in rp.slots[:count] {
		if s.used && (s.cube != nil || i == finishing) {
			append(&order, i)
		}
	}
	volume :: proc(s: ^Reflection_Probe_Slot) -> f32 {
		e, _ := reflection_probe_boxes(s.key)
		return e.x * e.y * e.z
	}
	// Insertion sort: few probes have cubes.
	for i in 1 ..< len(order) {
		for j := i; j > 0; j -= 1 {
			a, b := &rp.slots[order[j]], &rp.slots[order[j - 1]]
			first :=
				a.key.probe.priority > b.key.probe.priority ||
				(a.key.probe.priority == b.key.probe.priority && volume(a) < volume(b))
			if !first {
				break
			}
			order[j], order[j - 1] = order[j - 1], order[j]
		}
	}
	records := make([]Reflection_Probe_Record, len(order), allocator)
	for i, k in order {
		s := &rp.slots[i]
		p := s.key.probe
		extent, projection := reflection_probe_boxes(s.key)
		x := linalg.normalize(linalg.quaternion128_mul_vector3(s.key.rotation, [3]f32{1, 0, 0}))
		y := linalg.normalize(linalg.quaternion128_mul_vector3(s.key.rotation, [3]f32{0, 1, 0}))
		z := linalg.normalize(linalg.quaternion128_mul_vector3(s.key.rotation, [3]f32{0, 0, 1}))
		cube := i == finishing ? target : (s.cube.?).index
		records[k] = {
			center     = ecs.position_sub(s.key.position, origin),
			cube       = u32(cube),
			axes       = {{x.x, x.y, x.z, 0}, {y.x, y.y, y.z, 0}, {z.x, z.y, z.z, 0}},
			extent     = extent,
			blend      = reflection_probe_blend(p, extent),
			projection = p.box_projection ? projection : {},
			intensity  = p.intensity > 0 ? p.intensity : 1,
		}
	}
	return records
}

// probe_reaches_box is whether a probe's influence box reaches a box in a view's space, whose axes in the world are
// right, up and forward, from an eye: the box in view space that holds the probe's turned box overlaps it. Matches
// probe_reaches in cluster_lights.hlsl.
probe_reaches_box :: proc(
	record: Reflection_Probe_Record,
	eye, right, up, forward: [3]f32,
	box_min, box_max: [3]f32,
) -> bool {
	to_view :: proc(v, right, up, forward: [3]f32) -> [3]f32 {
		return {linalg.dot(v, right), linalg.dot(v, up), linalg.dot(v, forward)}
	}
	center := to_view(record.center - eye, right, up, forward)
	half: [3]f32
	for a in 0 ..< 3 {
		axis := to_view(record.axes[a].xyz, right, up, forward)
		half += [3]f32{abs(axis.x), abs(axis.y), abs(axis.z)} * record.extent[a]
	}
	lo, hi := center - half, center + half
	return(
		lo.x <= box_max.x &&
		lo.y <= box_max.y &&
		lo.z <= box_max.z &&
		hi.x >= box_min.x &&
		hi.y >= box_min.y &&
		hi.z >= box_min.z \
	)
}

// reflection_probe_face_projection is a capture face's projection of positions relative to the camera, from the probe's
// position relative to the camera: a square 90° view along the face, with reversed depth from REFLECTION_PROBE_NEAR to
// infinity, as view_projection makes.
reflection_probe_face_projection :: proc(center: [3]f32, face: u32) -> matrix[4, 4]f32 {
	axes := REFLECTION_PROBE_FACES
	right, up, forward := axes[face][0], axes[face][1], axes[face][2]
	return matrix[4, 4]f32{
		right.x, right.y, right.z, -linalg.dot(right, center),
		up.x, up.y, up.z, -linalg.dot(up, center),
		0, 0, 0, REFLECTION_PROBE_NEAR,
		forward.x, forward.y, forward.z, -linalg.dot(forward, center),
	}
}

// reflection_probe_view is whether a scene view is a face of this frame's capture, and which face.
@(private)
reflection_probe_view :: proc(f: ^Frame, view: int) -> (face: u32, ok: bool) {
	pf := f.reflection_probes
	if pf == nil ||
	   !pf.capturing ||
	   view < pf.first_view ||
	   view >= pf.first_view + int(pf.face_count) {
		return
	}
	return pf.first_face + u32(view - pf.first_view), true
}

// reflection_probe_view_constants gives a capture face's view its constants: its projection and culling, a linear
// color with no screen-space light, no fog and no probes of its own, its own clusters and copy of the lights, and every
// depth in the first cascade, which is the probe's own shadow view. It keeps the camera's level of detail, as the
// shadow views do, so it draws the meshlets that the camera's walk of their hierarchy picked.
@(private)
reflection_probe_view_constants :: proc(
	f: ^Frame,
	c: ^Frame_Constants,
	view: ^Cull_View,
	face: u32,
) {
	r := f.renderer
	pf := f.reflection_probes
	axes := REFLECTION_PROBE_FACES
	right, up := axes[face][0], axes[face][1]
	m := reflection_probe_face_projection(pf.center, face)
	size := pf.params.face
	c.view_projection, c.previous_view_projection, c.cluster_view_projection = m, m, m
	c.near = REFLECTION_PROBE_NEAR
	// A face is a quarter turn wide and high.
	c.projection = {1, 1, REFLECTION_PROBE_NEAR, 0}
	c.camera_right, c.camera_up = {right.x, right.y, right.z, 0}, {up.x, up.y, up.z, 0}
	c.previous_camera_right, c.previous_camera_up = c.camera_right, c.camera_up
	c.screen_size = {f32(size), f32(size)}
	c.jitter = {}
	c.exposure = gpu.read_index(r.post.unit_exposure)
	c.fog, c.gi, c.debug_view, c.occlusion = 0, 0, 0, 0
	// The faces see no clouds, so their light takes no cloud shadow either.
	c.cloud_shadow = 0
	c.virtual_levels, c.virtual_draw = 0, 0
	c.reflection_probe_count, c.reflection_probe_clusters = 0, 0
	c.capture = 1
	c.cascade_splits = {math.F32_MAX, math.F32_MAX, math.F32_MAX, math.F32_MAX}
	c.cull_eye = {pf.center.x, pf.center.y, pf.center.z, 1}
	if pf.lights.data != nil {
		c.lights, c.lights_offset = gpu.read_index(pf.lights.buffer), pf.lights.offset
	}
	c.cluster_columns, c.cluster_rows = pf.columns, pf.rows
	c.slice_scale, c.slice_bias = pf.slice_scale, pf.slice_bias
	c.clustered = u32(pf.face_clustered)
	c.clusters, c.cluster_indices = 0, 0
	if pf.face_clustered {
		c.clusters = gpu.read_index(r.reflection_probes.face_clusters[face])
		c.cluster_indices = gpu.read_index(r.reflection_probes.face_indices)
	}
	view.planes = frustum_planes_6(m)
}

// reflection_probe_constants gives the camera's constants the probes, once the clusters bin them.
@(private)
reflection_probe_constants :: proc(c: ^Frame_Constants, f: ^Frame) {
	pf := f.reflection_probes
	if pf == nil {
		return
	}
	c.reflection_probe_rough_start, c.reflection_probe_rough_end =
		pf.params.rough_start, pf.params.rough_end
	rp := &f.renderer.reflection_probes
	if len(pf.records) == 0 || !f.lights.binned_probes {
		return
	}
	c.reflection_probes, c.reflection_probes_offset =
		gpu.read_index(pf.upload.buffer), pf.upload.offset
	c.reflection_probe_count = u32(len(pf.records))
	c.reflection_probe_clusters = gpu.read_index(rp.clusters)
	c.reflection_probe_cubes = gpu.read_index(rp.cubes.texture)
	c.reflection_probe_mips = f32(pf.mips)
}

// reflection_probe_cluster_fields gives the camera's clusters' constants the probes to bin, and readies their lists for
// a count of clusters. It is false without probes.
@(private)
reflection_probe_cluster_fields :: proc(
	f: ^Frame,
	constants: ^Cluster_Constants,
	cluster_count: int,
) -> bool {
	pf := f.reflection_probes
	if pf == nil || len(pf.records) == 0 {
		return false
	}
	r := f.renderer
	rp := &r.reflection_probes
	if cluster_count > rp.cluster_capacity {
		r.platform.gpu_destroy_buffer(rp.clusters)
		rp.clusters = r.platform.gpu_create_buffer(
			{
				size = u32(cluster_count * REFLECTION_PROBE_CLUSTER_STRIDE),
				usage = {.Storage},
				label = "reflection probe clusters",
			},
			nil,
		)
		rp.cluster_capacity = rp.clusters != {} ? cluster_count : 0
	}
	if rp.clusters == {} {
		return false
	}
	constants.probes, constants.probes_offset = gpu.read_index(pf.upload.buffer), pf.upload.offset
	constants.probe_count = u32(len(pf.records))
	constants.probe_clusters = gpu.write_index(rp.clusters)
	return true
}

// has_reflection_probes is whether the frame looks probes up, so the clusters bin them without punctual lights too.
@(private)
has_reflection_probes :: proc(f: ^Frame) -> bool {
	return f.reflection_probes != nil && len(f.reflection_probes.records) > 0
}

// declare_reflection_probe_reads declares a pass's reads of the probes that its shaders look up.
@(private)
declare_reflection_probe_reads :: proc(f: ^Frame, p: Pass) {
	pf := f.reflection_probes
	if pf == nil || len(pf.records) == 0 || pf.clusters == 0 {
		return
	}
	read(f.graph, p, pf.cubes)
	read(f.graph, p, pf.clusters)
}

// add_reflection_probe_shadow gives the capture its own shadow view of the first directional light that casts, in a
// slot of the atlas: an orthographic view of the sphere around the probe's boxes, since the camera's cascades do not
// cover a probe far from the camera.
@(private)
add_reflection_probe_shadow :: proc(f: ^Frame, sf: ^Shadow_Frame, slot: int, max_views: int) {
	pf := f.reflection_probes
	lf := f.lights
	if pf == nil || !pf.capturing || slot >= max_views {
		return
	}
	for i in 0 ..< lf.directional_count {
		if !lf.casts[i] {
			continue
		}
		pf.shadow_view, pf.shadow_light = len(sf.views), i
		add_orthographic_shadow_view(sf, lf.records[i].direction, pf.center, pf.radius, slot)
		return
	}
}

// upload_reflection_probe_lights writes the capture's copy of the lights, after the shadows give them theirs, and readies
// its faces' clusters. The faces have no shadow mask, so no light takes a channel, and the directional light with the
// probe's shadow view takes it as its only cascade; the others have none. The faces have no cloud shadow map either.
@(private)
upload_reflection_probe_lights :: proc(f: ^Frame) {
	pf := f.reflection_probes
	if pf == nil || !pf.capturing {
		return
	}
	r := f.renderer
	rp := &r.reflection_probes
	platform := r.platform
	lf := f.lights
	records := make([]Light_Record, max(len(lf.records), 1), platform.frame_allocator)
	copy(records, lf.records[:])
	for &record, i in records[:len(lf.records)] {
		record.mask = -1
		if record.type == .Directional {
			record.shadow =
				i == pf.shadow_light && pf.shadow_view < len(f.shadows.views) ? i32(pf.shadow_view) : -1
			record.flags -= {.Virtual_Shadow, .Cloud_Shadow}
		}
	}
	ok: bool
	pf.lights, ok = upload_bytes(platform, slice.to_bytes(records))
	if !ok {
		return
	}
	size := pf.params.face
	pf.columns, pf.rows = cluster_grid({size, size})
	pf.slice_scale, pf.slice_bias = slice_constants(Perspective{near = REFLECTION_PROBE_NEAR})
	if len(lf.records) == lf.directional_count || r.lights.pipeline.pipeline == {} {
		return
	}
	per_face := int(pf.columns * pf.rows) * CLUSTER_SLICES
	if per_face > rp.face_cluster_capacity {
		for &b in rp.face_clusters {
			platform.gpu_destroy_buffer(b)
			b = platform.gpu_create_buffer(
				{
					size = u32(per_face * 8),
					usage = {.Storage},
					label = "reflection probe face clusters",
				},
				nil,
			)
		}
		platform.gpu_destroy_buffer(rp.face_indices)
		rp.face_indices = platform.gpu_create_buffer(
			{
				size = u32(6 * per_face * CLUSTER_AVERAGE_LIGHTS * 4),
				usage = {.Storage},
				label = "reflection probe face cluster indices",
			},
			nil,
		)
		rp.face_cluster_capacity = per_face
	}
	if rp.face_indices == {} || rp.face_counter == {} {
		return
	}
	pf.zero, ok = platform.gpu_upload(4, 4)
	if !ok {
		return
	}
	(^u32)(raw_data(pf.zero.data))^ = 0
	axes := REFLECTION_PROBE_FACES
	for k in 0 ..< pf.face_count {
		face := pf.first_face + k
		right, up, forward := axes[face][0], axes[face][1], axes[face][2]
		constants := Cluster_Constants {
			right         = {right.x, right.y, right.z, 0},
			up            = {up.x, up.y, up.z, 0},
			forward       = {forward.x, forward.y, forward.z, 0},
			// A 90° view's x and y scales are 1.
			projection    = {1, 1, REFLECTION_PROBE_NEAR, pf.slice_scale},
			size          = {f32(size), f32(size)},
			columns       = pf.columns,
			rows          = pf.rows,
			lights        = gpu.read_index(pf.lights.buffer),
			lights_offset = pf.lights.offset,
			first_light   = u32(lf.directional_count),
			light_count   = u32(len(lf.records) - lf.directional_count),
			clusters      = gpu.write_index(rp.face_clusters[face]),
			indices       = gpu.write_index(rp.face_indices),
			counter       = gpu.write_index(rp.face_counter),
			capacity      = u32(6 * rp.face_cluster_capacity * CLUSTER_AVERAGE_LIGHTS),
			eye           = pf.center,
		}
		pf.cluster_constants[k], ok = platform.gpu_upload(
			size_of(Cluster_Constants),
			gpu.PASS_CONSTANTS_ALIGN,
		)
		if !ok {
			return
		}
		(^Cluster_Constants)(raw_data(pf.cluster_constants[k].data))^ = constants
	}
	pf.face_clustered = true
}

// add_reflection_probe_passes adds this frame's share of the capture, after the shadow maps and the sky's cubemap,
// which its faces read, and before the world pass: for each face, its clusters, a prepass and a forward pass of its
// view, and its copy into the source cube; with the last face, the source's mips and the prefilter into the spare
// cube. The readers sample cubes that earlier frames finished, so they need nothing from these passes.
@(private)
add_reflection_probe_passes :: proc(f: ^Frame) {
	pf := f.reflection_probes
	if pf == nil || !pf.capturing {
		return
	}
	r := f.renderer
	rp := &r.reflection_probes
	g := f.graph
	platform := r.platform
	pf.source = import_texture(g, rp.source.texture, .Storage)
	// The faces' indirect light: the world probes' or the voxel cones', which are known once the global illumination's
	// passes are added, after the scene's constants, or without either the ambient light, which the faces' own ambient
	// occlusion scales.
	gf := f.gi
	world_probes := gf != nil && gf.probes != nil
	voxels := reflection_probe_voxels(f)
	occlusion := !world_probes && !voxels && f.ao != nil
	if sf := f.scene_frame; world_probes || voxels {
		for k in 0 ..< int(pf.face_count) {
			view := pf.first_view + k
			if sf == nil || view >= len(sf.view_constants) || sf.view_constants[view].data == nil {
				continue
			}
			c := (^Frame_Constants)(raw_data(sf.view_constants[view].data))
			if voxels {
				c.gi = 1
			} else {
				c.world_probes, c.world_probe_grid, c.world_probe_grid_offset =
					1, gpu.read_index(gf.probes.upload.buffer), gf.probes.upload.offset
			}
		}
	}
	if pf.face_clustered {
		for k in 0 ..< pf.face_count {
			pf.face_clusters[pf.first_face + k] = import_buffer(
				g,
				rp.face_clusters[pf.first_face + k],
			)
		}
		pf.face_indices = import_buffer(g, rp.face_indices)
		pf.face_counter = import_buffer(g, rp.face_counter)
		p := add_compute_pass(g, "clear reflection probe face counter", proc(ctx: ^Pass_Context) {
				pf := (^Frame)(ctx.data).reflection_probes
				gpu.cmd_copy_buffer(
					ctx.cb,
					pf.zero.buffer,
					pf.zero.offset,
					gpu_buffer(ctx.graph, pf.face_counter),
					0,
					4,
				)
			}, f)
		copy_dest(g, p, pf.face_counter)
		p = add_compute_pass(g, "reflection probe face clusters", proc(ctx: ^Pass_Context) {
				f := (^Frame)(ctx.data)
				pf := f.reflection_probes
				count := pf.columns * pf.rows * CLUSTER_SLICES
				gpu.cmd_set_pipeline(ctx.cb, f.renderer.lights.pipeline.pipeline)
				for k in 0 ..< pf.face_count {
					gpu.cmd_set_pass_constants(ctx.cb, pf.cluster_constants[k])
					gpu.cmd_dispatch(
						ctx.cb,
						{(count + CLUSTER_GROUP_SIZE - 1) / CLUSTER_GROUP_SIZE, 1, 1},
					)
				}
			}, f)
		write(g, p, pf.face_counter)
		write(g, p, pf.face_indices)
		for k in 0 ..< pf.face_count {
			write(g, p, pf.face_clusters[pf.first_face + k])
		}
	}
	// The gather and the ambient occlusion read the prepass's normals, and the gather its roughness.
	keep: gpu.Store_Op = voxels || occlusion ? .Store : .Discard
	axes := REFLECTION_PROBE_FACES
	size := [2]u32{pf.params.face, pf.params.face}
	// Each face has targets of its own, and the graph gives a face the textures of the one before it, which is done with
	// them (see docs/gpu/render-graph.md#render-graph).
	for k in 0 ..< pf.face_count {
		face := pf.first_face + k
		step := new(Reflection_Probe_Step, platform.frame_allocator)
		step^ = {
			frame = f,
			face  = face,
			view  = pf.first_view + int(k),
			scene = create_texture(g, {size = size, format = SCENE_FORMAT, label = "reflection probe scene"}),
			depth = create_texture(g, {size = size, format = DEPTH_FORMAT, label = "reflection probe depth"}),
		}
		normals := create_texture(g, {size = size, format = NORMAL_FORMAT, label = "reflection probe normals"})
		velocity := create_texture(g, {size = size, format = VELOCITY_FORMAT, label = "reflection probe velocity"})
		roughness := create_texture(g, {size = size, format = ROUGHNESS_FORMAT, label = "reflection probe roughness"})
		ids := create_texture(g, {size = size, format = ID_FORMAT, label = "reflection probe ids"})
		p := add_render_pass(g, "reflection probe prepass", proc(ctx: ^Pass_Context) {
				step := (^Reflection_Probe_Step)(ctx.data)
				draw_scene_view(step.frame, ctx.cb, step.view, .Prepass, filter = .No_Particles)
			}, step)
		color(g, p, normals, .Clear, store = keep)
		color(g, p, velocity, .Clear, {VELOCITY_NONE, VELOCITY_NONE, 0, 0}, store = .Discard)
		color(g, p, roughness, .Clear, {ROUGHNESS_NONE, 0, 0, 0}, store = voxels ? .Store : .Discard)
		depth(g, p, step.depth, .Clear)
		declare_scene_draws(f, p)
		if voxels {
			light := Reflection_Probe_Voxel_Light {
				diffuse  = create_texture(g, {size = size, format = GI_FORMAT, label = "reflection probe gi diffuse"}),
				specular = create_texture(g, {size = size, format = GI_FORMAT, label = "reflection probe gi specular"}),
			}
			pf.face_light[face] = light
			capture := new(Voxel_Capture, platform.frame_allocator)
			capture^ = {
				frame     = f,
				axes      = axes[face],
				origin    = pf.center,
				size      = pf.params.face,
				depth     = step.depth,
				normals   = normals,
				roughness = roughness,
				diffuse   = light.diffuse,
				specular  = light.specular,
			}
			add_voxel_capture_gather(f, capture)
		}
		if occlusion {
			af := ao_face(f, axes[face], pf.params.face, step.depth, normals)
			pf.face_light[face] = Reflection_Probe_Occlusion{af.output}
		}
		p = add_render_pass(g, "reflection probe face", proc(ctx: ^Pass_Context) {
				step := (^Reflection_Probe_Step)(ctx.data)
				draw_scene_view(step.frame, ctx.cb, step.view, .Forward, filter = .No_Particles)
			}, step)
		color(g, p, step.scene, .Clear, {0, 0, 0, 1})
		color(g, p, ids, .Clear, store = .Discard)
		depth(g, p, step.depth, .Load)
		declare_scene_draws(f, p)
		declare_reflection_probe_face_lighting(f, p, face)
		p = add_compute_pass(g, "reflection probe copy", run_reflection_probe_copy, step)
		read(g, p, step.scene)
		read(g, p, step.depth)
		declare_sky_cube_reads(f, p)
		write(g, p, pf.source)
	}
	if pf.finish {
		// A pass a mip, each from the one before, which the graph's barrier between the writes orders.
		for mip in 1 ..< rp.mips {
			step := new(Reflection_Probe_Step, platform.frame_allocator)
			step^ = {
				frame = f,
				face  = mip,
			}
			p := add_compute_pass(
				g,
				"reflection probe downsample",
				run_reflection_probe_downsample,
				step,
			)
			write(g, p, pf.source)
		}
		p := add_compute_pass(g, "reflection probe prefilter", run_reflection_probe_prefilter, f)
		read(g, p, pf.source)
		write(g, p, pf.cubes)
	}
	// The scene's passes are added, and a full upload ring takes its items, so the inputs are known now.
	pf.complete = reflection_probe_inputs_complete(f)
	// The capture moves on only when the faces were drawn, so a frame that fails draws them again.
	on_executed(g, proc(data: rawptr) {
			f := (^Frame)(data)
			pf := f.reflection_probes
			platform := f.renderer.platform
			now := platform.time_seconds != nil ? platform.time_seconds() : 0
			advance_reflection_probe_capture(
				&f.renderer.reflection_probes,
				pf.face_count,
				pf.complete,
				now,
			)
		}, f)
}

// declare_reflection_probe_face_lighting declares what a face's forward pass reads: the shadow atlas, the sky's
// cubemap, the face's clusters, the world probes, and the face's own voxel cones' light or ambient occlusion.
@(private = "file")
declare_reflection_probe_face_lighting :: proc(f: ^Frame, p: Pass, face: u32) {
	g := f.graph
	pf := f.reflection_probes
	if f.shadows.atlas != 0 {
		read(g, p, f.shadows.atlas)
	}
	declare_sky_cube_reads(f, p)
	if pf.face_clustered {
		read(g, p, pf.face_indices)
		for k in 0 ..< pf.face_count {
			read(g, p, pf.face_clusters[pf.first_face + k])
		}
	}
	if gf := f.gi; gf != nil && gf.probes != nil {
		read(g, p, gf.probes.radiance)
		read(g, p, gf.probes.irradiance)
		read(g, p, gf.probes.states)
	}
	switch light in pf.face_light[face] {
	case Reflection_Probe_Voxel_Light:
		read(g, p, light.diffuse)
		read(g, p, light.specular)
	case Reflection_Probe_Occlusion:
		read(g, p, light.texture)
	}
}

// reflection_probe_voxels is whether this frame's capture takes the voxel cones' light: they run this frame, and a level
// that holds surfaces holds the probe. A probe outside every level takes the light that a capture takes without them.
@(private)
reflection_probe_voxels :: proc(f: ^Frame) -> bool {
	gf := f.gi
	pf := f.reflection_probes
	return gf != nil && gf.voxel != nil && pf != nil && voxel_holds(gf.voxel, pf.center)
}

// reflection_probe_push is a capture face's textures for the forward pass: the shadow atlas, the face's own voxel cones'
// light or ambient occlusion, and white for the camera's screen-space ones, which it reads none of.
@(private)
reflection_probe_push :: proc(f: ^Frame, face: u32) -> Material_Push {
	white := gpu.read_index(f.renderer.materials.defaults[.White])
	push := Material_Push {
		shadow_atlas      = white,
		shadow_mask       = white,
		ambient_occlusion = white,
		fog               = white,
		gi_diffuse        = white,
		gi_specular       = white,
	}
	if f.shadows.atlas != 0 {
		push.shadow_atlas = gpu.read_index(gpu_texture(f.graph, f.shadows.atlas))
	}
	if pf := f.reflection_probes; pf != nil {
		switch light in pf.face_light[face] {
		case Reflection_Probe_Voxel_Light:
			push.gi_diffuse = gpu.read_index(gpu_texture(f.graph, light.diffuse))
			push.gi_specular = gpu.read_index(gpu_texture(f.graph, light.specular))
		case Reflection_Probe_Occlusion:
			push.ambient_occlusion = gpu.read_index(gpu_texture(f.graph, light.texture))
		}
	}
	return push
}

@(private = "file")
run_reflection_probe_copy :: proc(ctx: ^Pass_Context) {
	step := (^Reflection_Probe_Step)(ctx.data)
	f := step.frame
	r := f.renderer
	rp := &r.reflection_probes
	g := ctx.graph
	sky := sky_cube_reads(f)
	size := f.reflection_probes.params.face
	push := Reflection_Probe_Face_Push {
		ambient       = f.reflection_probes.ambient,
		scene         = gpu.read_index(gpu_texture(g, step.scene)),
		depth         = gpu.read_index(gpu_texture(g, step.depth)),
		output        = gpu.write_index(rp.source.views[0]),
		face          = step.face,
		size          = size,
		sky           = sky.current,
		sky_mips      = sky.mips,
		sampler_index = gpu.sampler_index(r.post.sampler),
	}
	gpu.cmd_set_pipeline(ctx.cb, rp.face.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups({size, size}, SKY_CUBE_GROUP_SIZE))
}

@(private = "file")
run_reflection_probe_downsample :: proc(ctx: ^Pass_Context) {
	step := (^Reflection_Probe_Step)(ctx.data)
	rp := &step.frame.renderer.reflection_probes
	mip := step.face
	size := max(rp.params.face >> mip, 1)
	push := Cube_Downsample_Push {
		source = gpu.write_index(rp.source.views[mip - 1]),
		output = gpu.write_index(rp.source.views[mip]),
		size   = size,
		block  = 2,
	}
	gpu.cmd_set_pipeline(ctx.cb, rp.downsample.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, cube_groups(size))
}

@(private = "file")
run_reflection_probe_prefilter :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	r := f.renderer
	rp := &r.reflection_probes
	pf := f.reflection_probes
	gpu.cmd_set_pipeline(ctx.cb, r.sky.cube.prefilter.pipeline)
	for mip in 0 ..< rp.mips {
		face := max(rp.params.face >> mip, 1)
		push := Cube_Prefilter_Push {
			source        = gpu.read_index(rp.source.texture),
			output        = gpu.write_index(rp.cubes.views[mip]),
			face          = face,
			source_face   = rp.params.face,
			source_mips   = rp.mips,
			samples       = rp.params.samples,
			sampler_index = gpu.sampler_index(r.post.sampler),
			roughness     = sky_cube_roughness(mip, rp.mips),
			first_layer   = pf.target * 6,
		}
		gpu.cmd_push_constants(ctx.cb, &push)
		gpu.cmd_dispatch(ctx.cb, cube_groups(face))
	}
}
