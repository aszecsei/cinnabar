// Package render is the render frontend. Its render graph culls unused passes, creates transient textures and
// records every barrier. See docs/gpu.md#render-graph.
package render

import "base:runtime"
import "core:log"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/jobs"

// Graph handles are valid in the graph that returned them. 0 is the nil handle.
Texture :: distinct u32
Buffer :: distinct u32
Accel :: distinct u32
Pass :: distinct u32

Texture_Use :: enum u8 {
	// Read in shaders through gpu.read_index.
	Sampled,
	// Read and written in shaders through gpu.write_index.
	Storage,
	// A color attachment of a render pass.
	Color,
	// The depth attachment of a render pass.
	Depth,
}

Buffer_Use :: enum u8 {
	// Read in shaders through gpu.read_index.
	Read,
	// Read and written in shaders through gpu.write_index.
	Storage,
	Index,
	// Indirect arguments or a count, read by an indirect command.
	Indirect,
	// Geometry that an acceleration structure build reads.
	Build_Input,
	// The source or destination of cmd_copy_buffer.
	Copy_Source,
	Copy_Dest,
}

Accel_Use :: enum u8 {
	// The pass builds or updates the structure.
	Build,
	// Shaders in the pass trace against the structure.
	Read,
	// A build in the pass reads the structure: a top-level build reads its bottom-level structures.
	Build_Input,
}

Pass_Kind :: enum u8 {
	Render,
	Compute,
	// A pass that dispatches rays with a ray tracing pipeline.
	Ray_Tracing,
}

// A pass can be split into at most this many pieces.
MAX_PASS_PIECES :: 64

// Pass_Context is what a Pass_Proc records with. A pass split into pieces runs its Pass_Proc once per piece, with
// piece from 0 to piece_count - 1. Each piece records into its own command buffer and draws its share of the work.
Pass_Context :: struct {
	graph:       ^Graph,
	cb:          ^gpu.Command_Buffer,
	data:        rawptr,
	piece:       int,
	piece_count: int,
}

// Pass_Proc records a pass's commands. For a render pass, the graph records Begin_Pass before it and End_Pass after it.
// Each pass, and each piece of a split pass, records on its own job in parallel with the others. It may read the
// graph and its data, and use context.temp_allocator, but it must not write shared state without synchronization.
// Each piece of a render pass starts with nothing bound, so it binds its own pipeline and constants.
Pass_Proc :: #type proc(ctx: ^Pass_Context)

// Graph holds one frame's passes and resources in frame memory. Declare the passes in execution order, then call execute.
Graph :: struct {
	platform:  ^core.Platform_API,
	cache:     ^Texture_Cache,
	allocator: runtime.Allocator,
	textures:  [dynamic]Texture_Node,
	buffers:   [dynamic]Buffer_Node,
	passes:    [dynamic]Pass_Node,
}

// State is what a resource's last uses did. Buffers have no layout, so theirs stays Undefined.
@(private)
State :: struct {
	sync:   gpu.Syncs,
	access: gpu.Accesses,
	layout: gpu.Texture_Layout,
}

@(private)
Texture_Node :: struct {
	// A transient texture's usage is the union of its uses in live passes.
	desc:     gpu.Texture_Desc,
	texture:  gpu.Texture,
	// The queue of the last use this frame, if touched.
	queue:    gpu.Queue,
	touched:  bool,
	imported: bool,
	// The layout an imported texture has between frames.
	resting:  gpu.Texture_Layout,
	state:    State,
	// Culling: a later live pass reads the contents.
	needed:   bool,
	used:     bool,
}

// Acceleration structures share the buffer nodes: accel selects the barrier type, and buffer holds the handle.
@(private)
Buffer_Node :: struct {
	buffer:  gpu.Buffer,
	accel:   bool,
	state:   State,
	needed:  bool,
	queue:   gpu.Queue,
	touched: bool,
}

@(private)
Use :: struct {
	index:  u32,
	buffer: bool,
	state:  State,
	// The pass reads the contents that earlier passes left.
	reads:  bool,
	writes: bool,
}

@(private)
Pass_Node :: struct {
	name:           string,
	kind:           Pass_Kind,
	queue:          gpu.Queue,
	// The queues whose earlier work this pass uses resources from.
	wait_for:       gpu.Queues,
	execute:        Pass_Proc,
	data:           rawptr,
	color_count:    int,
	colors:         [gpu.MAX_COLOR_ATTACHMENTS]gpu.Color_Attachment,
	color_textures: [gpu.MAX_COLOR_ATTACHMENTS]Texture,
	depth:          gpu.Depth_Attachment,
	depth_texture:  Texture,
	uses:           [dynamic]Use,
	keep:           bool,
	live:           bool,
	piece_count:    int,
	// Computed in order before the passes record. The first piece records them.
	barriers:       Barriers,
	cbs:            []gpu.Command_Buffer,
	graph:          ^Graph,
}

@(private)
Piece :: struct {
	pass:  ^Pass_Node,
	index: int,
}

@(private)
Barriers :: struct {
	buffers:  [dynamic]gpu.Buffer_Barrier,
	textures: [dynamic]gpu.Texture_Barrier,
	accels:   [dynamic]gpu.Accel_Barrier,
}

// begin starts the frame's graph. Build one graph per frame for each cache.
begin :: proc(platform: ^core.Platform_API, cache: ^Texture_Cache) -> Graph {
	cache_begin_frame(cache, platform)
	allocator := platform.frame_allocator
	return {
		platform = platform,
		cache = cache,
		allocator = allocator,
		textures = make([dynamic]Texture_Node, allocator),
		buffers = make([dynamic]Buffer_Node, allocator),
		passes = make([dynamic]Pass_Node, allocator),
	}
}

// import_texture adds a texture that outlives the frame. Between frames, the texture is in the layout of
// its resting use. The graph returns it to that layout at the end of the frame. The frame target rests as Color.
import_texture :: proc(g: ^Graph, texture: gpu.Texture, resting: Texture_Use) -> Texture {
	layout := texture_state(resting, .Render).layout
	for node, i in g.textures {
		if node.imported && node.texture == texture {
			assert(node.resting == layout, "render: a texture is imported twice with different resting uses")
			return Texture(i + 1)
		}
	}
	append(&g.textures, Texture_Node{texture = texture, imported = true, resting = layout, state = {layout = layout}, needed = true})
	return Texture(len(g.textures))
}

// import_buffer adds a buffer that outlives the frame.
import_buffer :: proc(g: ^Graph, buffer: gpu.Buffer) -> Buffer {
	for node, i in g.buffers {
		if !node.accel && node.buffer == buffer {
			return Buffer(i + 1)
		}
	}
	append(&g.buffers, Buffer_Node{buffer = buffer, needed = true})
	return Buffer(len(g.buffers))
}

// import_accel adds an acceleration structure. Acceleration structures are always imported.
import_accel :: proc(g: ^Graph, accel: gpu.Accel_Struct) -> Accel {
	for node, i in g.buffers {
		if node.accel && node.buffer == gpu.Buffer(accel) {
			return Accel(i + 1)
		}
	}
	append(&g.buffers, Buffer_Node{buffer = gpu.Buffer(accel), accel = true, needed = true})
	return Accel(len(g.buffers))
}

// create_texture adds a transient texture. Its contents are undefined until a pass writes them.
// The graph adds the usages that the passes need to desc.usage.
create_texture :: proc(g: ^Graph, desc: gpu.Texture_Desc) -> Texture {
	append(&g.textures, Texture_Node{desc = desc})
	return Texture(len(g.textures))
}

// pieces splits a large pass across jobs. The pieces of a render pass are one render pass on the GPU: the first
// piece loads or clears the attachments, and the last one stores them (see docs/gpu.md#split-passes).
add_render_pass :: proc(g: ^Graph, name: string, execute: Pass_Proc, data: rawptr = nil, pieces := 1) -> Pass {
	return add_pass(g, name, .Render, execute, data, pieces, .Graphics)
}

// A compute pass on the Compute queue runs alongside graphics work (async compute). The graph orders it against
// the graphics passes that share its resources (see docs/gpu.md#queues).
add_compute_pass :: proc(
	g: ^Graph,
	name: string,
	execute: Pass_Proc,
	data: rawptr = nil,
	pieces := 1,
	queue := gpu.Queue.Graphics,
) -> Pass {
	return add_pass(g, name, .Compute, execute, data, pieces, queue)
}

// add_ray_tracing_pass adds a pass that dispatches rays. Its shader accesses synchronize with the ray tracing stage.
add_ray_tracing_pass :: proc(g: ^Graph, name: string, execute: Pass_Proc, data: rawptr = nil, queue := gpu.Queue.Graphics) -> Pass {
	return add_pass(g, name, .Ray_Tracing, execute, data, 1, queue)
}

// keep_pass stops the graph from culling a pass whose results it cannot see, for example a readback.
keep_pass :: proc(g: ^Graph, pass: Pass) {
	g.passes[pass - 1].keep = true
}

color :: proc(g: ^Graph, pass: Pass, texture: Texture, load: gpu.Load_Op, clear: [4]f32 = {}, store := gpu.Store_Op.Store) {
	p := &g.passes[pass - 1]
	assert(p.kind == .Render, "render: color attachments need a render pass")
	assert(p.color_count < gpu.MAX_COLOR_ATTACHMENTS, "render: too many color attachments")
	use_texture(g, pass, texture, .Color, reads = load == .Load)
	p.colors[p.color_count] = {load = load, store = store, clear = clear}
	p.color_textures[p.color_count] = texture
	p.color_count += 1
}

depth :: proc(g: ^Graph, pass: Pass, texture: Texture, load: gpu.Load_Op, clear: f32 = 1, store := gpu.Store_Op.Store) {
	p := &g.passes[pass - 1]
	assert(p.kind == .Render, "render: a depth attachment needs a render pass")
	assert(p.depth_texture == 0, "render: a pass has one depth attachment")
	use_texture(g, pass, texture, .Depth, reads = load == .Load)
	p.depth = {load = load, store = store, clear = clear}
	p.depth_texture = texture
}

// read declares that the pass reads a resource in shaders.
read :: proc {
	read_texture,
	read_buffer,
}

// write declares that the pass writes a resource in shaders. It may also read it.
write :: proc {
	write_texture,
	write_buffer,
}

read_texture :: proc(g: ^Graph, pass: Pass, texture: Texture) {
	use_texture(g, pass, texture, .Sampled, reads = true)
}

write_texture :: proc(g: ^Graph, pass: Pass, texture: Texture) {
	use_texture(g, pass, texture, .Storage, reads = true)
}

read_buffer :: proc(g: ^Graph, pass: Pass, buffer: Buffer) {
	use_buffer(g, pass, buffer, .Read)
}

write_buffer :: proc(g: ^Graph, pass: Pass, buffer: Buffer) {
	use_buffer(g, pass, buffer, .Storage)
}

index_buffer :: proc(g: ^Graph, pass: Pass, buffer: Buffer) {
	assert(g.passes[pass - 1].kind == .Render, "render: index buffers need a render pass")
	use_buffer(g, pass, buffer, .Index)
}

// indirect_buffer declares that the pass reads indirect arguments or a count from a buffer.
indirect_buffer :: proc(g: ^Graph, pass: Pass, buffer: Buffer) {
	use_buffer(g, pass, buffer, .Indirect)
}

// build_accel declares that the pass builds or updates an acceleration structure.
build_accel :: proc(g: ^Graph, pass: Pass, accel: Accel) {
	use_accel(g, pass, accel, .Build)
}

// read_accel declares that shaders in the pass trace rays against an acceleration structure.
read_accel :: proc(g: ^Graph, pass: Pass, accel: Accel) {
	use_accel(g, pass, accel, .Read)
}

// build_input declares that a build in the pass reads a geometry buffer or a bottom-level structure.
build_input :: proc {
	build_input_buffer,
	build_input_accel,
}

// copy_source and copy_dest declare that the pass copies from or to a buffer with cmd_copy_buffer.
copy_source :: proc(g: ^Graph, pass: Pass, buffer: Buffer) {
	use_buffer(g, pass, buffer, .Copy_Source)
}

copy_dest :: proc(g: ^Graph, pass: Pass, buffer: Buffer) {
	use_buffer(g, pass, buffer, .Copy_Dest)
}

build_input_buffer :: proc(g: ^Graph, pass: Pass, buffer: Buffer) {
	use_buffer(g, pass, buffer, .Build_Input)
}

build_input_accel :: proc(g: ^Graph, pass: Pass, accel: Accel) {
	use_accel(g, pass, accel, .Build_Input)
}

// gpu_texture returns the texture behind a graph texture. Use it in a Pass_Proc: transient textures exist
// only after the graph starts recording.
gpu_texture :: proc(g: ^Graph, texture: Texture) -> gpu.Texture {
	return g.textures[texture - 1].texture
}

gpu_buffer :: proc(g: ^Graph, buffer: Buffer) -> gpu.Buffer {
	return g.buffers[buffer - 1].buffer
}

gpu_accel :: proc(g: ^Graph, accel: Accel) -> gpu.Accel_Struct {
	return gpu.Accel_Struct(g.buffers[accel - 1].buffer)
}

// Submission is one gpu_submit call: the command buffers of consecutive live passes on one queue.
Submission :: struct {
	buffers:  [dynamic]gpu.Command_Buffer,
	queue:    gpu.Queue,
	wait_for: gpu.Queues,
}

// execute records the graph and submits it. It returns false if recording or a submission failed.
// Call it from the game's frame code or from a job: it waits for the recording jobs.
execute :: proc(g: ^Graph) -> bool {
	submissions := record(g) or_return
	for s in submissions {
		g.platform.gpu_submit(s.buffers[:], s.queue, s.wait_for) or_return
	}
	return true
}

// record culls passes that do not contribute to an imported resource, creates the transient textures and computes
// the barriers and queue waits in pass order. Then it records each live pass, with its barriers, into its own command
// buffer on a job, and groups consecutive passes on one queue into a submission. A last command buffer returns
// imported textures to their resting layouts.
record :: proc(g: ^Graph) -> (submissions: []Submission, ok: bool) {
	cull(g)
	create_transients(g) or_return
	compute_barriers(g) or_return

	live := make([dynamic]^Pass_Node, g.allocator)
	pieces := make([dynamic]Piece, g.allocator)
	for &pass in g.passes {
		if !pass.live {
			continue
		}
		append(&live, &pass)
		pass.graph = g
		pass.cbs = make([]gpu.Command_Buffer, pass.piece_count, g.allocator)
		for i in 0 ..< pass.piece_count {
			append(&pieces, Piece{&pass, i})
		}
	}
	pass_jobs := make([]jobs.Job, len(pieces), g.allocator)
	for &piece, i in pieces {
		pass_jobs[i] = {record_piece, &piece}
	}
	counter: jobs.Counter
	g.platform.jobs_run(pass_jobs, &counter)

	// The next frame starts after this one ends, so only the layout has to change. A texture that the compute queue
	// used last is ordered by a wait, like any cross-queue use.
	final := gpu.command_buffer(g.allocator)
	final_wait: gpu.Queues
	textures := make([dynamic]gpu.Texture_Barrier, g.allocator)
	for &node in g.textures {
		if node.imported && node.state.layout != node.resting {
			if node.touched && node.queue != .Graphics {
				final_wait += {node.queue}
				node.state = {layout = node.state.layout}
			}
			append(
				&textures,
				gpu.Texture_Barrier {
					texture = node.texture,
					sync_before = node.state.sync,
					access_before = node.state.access,
					layout_before = node.state.layout,
					layout_after = node.resting,
				},
			)
		}
	}
	gpu.cmd_barriers(&final, nil, textures[:])

	g.platform.jobs_wait(&counter)
	result := make([dynamic]Submission, g.allocator)
	for pass in live {
		add_to_submission(g, &result, pass.cbs, pass.queue, pass.wait_for)
	}
	if len(textures) > 0 {
		add_to_submission(g, &result, {final}, .Graphics, final_wait)
	}
	return result[:], true
}

// add_to_submission appends command buffers to the last submission if it is on the same queue, and starts a new
// one otherwise. The waits of a submission apply at its start, which comes before every pass in it.
@(private = "file")
add_to_submission :: proc(g: ^Graph, submissions: ^[dynamic]Submission, buffers: []gpu.Command_Buffer, queue: gpu.Queue, wait_for: gpu.Queues) {
	n := len(submissions)
	if n == 0 || submissions[n - 1].queue != queue {
		append(submissions, Submission{buffers = make([dynamic]gpu.Command_Buffer, g.allocator), queue = queue})
		n += 1
	}
	last := &submissions[n - 1]
	append(&last.buffers, ..buffers)
	last.wait_for += wait_for
}

// compute_barriers walks the live passes in order and gives each pass the barriers before it.
@(private = "file")
compute_barriers :: proc(g: ^Graph) -> bool {
	for &pass in g.passes {
		if !pass.live {
			continue
		}
		pass.barriers = {
			make([dynamic]gpu.Buffer_Barrier, g.allocator),
			make([dynamic]gpu.Texture_Barrier, g.allocator),
			make([dynamic]gpu.Accel_Barrier, g.allocator),
		}
		for use in pass.uses {
			if use.buffer {
				node := &g.buffers[use.index]
				cross_queue(&pass, &node.state, &node.queue, &node.touched)
				if before, needed := transition(&node.state, use.state); needed {
					if node.accel {
						barrier := gpu.Accel_Barrier{gpu.Accel_Struct(node.buffer), before.sync, use.state.sync, before.access, use.state.access}
						append(&pass.barriers.accels, barrier)
					} else {
						append(&pass.barriers.buffers, gpu.Buffer_Barrier{node.buffer, before.sync, use.state.sync, before.access, use.state.access})
					}
				}
				continue
			}
			node := &g.textures[use.index]
			cross_queue(&pass, &node.state, &node.queue, &node.touched)
			if node.state.layout == .Undefined && use.state.layout == .Shader_Resource {
				log.errorf("render: pass %q samples texture %q before a pass writes it", pass.name, node.desc.label)
				return false
			}
			if before, needed := transition(&node.state, use.state); needed {
				append(
					&pass.barriers.textures,
					gpu.Texture_Barrier{node.texture, before.sync, use.state.sync, before.access, use.state.access, before.layout, use.state.layout},
				)
			}
		}
	}
	return true
}

// record_piece records one piece of a pass. Only the first piece of a render pass loads or clears the attachments,
// and only the last one stores them. Commands between suspended and resumed pieces are not allowed, so a split
// render pass has its debug marker inside each piece.
// cross_queue handles a use on another queue than the resource's last use this frame. The pass waits for that
// queue's earlier work, and the fence makes the earlier accesses complete and visible, so only a layout change is
// left for a barrier.
@(private = "file")
cross_queue :: proc(pass: ^Pass_Node, state: ^State, queue: ^gpu.Queue, touched: ^bool) {
	if touched^ && queue^ != pass.queue {
		pass.wait_for += {queue^}
		state^ = {layout = state.layout}
	}
	queue^ = pass.queue
	touched^ = true
}

@(private = "file")
record_piece :: proc(data: rawptr) {
	piece := (^Piece)(data)
	pass, i := piece.pass, piece.index
	g := pass.graph
	last := pass.piece_count - 1
	split_render := pass.kind == .Render && pass.piece_count > 1
	pass.cbs[i] = gpu.command_buffer(g.allocator)
	cb := &pass.cbs[i]
	if i == 0 {
		gpu.cmd_barriers(cb, pass.barriers.buffers[:], pass.barriers.textures[:], pass.barriers.accels[:])
	}
	if !split_render {
		gpu.cmd_begin_marker(cb, pass.name)
	}
	if pass.kind == .Render {
		colors := pass.colors
		depth := pass.depth
		flags: gpu.Pass_Flags
		if i > 0 {
			flags += {.Resuming}
			for &color in colors {
				color.load = .Load
			}
			depth.load = .Load
		}
		if i < last {
			flags += {.Suspending}
			for &color in colors {
				color.store = .Store
			}
			depth.store = .Store
		}
		for c in 0 ..< pass.color_count {
			colors[c].texture = gpu_texture(g, pass.color_textures[c])
		}
		if pass.depth_texture != 0 {
			depth.texture = gpu_texture(g, pass.depth_texture)
		}
		gpu.cmd_begin_pass(cb, colors[:pass.color_count], depth, flags)
		if split_render {
			gpu.cmd_begin_marker(cb, pass.name)
		}
	}
	ctx := Pass_Context{g, cb, pass.data, i, pass.piece_count}
	pass.execute(&ctx)
	if pass.kind == .Render {
		if split_render {
			gpu.cmd_end_marker(cb)
		}
		gpu.cmd_end_pass(cb)
	}
	if !split_render {
		gpu.cmd_end_marker(cb)
	}
}

@(private = "file")
add_pass :: proc(g: ^Graph, name: string, kind: Pass_Kind, execute: Pass_Proc, data: rawptr, pieces: int, queue: gpu.Queue) -> Pass {
	assert(pieces >= 1 && pieces <= MAX_PASS_PIECES, "render: a pass has 1 to MAX_PASS_PIECES pieces")
	append(
		&g.passes,
		Pass_Node {
			name = name,
			kind = kind,
			queue = queue,
			execute = execute,
			data = data,
			piece_count = pieces,
			uses = make([dynamic]Use, g.allocator),
		},
	)
	return Pass(len(g.passes))
}

@(private = "file")
use_texture :: proc(g: ^Graph, pass: Pass, texture: Texture, use: Texture_Use, reads: bool) {
	p := &g.passes[pass - 1]
	add_use(p, {index = u32(texture - 1), state = texture_state(use, p.kind), reads = reads})
}

@(private = "file")
use_accel :: proc(g: ^Graph, pass: Pass, accel: Accel, use: Accel_Use) {
	p := &g.passes[pass - 1]
	assert(p.kind != .Render, "render: acceleration structures are built and traced outside render passes")
	add_use(p, {index = u32(accel - 1), buffer = true, state = accel_state(use, p.kind), reads = use != .Build})
}

@(private = "file")
use_buffer :: proc(g: ^Graph, pass: Pass, buffer: Buffer, use: Buffer_Use) {
	p := &g.passes[pass - 1]
	assert(p.kind != .Render || (use != .Copy_Source && use != .Copy_Dest), "render: copies occur outside render passes")
	// A copy destination is written without being read, so earlier writers are not needed for it.
	add_use(p, {index = u32(buffer - 1), buffer = true, state = buffer_state(use, p.kind), reads = use != .Copy_Dest})
}

// add_use merges two reads of a resource in one pass. Any other second use of the resource is an error.
@(private = "file")
add_use :: proc(pass: ^Pass_Node, use: Use) {
	use := use
	use.writes = use.state.access & gpu.WRITE_ACCESSES != {}
	for &u in pass.uses {
		if u.index != use.index || u.buffer != use.buffer {
			continue
		}
		if u.writes || use.writes || u.state.layout != use.state.layout {
			log.panicf("render: pass %q uses a resource in two conflicting ways", pass.name)
		}
		u.state.sync += use.state.sync
		u.state.access += use.state.access
		return
	}
	append(&pass.uses, use)
}

@(private = "file")
shading_sync :: proc(kind: Pass_Kind) -> gpu.Syncs {
	switch kind {
	case .Render:
		return {.Vertex_Shading, .Pixel_Shading}
	case .Compute:
		return {.Compute_Shading}
	case .Ray_Tracing:
		return {.Ray_Tracing}
	}
	return {}
}

@(private = "file")
accel_state :: proc(use: Accel_Use, kind: Pass_Kind) -> State {
	switch use {
	case .Build:
		return {sync = {.Build_Accel}, access = {.Accel_Write}}
	case .Read:
		return {sync = shading_sync(kind), access = {.Accel_Read}}
	case .Build_Input:
		return {sync = {.Build_Accel}, access = {.Accel_Read}}
	}
	return {}
}

@(private = "file")
texture_state :: proc(use: Texture_Use, kind: Pass_Kind) -> State {
	switch use {
	case .Sampled:
		return {shading_sync(kind), {.Shader_Resource}, .Shader_Resource}
	case .Storage:
		return {shading_sync(kind), {.Unordered_Access}, .Unordered_Access}
	case .Color:
		return {{.Render_Target}, {.Render_Target}, .Render_Target}
	case .Depth:
		return {{.Depth_Stencil}, {.Depth_Stencil_Write}, .Depth_Stencil_Write}
	}
	return {}
}

@(private = "file")
buffer_state :: proc(use: Buffer_Use, kind: Pass_Kind) -> State {
	switch use {
	case .Read:
		return {sync = shading_sync(kind), access = {.Shader_Resource}}
	case .Storage:
		return {sync = shading_sync(kind), access = {.Unordered_Access}}
	case .Index:
		return {sync = {.Index_Input}, access = {.Index_Buffer}}
	case .Indirect:
		return {sync = {.Execute_Indirect}, access = {.Indirect_Argument}}
	case .Build_Input:
		return {sync = {.Build_Accel}, access = {.Shader_Resource}}
	case .Copy_Source:
		return {sync = {.Copy}, access = {.Copy_Source}}
	case .Copy_Dest:
		return {sync = {.Copy}, access = {.Copy_Dest}}
	}
	return {}
}

// transition moves a resource to its next use. A use needs a barrier when it changes the layout, when it follows
// a write, or when it writes after any access. Reads in the same layout merge into one state without a barrier,
// so a later write waits for all of them.
@(private)
transition :: proc(state: ^State, next: State) -> (before: State, needed: bool) {
	hazard := state.access & gpu.WRITE_ACCESSES != {} || (next.access & gpu.WRITE_ACCESSES != {} && state.access != {})
	if state.layout == next.layout && !hazard {
		state.sync += next.sync
		state.access += next.access
		return {}, false
	}
	before = state^
	state^ = next
	return before, true
}

// cull walks the passes backward from the imported resources. A pass is live when it writes a resource that a
// later live pass reads, writes an imported resource, or is kept.
@(private = "file")
cull :: proc(g: ^Graph) {
	needed :: proc(g: ^Graph, use: Use) -> ^bool {
		return use.buffer ? &g.buffers[use.index].needed : &g.textures[use.index].needed
	}
	#reverse for &pass in g.passes {
		pass.live = pass.keep
		for use in pass.uses {
			if use.writes && needed(g, use)^ {
				pass.live = true
			}
		}
		if !pass.live {
			continue
		}
		// A write that does not read replaces the contents, so earlier writers are not needed for it.
		for use in pass.uses {
			if use.writes && !use.reads {
				needed(g, use)^ = false
			}
		}
		for use in pass.uses {
			if use.reads {
				needed(g, use)^ = true
			}
		}
	}
}

// create_transients takes a texture from the cache for each transient texture that a live pass uses.
@(private = "file")
create_transients :: proc(g: ^Graph) -> bool {
	for pass in g.passes {
		if !pass.live {
			continue
		}
		for use in pass.uses {
			if use.buffer {
				continue
			}
			node := &g.textures[use.index]
			node.used = true
			if usage, ok := gpu.layout_usage(use.state.layout); ok && !node.imported {
				node.desc.usage += {usage}
			}
		}
	}
	for &node in g.textures {
		if node.imported || !node.used {
			continue
		}
		node.texture = cache_acquire(g.cache, g.platform, node.desc)
		if node.texture == {} {
			return false
		}
	}
	return true
}
