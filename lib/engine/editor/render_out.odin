package editor

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/cutscene"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"
import "cinnabar:engine/script"
import "cinnabar:engine/streaming"

// Render out (see docs/editor/cutscene-editor.md#render-out): the editor asks the game to play a cutscene out of real
// time and write each frame. The world runs as in Play, a frame at a time at the run's rate, and each frame draws only
// once everything that it shows has streamed in and compiled, so the frames are final and the same in every run.
//
// Each frame of the cutscene takes several of the game's frames, the steps of Frame_Step:
//   1. World: the world steps by exactly the frame's duration, which comes from the frame's number, never from a sum,
//      and the cutscene's driven clock goes to the frame's exact tick;
//   2. Settling: the view draws with a View_State of its own, the probe, until the renderer reports that nothing it
//      needs still streams or compiles for SETTLE_QUIET_DRAWS draws in a row;
//   3. Drawing: the view draws once with the run's own View_State, whose histories, exposure and jitter so move once
//      a frame, and the host writes the target's copy.
// The renderer's clock is fixed at the frame's time for every draw, so what moves by it moves the same in every run.

// The lowest rate: below it a frame is more ticks than a game frame runs (ecs.MAX_TICKS_PER_FRAME at 60 Hz).
RENDER_OUT_MIN_RATE :: 15
// How many draws in a row must find nothing streaming or compiling. The GPU's answers come a frame or two late.
SETTLE_QUIET_DRAWS :: 3
// How long one frame may wait for what it shows, and the run for its cutscene to load and its files to open.
SETTLE_TIMEOUT_SECONDS :: 60
PREPARE_TIMEOUT_SECONDS :: 30
// How many draws in a row may fail before the run does.
MAX_FAILED_DRAWS :: 3
// The renderer's clock at a run's first frame, in seconds. Every run starts there, so a material that reads the time
// shows the same in each.
RENDER_CLOCK_BASE :: 60.0
// The sound's rate, in frames a second.
RENDER_AUDIO_RATE :: 48000

// Render_Run is a render out: what the editor asked for, the cutscene's player, the target and the two View_States,
// and its stage. It lives in Mode_Render, and end_render_run frees what it holds.
Render_Run :: struct {
	ticket:         u64,
	asset:          format.Guid,
	// In the host's heap.
	name:           string,
	folder:         string,
	pattern:        string,
	range_start:    i32,
	frame_count:    i32,
	rate:           u32,
	size:           [2]u32,
	format:         core.Render_Out_Format,
	camera_binding: u32,
	warmup:         u32,
	audio:          bool,
	player:         cutscene.Player_Handle,
	target:         gpu.Texture,
	// The output's state, which only the frames' own draws and the warm-up's move, and the probe's, which the settle
	// draws use. In the host's heap.
	view:           ^render.View_State,
	probe:          ^render.View_State,
	// The draws in a row that failed.
	failed_draws:   u32,
	stage:          Render_Stage,
}

// Render_Stage is where a run is. change_render is its one writer.
Render_Stage :: union #no_nil {
	Render_Preparing,
	Render_Warming,
	Render_Rendering,
	Render_Finishing,
	Render_Ended,
}

// Render_Preparing waits for the cutscene to load and the host to open the run's files.
Render_Preparing :: struct {
	since: f64,
}

// Render_Warming draws left more frames at the first frame's time that are not written, so the temporal histories
// and the exposure have settled when the first one is.
Render_Warming :: struct {
	left: u32,
	step: Frame_Step,
}

// Render_Rendering is on a frame, at a step of it, since the game's time started.
Render_Rendering :: struct {
	frame:   i32,
	step:    Frame_Step,
	started: f64,
}

// Render_Finishing waits for the host to write the frames that it took, and then ends as outcome says.
Render_Finishing :: struct {
	outcome: link.Render_Out_Outcome,
	// In the host's heap.
	reason:  string,
	frames:  i32,
	since:   f64,
}

// Render_Ended is a run that ended, which stays until the editor sets Edit.
Render_Ended :: struct {
	outcome: link.Render_Out_Outcome,
	frames:  i32,
}

// Frame_Step is the step of a frame that the game's frame takes (see the top of this file).
Frame_Step :: union #no_nil {
	Step_World,
	Step_Settling,
	Step_Drawing,
}

Step_World :: struct {}

// Step_Settling counts the quiet draws in a row, every settle draw of the frame, and when it began. cut is a camera cut
// that a draw of the frame carried, which the frame's own draw takes (see plan_render_frame).
Step_Settling :: struct {
	quiet: u32,
	draws: u32,
	since: f64,
	cut:   bool,
}

// Step_Drawing draws the frame, after draws settle draws, with a cut that one of them carried.
Step_Drawing :: struct {
	draws: u32,
	cut:   bool,
}

// frame_duration is how long the world steps before frame n of a run at rate: 0 before the first, and after it the
// whole nanoseconds between its time and the last frame's, so the durations sum to n / rate exactly.
frame_duration :: proc(n: i32, rate: u32) -> time.Duration {
	if n <= 0 {
		return 0
	}
	second := i64(time.Second)
	return time.Duration(i64(n) * second / i64(rate) - i64(n - 1) * second / i64(rate))
}

// frame_tick is frame n's time on the cutscene's time.
frame_tick :: proc(start, n: i32, rate: u32) -> i32 {
	return start + i32(i64(n) * format.CUTSCENE_TICKS_PER_SECOND / i64(rate))
}

// frame_samples is how many frames of sound play from frame n to frame n + 1, so they sum to the time exactly.
frame_samples :: proc(n: i32, rate: u32) -> int {
	return int(
		i64(n + 1) * RENDER_AUDIO_RATE / i64(rate) - i64(n) * RENDER_AUDIO_RATE / i64(rate),
	)
}

// frame_seconds is the renderer's clock for frame n.
frame_seconds :: proc(n: i32, rate: u32) -> f64 {
	return RENDER_CLOCK_BASE + f64(n) / f64(rate)
}

// first_frame is the number of the frame at start, counted at the rate from the cutscene's 0.
first_frame :: proc(start: i32, rate: u32) -> i32 {
	return i32(i64(start) * i64(rate) / format.CUTSCENE_TICKS_PER_SECOND)
}

// rendering is the session's run while the editor renders out, or nil.
rendering :: proc(e: ^Editor) -> ^Render_Run {
	if !active(e) {
		return nil
	}
	if m, is_render := &e.session.mode.(Mode_Render); is_render {
		return &m.run
	}
	return nil
}

// render_refusal is why a render out cannot begin, or "" when it can.
@(private)
render_refusal :: proc(e: ^Editor, m: link.Render_Out_Begin) -> string {
	switch {
	case mode_of(e.session.mode) != .Edit:
		return "a render out begins in Edit"
	case e.session.mirror == nil:
		return "the editor's scene is not the world yet"
	case e.cutscenes == nil || e.assets == nil || e.renderer == nil:
		return "the game has no cutscenes or no renderer"
	case e.platform.render_out.open == nil:
		return "the host cannot write a render out"
	case m.rate < RENDER_OUT_MIN_RATE:
		return fmt.tprintf("a rate of %d is below %d frames a second", m.rate, RENDER_OUT_MIN_RATE)
	case m.frame_count <= 0:
		return "a render out has at least one frame"
	case m.width == 0 || m.height == 0 || m.width > gpu.MAX_VIEWPORT_SIZE || m.height > gpu.MAX_VIEWPORT_SIZE:
		return fmt.tprintf("a size of %dx%d is not 1 to %d on a side", m.width, m.height, gpu.MAX_VIEWPORT_SIZE)
	case m.format == .Exr:
		return "EXR frames need an HDR target, which the renderer does not have yet"
	case m.folder == "":
		return "a render out has a folder"
	}
	return ""
}

// begin_render_out starts a run from the editor's message, in place of Edit, or answers at once why it cannot.
@(private)
begin_render_out :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	m: link.Render_Out_Begin,
	out: ^[dynamic]byte,
) -> (
	despawned: bool,
) {
	if reason := render_refusal(e, m); reason != "" {
		link.write_message(out, link.Render_Out_Ended{ticket = m.ticket, outcome = .Failed, reason = reason})
		return
	}
	heap := e.platform.heap_allocator
	player, made := cutscene.load(
		e.cutscenes,
		w,
		{cutscene = format.Guid(m.cutscene), start = m.range_start, driven = true},
	)
	if !made {
		link.write_message(
			out,
			link.Render_Out_Ended{ticket = m.ticket, outcome = .Failed, reason = "every cutscene player is taken"},
		)
		return
	}
	run := Render_Run {
		ticket         = m.ticket,
		asset          = format.Guid(m.cutscene),
		name           = strings.clone(m.name != "" ? m.name : "cutscene", heap),
		folder         = strings.clone(m.folder, heap),
		pattern        = strings.clone(m.pattern != "" ? m.pattern : "{name}.{frame}.png", heap),
		range_start    = m.range_start,
		frame_count    = m.frame_count,
		rate           = m.rate,
		size           = {m.width, m.height},
		format         = core.Render_Out_Format(m.format),
		camera_binding = m.camera_binding,
		warmup         = m.warmup,
		audio          = m.audio,
		player         = player,
		stage          = Render_Preparing{since = e.platform.time_seconds()},
	}
	despawned = enter_render(e, w, scripts, run)
	send_render_progress(e, rendering(e))
	return
}

// cancel_render_out stops a run after the frame that it is on: the files that the host took are written, and the run
// ends as Cancelled.
@(private)
cancel_render_out :: proc(e: ^Editor, w: ^ecs.World, ticket: u64) {
	run := rendering(e)
	if run == nil || run.ticket != ticket {
		return
	}
	switch s in run.stage {
	case Render_Preparing:
		change_render(e, w, run, Render_Ended{outcome = .Cancelled})
	case Render_Warming:
		change_render(e, w, run, finishing(e, .Cancelled, "", 0))
	case Render_Rendering:
		change_render(e, w, run, finishing(e, .Cancelled, "", s.frame))
	case Render_Finishing, Render_Ended:
	}
}

// fail_render_out ends a run that cannot go on, after the files that the host took are written.
@(private)
fail_render_out :: proc(e: ^Editor, w: ^ecs.World, reason: string) {
	run := rendering(e)
	if run == nil {
		return
	}
	switch s in run.stage {
	case Render_Preparing:
		log.warnf("editor: the render out failed: %s", reason)
		change_render(e, w, run, Render_Ended{outcome = .Failed}, reason)
	case Render_Warming:
		change_render(e, w, run, finishing(e, .Failed, reason, 0))
	case Render_Rendering:
		change_render(e, w, run, finishing(e, .Failed, reason, s.frame))
	case Render_Finishing, Render_Ended:
	}
}

@(private = "file")
finishing :: proc(e: ^Editor, outcome: link.Render_Out_Outcome, reason: string, frames: i32) -> Render_Finishing {
	return {
		outcome = outcome,
		reason = strings.clone(reason, e.platform.heap_allocator),
		frames = frames,
		since = e.platform.time_seconds(),
	}
}

// render_allowed is whether a run may go from one stage to another.
render_allowed :: proc(from, to: Render_Stage) -> bool {
	switch f in from {
	case Render_Preparing:
		#partial switch _ in to {
		case Render_Warming, Render_Ended:
			return true
		}
	case Render_Warming:
		#partial switch _ in to {
		case Render_Warming, Render_Rendering, Render_Finishing:
			return true
		}
	case Render_Rendering:
		#partial switch t in to {
		case Render_Rendering:
			return t.frame == f.frame || t.frame == f.frame + 1
		case Render_Finishing:
			return true
		}
	case Render_Finishing:
		#partial switch _ in to {
		case Render_Ended:
			return true
		}
	case Render_Ended:
	}
	return false
}

// change_render is the one writer of a run's stage. It refuses a change that render_allowed does not allow, frees
// what the old stage held, tells the host to close the run's files on Finishing, and tells the editor of each new stage
// and of the end, with Finishing's reason, or reason for a run that ends from Preparing.
@(private)
change_render :: proc(e: ^Editor, w: ^ecs.World, run: ^Render_Run, to: Render_Stage, reason := "") -> bool {
	if !render_allowed(run.stage, to) {
		log.errorf("editor: a render out cannot go from %v to %v", stage_of(run.stage), stage_of(to))
		return false
	}
	same_stage := stage_of(run.stage) == stage_of(to)
	if ended, ends := to.(Render_Ended); ends {
		f, was_finishing := run.stage.(Render_Finishing)
		send_render_ended(e, run, ended.outcome, f.reason if was_finishing else reason, ended.frames)
		if was_finishing {
			delete(f.reason, e.platform.heap_allocator)
		}
	}
	switch t in to {
	case Render_Finishing:
		// The frames that the host took are written, and a cancel or a failure deletes the sound, which ends short.
		e.platform.render_out.close(run.ticket, t.outcome == .Done)
		// The output and its sound stop; the player gives the world back once the editor sends its scene.
		cutscene.stop(e.cutscenes, w, run.player)
	case Render_Preparing, Render_Warming, Render_Rendering, Render_Ended:
	}
	run.stage = to
	if !same_stage {
		send_render_progress(e, run)
	}
	return true
}

@(private = "file")
stage_of :: proc(s: Render_Stage) -> link.Render_Out_Stage {
	switch _ in s {
	case Render_Preparing:
		return .Preparing
	case Render_Warming:
		return .Warming
	case Render_Rendering:
		return .Rendering
	case Render_Finishing:
		return .Finishing
	case Render_Ended:
		return .Ended
	}
	return .Ended
}

@(private = "file")
send_render_progress :: proc(e: ^Editor, run: ^Render_Run) {
	frame: i32
	#partial switch s in run.stage {
	case Render_Rendering:
		frame = s.frame
	case Render_Finishing:
		frame = s.frames
	case Render_Ended:
		frame = s.frames
	}
	link.write_message(
		&e.session.outbox,
		link.Render_Out_Progress{ticket = run.ticket, stage = stage_of(run.stage), frame = frame},
	)
}

@(private = "file")
send_render_ended :: proc(
	e: ^Editor,
	run: ^Render_Run,
	outcome: link.Render_Out_Outcome,
	reason: string,
	frames: i32,
) {
	link.write_message(
		&e.session.outbox,
		link.Render_Out_Ended{ticket = run.ticket, outcome = outcome, reason = reason, frames = frames},
	)
}

// end_render_run lets go of what a run holds: its player, its target and View_States, its strings and the renderer's
// fixed clock, and the host's files when they are still open, which a cancel keeps as they are. The mode's change and
// the session's end call it.
@(private)
end_render_run :: proc(e: ^Editor, w: ^ecs.World, run: ^Render_Run) {
	heap := e.platform.heap_allocator
	switch s in run.stage {
	case Render_Ended:
	case Render_Preparing:
		send_render_ended(e, run, .Cancelled, "the editor left the render out", 0)
	case Render_Warming, Render_Rendering:
		e.platform.render_out.close(run.ticket, false)
		send_render_ended(e, run, .Cancelled, "the editor left the render out", 0)
	case Render_Finishing:
		send_render_ended(e, run, s.outcome, s.reason, s.frames)
		delete(s.reason, heap)
	}
	run.stage = Render_Ended{}
	if e.cutscenes != nil {
		cutscene.stop(e.cutscenes, w, run.player)
	}
	if e.renderer != nil {
		for state in ([]^render.View_State{run.view, run.probe}) {
			if state != nil {
				render.view_state_destroy(state, e.renderer)
				free(state, heap)
			}
		}
		render.set_render_clock(e.renderer, nil)
	}
	run.view, run.probe = nil, nil
	if run.target != {} {
		e.platform.gpu_destroy_texture(run.target)
		run.target = {}
	}
	delete(run.name, heap)
	delete(run.folder, heap)
	delete(run.pattern, heap)
	run.name, run.folder, run.pattern = "", "", ""
}

// render_frame_time is what the frame of a run steps the world by, at the top of the game's frame: the frame's duration
// at a World step, and 0 at the others. It moves the run on from Preparing, and drives the cutscene's clock to the
// frame's tick, and sets the renderer's clock. Without a run it gives dt.
render_frame_time :: proc(e: ^Editor, w: ^ecs.World, dt: time.Duration) -> time.Duration {
	run := rendering(e)
	if run == nil {
		return dt
	}
	switch &s in run.stage {
	case Render_Preparing:
		prepare_render(e, w, run, s)
		if warming, warms := run.stage.(Render_Warming); warms {
			if _, world := warming.step.(Step_World); world {
				render.set_render_clock(e.renderer, render.Fixed_Clock{frame_seconds(0, run.rate)})
				return 0
			}
		}
	case Render_Warming:
		render.set_render_clock(e.renderer, render.Fixed_Clock{frame_seconds(0, run.rate)})
	case Render_Rendering:
		render.set_render_clock(e.renderer, render.Fixed_Clock{frame_seconds(s.frame, run.rate)})
		if _, world := s.step.(Step_World); world {
			cutscene.drive(e.cutscenes, w, run.player, frame_tick(run.range_start, s.frame, run.rate))
			return frame_duration(s.frame, run.rate)
		}
	case Render_Finishing:
		finish_render(e, w, run, s)
	case Render_Ended:
	}
	return 0
}

// prepare_render opens the run's files once its cutscene is ready, makes its target and View_States, and starts it
// from a world clock that is aligned to a tick, so each run's ticks fall alike.
@(private = "file")
prepare_render :: proc(e: ^Editor, w: ^ecs.World, run: ^Render_Run, s: Render_Preparing) {
	switch cutscene.status(e.cutscenes, run.player) {
	case .Loading:
		if e.platform.time_seconds() - s.since > PREPARE_TIMEOUT_SECONDS {
			fail_render_out(e, w, "the cutscene did not load")
		}
		return
	case .Ready:
	case .Gone, .Playing, .Paused, .Skipping, .Finishing, .Restored, .Failed:
		fail_render_out(e, w, "the cutscene could not play")
		return
	}
	ok, reason := e.platform.render_out.open(
		{
			run = run.ticket,
			folder = run.folder,
			name = run.name,
			pattern = run.pattern,
			format = run.format,
			size = run.size,
			first_frame = first_frame(run.range_start, run.rate),
			audio = run.audio,
		},
	)
	if !ok {
		fail_render_out(e, w, reason)
		return
	}
	heap := e.platform.heap_allocator
	run.target = e.platform.gpu_create_texture(
		{size = run.size, format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}, label = "render out"},
		nil,
	)
	run.view = new(render.View_State, heap)
	run.probe = new(render.View_State, heap)
	render.view_state_init(run.view, e.renderer)
	render.view_state_init(run.probe, e.renderer)
	ecs.align_clock(w)
	cutscene.start(e.cutscenes, w, run.player)
	// One step of no time, so the world and the cutscene's tracks are at the first frame before anything draws.
	change_render(e, w, run, Render_Warming{left = run.warmup, step = Step_World{}})
}

// finish_render ends a run once the host has written what it took.
@(private = "file")
finish_render :: proc(e: ^Editor, w: ^ecs.World, run: ^Render_Run, s: Render_Finishing) {
	status := e.platform.render_out.status(run.ticket)
	if closed, is_closed := status.(core.Render_Out_Closed); is_closed {
		// A write that failed fails a run that would be Done.
		if !closed.ok && s.outcome == .Done {
			f := &run.stage.(Render_Finishing)
			delete(f.reason, e.platform.heap_allocator)
			f.outcome = .Failed
			f.reason = strings.clone(closed.reason, e.platform.heap_allocator)
		}
	} else if status != nil {
		return
	}
	change_render(e, w, run, Render_Ended{outcome = run.stage.(Render_Finishing).outcome, frames = s.frames})
}

// render_simulation is what a run's frame runs: the world at a World step, and nothing at the others.
@(private)
render_simulation :: proc(run: ^Render_Run, dt: time.Duration) -> (Simulation, time.Duration) {
	world := false
	switch s in run.stage {
	case Render_Warming:
		_, world = s.step.(Step_World)
	case Render_Rendering:
		_, world = s.step.(Step_World)
	case Render_Preparing, Render_Finishing, Render_Ended:
	}
	return .Run if world else .Hold, dt
}

// frame_size is the size that the game's frame lays its UI and its views out at: the run's while it renders out, and
// the window's otherwise.
frame_size :: proc(e: ^Editor, window: [2]i32) -> [2]i32 {
	if run := rendering(e); run != nil {
		return {i32(run.size.x), i32(run.size.y)}
	}
	return window
}

// plan_render_frame is the frame of a run: the game's own view, as the cut track shows it or through the binding's
// camera, into the run's target with the step's View_State, and nothing of the editor's.
@(private)
plan_render_frame :: proc(
	e: ^Editor,
	w: ^ecs.World,
	run: ^Render_Run,
	desc: render.Frame_Desc,
) -> (
	out: render.Frame_Desc,
	draws: bool,
) {
	out = desc
	out.extra_views = nil
	out.previews = nil
	out.rect = nil
	out.no_debug = true
	out.keep_ids = false
	out.size = run.size
	out.target = run.target
	if run.camera_binding != 0 {
		if view, found := binding_view(e, w, run); found {
			out.view = view
		}
	}
	step: ^Frame_Step
	switch &s in run.stage {
	case Render_Warming:
		step = &s.step
	case Render_Rendering:
		step = &s.step
	case Render_Preparing, Render_Finishing, Render_Ended:
		return out, false
	}
	// A cut that the camera stacks gave in a World step or a settle draw is the output's: the frame after it is the
	// first of the new shot, and its own draw drops the histories. The probe keeps its histories, which no output reads.
	out.state = run.probe
	out.cut = false
	switch &st in step {
	case Step_World:
		if desc.cut {
			step^ = Step_Settling{cut = true}
		}
	case Step_Settling:
		st.cut ||= desc.cut
	case Step_Drawing:
		out.state = run.view
		out.cut = st.cut || desc.cut
	}
	return out, true
}

@(private = "file")
binding_view :: proc(e: ^Editor, w: ^ecs.World, run: ^Render_Run) -> (view: render.View, ok: bool) {
	ev := cutscene.player_evaluation(e.cutscenes, run.player) or_return
	data, blob := cutscene.cutscene_data(e.cutscenes, ev) or_return
	index := cutscene.binding_index(data, blob, cutscene.Binding_Id(run.camera_binding)) or_return
	entity := cutscene.binding_entity(&ev.bindings, w, index) or_return
	return render.camera_view(w, entity)
}

// render_drew moves the run on after the frame drew, or did not: a World step goes to Settling, a settle draw counts
// whether the renderer found anything streaming or compiling, and the frame's own draw goes to the host and to the next
// frame.
@(private)
render_drew :: proc(e: ^Editor, w: ^ecs.World, run: ^Render_Run, drew: bool) {
	now := e.platform.time_seconds()
	if drew {
		run.failed_draws = 0
	} else {
		run.failed_draws += 1
		if run.failed_draws >= MAX_FAILED_DRAWS {
			fail_render_out(e, w, "the frame could not be drawn")
			return
		}
	}
	step: ^Frame_Step
	frame: i32 = -1
	switch &s in run.stage {
	case Render_Warming:
		step = &s.step
	case Render_Rendering:
		step = &s.step
		frame = s.frame
	case Render_Preparing, Render_Finishing, Render_Ended:
		return
	}
	switch &st in step {
	case Step_World:
		step^ = Step_Settling{since = now}
	case Step_Settling:
		if st.since == 0 {
			st.since = now
		}
		st.draws += 1
		st.quiet = st.quiet + 1 if drew && settled(e, run) else 0
		if st.quiet >= SETTLE_QUIET_DRAWS {
			step^ = Step_Drawing{draws = st.draws, cut = st.cut}
		} else if now - st.since > SETTLE_TIMEOUT_SECONDS {
			fail_render_out(e, w, "what the frame shows did not finish streaming or compiling")
		}
	case Step_Drawing:
		if !drew {
			return
		}
		if frame < 0 {
			warming := &run.stage.(Render_Warming)
			// Each warm-up draw settles before it too, so what the GPU reads back to the view's state, such as the global
			// illumination's counts, has come back by the next one in every run, however fast the GPU is.
			if warming.left > 0 {
				warming.left -= 1
				warming.step = Step_Settling{since = now}
				return
			}
			change_render(e, w, run, Render_Rendering{frame = 0, step = Step_Settling{since = now}, started = now})
			return
		}
		draw_render_frame(e, w, run, frame, st.draws, now)
	}
}

// draw_render_frame gives the host the frame that drew, tells the editor, and moves on to the next frame, or to
// Finishing after the last.
@(private = "file")
draw_render_frame :: proc(e: ^Editor, w: ^ecs.World, run: ^Render_Run, frame: i32, draws: u32, now: f64) {
	rendering := &run.stage.(Render_Rendering)
	switch e.platform.render_out.frame(run.ticket, frame, run.target) {
	case .Accepted:
	case .No_Room:
		// render_has_room asked before the draw, which moved the output's state, so it cannot draw again.
		fail_render_out(e, w, "the host had no room for a frame that drew")
		return
	case .Not_Open:
		fail_render_out(e, w, "the host closed the render out")
		return
	}
	if run.audio {
		e.platform.render_out.audio(run.ticket, frame_samples(frame, run.rate))
	}
	link.write_message(
		&e.session.outbox,
		link.Render_Out_Frame {
			ticket = run.ticket,
			frame = frame,
			tick = frame_tick(run.range_start, frame, run.rate),
			settle_draws = draws,
			ms = f32((now - rendering.started) * 1000),
		},
	)
	if frame + 1 >= run.frame_count {
		change_render(e, w, run, finishing(e, .Done, "", frame + 1))
		return
	}
	change_render(e, w, run, Render_Rendering{frame = frame + 1, step = Step_World{}, started = now})
}

// render_has_room is whether the frame that draws next may draw: a Drawing step waits until the host has room for it,
// as its draw moves the output's state, which a draw that the host refused could not take back.
@(private)
render_has_room :: proc(e: ^Editor, run: ^Render_Run) -> bool {
	s, is_rendering := run.stage.(Render_Rendering)
	if !is_rendering {
		return true
	}
	if _, drawing := s.step.(Step_Drawing); !drawing {
		return true
	}
	return e.platform.render_out.room(run.ticket) == .Accepted
}

// settled is whether the last draw found nothing that a later draw would show otherwise: no pipeline compiling, no
// asset streaming, no texture at a coarser mip than it wants, no page of a mesh or a virtual texture waiting, no blob
// that the cooker wrote and the game has not seen, and no scene loading.
@(private = "file")
settled :: proc(e: ^Editor, run: ^Render_Run) -> bool {
	r := e.renderer
	if render.frame_compiling() || render.residency_unsettled(&r.residency) > 0 {
		return false
	}
	if render.mesh_stream_stats(&r.residency).pending_requests > 0 ||
	   render.texture_stream_stats(&r.residency).pending_pages > 0 {
		return false
	}
	if !asset.current(e.assets) {
		return false
	}
	if e.streaming != nil && streaming.stats(e.streaming).scenes_loading > 0 {
		return false
	}
	return cutscene.status(e.cutscenes, run.player) != .Loading
}
