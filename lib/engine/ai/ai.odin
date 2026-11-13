// Package ai is the core of the engine's AI (see docs/ai/agents.md): agents, their blackboards, the decision modules
// that pick their actions, the native and script actions that act, and the ai think system that runs the decisions
// on jobs within a budget of agents in each tick. It has no decision module of its own: each technique of the
// .decision kind registers one (see docs/content/kinds/decisions.md). It holds no static state, so a code reload keeps
// it and jobs can read it.
package ai

import "core:log"

import "cinnabar:core"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/physics"
import "cinnabar:engine/script"

// The AI components' stable IDs, in the AI's range, 128 to 143 (see docs/world/ecs.md#component-registry). nav has
// 128, 129, 134 and 135, and perception 132 and 133.
AGENT_ID :: ecs.Component_Id(130)
AGENT_STATE_ID :: ecs.Component_Id(131)

// The agents that think in a tick by default (see docs/ai/agents.md#thinking).
DEFAULT_THINK_BUDGET :: 64
// The agents that one think job runs.
THINK_BATCH :: 32
// The search nodes that the agents of a planning technique expand in a tick by default, or the decomposition steps
// that they take (see docs/ai/agents.md#planning).
DEFAULT_PLAN_BUDGET :: 256
// The bytes of state that a native action may keep in each agent.
MAX_ACTION_STATE :: 64
// The native actions and the parameters of each that register_action takes.
MAX_NATIVE_ACTIONS :: 256
MAX_ACTION_PARAMS :: 16

// Agent is an entity that thinks: its blackboard and its decision, by GUID, how often it thinks, and its priority for
// the think budget, higher first. The decision must be cooked against the blackboard.
Agent :: struct {
	blackboard: format.Guid `asset:"blackboard"`,
	decision:   format.Guid `asset:"decision"`,
	// Seconds between thinks. 0 thinks in every tick.
	interval:   f32,
	priority:   i32,
}

DEFAULT_AGENT :: Agent {
	interval = 0.25,
}

// Agent_Handle is an agent's slot in the state's pool. The zero handle is none.
Agent_Handle :: struct {
	index:      u32,
	generation: u32,
}

// Agent_State is the runtime component that the ai think system adds to an Agent: its slot in the pool, which holds its
// blackboard's values, its decision's module state and its running action. Nothing saves it.
Agent_State :: struct {
	agent: Agent_Handle `editor:"-" script:"-"`,
}

#assert(size_of(Agent) <= ecs.MAX_COMPONENT_SIZE)

// Action_Status is how an action is after a tick: running, or done.
Action_Status :: script.Action_Status

// Board is a loaded blackboard blob, valid in the frame that prepare read it in.
Board :: struct {
	data: []byte,
	blob: ^format.Blackboard_Blob,
}

// Decision is a loaded decision blob, valid in the frame that prepare read it in.
Decision :: struct {
	data: []byte,
	blob: ^format.Decision_Blob,
}

// Load_Ok is a blob that loaded, by its handle.
@(private)
Load_Ok :: struct {
	handle: asset.Handle,
}

// Load_Missing is a blob that did not load at the cache's generation, which is tried again when the generation changes.
@(private)
Load_Missing :: struct {
	generation: i64,
}

// Load_State is where a blob is: loaded, or missing. nil has not been tried yet.
@(private)
Load_State :: union {
	Load_Ok,
	Load_Missing,
}

// Loaded is a blackboard or a decision that an agent uses, and whether it loaded.
@(private)
Loaded :: struct {
	guid:    format.Guid,
	state:   Load_State,
	// The version that was checked, so a refused blob or a decision's missing actions are warned about once.
	checked: u32,
	// Whether an agent's slot names it, which prepare counts again in each frame.
	used:    bool,
}

// View is a loaded blob that checks, in the frame.
@(private)
View :: struct {
	guid:       format.Guid,
	board:      Board,
	decision:   Decision,
	perception: Perception,
}

// State is the AI's state in Game_State: the agents' pool, the blobs that they use and the frame's views of them, the
// actions that are to stop, the noises and perception events of the tick, and the registrations of native actions and
// decision modules, which register clears. It holds handles and plain data only, besides the registrations, so a code
// reload keeps it.
State :: struct {
	platform:       ^core.Platform_API,
	assets:         ^asset.Assets,
	// The world, the script runtime and physics live in Game_State too, so the pointers stay valid across reloads.
	world:          ^ecs.World,
	scripts:        ^script.Runtime,
	// The physics that sight and hearing cast their rays in, nil for none, where every ray misses.
	physics:        ^physics.State,
	agents:         Agent_Pool,
	loaded:         [dynamic]Loaded,
	// The loaded blobs that check, in frame memory, from prepare to end_frame, and nil between frames.
	frame:          []View,
	// Actions that were replaced or whose agents went, which their system stops: the natives in the next tick's ai think,
	// the scripts in this tick's script step.
	ending_native:  [dynamic]Ending,
	ending_script:  [dynamic]Ending,
	// Writes to agents that were not ready, by name, which apply when each is (see Blackboard.set).
	early:          [dynamic]Command,
	// The agents that think in a tick, and the search nodes that each technique's agents expand in a tick.
	budget:         int,
	plan_budgets:   [format.Decision_Technique]int,
	// The seed of the agents' generators, which set_seed sets.
	seed:           u64,
	// The project's perception.tags, the sight rays of a tick, and the slot of the perceiver that was visited last.
	tags:           Tag_Names,
	sight_budget:   int,
	sight_cursor:   i64,
	// The noises made since the last perception, which it hears, and those that it hears in this tick.
	noises_pending: [dynamic]Noise,
	noises:         [dynamic]Noise,
	// What the tick's perception found, which send_events gives the behaviours.
	events:         [dynamic]Perception_Event,
	// Registrations, which register clears: native actions, and each technique's module.
	natives:        [MAX_NATIVE_ACTIONS]Native_Action,
	native_params:  [MAX_NATIVE_ACTIONS][MAX_ACTION_PARAMS]Param,
	native_count:   int,
	modules:        [format.Decision_Technique]Module,
	job_commands:   ecs.Job_Buffer,
	new_agents:     ecs.Query,
	states:         ecs.Query,
	perceivables:   ecs.Query,
}

// register_components registers Agent, Agent_State, Perceiver and Perceivable. Call it with the engine's components,
// in init and on_reload.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Agent, AGENT_ID, DEFAULT_AGENT)
	ecs.register_component(r, Agent_State, AGENT_STATE_ID)
	ecs.register_component(r, Perceiver, PERCEIVER_ID, DEFAULT_PERCEIVER)
	ecs.register_component(r, Perceivable, PERCEIVABLE_ID, DEFAULT_PERCEIVABLE)
}

// init makes the state's lists. scripts is the runtime that runs the script actions, and physics the one that sight and
// hearing cast rays in, nil for none. Call it once, before register.
init :: proc(s: ^State, platform: ^core.Platform_API, assets: ^asset.Assets, scripts: ^script.Runtime = nil, physics: ^physics.State = nil) {
	s.platform, s.assets, s.scripts, s.physics = platform, assets, scripts, physics
	heap := platform.heap_allocator
	s.agents = {
		slots       = make([dynamic]Agent_Slot, heap),
		generations = make([dynamic]u32, heap),
		free        = make([dynamic]u32, heap),
	}
	s.loaded = make([dynamic]Loaded, heap)
	s.ending_native = make([dynamic]Ending, heap)
	s.ending_script = make([dynamic]Ending, heap)
	s.early = make([dynamic]Command, heap)
	s.budget = DEFAULT_THINK_BUDGET
	for &b in s.plan_budgets {
		b = DEFAULT_PLAN_BUDGET
	}
	s.sight_budget = DEFAULT_SIGHT_BUDGET
	s.sight_cursor = -1
	s.noises_pending = make([dynamic]Noise, heap)
	s.noises = make([dynamic]Noise, heap)
	s.events = make([dynamic]Perception_Event, heap)
}

// register makes the queries, the commands' job buffer and the systems, and clears the native actions and the modules,
// which the game registers again after it. Call it after the world's components are registered, in init and in
// on_reload.
register :: proc(s: ^State, w: ^ecs.World) {
	s.world = w
	s.frame = nil
	s.native_count = 0
	s.modules = {}
	s.new_agents = ecs.query(w, {ecs.read(w, Agent), ecs.without(w, Agent_State)})
	s.states = ecs.query(w, {ecs.read(w, Agent_State)})
	s.perceivables = ecs.query(w, {ecs.read(w, Perceivable), ecs.read(w, ecs.Transform)})
	s.job_commands = ecs.register_job_buffer(w, {name = "ai commands", user = s, make = make_job_commands, flush = flush_job_commands})
	ecs.register_system(
		w,
		{
			name = "ai perceive",
			stage = .Fixed,
			procedure = perceive_system,
			reads = {AGENT_ID, AGENT_STATE_ID, PERCEIVER_ID, PERCEIVABLE_ID, ecs.TRANSFORM_ID, physics.PHYSICS_BODY_ID, physics.PHYSICS_CHARACTER_ID},
			data = s,
		},
	)
	ecs.register_system(
		w,
		{name = "ai think", stage = .Fixed, procedure = think_system, reads = {AGENT_ID, ecs.TRANSFORM_ID}, writes = {AGENT_STATE_ID}, after = {"ai perceive"}, data = s},
	)
	ecs.register_system(
		w,
		{
			name = "ai actions",
			stage = .Fixed,
			procedure = actions_system,
			terms = {ecs.read(w, Agent_State)},
			reads = {AGENT_ID, ecs.TRANSFORM_ID},
			after = {"ai think"},
			data = s,
		},
	)
	// The decisions' actions are checked again, since a reload may have changed the natives.
	for &l in s.loaded {
		l.checked = 0
	}
}

// reload keeps the state after a code reload.
reload :: proc(s: ^State, platform: ^core.Platform_API) {
	s.platform = platform
}

// destroy unloads the blobs and frees the agents. A soft restart destroys the VM too, so the script actions are not
// stopped.
destroy :: proc(s: ^State) {
	for i in 0 ..< len(s.agents.slots) {
		release_slot(s, &s.agents.slots[i])
	}
	for l in s.loaded {
		if ok, loaded := l.state.(Load_Ok); loaded {
			asset.unload(s.assets, ok.handle)
		}
	}
	delete(s.agents.slots)
	delete(s.agents.generations)
	delete(s.agents.free)
	delete(s.loaded)
	delete(s.ending_native)
	delete(s.ending_script)
	delete(s.early)
	delete(s.noises_pending)
	delete(s.noises)
	delete(s.events)
	s.frame = nil
}

// set_budget sets the agents that think in a tick (see docs/ai/agents.md#thinking).
set_budget :: proc(s: ^State, agents: int) {
	s.budget = max(agents, 1)
}

// set_plan_budget sets the search nodes that a technique's agents expand in a tick, or the decomposition steps that
// they take, which its searching agents share (see docs/ai/agents.md#planning).
set_plan_budget :: proc(s: ^State, technique: format.Decision_Technique, nodes: int) {
	s.plan_budgets[technique] = max(nodes, 1)
}

// set_seed sets the seed that each agent's generator starts from, with its slot, when it starts (see
// docs/ai/agents.md#determinism). It is 0 by default. The agents that run already keep their sequences.
set_seed :: proc(s: ^State, seed: u64) {
	s.seed = seed
}

// scores is what an agent's module scored in its last think, by option, for debuggers and scripts, in the allocator.
// It is false for an agent that is not ready, or whose module keeps no scores.
scores :: proc(s: ^State, e: ecs.Entity, allocator := context.temp_allocator) -> ([]Option_Score, bool) {
	slot, ready := ready_of(s, s.world, e)
	if ready == nil {
		return nil, false
	}
	board, board_ok := board_of(s, slot.blackboard)
	decision, decision_ok := decision_of(s, slot.decision)
	if !board_ok || !decision_ok {
		return nil, false
	}
	module := s.modules[decision.blob.technique]
	if module.scores == nil {
		return nil, false
	}
	return module.scores(decision, board, ready.state, allocator), true
}

// plan is an agent's goal and plan, from its module's state, for debuggers and scripts, in the allocator. It is false
// for an agent that is not ready, or whose module does not plan.
plan :: proc(s: ^State, e: ecs.Entity, allocator := context.temp_allocator) -> (Plan_View, bool) {
	slot, ready := ready_of(s, s.world, e)
	if ready == nil {
		return {}, false
	}
	board, board_ok := board_of(s, slot.blackboard)
	decision, decision_ok := decision_of(s, slot.decision)
	if !board_ok || !decision_ok {
		return {}, false
	}
	module := s.modules[decision.blob.technique]
	if module.plan == nil {
		return {}, false
	}
	return module.plan(decision, board, ready.state, allocator), true
}

// register_module registers a technique's decision module. Call it in register_world, after register.
register_module :: proc(s: ^State, technique: format.Decision_Technique, m: Module) {
	if s.modules[technique].think != nil {
		log.errorf("ai: the technique %v has a module already", technique)
		return
	}
	s.modules[technique] = m
}

// prepare loads the blackboards and decisions that the agents use, unloads those that none uses, and reads the loaded
// ones into the frame's views. A decision's actions are checked when it loads: one that no native or script action has
// is warned about, and fails when it starts, unless a module defines it before. Call it in the frame code in every
// mode, before the ticks.
prepare :: proc(s: ^State, w: ^ecs.World) {
	for &l in s.loaded {
		l.used = false
	}
	use :: proc(s: ^State, guid: format.Guid) {
		if guid == {} {
			return
		}
		for &l in s.loaded {
			if l.guid == guid {
				l.used = true
				return
			}
		}
		append(&s.loaded, Loaded{guid = guid, used = true})
	}
	for &slot in s.agents.slots {
		if slot.phase == nil {
			continue
		}
		use(s, slot.blackboard)
		use(s, slot.decision)
		if ecs.is_alive(w, slot.entity) {
			if perceiver := ecs.get(w, slot.entity, Perceiver); perceiver != nil {
				use(s, perceiver.perception)
			}
		}
	}
	generation := s.assets.cache_generation
	views := make([dynamic]View, 0, len(s.loaded), w.platform.frame_allocator)
	for i := 0; i < len(s.loaded); {
		l := &s.loaded[i]
		if !l.used {
			if ok, loaded := l.state.(Load_Ok); loaded {
				asset.unload(s.assets, ok.handle)
			}
			unordered_remove(&s.loaded, i)
			continue
		}
		i += 1
		switch state in l.state {
		case Load_Ok:
		case Load_Missing:
			if state.generation != generation {
				l.state = load(s, l.guid, generation)
			}
		case nil:
			l.state = load(s, l.guid, generation)
		}
		loaded, is_loaded := l.state.(Load_Ok)
		if !is_loaded {
			continue
		}
		data, ok := asset.data(s.assets, loaded.handle)
		if !ok {
			continue
		}
		version := asset.version(s.assets, loaded.handle)
		view := View {
			guid = l.guid,
		}
		header, _ := format.blob_header(data)
		valid := false
		if header != nil && header.kind == .Blackboard {
			view.board.blob, valid = format.blackboard_view(data)
			view.board.data = data
		} else if header != nil && header.kind == .Decision {
			view.decision.blob, valid = format.decision_view(data)
			view.decision.data = data
		} else if header != nil && header.kind == .Perception {
			view.perception.blob, valid = format.perception_view(data)
			view.perception.data = data
		}
		first := l.checked != version
		l.checked = version
		if !valid {
			if first {
				log.warnf("ai: %s is not a blackboard, decision or perception blob of this build. Cook the content.", guid_text(l.guid))
			}
			continue
		}
		if view.decision.blob != nil && first {
			check_actions(s, view.decision)
		}
		if view.perception.blob != nil {
			resolve_tags(s, &view.perception, first, w.platform.frame_allocator)
		}
		append(&views, view)
	}
	s.frame = views[:]
}

// load loads a blob by its GUID, or gives the generation that it was missing at.
@(private)
load :: proc(s: ^State, guid: format.Guid, generation: i64) -> Load_State {
	if handle, ok := asset.load(s.assets, guid); ok {
		return Load_Ok{handle}
	}
	return Load_Missing{generation}
}

// end_frame lets the frame's views go, before asset.poll can swap their blobs. Call it at the end of the frame code.
end_frame :: proc(s: ^State) {
	s.frame = nil
}

// board_of is the loaded blackboard of a GUID in the frame.
board_of :: proc(s: ^State, guid: format.Guid) -> (Board, bool) {
	for v in s.frame {
		if v.guid == guid && v.board.blob != nil {
			return v.board, true
		}
	}
	return {}, false
}

// decision_of is the loaded decision of a GUID in the frame.
decision_of :: proc(s: ^State, guid: format.Guid) -> (Decision, bool) {
	for v in s.frame {
		if v.guid == guid && v.decision.blob != nil {
			return v.decision, true
		}
	}
	return {}, false
}

@(private)
guid_text :: proc(guid: format.Guid) -> string {
	buffer := new([32]u8, context.temp_allocator)
	return format.guid_format(guid, buffer)
}
