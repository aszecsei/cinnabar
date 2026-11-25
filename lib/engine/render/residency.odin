package render

import "core:log"
import "core:math"
import "core:mem"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

// At most this many assets are resident at once: Sponza with its curtains, a USD stage, is about 250 meshes and textures,
// and Jungle Ruins about 1,200 with an instance set for each of its 778 point instancers (see
// docs/content/kinds/stages.md#limits).
MAX_RESIDENT :: 4096
// A resident mesh keeps at most this many submeshes. A mesh with more draws only these.
MAX_SUBMESHES :: 16
// An asset that cannot be made resident is tried again after this many frames.
RESIDENT_RETRY_FRAMES :: 60
// An asset that was used within this many frames is never evicted to meet the byte budget.
RESIDENT_KEEP_FRAMES :: 30
// A texture draws at a coarser mip only after it has wanted one for this many frames, so that a camera that turns does
// not make its textures stream back and forth. A finer mip streams at once.
MIP_DROP_FRAMES :: 120
// At most this many textures start to stream another mip in a frame.
MIP_STREAMS_PER_FRAME :: 8

// Resident_Mesh is a mesh asset's GPU buffers, and what drawing it needs from its blob. Its pointer is valid for the
// frame that it was given in. A paged mesh has no meshlet buffers: its meshlets are in the pool of pages. It has no
// positions, attributes or indices either until its level 0 is ready, which resident_level0 asks for.
Resident_Mesh :: struct {
	// Whether the mesh's meshlets and vertices are in pages, its id in the pool, and its level 0 (see mesh_pages.odin and
	// mesh_level0.odin).
	paged:             bool,
	pool_mesh:         u32,
	// Its range of the page table, for its mesh record.
	pages_first:       u32,
	page_count:        u32,
	level0:            Level0,
	// The frame of the last failure to assemble level 0, which was logged, or 0.
	level0_failed_at:  u64,
	positions:         gpu.Buffer,
	attributes:        gpu.Buffer,
	indices:           gpu.Buffer,
	// The meshlets of every level of detail, which the mesh shader path draws (see docs/rendering/assets.md#gpu-residency).
	meshlets:          gpu.Buffer,
	meshlet_vertices:  gpu.Buffer,
	meshlet_triangles: gpu.Buffer,
	// The trees over each level's groups of meshlets, which select meshlets walks (see
	// docs/rendering/gpu-scene.md#mesh-shader-path), for a mesh cooked with them.
	meshlet_nodes:     gpu.Buffer,
	// For a mesh cooked with a skin stream, each vertex's joints and weights, which skin_meshes.hlsl poses the vertices
	// by (see docs/rendering/gpu-scene.md#skinned-meshes).
	skin:              gpu.Buffer,
	// The impostor's atlas, for a mesh cooked with one, the side of its frames in texels, and how far it may be from the
	// mesh, in meters (see docs/rendering/gpu-scene.md#impostors).
	impostor:          gpu.Buffer,
	impostor_size:     u32,
	impostor_error:    f32,
	// Numbers the swap that made these resources resident, which no other mesh's swap shares: the shadow caches take a
	// new one as a change of what the mesh draws, whatever its bounds and counts (see casters.odin).
	generation:        u32,
	index_format:      gpu.Index_Format,
	index_count:       u32,
	vertex_count:      u32,
	attribute_stride:  u32,
	flags:             format.Mesh_Flags,
	bounds:            format.Mesh_Bounds,
	submesh_count:     u32,
	submeshes:         [MAX_SUBMESHES]Resident_Submesh,
	submesh_bounds:    [MAX_SUBMESHES]format.Mesh_Bounds,
	// For instanced draws on the mesh shader path (see docs/rendering/gpu-scene.md#instanced-meshes): each submesh's
	// first meshlet of each level bucket, from its first, at its last level for a bucket past it; and for each level
	// below the last bucket's, the largest parent error of the mesh's meshlets there and how far their parents'
	// spheres reach from the mesh's center, F32_MAX past the mesh's last level.
	level_first:       [MAX_SUBMESHES][INSTANCE_LEVEL_BUCKETS]u32,
	levels:            [INSTANCE_LEVEL_BUCKETS][2]f32,
	// With Ray_Query, the bottom-level acceleration structure of every triangle, which the renderer builds the first
	// frame after the mesh is ready and then compacts, and where it is in that (see
	// docs/rendering/ray-scene.md#acceleration-structure).
	accel:             gpu.Accel_Struct,
	accel_state:       Mesh_Accel,
}

// Resident_Submesh is a submesh's ranges of its mesh's indices, meshlets and meshlet nodes, the first root_count of
// which are its levels' roots.
Resident_Submesh :: struct {
	first_index:   u32,
	index_count:   u32,
	first_meshlet: u32,
	meshlet_count: u32,
	first_node:    u32,
	node_count:    u32,
	root_count:    u32,
}

// Resident_Instance_Set is an instance set asset's GPU buffers, its instances and its cells, and what culling them
// needs from its blob (see docs/rendering/gpu-scene.md#instanced-meshes).
Resident_Instance_Set :: struct {
	instances:  gpu.Buffer,
	cells:      gpu.Buffer,
	count:      u32,
	cell_count: u32,
	// A sphere about every instance's position, in the set's space, and the largest scale of any instance's axes, which
	// the caster tracking bounds the set's shadow by (see casters.odin).
	center:     [3]f32,
	radius:     f32,
	max_scale:  f32,
	// Each cell's sphere and the hash of its instances, which a newer version is compared with (see
	// residency_changed_cells). It is in the heap.
	cells_cpu:  []Set_Cell,
}

// Set_Cell is an instance set's cell on the CPU: its sphere about its instances' positions, in the set's space, and the
// largest scale of their axes, and a hash of what its instances draw: their poses, not their index in the instancer.
Set_Cell :: struct {
	center:    [3]f32,
	radius:    f32,
	max_scale: f32,
	hash:      u64,
}

// Changed_Set_Cell is a cell of an instance set that a newer version of it adds, removes or changes (as one removed and
// one added): the cell's sphere before and after, nil where it was not or is not.
Changed_Set_Cell :: struct {
	guid: format.Guid,
	old:  Maybe(Set_Cell),
	new:  Maybe(Set_Cell),
}

// A set whose newer version changes more cells than this changes as a whole, in one Changed_Set_Cell.
MAX_CHANGED_CELLS :: 32

// Resident_Texture is a texture asset's GPU texture.
Resident_Texture :: struct {
	texture:      gpu.Texture,
	pixel_format: gpu.Format,
	size:         [2]u32,
	mip_count:    u32,
	usage:        format.Texture_Usage,
	// What its layers are, and how many. A shader must read it through the type of its dimension.
	dimension:    format.Texture_Dimension,
	layer_count:  u32,
	// How the texture asks to be sampled (see texture_sampler).
	sampler:      format.Texture_Sampler,
	// For a virtual texture, its record's index in the pool of virtual texture pages and 1, which a material names it by
	// (see VIRTUAL_TEXTURE_BIT); 0 for any other texture. Its texture is then the tail's, whose mip 0 is the asset's mip
	// tail_mip, and size and mip_count are the asset's.
	virtual:      u32,
	// The asset's mip that the texture's mip 0 is, for a texture that is not virtual: its coarser mips stream when what
	// draws it is small on the screen (see resident_texture_want). size and mip_count are the asset's.
	top_mip:      u32,
}

// Residency gives the GPU resources of the texture and mesh assets that the renderer draws, by GUID (see
// docs/rendering/assets.md#gpu-residency). It lives in Game_State and holds handles only, so a code reload keeps it.
Residency :: struct {
	platform:      ^core.Platform_API,
	assets:        ^asset.Assets,
	entries:       [MAX_RESIDENT]Resident_Entry,
	count:         int,
	// Each entry's index, by its GUID and kind.
	index:         map[Resident_Key]int,
	frame:         u64,
	// Whether meshes get acceleration structures, which the renderer sets the first frame that traces (see
	// residency_enable_accels).
	accels:        bool,
	// What this asks for is for a thumbnail, not the world, so it can go when the thumbnails are done.
	baking:        bool,
	// The pages of the paged meshes that are resident (see mesh_pages.odin).
	pool:          Mesh_Pool,
	// The pages of the virtual textures that are resident (see texture_pages.odin).
	texture_pool:  Texture_Pool,
	// When assets that nothing uses go, and how their textures' mips follow their size on the screen.
	policy:        Residency_Policy,
	// Textures take the mip that they want at once, coarser as well as finer, so that what a frame draws does not
	// depend on what drew before it, as a render out needs (see residency_set_exact_mips).
	exact_mips:    bool,
	// What is resident, and what the policy did. Only set_bytes writes stats.resident_bytes.
	stats:         Residency_Stats,
	// The textures whose finer mips came in this frame, which change the shadows of masked materials (see
	// residency_refined).
	refined:       [dynamic]Refined_Texture,
	// The cells of instance sets that a newer version changed this frame, which change the shadows of the slots that draw
	// the set (see residency_changed_cells).
	changed_cells: [dynamic]Changed_Set_Cell,
	// The count of the meshes that swapped in, which numbers each swap (see Resident_Mesh.generation).
	swaps:         u32,
}

// residency_changed_cells are the cells of instance sets whose newer version swapped in this frame, that it added,
// removed or changed. A set that changes more than MAX_CHANGED_CELLS cells is one cell: the whole set.
residency_changed_cells :: proc(r: ^Residency) -> []Changed_Set_Cell {
	return r.changed_cells[:]
}

// Refined_Texture is a texture that drew at a finer mip from this frame on: its size at mip 0, and the mip that drew
// before, at least where the finer one is.
Refined_Texture :: struct {
	guid: format.Guid,
	size: [2]u32,
	mip:  u32,
}

// residency_refined are the textures that drew at a finer mip from this frame on.
residency_refined :: proc(r: ^Residency) -> []Refined_Texture {
	return r.refined[:]
}

// Residency_Policy is when the residency lets go of what the frames do not use (see
// docs/rendering/assets.md#gpu-residency). The renderer sets it from the quality each frame.
Residency_Policy :: struct {
	// An asset that has not been asked for in this many frames is unloaded. 0 unloads nothing by idleness.
	idle_frames:  u64,
	// While the assets that are resident hold more bytes than this, the one that was used longest ago is unloaded, if it
	// was not used in the last RESIDENT_KEEP_FRAMES. 0 is no budget.
	budget_bytes: u64,
	// How many mips coarser than its size on the screen says a texture streams: a negative number is finer.
	mip_bias:     i32,
}

// Residency_Stats is what the residency holds, for the editor's resource monitor.
Residency_Stats :: struct {
	// The GPU memory of the buffers and textures of the assets that are resident, not the pools' pages.
	resident_bytes: u64,
	// How many assets are resident.
	entries:        int,
	// How many assets were unloaded, and how many times a texture streamed another mip, since the start.
	evicted:        u64,
	mip_streams:    u64,
}

@(private)
Resident_Key :: struct {
	guid: format.Guid,
	kind: format.Asset_Kind,
}

@(private)
Resident_Entry :: struct {
	guid:                   format.Guid,
	kind:                   format.Asset_Kind,
	// The asset, once loaded. Every source keeps it, so a live mesh that is let go streams its asset's blob again.
	handle:                 asset.Handle,
	// The resources that draw, from the blob of version, once ready.
	current:                Resident_Resources,
	version:                u32,
	ready:                  bool,
	// What the resources come from, and what streams in to replace current. Only change writes them.
	source:                 Resident_Source,
	stream:                 Maybe(Resident_Stream),
	// The frame of the last failure, which was logged, or 0.
	failed_at:              u64,
	// This version of a texture was read as another dimension, which was logged.
	wrong_dimension_logged: bool,
	// Who has asked for it: a thumbnail, or anything else, which keeps it.
	baked:                  bool,
	world:                  bool,
	// The frame of the last request, which the policy unloads by.
	used_at:                u64,
	// The GPU memory of current, which stats.resident_bytes sums.
	bytes:                  u64,
	// What asked for a texture that is not virtual by its size on the screen (see Mip_Want).
	want:                   Mip_Want,
	// The frame that the texture's wanted mip first was coarser than its top mip, if it is.
	coarser_since:          Maybe(u64),
}

// Mip_Want is the last request for the mips of a texture that is not virtual, with the frame that made it, nil if
// nothing asked. A request is current in its frame and the next. Without a current one nothing draws the texture, so it
// wants its last mip only (see wanted_mip), and a new version of it streams from the mip that it has (see first_mip).
@(private)
Mip_Want :: union {
	Mip_Full,
	Mip_Sized,
}

// Mip_Full is a reader that reads every mip: whatever is not a material.
@(private)
Mip_Full :: struct {
	frame: u64,
}

// Mip_Sized is the largest size in pixels across that what draws the texture shows at, which is a material's.
@(private)
Mip_Sized :: struct {
	pixels: f32,
	frame:  u64,
}

// Resident_Resources is an asset's GPU resources, as the variant of its kind. An entry's current resources are that
// variant from when the entry is made, empty until they are ready, so a reader's pointer to them is always valid; what
// streams in has it from when its stream starts.
@(private)
Resident_Resources :: union {
	Resident_Mesh,
	Texture_Resources,
	Resident_Instance_Set,
}

// Texture_Resources is a texture asset's resources: the texture that draws, and a virtual texture's whole texture, for
// the readers that cannot sample pages, once one asked for it (see texture_whole.odin), with the frame of the last
// failure to assemble it, which was logged, or 0.
@(private)
Texture_Resources :: struct {
	texture:         Resident_Texture,
	whole:           Resident_Texture,
	whole_state:     Texture_Whole,
	whole_failed_at: u64,
}

// empty_resources is the empty variant of a kind's resources, nil for a kind that is not resident.
@(private = "file")
empty_resources :: proc(kind: format.Asset_Kind) -> Resident_Resources {
	#partial switch kind {
	case .Mesh:
		return Resident_Mesh{}
	case .Texture:
		return Texture_Resources{}
	case .Instance_Set:
		return Resident_Instance_Set{}
	}
	return nil
}

// Resident_Source is what an entry's resources come from.
@(private)
Resident_Source :: union #no_nil {
	Asset_Source,
	Live_Source,
	Released_Source,
	Evicted_Source,
	Stale_Source,
}

// Asset_Source is the asset's blob.
@(private)
Asset_Source :: struct {}

// Live_Source is a live mesh: the editor's unsaved mesh, streamed from memory in place of the asset's blob (see
// set_live). next is the newest blob that arrived while one streamed, in the heap, which streams when that one is in.
@(private)
Live_Source :: struct {
	next: []byte,
}

// Released_Source is a live mesh that was let go. Its buffers draw until the asset's blob is in, whatever its version,
// and go if the asset's blob cannot stream, as what the editor gave up must not stay on screen.
@(private)
Released_Source :: struct {}

// Evicted_Source is an asset that was unloaded because nothing used it: it has no resources, and no blob in memory. The
// next request streams it again, which makes it an Asset_Source.
@(private)
Evicted_Source :: struct {}

// Stale_Source is an asset whose newest blob could not be made resident: the resources of an older blob draw. It is
// not unloaded, as the next request would stream the blob that failed, and it does not stream mips of it. Only a newer
// blob streams again, which makes it an Asset_Source.
@(private)
Stale_Source :: struct {}

// Resident_Stream is new resources that stream in, from the blob of version, which replace current when their
// transfers are done, so the old version draws until then.
@(private)
Resident_Stream :: struct {
	pending:        Resident_Resources,
	version:        u32,
	// A mesh's seven streams, its impostor and its skin, a texture's one, or an instance set's two.
	transfers:      [9]gpu.Transfer,
	transfer_count: int,
	// It streams in over a live mesh that was let go, which must not go on drawing if this does not come in.
	released:       bool,
	// The GPU memory of pending.
	bytes:          u64,
}

// Resident_Event is what changes an entry's source or stream, which change applies.
@(private = "file")
Resident_Event :: union #no_nil {
	Event_Live_Blob,
	Event_Let_Go,
	Event_Landed,
	Event_Stream_Failed,
	Event_Stream_Superseded,
	Event_Asset_Streaming,
	Event_Asset_Failed,
	Event_Evicted,
	Event_Mips_Failed,
}

// The editor sent a live mesh's blob.
@(private = "file")
Event_Live_Blob :: struct {
	blob: []byte,
}

// The editor let the live mesh go.
@(private = "file")
Event_Let_Go :: struct {}

// The stream's transfers are done.
@(private = "file")
Event_Landed :: struct {}

// What streams cannot come in: a page of a paged mesh's roots was not what its table said.
@(private = "file")
Event_Stream_Failed :: struct {
	reason: string,
}

// The asset's blob was swapped while what streams was still coming in from the blob before it, which cannot finish: a
// paged mesh's root pages are in the head that went.
@(private = "file")
Event_Stream_Superseded :: struct {}

// The asset's blob started to stream.
@(private = "file")
Event_Asset_Streaming :: struct {
	stream: Resident_Stream,
}

// The asset's blob could not stream.
@(private = "file")
Event_Asset_Failed :: struct {
	reason: string,
}

// The asset was not used for longer than the policy allows: its resources go, and it streams again when it is asked for.
@(private = "file")
Event_Evicted :: struct {}

// The mips of a texture that draws could not be made resident: it goes on drawing the mips that it has.
@(private = "file")
Event_Mips_Failed :: struct {
	reason: string,
}

residency_init :: proc(r: ^Residency, platform: ^core.Platform_API, assets: ^asset.Assets) {
	// The table is too large for a temporary on the stack, so it is zeroed in place.
	mem.zero_item(r)
	r.platform, r.assets = platform, assets
	r.index = make(map[Resident_Key]int, platform.heap_allocator)
	mesh_pool_init(&r.pool, platform)
	texture_pool_init(&r.texture_pool, platform)
}

// residency_reload keeps every resident asset after a code reload.
residency_reload :: proc(r: ^Residency, platform: ^core.Platform_API) {
	r.platform = platform
}

// residency_destroy destroys every resident resource. Call it from the game's shutdown.
residency_destroy :: proc(r: ^Residency) {
	for &e in r.entries[:r.count] {
		destroy_resources(r, &e.current)
		if s, streaming := &e.stream.(Resident_Stream); streaming {
			destroy_resources(r, &s.pending)
		}
		if live, is_live := &e.source.(Live_Source); is_live {
			free_next(r, &live.next)
		}
	}
	r.count = 0
	delete(r.index)
	delete(r.refined)
	delete(r.changed_cells)
	mesh_pool_destroy(&r.pool, r.platform)
	texture_pool_destroy(&r.texture_pool, r.platform)
}

// residency_set_mesh_pool sets the budget of the pool of mesh pages, in MiB. The pool is made again at its new size at
// the next update, and every page streams in again, the roots first.
residency_set_mesh_pool :: proc(r: ^Residency, megabytes: u32) {
	r.pool.wanted_slots = mesh_pool_slots(megabytes)
}

// residency_set_texture_pool sets the budget of the pool of virtual texture pages, in MiB. The atlases are made again at
// their new size at the next update, and every page streams in again, the roots first.
residency_set_texture_pool :: proc(r: ^Residency, megabytes: u32) {
	bytes := texture_pool_bytes(megabytes)
	if r.texture_pool.quality_bytes != bytes {
		// A new budget replaces what the video memory had limited it to.
		r.texture_pool.quality_bytes, r.texture_pool.limit_bytes = bytes, 0
	}
}

// residency_set_quality sets the policy from a quality: its budget in MiB, and its frames of idleness.
residency_set_quality :: proc(r: ^Residency, q: Quality) {
	residency_set_policy(
		r,
		{
			idle_frames = u64(q.residency_idle),
			budget_bytes = u64(q.residency_budget) * mem.Megabyte,
			mip_bias = i32(q.texture_mip_bias),
		},
	)
}

// residency_set_exact_mips sets whether a texture that wants a coarser mip streams it at once, rather than after
// MIP_DROP_FRAMES. A render out sets it while it runs, so two runs draw the same mips whatever was drawn before them.
residency_set_exact_mips :: proc(r: ^Residency, exact: bool) {
	r.exact_mips = exact
}

// residency_set_policy sets when the residency unloads what nothing uses, and how coarse its textures' mips may be.
residency_set_policy :: proc(r: ^Residency, policy: Residency_Policy) {
	r.policy = policy
}

// residency_stats is what the residency holds, and how often it unloaded and streamed mips.
residency_stats :: proc(r: ^Residency) -> Residency_Stats {
	return r.stats
}

// texture_stream_stats is what the pool of virtual texture pages holds and what it waits for, and the video memory that
// the process uses of its budget.
texture_stream_stats :: proc(r: ^Residency) -> Texture_Stream_Stats {
	return r.texture_pool.stats
}

// mesh_stream_stats is what the pool of mesh pages holds and what it waits for.
mesh_stream_stats :: proc(r: ^Residency) -> Mesh_Stream_Stats {
	return r.pool.stats
}

// resident_pin keeps every page of a paged mesh resident for this frame, and asks for the ones that are not. What draws
// a mesh's meshlets without the selection, which tests every one, pins it: instanced meshes and the view model.
resident_pin :: proc(r: ^Residency, m: ^Resident_Mesh) {
	if m.paged {
		mesh_pool_pin(&r.pool, m.pool_mesh)
	}
}

// residency_update starts a frame: it swaps in the resources whose transfers are done, streams a new version of each
// asset whose blob asset.poll swapped, and streams the mips that the textures' sizes on the screen want. Then it unloads
// what the policy lets go of: the one point of the frame where no pointer that a resident_* call gave is alive. Call it
// once a frame, before drawing.
residency_update :: proc(r: ^Residency) {
	r.frame += 1
	mesh_pool_update(&r.pool, r.platform, r.assets)
	texture_pool_update(&r.texture_pool, r.platform, r.assets)
	if r.refined == nil {
		r.refined = make([dynamic]Refined_Texture, r.platform.heap_allocator)
	}
	clear(&r.refined)
	if r.changed_cells == nil {
		r.changed_cells = make([dynamic]Changed_Set_Cell, r.platform.heap_allocator)
	}
	clear(&r.changed_cells)
	// The virtual textures' pages that came in since the last update.
	for p in texture_pool_refined(&r.texture_pool) {
		append(&r.refined, p)
	}
	mip_streams := 0
	defer residency_evict(r)
	for &e in r.entries[:r.count] {
		switch &v in e.current {
		case Texture_Resources:
			// A virtual texture's whole texture comes in over some frames, for what asked for it.
			if e.ready && v.texture.virtual != 0 {
				advance_whole(r, &e, &v)
			}
		case Resident_Mesh:
			// A paged mesh's level 0 comes in over some frames, for what asked for it, and for the ray scene.
			if e.ready && v.paged {
				if r.accels {
					resident_level0(r, &v)
				}
				advance_level0(r, &v)
			}
		case Resident_Instance_Set:
		}
		if s, streaming := &e.stream.(Resident_Stream); streaming {
			done := true
			// Every transfer is asked, not only up to the first that is not done, so each one's answer is as fresh.
			for t in s.transfers[:s.transfer_count] {
				if !r.platform.gpu_transfer_done(t) {
					done = false
				}
			}
			// A paged mesh is in when its roots are in the pool, and a virtual texture when its root is.
			pooled := false
			failure: string
			switch v in s.pending {
			case Resident_Mesh:
				if v.paged {
					pooled = true
					if mesh_pool_failed(&r.pool, v.pool_mesh) {
						failure = "has a root page that is not what its table names"
					} else {
						done &&= mesh_pool_ready(&r.pool, v.pool_mesh)
					}
				}
			case Texture_Resources:
				if v.texture.virtual != 0 {
					pooled = true
					if texture_pool_failed(&r.texture_pool, v.texture.virtual) {
						failure = "has a page that is not what its table names"
					} else {
						done &&= texture_pool_ready(&r.texture_pool, v.texture.virtual)
					}
				}
			case Resident_Instance_Set:
			}
			if failure != "" {
				change(r, &e, Event_Stream_Failed{failure})
				continue
			}
			// Its roots come from the head of the version that it streams, which a newer blob has replaced.
			superseded :=
				pooled && !done && e.handle != {} && asset.version(r.assets, e.handle) != s.version
			if done {
				change(r, &e, Event_Landed{})
			}
			if !superseded {
				continue
			}
			// The newer version streams below, in this frame.
			change(r, &e, Event_Stream_Superseded{})
		}
		// A live mesh draws from memory, whatever the asset's blob does.
		switch _ in e.source {
		case Live_Source:
		case Released_Source:
			// The asset's blob streams again, whatever its version. With no asset to load, the buffers go now, not when
			// something next draws the mesh.
			start_streaming(r, &e)
		case Asset_Source, Stale_Source:
			// A failed version keeps its number, so only a newer blob tries again.
			if e.handle != {} && asset.version(r.assets, e.handle) != e.version {
				start_streaming(r, &e)
			}
		case Evicted_Source:
		// A newer blob waits until something asks for the asset.
		}
		if mip_streams < MIP_STREAMS_PER_FRAME && retarget_mips(r, &e) {
			mip_streams += 1
		}
	}
}

// residency_evict unloads the assets that the policy lets go of: first each that nothing asked for in policy.idle_frames,
// then, while the resident bytes are over the budget, the one that was used longest ago, if it was not used in the last
// RESIDENT_KEEP_FRAMES. Live and released meshes, what streams, and what only thumbnails asked for stay: the last go with
// residency_release_baked. An asset that is unloaded keeps its entry, so a later request streams it again.
@(private = "file")
residency_evict :: proc(r: ^Residency) {
	for &e in r.entries[:r.count] {
		if r.policy.idle_frames > 0 &&
		   evictable(&e) &&
		   r.frame - e.used_at > r.policy.idle_frames {
			evict(r, &e)
		}
	}
	for r.policy.budget_bytes > 0 && r.stats.resident_bytes > r.policy.budget_bytes {
		oldest: ^Resident_Entry
		for &e in r.entries[:r.count] {
			if e.bytes == 0 || !evictable(&e) || r.frame - e.used_at <= RESIDENT_KEEP_FRAMES {
				continue
			}
			if oldest == nil || e.used_at < oldest.used_at {
				oldest = &e
			}
		}
		if oldest == nil {
			break
		}
		evict(r, oldest)
	}
	r.stats.entries = 0
	for &e in r.entries[:r.count] {
		r.stats.entries += int(e.ready)
	}
}

// evictable is whether an entry may be unloaded: it draws from its asset's blob, and nothing streams in to replace it.
@(private = "file")
evictable :: proc(e: ^Resident_Entry) -> bool {
	_, from_asset := e.source.(Asset_Source)
	return from_asset && e.ready && e.stream == nil && (e.world || !e.baked)
}

@(private = "file")
evict :: proc(r: ^Residency, e: ^Resident_Entry) {
	if change(r, e, Event_Evicted{}) {
		r.stats.evicted += 1
	}
}

// resident_mesh gives a mesh asset's resources, and whether they are ready. The first call loads the asset and
// streams its data. Until it is ready, draw nothing.
resident_mesh :: proc(r: ^Residency, guid: format.Guid) -> (mesh: ^Resident_Mesh, ready: bool) {
	e := entry(r, guid, .Mesh) or_return
	mesh = (&e.current.(Resident_Mesh)) or_return
	// A paged mesh draws nothing while the pool of pages was made again and the GPU's table is still the old pool's.
	return mesh, e.ready && (!mesh.paged || mesh_pool_drawable(&r.pool))
}

// resident_whole_mesh gives a mesh asset's resources as resident_mesh does, for what draws its vertices by index: it is
// ready when the mesh's positions, attributes and indices are resident too, which a paged mesh's are some frames after
// the first call (see resident_level0).
resident_whole_mesh :: proc(
	r: ^Residency,
	guid: format.Guid,
) -> (
	mesh: ^Resident_Mesh,
	ready: bool,
) {
	mesh, ready = resident_mesh(r, guid)
	if ready {
		ready = resident_level0(r, mesh)
	}
	return
}

// resident_failed is whether a mesh asset could not be made resident, so what waits for it should not.
resident_failed :: proc(r: ^Residency, guid: format.Guid) -> bool {
	i, found := r.index[{guid, .Mesh}]
	return !found || r.entries[i].failed_at != 0
}

// resident_streaming is how many assets are on their way to the GPU.
resident_streaming :: proc(r: ^Residency) -> (count: int) {
	for &e in r.entries[:r.count] {
		count += int(e.stream != nil)
	}
	return
}

// residency_unsettled is how many of the entries that the last frames asked for would draw differently in a later frame:
// those that are not ready or still stream, and the textures whose top mip is not the one that they want. A
// render out waits until it is 0 (see docs/editor/cutscene-editor.md#render-out), so no frame shows a lower mip, nor,
// with exact mips, a finer one that an earlier frame left.
residency_unsettled :: proc(r: ^Residency) -> (count: int) {
	for &e in r.entries[:r.count] {
		// A failed entry draws its default in every frame until its retry, so it does not hold the frame back.
		if _, wanted := current_want(r, &e); !wanted || e.failed_at != 0 {
			continue
		}
		if !e.ready || e.stream != nil {
			count += 1
			continue
		}
		if res, is_texture := &e.current.(Texture_Resources);
		   is_texture && res.texture.virtual == 0 {
			if res.texture.top_mip != wanted_mip(r, &e, res.texture.size, res.texture.mip_count) {
				count += 1
			}
		}
	}
	return
}

// residency_baked_count is how many entries only thumbnails asked for.
residency_baked_count :: proc(r: ^Residency) -> (count: int) {
	for &e in r.entries[:r.count] {
		count += int(e.baked && !e.world)
	}
	return
}

// residency_release_baked gives back what only thumbnails asked for, and gives how many it let go. Something that streams
// stays for a later call, and a thumbnail that asks again makes it resident again. The GPU's destroys wait for the frames
// that use what they destroy.
residency_release_baked :: proc(r: ^Residency) -> (released: int) {
	for i := r.count - 1; i >= 0; i -= 1 {
		e := &r.entries[i]
		_, live := e.source.(Live_Source)
		if !e.baked || e.world || e.stream != nil || live {
			continue
		}
		destroy_resources(r, &e.current)
		set_bytes(r, e, 0)
		if e.handle != {} {
			asset.unload(r.assets, e.handle)
		}
		delete_key(&r.index, Resident_Key{e.guid, e.kind})
		r.count -= 1
		if i != r.count {
			r.entries[i] = r.entries[r.count]
			r.index[{r.entries[i].guid, r.entries[i].kind}] = i
		}
		r.entries[r.count] = {}
		released += 1
	}
	return
}

// resident_instance_set gives an instance set asset's resources, and whether they are ready, as resident_mesh does.
resident_instance_set :: proc(
	r: ^Residency,
	guid: format.Guid,
) -> (
	set: ^Resident_Instance_Set,
	ready: bool,
) {
	e := entry(r, guid, .Instance_Set) or_return
	set = (&e.current.(Resident_Instance_Set)) or_return
	return set, e.ready
}

// resident_texture gives a texture asset's resources, and whether they are ready. Until it is ready, use a default
// for its usage. A shader reads a texture through the type of its dimension, and any other is undefined, so a texture of
// another dimension is never ready, which is logged once for each of its versions.
resident_texture :: proc(
	r: ^Residency,
	guid: format.Guid,
	dimension := format.Texture_Dimension.D2,
) -> (
	texture: ^Resident_Texture,
	ready: bool,
) {
	return resident_texture_of(r, guid, dimension, dimension)
}

// resident_texture_want says that a material draws a texture at most this many pixels across on the screen this frame,
// which decides what mip of it is resident (see texture_mip_for_pixels). Call it before the material's
// resident_virtual_texture, so the texture streams in at the mip that it wants. Every other reader wants all of the mips.
resident_texture_want :: proc(r: ^Residency, guid: format.Guid, pixels: f32) {
	e, ok := find_entry(r, guid, .Texture)
	if !ok {
		return
	}
	merge_want(r, e, Mip_Sized{max(pixels, 1), r.frame})
}

// merge_want makes a request for a frame's mips the texture's: it replaces an older one, and joins one of this frame, in
// which every mip wins, and the largest size of the others.
@(private = "file")
merge_want :: proc(r: ^Residency, e: ^Resident_Entry, request: Mip_Want) {
	if full, is_full := e.want.(Mip_Full); is_full && full.frame == r.frame {
		return
	}
	if sized, is_sized := e.want.(Mip_Sized); is_sized && sized.frame == r.frame {
		if more, also_sized := request.(Mip_Sized); also_sized {
			e.want = Mip_Sized{max(sized.pixels, more.pixels), r.frame}
			return
		}
	}
	e.want = request
}

// current_want is the size in pixels that the current request wants, max(f32) for every mip, or false if none is.
@(private = "file")
current_want :: proc(r: ^Residency, e: ^Resident_Entry) -> (pixels: f32, ok: bool) {
	switch want in e.want {
	case Mip_Full:
		return max(f32), r.frame - want.frame <= 1
	case Mip_Sized:
		return want.pixels, r.frame - want.frame <= 1
	}
	return 0, false
}

// resident_virtual_texture gives a texture asset's resources as a material samples it, and whether they are ready: a
// virtual texture is not assembled whole, and its resources are its tail's, with its record in virtual (see
// VIRTUAL_TEXTURE_BIT). It is not ready while the pool's atlases were made again and no pass has copied the table for
// them. Until it is ready, use a default for its usage. Every other reader of a texture asks resident_texture, which
// gives a virtual texture's whole texture.
resident_virtual_texture :: proc(
	r: ^Residency,
	guid: format.Guid,
) -> (
	texture: ^Resident_Texture,
	ready: bool,
) {
	e := entry(r, guid, .Texture, material = true) or_return
	res := (&e.current.(Texture_Resources)) or_return
	texture = &res.texture
	if e.ready && texture.dimension != .D2 {
		log_wrong_dimension(e, texture, .D2)
		return texture, false
	}
	virtual := texture.virtual != 0
	return texture, e.ready && (!virtual || texture_pool_drawable(&r.texture_pool))
}

// resident_texture_of gives a texture asset's resources as resident_texture does, for a reader that takes either of two
// dimensions and reads the one that it gets.
resident_texture_of :: proc(
	r: ^Residency,
	guid: format.Guid,
	first, second: format.Texture_Dimension,
) -> (
	texture: ^Resident_Texture,
	ready: bool,
) {
	e := entry(r, guid, .Texture) or_return
	res := (&e.current.(Texture_Resources)) or_return
	texture = &res.texture
	if e.ready && texture.dimension != first && texture.dimension != second {
		log_wrong_dimension(e, texture, first)
		return texture, false
	}
	if texture.virtual != 0 {
		return resident_whole(r, res)
	}
	// A reader that is not a material reads every mip, so it waits for the full chain, which its request asked for.
	return texture, e.ready && texture.top_mip == 0
}

@(private = "file")
log_wrong_dimension :: proc(
	e: ^Resident_Entry,
	texture: ^Resident_Texture,
	wanted: format.Texture_Dimension,
) {
	if !e.wrong_dimension_logged {
		e.wrong_dimension_logged = true
		buffer: [32]u8
		log.errorf(
			"render: texture %s is a %v, and is read as a %v",
			format.guid_format(e.guid, &buffer),
			texture.dimension,
			wanted,
		)
	}
}

// entry finds an asset's entry, or makes one and starts streaming, and notes that the frame uses it. A material's
// texture does not want its whole chain (see resident_texture_want). An asset that cannot load is tried again after
// RESIDENT_RETRY_FRAMES, and logged once. A live mesh never loads its asset.
@(private = "file")
entry :: proc(
	r: ^Residency,
	guid: format.Guid,
	kind: format.Asset_Kind,
	material := false,
) -> (
	e: ^Resident_Entry,
	ok: bool,
) {
	e = find_entry(r, guid, kind) or_return
	e.used_at = r.frame
	if kind == .Texture && !material {
		merge_want(r, e, Mip_Full{r.frame})
	}
	if r.baking {
		e.baked = true
	} else {
		e.world = true
	}
	_, live := e.source.(Live_Source)
	if !live &&
	   e.handle == {} &&
	   e.stream == nil &&
	   (e.failed_at == 0 || r.frame - e.failed_at >= RESIDENT_RETRY_FRAMES) {
		start_streaming(r, e)
	}
	return e, true
}

// find_entry finds an asset's entry, or makes an empty one.
@(private = "file")
find_entry :: proc(
	r: ^Residency,
	guid: format.Guid,
	kind: format.Asset_Kind,
) -> (
	e: ^Resident_Entry,
	ok: bool,
) {
	if guid == {} {
		return
	}
	if i, found := r.index[{guid, kind}]; found {
		return &r.entries[i], true
	}
	slot := r.count
	if r.count == MAX_RESIDENT {
		// The asset that was unloaded longest ago gives its place. It has no resources, and the slot stays where it is, so
		// no pointer that a caller holds to another entry moves.
		slot = -1
		for &old, i in r.entries[:r.count] {
			// Not one that a caller asked for this frame, whose pointer it may hold.
			if _, evicted := old.source.(Evicted_Source);
			   evicted &&
			   old.used_at != r.frame &&
			   (slot < 0 || old.used_at < r.entries[slot].used_at) {
				slot = i
			}
		}
		if slot < 0 {
			log.errorf("render: more than %d resident assets", MAX_RESIDENT)
			return
		}
		delete_key(&r.index, Resident_Key{r.entries[slot].guid, r.entries[slot].kind})
	} else {
		r.count += 1
	}
	e = &r.entries[slot]
	r.index[{guid, kind}] = slot
	e^ = {
		guid    = guid,
		kind    = kind,
		current = empty_resources(kind),
	}
	return e, true
}

// set_live makes a mesh blob in memory resident under a GUID, in place of the asset's blob, until clear_live (see
// docs/rendering/assets.md#gpu-residency): the editor's live meshes. The blob streams as an asset's does, and swaps in when
// its transfers are done, so the version before draws until then. A blob that arrives while one streams waits for it,
// and the newest wins, so a drag never queues behind itself. The blob is copied, so it may go after the call.
set_live :: proc(r: ^Residency, guid: format.Guid, blob: []byte) -> bool {
	e := find_entry(r, guid, .Mesh) or_return
	return change(r, e, Event_Live_Blob{blob})
}

// clear_live ends a GUID's live mesh. The asset's blob streams again at the next chance, or loads when it is cooked.
// The live mesh draws until then, and draws nothing if the asset's blob cannot stream.
clear_live :: proc(r: ^Residency, guid: format.Guid) {
	if i, found := r.index[{guid, .Mesh}]; found {
		change(r, &r.entries[i], Event_Let_Go{})
	}
}

// is_live is whether a GUID draws a live mesh.
is_live :: proc(r: ^Residency, guid: format.Guid) -> bool {
	i := r.index[{guid, .Mesh}] or_return
	_, live := r.entries[i].source.(Live_Source)
	return live
}

// change is the one writer of an entry's source and stream (see docs/overview/conventions.md#state-with-a-lifecycle).
// It gives false for an event that the entry's source does not take, and for a live blob that cannot stream.
@(private = "file")
change :: proc(r: ^Residency, e: ^Resident_Entry, event: Resident_Event) -> (ok: bool) {
	defer {
		live, is_live := e.source.(Live_Source)
		assert(
			!is_live || live.next == nil || e.stream != nil,
			"a live mesh's next blob waits only for a stream",
		)
	}
	switch ev in event {
	case Event_Live_Blob:
		e.failed_at = 0
		if _, is_live := e.source.(Live_Source); !is_live {
			e.source = Live_Source{}
		}
		live := &e.source.(Live_Source)
		// A blob that arrives while one streams waits for it, and the newest wins.
		if e.stream != nil {
			free_next(r, &live.next)
			next, err := mem.alloc_bytes(
				len(ev.blob),
				format.BLOB_ALIGN,
				r.platform.heap_allocator,
			)
			if err != nil {
				return false
			}
			copy(next, ev.blob)
			live.next = next
			return true
		}
		e.stream = live_stream(r, e, ev.blob) or_return
	case Event_Let_Go:
		live := e.source.(Live_Source) or_return
		free_next(r, &live.next)
		e.source = Released_Source{}
	case Event_Landed:
		s := e.stream.? or_return
		landed(r, e, &s.pending)
		destroy_resources(r, &e.current)
		if m, is_mesh := &s.pending.(Resident_Mesh); is_mesh && r.accels {
			create_mesh_accel(r, m)
		}
		e.current, e.version, e.ready = s.pending, s.version, true
		set_bytes(r, e, s.bytes)
		e.stream, e.wrong_dimension_logged = nil, false
		// The newest live step waited for this one.
		if live, is_live := &e.source.(Live_Source); is_live && live.next != nil {
			next := live.next
			live.next = nil
			defer mem.free_bytes(next, r.platform.heap_allocator)
			if stream, streams := live_stream(r, e, next); streams {
				e.stream = stream
			}
		}
	case Event_Stream_Failed:
		s := e.stream.? or_return
		destroy_resources(r, &s.pending)
		// Nothing may go on drawing what the editor gave up.
		if s.released {
			destroy_resources(r, &e.current)
			e.ready = false
			set_bytes(r, e, 0)
		}
		// The version stays, so only a newer blob tries again. An older blob that draws goes on, and stays.
		e.stream, e.version = nil, s.version
		if _, from_asset := e.source.(Asset_Source); from_asset && e.ready {
			e.source = Stale_Source{}
		}
		fail(r, e, ev.reason)
	case Event_Stream_Superseded:
		s := e.stream.? or_return
		destroy_resources(r, &s.pending)
		e.stream = nil
		// What it was to replace is as it was, a live mesh that was let go too.
		if s.released {
			e.source = Released_Source{}
		}
	case Event_Asset_Streaming:
		_, is_live := e.source.(Live_Source)
		assert(
			!is_live && e.stream == nil,
			"an asset streams only into an entry that is not live and streams nothing",
		)
		// A live mesh that was let go draws until this is in.
		stream := ev.stream
		_, stream.released = e.source.(Released_Source)
		e.source, e.stream, e.failed_at = Asset_Source{}, stream, 0
	case Event_Asset_Failed:
		_, is_live := e.source.(Live_Source)
		assert(
			!is_live && e.stream == nil,
			"an asset fails only in an entry that is not live and streams nothing",
		)
		// Nothing may go on drawing what the editor gave up.
		if _, released := e.source.(Released_Source); released {
			destroy_resources(r, &e.current)
			e.ready = false
			set_bytes(r, e, 0)
		}
		// An older blob that draws goes on, and stays.
		e.source = e.ready ? Stale_Source{} : Asset_Source{}
		fail(r, e, ev.reason)
	case Event_Mips_Failed:
		fail(r, e, ev.reason)
	case Event_Evicted:
		_ = e.source.(Asset_Source) or_return
		if e.stream != nil || !e.ready {
			return false
		}
		destroy_resources(r, &e.current)
		set_bytes(r, e, 0)
		e.ready, e.wrong_dimension_logged = false, false
		e.want, e.coarser_since = nil, nil
		// The blob goes too: the next request loads it again.
		if e.handle != {} {
			asset.unload(r.assets, e.handle)
			e.handle = {}
		}
		e.source = Evicted_Source{}
	}
	return true
}

// landed notes what resources that came in change, before they replace the entry's current ones: a texture that draws
// from a finer mip than it did, or at all, as it drew its default before, as coarse as its last mip; the cells of an
// instance set that a newer version changed; and the swap that a mesh's resources are, which numbers them.
@(private = "file")
landed :: proc(r: ^Residency, e: ^Resident_Entry, pending: ^Resident_Resources) {
	switch &v in pending {
	case Texture_Resources:
		t := v.texture
		if t.virtual != 0 {
			return
		}
		before := t.mip_count
		if current, is_texture := e.current.(Texture_Resources); is_texture && e.ready {
			before = current.texture.top_mip
		}
		if t.top_mip < before {
			append(&r.refined, Refined_Texture{e.guid, t.size, before})
		}
	case Resident_Instance_Set:
		if current, is_set := &e.current.(Resident_Instance_Set); is_set && e.ready {
			diff_set_cells(&r.changed_cells, e.guid, current, &v)
		}
	case Resident_Mesh:
		r.swaps += 1
		v.generation = r.swaps
	}
}

// set_bytes sets the GPU memory of an entry's resources, and the sum that stats holds.
@(private = "file")
set_bytes :: proc(r: ^Residency, e: ^Resident_Entry, bytes: u64) {
	r.stats.resident_bytes = r.stats.resident_bytes - e.bytes + bytes
	e.bytes = bytes
}

// live_stream streams a live mesh's blob, at the version that draws, as it is not the asset's.
@(private = "file")
live_stream :: proc(
	r: ^Residency,
	e: ^Resident_Entry,
	blob: []byte,
) -> (
	s: Resident_Stream,
	ok: bool,
) {
	s, ok = new_stream(r, .Mesh, blob, e.version, {}, 0)
	if !ok {
		buffer: [32]u8
		log.errorf(
			"render: the live mesh %s is not a blob that can be made resident",
			format.guid_format(e.guid, &buffer),
		)
	}
	return
}

@(private = "file")
free_next :: proc(r: ^Residency, next: ^[]byte) {
	if next^ != nil {
		mem.free_bytes(next^, r.platform.heap_allocator)
		next^ = nil
	}
}

// start_streaming streams the asset's blob, which it loads first if it must. A texture streams from the mip that it wants.
@(private = "file")
start_streaming :: proc(r: ^Residency, e: ^Resident_Entry) {
	if e.handle == {} {
		handle, loaded := asset.load(r.assets, e.guid)
		if !loaded {
			change(r, e, Event_Asset_Failed{"is not cooked"})
			return
		}
		e.handle = handle
	}
	data, _ := asset.data(r.assets, e.handle)
	version := asset.version(r.assets, e.handle)
	top_mip: u32
	if texture, is_texture := &e.current.(Texture_Resources); is_texture {
		top_mip = first_mip(r, e, &texture.texture, data)
	}
	stream, ok := new_stream(
		r,
		e.kind,
		data,
		version,
		{e.guid, e.handle, asset.modified(r.assets, e.handle)},
		top_mip,
	)
	if !ok {
		// The version stays, so a broken blob is tried again when the cooker writes a new one.
		e.version = version
		change(r, e, Event_Asset_Failed{"is not a blob that can be made resident"})
		return
	}
	change(r, e, Event_Asset_Streaming{stream})
}

// texture_mip_for_pixels is the finest mip that a texture needs to look sharp where what draws it shows at most pixels
// across: the one whose longer side is about pixels, which is 0 when pixels is at least the side, or is max(f32), for
// every mip. bias coarsens the mip, or refines it if it is negative.
texture_mip_for_pixels :: proc(size: [2]u32, mip_count: u32, pixels: f32, bias: i32) -> u32 {
	// Everything that is not sized wants every mip, whatever the bias is.
	if mip_count <= 1 || pixels >= max(f32) {
		return 0
	}
	ratio := f32(max(size.x, size.y)) / max(pixels, 1)
	mip := ratio > 1 ? int(math.floor(math.log2(ratio))) : 0
	return u32(clamp(mip + int(bias), 0, int(mip_count) - 1))
}

// wanted_mip is the mip that an entry's texture should have its top at: the one that the current request asks for, and
// the last without one (see Mip_Want).
@(private = "file")
wanted_mip :: proc(r: ^Residency, e: ^Resident_Entry, size: [2]u32, mip_count: u32) -> u32 {
	pixels, current := current_want(r, e)
	if !current {
		return max(mip_count, 1) - 1
	}
	return texture_mip_for_pixels(size, mip_count, pixels, r.policy.mip_bias)
}

// first_mip is the mip that a texture's blob streams from: the one that the current request asks for, and without one
// the mip that draws now, or every mip for a texture that is not resident (see Mip_Want).
@(private = "file")
first_mip :: proc(r: ^Residency, e: ^Resident_Entry, t: ^Resident_Texture, data: []byte) -> u32 {
	blob, ok := format.texture_view(data)
	if !ok || .Virtual in blob.flags {
		return 0
	}
	if _, current := current_want(r, e); !current {
		return e.ready ? min(t.top_mip, max(blob.mip_count, 1) - 1) : 0
	}
	return wanted_mip(r, e, blob.size, blob.mip_count)
}

// retarget_mips streams a texture that is not virtual again at the mip that it wants, in new textures: the GPU gives a
// texture one stream, so what streams in is a texture of the mips from the wanted one, which replaces the texture that
// draws when its transfers are done. It refines at once, and coarsens after MIP_DROP_FRAMES of wanting to. It gives
// whether it started a stream.
@(private = "file")
retarget_mips :: proc(r: ^Residency, e: ^Resident_Entry) -> bool {
	res, is_texture := &e.current.(Texture_Resources)
	if !is_texture || !e.ready || e.stream != nil || e.handle == {} || res.texture.virtual != 0 {
		return false
	}
	if _, from_asset := e.source.(Asset_Source); !from_asset {
		return false
	}
	t := &res.texture
	target := wanted_mip(r, e, t.size, t.mip_count)
	if target == t.top_mip {
		e.coarser_since = nil
		return false
	}
	if target > t.top_mip {
		since, waiting := e.coarser_since.?
		if !waiting {
			since = r.frame
			e.coarser_since = since
		}
		if r.frame - since < MIP_DROP_FRAMES && !r.exact_mips {
			return false
		}
	}
	// A failure is tried again after a while, as an asset that cannot be made resident is.
	if e.failed_at != 0 && r.frame - e.failed_at < RESIDENT_RETRY_FRAMES {
		return false
	}
	data, _ := asset.data(r.assets, e.handle)
	version := asset.version(r.assets, e.handle)
	if version != e.version {
		return false
	}
	stream, ok := new_stream(
		r,
		.Texture,
		data,
		version,
		{e.guid, e.handle, asset.modified(r.assets, e.handle)},
		target,
	)
	e.coarser_since = nil
	if !ok {
		change(r, e, Event_Mips_Failed{"has mips that cannot be made resident"})
		return false
	}
	r.stats.mip_streams += 1
	return change(r, e, Event_Asset_Streaming{stream})
}

// Stream_Origin is the asset that a blob is the head of, which a paged mesh or a virtual texture reads its pages from: its
// GUID, its handle and its file's time. A blob from memory, a live mesh's, has none.
@(private = "file")
Stream_Origin :: struct {
	guid:     format.Guid,
	handle:   asset.Handle,
	modified: i64,
}

// new_stream creates new resources from a blob and streams its data into them. A texture that is not virtual has the
// blob's mips from top_mip on.
@(private = "file")
new_stream :: proc(
	r: ^Residency,
	kind: format.Asset_Kind,
	data: []byte,
	version: u32,
	origin: Stream_Origin,
	top_mip: u32,
) -> (
	s: Resident_Stream,
	ok: bool,
) {
	s.pending = empty_resources(kind)
	switch &v in s.pending {
	case Resident_Mesh:
		ok = stream_mesh(r, &s, &v, data, version, origin)
	case Texture_Resources:
		ok = stream_texture(r, &s, &v.texture, data, version, origin, top_mip)
	case Resident_Instance_Set:
		ok = stream_instance_set(r, &s, &v, data)
	}
	if !ok {
		destroy_resources(r, &s.pending)
		return {}, false
	}
	s.version = version
	return s, true
}

@(private = "file")
fail :: proc(r: ^Residency, e: ^Resident_Entry, reason: string) {
	if e.failed_at == 0 {
		buffer: [32]u8
		log.errorf(
			"render: the %v asset %s %s",
			e.kind,
			format.guid_format(e.guid, &buffer),
			reason,
		)
	}
	e.failed_at = max(r.frame, 1)
}

@(private = "file")
stream_mesh :: proc(
	r: ^Residency,
	s: ^Resident_Stream,
	m: ^Resident_Mesh,
	data: []byte,
	version: u32,
	origin: Stream_Origin,
) -> bool {
	blob, ok := format.mesh_view(data)
	paged := ok && .Paged in blob.flags
	// A paged mesh reads its pages from its asset's file, so a blob from memory cannot be one.
	if !ok || (paged && origin.handle == {}) {
		return false
	}
	m.paged = paged
	m.vertex_count = blob.vertex_count
	m.attribute_stride = format.mesh_attribute_stride(blob.flags)
	m.flags = blob.flags
	m.bounds = blob.bounds
	m.index_format = .Index32 in blob.flags ? .U32 : .U16
	m.index_count = blob.index_count
	submeshes := format.mesh_submeshes(data, blob)
	m.submesh_count = u32(min(len(submeshes), MAX_SUBMESHES))
	for s, i in submeshes[:m.submesh_count] {
		m.submeshes[i] = {
			s.first_index,
			s.index_count,
			s.first_meshlet,
			s.meshlet_count,
			s.first_node,
			s.node_count,
			s.root_count,
		}
		m.submesh_bounds[i] = s.bounds
		// A paged mesh's level buckets are in its head, as its meshlets are not.
		m.level_first[i] = s.level_first
	}
	if paged {
		m.levels = blob.levels
		m.pool_mesh = mesh_pool_add(
			&r.pool,
			r.platform,
			origin.guid,
			origin.handle,
			version,
			origin.modified,
			data,
			blob,
		)
		if m.pool_mesh == 0 {
			return false
		}
		m.pages_first, m.page_count = mesh_pool_range(&r.pool, m.pool_mesh)
	} else {
		mesh_levels(m, format.mesh_meshlets(data, blob))
		m.positions = stream_buffer(
			r,
			s,
			format.blob_bytes(data, blob.positions),
			{},
			"mesh positions",
		) or_return
		m.attributes = stream_buffer(
			r,
			s,
			format.blob_bytes(data, blob.attributes),
			{},
			"mesh attributes",
		) or_return
		m.indices = stream_buffer(
			r,
			s,
			format.blob_bytes(data, blob.indices),
			{.Index},
			"mesh indices",
		) or_return
		m.meshlets = stream_buffer(
			r,
			s,
			format.blob_bytes(data, blob.meshlets),
			{},
			"meshlets",
		) or_return
		m.meshlet_vertices = stream_buffer(
			r,
			s,
			format.blob_bytes(data, blob.meshlet_vertices),
			{},
			"meshlet vertices",
		) or_return
		m.meshlet_triangles = stream_buffer(
			r,
			s,
			format.blob_bytes(data, blob.meshlet_triangles),
			{},
			"meshlet triangles",
		) or_return
	}
	m.meshlet_nodes = {}
	if blob.meshlet_nodes.size > 0 {
		m.meshlet_nodes = stream_buffer(
			r,
			s,
			format.blob_bytes(data, blob.meshlet_nodes),
			{},
			"meshlet nodes",
		) or_return
	}
	m.skin = {}
	if .Skinned in blob.flags {
		m.skin = stream_buffer(r, s, format.blob_bytes(data, blob.skin), {}, "mesh skin") or_return
	}
	m.impostor, m.impostor_size, m.impostor_error = {}, 0, 0
	if blob.impostor.size > 0 {
		m.impostor = stream_buffer(
			r,
			s,
			format.blob_bytes(data, blob.impostor),
			{},
			"mesh impostor",
		) or_return
		m.impostor_size, m.impostor_error = blob.impostor_size, blob.impostor_error
	}
	return true
}

@(private = "file")
stream_instance_set :: proc(
	r: ^Residency,
	s: ^Resident_Stream,
	set: ^Resident_Instance_Set,
	data: []byte,
) -> bool {
	blob, ok := format.instance_set_view(data)
	if !ok || blob.count == 0 {
		return false
	}
	set.count, set.cell_count = blob.count, blob.cell_count
	set.center, set.radius, set.max_scale = blob.center, blob.radius, blob.max_scale
	set.cells_cpu = set_cells(data, blob, r.platform.heap_allocator)
	set.instances = stream_buffer(
		r,
		s,
		format.blob_bytes(data, blob.instances),
		{},
		"instances",
	) or_return
	set.cells = stream_buffer(
		r,
		s,
		format.blob_bytes(data, blob.cells),
		{},
		"instance cells",
	) or_return
	return true
}

// set_cells gives each cell of an instance set blob on the CPU.
@(private)
set_cells :: proc(
	data: []byte,
	blob: ^format.Instance_Set_Blob,
	allocator: mem.Allocator,
) -> []Set_Cell {
	cells := format.instance_set_cells(data, blob)
	instances := format.instance_set_instances(data, blob)
	result := make([]Set_Cell, len(cells), allocator)
	for c, i in cells {
		// FNV-1a over each instance's pose. Its point is its index in the instancer, which an added instance shifts.
		h := u64(0xcbf29ce484222325)
		mix :: proc(h: u64, v: u64) -> u64 {
			return (h ~ v) * 0x100000001b3
		}
		for k in c.first ..< c.first + c.count {
			pose := instances[k]
			h = mix(
				h,
				u64(transmute(u32)pose.position.x) | u64(transmute(u32)pose.position.y) << 32,
			)
			h = mix(h, u64(transmute(u32)pose.position.z) | u64(u16(pose.rotation.x)) << 32)
			h = mix(
				h,
				u64(u16(pose.rotation.y)) |
				u64(u16(pose.rotation.z)) << 16 |
				u64(u16(pose.rotation.w)) << 32,
			)
			h = mix(
				h,
				u64(transmute(u16)pose.scale.x) |
				u64(transmute(u16)pose.scale.y) << 16 |
				u64(transmute(u16)pose.scale.z) << 32,
			)
		}
		result[i] = {c.center, c.radius, c.max_scale, h}
	}
	return result
}

// diff_set_cells appends the cells that a newer version of an instance set adds, removes or changes, matched by what
// their instances draw, so an added instance that shifts the cells after it changes only its own. A change of more than
// MAX_CHANGED_CELLS cells is the whole set.
@(private)
diff_set_cells :: proc(
	out: ^[dynamic]Changed_Set_Cell,
	guid: format.Guid,
	before, after: ^Resident_Instance_Set,
) {
	start := len(out)
	left := make(map[u64]int, len(before.cells_cpu), context.temp_allocator)
	for c in before.cells_cpu {
		left[c.hash] += 1
	}
	for c in after.cells_cpu {
		if left[c.hash] > 0 {
			left[c.hash] -= 1
		} else {
			append(out, Changed_Set_Cell{guid = guid, new = c})
		}
	}
	for c in before.cells_cpu {
		if left[c.hash] > 0 {
			left[c.hash] -= 1
			append(out, Changed_Set_Cell{guid = guid, old = c})
		}
	}
	if len(out) - start > MAX_CHANGED_CELLS {
		resize(out, start)
		append(
			out,
			Changed_Set_Cell {
				guid = guid,
				old = Set_Cell{before.center, before.radius, before.max_scale, 0},
				new = Set_Cell{after.center, after.radius, after.max_scale, 0},
			},
		)
	}
}

// mesh_levels finds each submesh's level buckets and each level's errors among the mesh's meshlets, which the cooker
// orders by level within each submesh (see format.mesh_level_buckets). A paged mesh's are in its blob.
@(private)
mesh_levels :: proc(m: ^Resident_Mesh, meshlets: []format.Meshlet) {
	deepest := -1
	m.levels = {}
	for s, i in m.submeshes[:m.submesh_count] {
		if u64(s.first_meshlet) + u64(s.meshlet_count) > u64(len(meshlets)) {
			continue
		}
		last: int
		m.level_first[i], last = format.mesh_level_buckets(
			meshlets[s.first_meshlet:][:s.meshlet_count],
			m.bounds.center,
			&m.levels,
		)
		deepest = max(deepest, last)
	}
	for &l in m.levels[clamp(deepest + 1, 0, INSTANCE_LEVEL_BUCKETS):] {
		l[0] = max(f32)
	}
}

#assert(INSTANCE_LEVEL_BUCKETS == format.MESH_LEVEL_BUCKETS)

// residency_enable_accels gives meshes acceleration structures from now on, and gives one to every mesh that is
// resident already.
residency_enable_accels :: proc(r: ^Residency) {
	if r.accels {
		return
	}
	r.accels = true
	for &e in r.entries[:r.count] {
		if m, is_mesh := &e.current.(Resident_Mesh); is_mesh && e.ready && m.accel == {} {
			create_mesh_accel(r, m)
		}
	}
}

// create_mesh_accel creates a ready mesh's bottom-level acceleration structure, which unbuilt_accels then gives to the
// renderer to build.
@(private)
create_mesh_accel :: proc(r: ^Residency, m: ^Resident_Mesh) {
	if m.index_count == 0 || m.index_count % 3 != 0 || m.accel != {} {
		return
	}
	// A paged mesh's is of its level 0, which the residency asks for while meshes have acceleration structures, and
	// which makes this when it is in.
	if _, ready := m.level0.(Level0_Ready); m.paged && !ready {
		return
	}
	geometry := gpu.Accel_Geometry {
		vertices      = m.positions,
		vertex_stride = 12,
		vertex_count  = m.vertex_count,
		vertex_format = .RGB32_Float,
		indices       = m.indices,
		index_count   = m.index_count,
		index_format  = m.index_format,
		opaque        = true,
	}
	accel := r.platform.gpu_create_accel(
		{kind = .Bottom, flags = {.Allow_Compaction}, geometries = {geometry}, label = "mesh"},
	)
	change_mesh_accel(r, m, Accel_Created{accel})
}

// unbuilt_accels are the ready meshes whose acceleration structures have not been built, in frame memory.
unbuilt_accels :: proc(r: ^Residency) -> []^Resident_Mesh {
	meshes := make([dynamic]^Resident_Mesh, r.platform.frame_allocator)
	for &e in r.entries[:r.count] {
		m, is_mesh := &e.current.(Resident_Mesh)
		if !is_mesh || !e.ready {
			continue
		}
		if _, unbuilt := m.accel_state.(Accel_Unbuilt); unbuilt {
			append(&meshes, m)
		}
	}
	return meshes[:]
}

// stream_buffer creates a buffer for data and streams it in. Buffers are multiples of 4 bytes, so 16-bit indices are
// padded.
@(private = "file")
stream_buffer :: proc(
	r: ^Residency,
	s: ^Resident_Stream,
	data: []byte,
	usage: gpu.Buffer_Usages,
	label: string,
) -> (
	buffer: gpu.Buffer,
	ok: bool,
) {
	size := (len(data) + 3) &~ 3
	if size == 0 {
		return
	}
	buffer = r.platform.gpu_create_buffer({size = u32(size), usage = usage, label = label}, nil)
	if buffer == {} {
		return
	}
	padded := data
	if size != len(data) {
		padded = make([]byte, size, r.platform.frame_allocator)
		copy(padded, data)
	}
	transfer := r.platform.gpu_stream_buffer(buffer, 0, padded)
	if transfer == 0 {
		r.platform.gpu_destroy_buffer(buffer)
		return {}, false
	}
	s.transfers[s.transfer_count] = transfer
	s.transfer_count += 1
	s.bytes += u64(size)
	return buffer, true
}

@(private = "file")
stream_texture :: proc(
	r: ^Residency,
	s: ^Resident_Stream,
	t: ^Resident_Texture,
	data: []byte,
	version: u32,
	origin: Stream_Origin,
	top_mip: u32,
) -> bool {
	blob, ok := format.texture_view(data)
	virtual := ok && .Virtual in blob.flags
	// A virtual texture reads its pages from its asset's file, so a blob from memory cannot be one.
	if !ok || (virtual && origin.handle == {}) {
		return false
	}
	t^ = {
		pixel_format = gpu_format(blob.format),
		size         = blob.size,
		mip_count    = blob.mip_count,
		usage        = blob.usage,
		dimension    = blob.dimension,
		layer_count  = blob.layer_count,
		sampler      = blob.sampler,
	}
	desc := gpu.Texture_Desc {
		size      = blob.size,
		format    = t.pixel_format,
		mip_count = blob.mip_count,
		usage     = {.Sampled, .Streamed},
		label     = "texture asset",
	}
	if blob.dimension != .D2 {
		desc.layers = blob.layer_count
		desc.cube = blob.dimension == .Cube
	}
	mips := format.blob_bytes(data, blob.mips)
	// A virtual texture's own texture is its tail: the mips whose sides are small enough to stay whole.
	if virtual {
		desc.size = {max(blob.size.x >> blob.tail_mip, 1), max(blob.size.y >> blob.tail_mip, 1)}
		desc.mip_count = blob.mip_count - blob.tail_mip
		mips = format.texture_tail(data, blob)
	} else if top_mip > 0 && blob.mip_count > 0 {
		t.top_mip = min(top_mip, blob.mip_count - 1)
		desc.size = {max(blob.size.x >> t.top_mip, 1), max(blob.size.y >> t.top_mip, 1)}
		desc.mip_count = blob.mip_count - t.top_mip
		mips = format.texture_mips_from(data, blob, t.top_mip, r.platform.frame_allocator)
		if mips == nil {
			return false
		}
	}
	t.texture = r.platform.gpu_create_texture(desc, nil)
	if t.texture == {} {
		return false
	}
	s.bytes += u64(gpu.mip_chain_size(desc))
	transfer := r.platform.gpu_stream_texture(t.texture, mips)
	if transfer == 0 {
		return false
	}
	s.transfers[0], s.transfer_count = transfer, 1
	if virtual {
		t.virtual = texture_pool_add(
			&r.texture_pool,
			r.platform,
			origin.guid,
			origin.handle,
			version,
			origin.modified,
			data,
			blob,
			t.texture,
		)
		return t.virtual != 0
	}
	return true
}

// gpu_format is a texture blob's format as the GPU names it.
gpu_format :: proc(f: format.Texture_Format) -> gpu.Format {
	switch f {
	case .RGBA8_Unorm:
		return .RGBA8_Unorm
	case .BC1_Unorm:
		return .BC1_Unorm
	case .BC1_Unorm_Srgb:
		return .BC1_Unorm_Srgb
	case .BC4_Unorm:
		return .BC4_Unorm
	case .BC5_Unorm:
		return .BC5_Unorm
	case .BC6H_Ufloat:
		return .BC6H_Ufloat
	case .BC7_Unorm:
		return .BC7_Unorm
	case .BC7_Unorm_Srgb:
		return .BC7_Unorm_Srgb
	case .R16_Unorm:
		return .R16_Unorm
	}
	return .Unknown
}

// destroy_resources frees an asset's resources, each exactly once, and leaves the empty variant of its kind.
@(private = "file")
destroy_resources :: proc(r: ^Residency, resources: ^Resident_Resources) {
	switch &v in resources {
	case Resident_Mesh:
		drop_level0(r, &v)
		mesh_pool_remove(&r.pool, r.platform, v.pool_mesh)
		r.platform.gpu_destroy_buffer(v.positions)
		r.platform.gpu_destroy_buffer(v.attributes)
		r.platform.gpu_destroy_buffer(v.indices)
		r.platform.gpu_destroy_buffer(v.meshlets)
		r.platform.gpu_destroy_buffer(v.meshlet_vertices)
		r.platform.gpu_destroy_buffer(v.meshlet_triangles)
		if v.meshlet_nodes != {} {
			r.platform.gpu_destroy_buffer(v.meshlet_nodes)
		}
		if v.skin != {} {
			r.platform.gpu_destroy_buffer(v.skin)
		}
		if v.impostor != {} {
			r.platform.gpu_destroy_buffer(v.impostor)
		}
		change_mesh_accel(r, &v, Accel_Destroyed{})
		v = {}
	case Texture_Resources:
		drop_whole(r, &v)
		texture_pool_remove(&r.texture_pool, r.platform, v.texture.virtual)
		r.platform.gpu_destroy_texture(v.texture.texture)
		v = {}
	case Resident_Instance_Set:
		r.platform.gpu_destroy_buffer(v.instances)
		r.platform.gpu_destroy_buffer(v.cells)
		delete(v.cells_cpu, r.platform.heap_allocator)
		v = {}
	}
}
