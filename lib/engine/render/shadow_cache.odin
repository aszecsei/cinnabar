package render

import "core:math"
import "core:math/linalg"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// The shadow atlas's cache (see docs/rendering/lighting-and-shadows.md#cached-shadow-maps). With
// Shadow_Settings.atlas_cache, a view keeps a second atlas from frame to frame, the cache, with each spot, point and area
// light's static casters, and the dynamic ones past its dynamic shadow distance, baked in its slots. A light keeps its
// slots while it keeps its shadow. Each frame copies each light's slots from the cache into the frame's atlas and draws
// only its live casters over them: the dynamic casters within the distance (see casters.odin). A light draws its cache
// again only when its baked casters changed in its reach, when it moved or changed, or when the camera's distance from
// it changed enough to change the level of detail, so a still light over still casters draws its cache once.

SHADOW_CACHE_SHADER :: #load("../content/shaders/shadow_cache.hlsl.meta", string)
// The most slots that an atlas has (see max_shadow_views), which a cache's lights fit in.
ATLAS_MAX_SLOTS :: 64
// A light draws its cache again when the camera's distance from its reach has grown or shrunk by this factor since it
// drew: the level of detail that the shadow views take is the camera's, and a factor of two is a level.
SHADOW_LOD_DRIFT :: math.SQRT_TWO

// Atlas_Light is a light that takes slots of the atlas, as the cache keeps it: its entity, its position in the world,
// its direction and field of view, its range and guard band (see soft_guard), its views (1 for a spot light, 6 for a
// cube), and the camera's distance from its reach, at least 1 m, which the level of detail follows.
Atlas_Light :: struct {
	entity:    ecs.Entity,
	position:  ecs.World_Position,
	direction: [3]f32,
	fov:       f32,
	range:     f32,
	guard:     int,
	faces:     int,
	distance:  f32,
}

// Atlas_Cache_Light is a light whose slots the cache holds: the light as it drew them, its slots, the scene frame that
// it drew, whether a report of a dynamic caster waits for it to draw again, and whether it drew while the frame's
// inputs were not complete, so it draws again once they are.
Atlas_Cache_Light :: struct {
	light:       Atlas_Light,
	slots:       [6]int,
	drawn:       u64,
	pending:     bool,
	provisional: bool,
}

// Atlas_Cache is what a view's cache holds, and so what keeps it valid: the shadows' parameters, the first slot after
// the cascades, the scene frame that it was drawn in, whose changes are the last that it took, its lights, and the slots
// that the view drew live, whose casters it does not hold.
Atlas_Cache :: struct {
	params:     Shadow_Params,
	first_slot: int,
	frame:      u64,
	lights:     [ATLAS_MAX_SLOTS]Atlas_Cache_Light,
	count:      int,
	live:       Live_Slots,
}

// Atlas_Cache_Stats are a view's cache in its last frame, which the editor shows: the lights that it held, the slots that
// the frame copied from it, those that it drew, and those of them that a report drew on the budget.
Atlas_Cache_Stats :: struct {
	lights:    u32,
	copied:    u32,
	drawn:     u32,
	refreshed: u32,
}

// Atlas_Cache_State is a view's cache between frames, in View_State: its texture, as large as the atlas, and what it
// holds. cache is nil when the texture holds nothing that a frame can keep: before the first frame, after a new texture,
// after a frame that executed without the cache, and after a frame that drew nothing. Only a frame's commit changes it
// (see commit_atlas_cache), so a frame that fails leaves what the GPU last drew. A soft restart makes a new View_State.
Atlas_Cache_State :: struct {
	texture: gpu.Texture,
	size:    int,
	cache:   Maybe(Atlas_Cache),
	stats:   Atlas_Cache_Stats,
}

// Atlas_Plan is a light's slots this frame, and whether it draws them into the cache.
Atlas_Plan :: struct {
	slots:  [6]int,
	redraw: bool,
}

// Atlas_Frame is one frame's cache, in Shadow_Frame: whether it has one; for each shadow view, whether its slot is
// copied from the cache, so it draws only its live casters; the views whose slots the cache draws again, which cull
// again as cache views after the shadow views; what the frame keeps, which its commit stores; and the cache's texture.
@(private)
Atlas_Frame :: struct {
	enabled: bool,
	cached:  []bool,
	redraw:  [dynamic]int,
	next:    Atlas_Cache,
	stats:   Atlas_Cache_Stats,
	texture: Texture,
}

// Shadow_Cache_Push matches Push in shadow_cache.hlsl.
@(private)
Shadow_Cache_Push :: struct {
	cache: u32,
	copy:  u32,
}

// atlas_cache_plan is what a frame keeps of the cache, the one place that decides it, from the lights that take slots
// this frame, in their order, and the view's changes of casters (see view_caster_changes). A frame starts again, and
// every light draws, when the cache is off, when there is none or it missed a frame's changes (tracked is false or its
// frame is not the last), or when the parameters or the first slot changed. Otherwise a light that the cache holds
// keeps its slots, and the others take free ones. A light draws when it is new, when it moved or changed, when the
// camera's distance from it drifted by SHADOW_LOD_DRIFT, when a change meets its reach at once, or once the frame's inputs
// are complete after it drew without them. A report that meets its reach waits: at most budget slots draw for reports a
// frame, the lights that drew longest ago first. free_slot is the first slot that no light takes, or -1.
atlas_cache_plan :: proc(
	cache: Maybe(Atlas_Cache),
	enabled, tracked: bool,
	params: Shadow_Params,
	first_slot: int,
	frame: u64,
	lights: []Atlas_Light,
	changes: []Caster_Change,
	live: ^Live_Slots,
	complete: bool,
	allocator := context.allocator,
) -> (
	next: Atlas_Cache,
	plans: []Atlas_Plan,
	free_slot: int,
	stats: Atlas_Cache_Stats,
) {
	previous, kept := cache.?
	reset :=
		!enabled ||
		!tracked ||
		!kept ||
		previous.frame + 1 != frame ||
		previous.params != params ||
		previous.first_slot != first_slot
	next = {
		params     = params,
		first_slot = first_slot,
		frame      = frame,
	}
	if live != nil {
		next.live = live^
	}
	plans = make([]Atlas_Plan, len(lights), allocator)
	held := make([]int, len(lights), context.temp_allocator)
	pending := make([]bool, len(lights), context.temp_allocator)
	used: [ATLAS_MAX_SLOTS]bool
	// The lights that the cache holds keep their slots.
	for light, i in lights {
		held[i] = -1
		if reset {
			continue
		}
		for k in 0 ..< previous.count {
			old := previous.lights[k]
			if old.light.entity == light.entity && old.light.faces == light.faces {
				held[i] = k
				plans[i].slots = old.slots
				for face in 0 ..< light.faces {
					used[old.slots[face]] = true
				}
				break
			}
		}
	}
	// The new lights take the free slots, from the first after the cascades.
	cursor := first_slot
	for light, i in lights {
		if held[i] >= 0 {
			continue
		}
		plans[i].redraw = true
		for face in 0 ..< light.faces {
			for cursor < ATLAS_MAX_SLOTS && used[cursor] {
				cursor += 1
			}
			plans[i].slots[face] = min(cursor, ATLAS_MAX_SLOTS - 1)
			if cursor < ATLAS_MAX_SLOTS {
				used[cursor] = true
			}
		}
	}
	free_slot = -1
	for slot in first_slot ..< ATLAS_MAX_SLOTS {
		if !used[slot] {
			free_slot = slot
			break
		}
	}
	// What makes a held light draw again.
	for light, i in lights {
		k := held[i]
		if k < 0 {
			continue
		}
		old := previous.lights[k]
		redraw :=
			old.light.position != light.position ||
			old.light.direction != light.direction ||
			old.light.fov != light.fov ||
			old.light.range != light.range ||
			old.light.guard != light.guard
		drift := light.distance / max(old.light.distance, 1)
		redraw ||= drift > SHADOW_LOD_DRIFT || drift < 1 / SHADOW_LOD_DRIFT
		redraw ||= old.provisional && complete
		pending[i] = old.pending
		for change in changes {
			if redraw {
				break
			}
			meets := false
			if s, has := change.old.?; has && sphere_meets(s, light.position, light.range) {
				meets = true
			}
			if s, has := change.new.?; has && sphere_meets(s, light.position, light.range) {
				meets = true
			}
			if !meets {
				continue
			}
			if change.report {
				pending[i] = true
			} else {
				redraw = true
			}
		}
		plans[i].redraw = redraw
	}
	// The reports' budget, in slots, for the lights that drew longest ago first. The last light may pass it, so every
	// light's report draws in time.
	budget := params.refresh_slots
	for budget > 0 {
		oldest := -1
		for i in 0 ..< len(lights) {
			if held[i] < 0 || plans[i].redraw || !pending[i] {
				continue
			}
			if oldest < 0 || previous.lights[held[i]].drawn < previous.lights[held[oldest]].drawn {
				oldest = i
			}
		}
		if oldest < 0 {
			break
		}
		plans[oldest].redraw = true
		budget -= lights[oldest].faces
		stats.refreshed += u32(lights[oldest].faces)
	}
	for light, i in lights {
		entry := Atlas_Cache_Light {
			light = light,
			slots = plans[i].slots,
			drawn = frame,
			provisional = !complete,
		}
		if !plans[i].redraw {
			entry = previous.lights[held[i]]
			entry.pending = pending[i]
		}
		if next.count < ATLAS_MAX_SLOTS {
			next.lights[next.count] = entry
			next.count += 1
		}
		stats.lights += 1
		stats.copied += u32(light.faces)
		if plans[i].redraw {
			stats.drawn += u32(light.faces)
		}
	}
	return
}

// atlas_light_distance is the camera's distance from a light's reach, at least 1 m, from the light's position relative
// to the camera.
atlas_light_distance :: proc(position: [3]f32, range: f32) -> f32 {
	return max(linalg.length(position) - range, 1)
}

// ensure_atlas_cache syncs the cache's pipeline and makes its texture as large as the atlas, and says whether this frame
// can use it: until the pipeline compiles, the frame draws the atlas in full. A texture of another size holds nothing.
@(private)
ensure_atlas_cache :: proc(r: ^Renderer, s: ^Atlas_Cache_State, p: Shadow_Params) -> bool {
	if !pipeline_ready(r.platform, &r.shadows.cache_pipeline) || max_shadow_views(p) > ATLAS_MAX_SLOTS {
		return false
	}
	if s.size != p.atlas {
		r.platform.gpu_destroy_texture(s.texture)
		s.texture, s.size, s.cache = {}, 0, nil
		s.texture = r.platform.gpu_create_texture(
			{size = {u32(p.atlas), u32(p.atlas)}, format = SHADOW_FORMAT, usage = {.Depth_Stencil, .Sampled}, label = "shadow atlas cache"},
			nil,
		)
		if s.texture == {} {
			return false
		}
		s.size = p.atlas
	}
	return true
}

// sync_shadow_cache_pipeline syncs the pipeline that clears the cache's slots and copies them into the atlas.
@(private)
sync_shadow_cache_pipeline :: proc(r: ^Renderer) {
	sync_graphics_pipeline(
		&r.shadows.cache_pipeline,
		r.platform,
		r.residency.assets,
		{.Vertex, .Pixel},
		{depth_format = SHADOW_FORMAT, depth_compare = .Always, depth_write = true, label = "shadow cache"},
		r.reloaded,
	)
}

// atlas_cache_state_destroy frees a view's cache.
@(private)
atlas_cache_state_destroy :: proc(s: ^Atlas_Cache_State, platform: ^core.Platform_API) {
	platform.gpu_destroy_texture(s.texture)
	s^ = {}
}

// atlas_cache_stats is the frame's own view's cache in its last frame that executed, all 0 without the cache.
atlas_cache_stats :: proc(r: ^Renderer) -> Atlas_Cache_Stats {
	return stats_state(r).atlas_cache.stats
}

// plan_atlas_slots gives the frame's lights their slots: with the cache, as atlas_cache_plan keeps them, and without
// it, one after another from first_slot, as every frame draws them all. It gives the first slot that no light takes.
@(private)
plan_atlas_slots :: proc(f: ^Frame, sf: ^Shadow_Frame, lights: []Atlas_Light, first_slot: int) -> (plans: []Atlas_Plan, free_slot: int) {
	r := f.renderer
	s := &r.scene
	ac := &sf.cache
	state := &f.state.atlas_cache
	scene := f.scene_frame
	ac.redraw = make([dynamic]int, r.platform.frame_allocator)
	ac.enabled = f.shadow_settings.atlas_cache && len(lights) > 0 && ensure_atlas_cache(r, state, sf.params)
	if !ac.enabled {
		plans = make([]Atlas_Plan, len(lights), r.platform.frame_allocator)
		next := first_slot
		for light, i in lights {
			for face in 0 ..< light.faces {
				plans[i].slots[face] = next
				next += 1
			}
		}
		return plans, next
	}
	live := scene != nil ? scene.live : nil
	tracked := s.casters.frame == s.frame && live != nil
	changes: []Caster_Change
	if previous, kept := state.cache.?; kept && tracked {
		changes = view_caster_changes(&s.casters, live, &previous.live, r.platform.frame_allocator)
	}
	ac.next, plans, free_slot, ac.stats = atlas_cache_plan(
		state.cache,
		true,
		tracked,
		sf.params,
		first_slot,
		s.frame,
		lights,
		changes,
		live,
		reflection_probe_inputs_complete(f),
		r.platform.frame_allocator,
	)
	return
}

// add_atlas_cache_pass adds the pass that draws the cache's slots again, a piece for each, which clears its slot and
// draws its cache view's casters. It runs before the atlas, which copies the slots.
@(private)
add_atlas_cache_pass :: proc(f: ^Frame) {
	sf := f.shadows
	ac := &sf.cache
	g := f.graph
	ac.texture = import_texture(g, f.state.atlas_cache.texture, .Depth)
	if len(ac.redraw) == 0 {
		return
	}
	p := add_render_pass(g, "shadow cache", draw_shadow_cache, f, pieces = len(ac.redraw))
	depth(g, p, ac.texture, .Load)
	declare_scene_draws(f, p)
}

@(private = "file")
draw_shadow_cache :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.shadows
	view := sf.cache.redraw[ctx.piece]
	viewport := sf.viewports[view]
	gpu.cmd_set_viewport(ctx.cb, {f32(viewport.x), f32(viewport.y)}, {f32(viewport.z), f32(viewport.w)})
	gpu.cmd_set_scissor(ctx.cb, {i32(viewport.x), i32(viewport.y)}, {i32(viewport.z), i32(viewport.w)})
	pipeline := f.renderer.shadows.cache_pipeline.pipeline
	if pipeline == {} {
		return
	}
	push := Shadow_Cache_Push{}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_draw(ctx.cb, 3)
	draw_scene_view(f, ctx.cb, FIRST_SHADOW_VIEW + len(sf.views) + ctx.piece, .Depth)
}

// copy_cached_slot copies a cached view's slot from the cache into the atlas, in the atlas's pass, whose viewport is the
// slot.
@(private)
copy_cached_slot :: proc(ctx: ^Pass_Context, f: ^Frame) {
	pipeline := f.renderer.shadows.cache_pipeline.pipeline
	if pipeline == {} {
		return
	}
	push := Shadow_Cache_Push {
		cache = gpu.read_index(gpu_texture(ctx.graph, f.shadows.cache.texture)),
		copy  = 1,
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_draw(ctx.cb, 3)
}

// commit_atlas_cache keeps what a frame that executed drew its cache for, which the next frame's plan compares with. A
// frame whose culling did not run drew nothing into the cache, so it keeps none.
@(private)
commit_atlas_cache :: proc(data: rawptr) {
	f := (^Frame)(data)
	state := &f.state.atlas_cache
	scene := f.scene_frame
	if scene == nil || scene.view_constants == nil {
		state.cache, state.stats = nil, {}
		return
	}
	state.cache, state.stats = f.shadows.cache.next, f.shadows.cache.stats
}

// forget_atlas_cache drops the cache of a view whose frame executes without it: what changed in the meantime is not
// known.
@(private)
forget_atlas_cache :: proc(f: ^Frame) {
	on_executed(f.graph, proc(data: rawptr) {
		state := &(^Frame)(data).state.atlas_cache
		state.cache, state.stats = nil, {}
	}, f)
}
