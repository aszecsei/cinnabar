# Agents

The core of the AI, in `lib/engine/ai`: agents, their blackboards, the decision modules that choose their actions, the native and script actions that act, and the `ai think` system that runs the decisions on jobs within a budget. It has no decision module of its own. Each technique of the [decision kind](../content/kinds/decisions.md#techniques) registers one. Read [Hot reload](../overview/hot-reload.md#rules), [World: ECS](../world/ecs.md#systems), [World: Time](../world/time.md) and [Scripting: Behaviours](../scripting/behaviours.md) first.

**In this document:** [Design](#design) · [Agents](#agents) · [Blackboards](#blackboards) · [Thinking](#thinking) · [Actions](#actions) · [The order in a tick](#the-order-in-a-tick) · [Determinism](#determinism) · [Reload and restart](#reload-and-restart) · [Scripts](#scripts) · [Limits](#limits)

## Design

1. **Decisions are data; scripts act.** A decision is a cooked blob that a technique's module runs natively on jobs. It never calls Luau. Scripts write the blackboard and implement actions, but they do not decide.
2. **One pool of agents.** An agent's blackboard values, its module's state and its running action live in `ai.State`'s pool on the host's heap, in the slot that its `Agent_State` names. The components stay small, and a code reload keeps everything.
3. **Writes land in a fixed order.** What decision jobs, native actions and other systems' jobs write goes through a job buffer, which applies after the tick's `Fixed` systems in system order and then job order. A blackboard never depends on the jobs' timing.
4. **A budget per tick.** At most a budget of agents think in a tick, chosen by priority and by how long since each last thought, so a crowd costs a steady share of each tick.
5. **Planning spans ticks in the agent's state.** Jobs end with the frame ([Core: Job system](../core/jobs-and-memory.md#job-system)), so a module that plans over several thinks keeps its search in its module state, not in a waiting job.

## Agents

| Component | ID | Kind | Fields |
|---|---|---|---|
| `Agent` | 130 | Authoring | `blackboard` and `decision`, by GUID; `interval`, the seconds between thinks (0.25 by default, 0 for every tick); `priority`, higher first for the budget |
| `Agent_State` | 131 | Runtime | `agent`, its slot in the pool, hidden in the editor and scripts |

An agent with a `Perceiver` also sees and hears, and keeps what it perceives in its slot ([Perception](perception.md#components)).

- **Slots:** the `ai think` system gives each `Agent` without an `Agent_State` a slot, and adds its `Agent_State` by command after the tick. A copy of an entity, whose `Agent_State` names another entity's slot, gets a slot of its own. A slot is freed when its entity goes, loses its `Agent`, or names another slot, and its action is stopped. An `Agent` whose blackboard or decision changes starts again.
- **Phases:** a slot is `Agent_Waiting` until its blobs are loaded and fit, then `Agent_Ready`. `set_phase` is its only writer.
- **Loading:** `ai.prepare`, in every mode before the ticks, loads each blackboard and decision that a slot names, unloads those that none names, and reads the loaded blobs into the frame's views. `ai.end_frame` lets them go before `asset.poll`. A blob that does not load is tried again after the next cook.
- **Fitting:** an agent waits, with a warning, while its decision names another blackboard than its `Agent`, was cooked against another version of its blackboard (`format.decision_check`), or is of a technique that no module runs.
- **Starting:** a ready agent's values start as its blackboard's defaults, its module state as zero, and it has no action. The writes that scripts made before it was ready then apply ([Scripts](#scripts)).

## Blackboards

An agent's blackboard is its values: `values_size` bytes in its slot, with each key at the offset that the cooker gave ([Content: Blackboards](../content/kinds/blackboards.md#the-blob)).

| Writer | How | When it applies |
|---|---|---|
| A decision module | `ai.write(t, index)`, a decision's `set` | After the tick's `Fixed` systems |
| A native action, or any system's job | `ai.write_key(ai.job_writer(s, ctx), entity, key, value)` | After the tick's `Fixed` systems |
| Frame code | `ai.set_key(s, entity, key, value)` | At once |
| Scripts | `Blackboard.set(entity, key, value)` | At once |

- **Values** are an `ai.Value`: `f32`, `i32`, `bool`, `Enum_Index`, `Entity`, `World_Position` or `[3]f32`. A write by name finds its key by `animation_graph_hash` of the name. A float and an int convert into each other. A write of another type, or to a key that the blackboard does not have, is warned about and dropped.
- **Reading:** `ai.get_key(s, entity, key)` from frame code, `ai.get(a, key)` in a native action, and `Blackboard.get` from scripts. A module reads its context's `values`.
- **Commands:** the job buffer `ai commands` holds `ai.Command`s: writes, and actions to start or stop. Its flush applies them in its order, which is the order of the systems and then of their jobs.

## Thinking

`ai think` is a `Fixed` system. In each tick it:

1. Stops the native actions that ended since the last tick ([Actions](#actions)).
2. Keeps the pool in step with the world's agents ([Agents](#agents)), and makes ready the agents whose blobs loaded. An agent whose blackboard or decision was recooked, by its blob's key, stops its action and starts again from its defaults.
3. Takes the agents whose next think is due and whose entities are active, and sorts them by `priority`, highest first, then by the tick each last thought in, oldest first, then by slot. The first `budget` of them think: `DEFAULT_THINK_BUDGET` (64), which `ai.set_budget` changes.
4. Runs their decision modules on jobs, `THINK_BATCH` (32) agents to a job. The jobs' commands go into the system's buffer in the agents' order.
5. Places each agent's next think at its interval from now.

An agent's first think is staggered by its slot: the slot's place on the golden ratio's sequence, scaled to the interval. Agents that start together think in ticks spread over their interval rather than in one tick. An agent that the budget delays thinks as soon as its turn comes, and its next think is placed from then.

- **Modules:** `ai.register_module(s, technique, {think})` in `register_world`. `think` gets a `Think_Context`: the agent, its decision and blackboard, its values, its module state (`state_size` bytes from the decision's blob), its action (`Action_View`: the reference that it started, and whether it runs or ended), the seconds since it last thought, and how often it thought. It may read the world, writes only its module state, and asks for its outputs:
  - `ai.condition_holds(t, index)` evaluates a decision's condition;
  - `ai.start_action(t, ref)` asks to start an action reference, which stops the one that runs. Asking for the action that runs does nothing.
  - `ai.stop_action(t)` asks to stop it;
  - `ai.write(t, index)` and `ai.node_writes(t, node)` ask for a decision's writes, with their values as the blackboard is at the think.
- **When outputs apply:** after the tick's `Fixed` systems. A native action starts in the next tick's `ai actions`; a script action in this tick's script step.

## Actions

An action is started with its arguments, ticked, and stopped. Each tick it is `Running`, `Succeeded` or `Failed`. It is stopped when it succeeds or fails, when its agent's decision starts another or stops it, and when its agent goes or starts again. An action that ended stays the agent's `Action_Done`, which its decision sees, until the decision starts another.

When a start applies, the action's name is looked for first among the native actions, then among the script actions. A name that neither has fails at once. Each decision is checked when it loads: a name that no action has, an argument that a native action has no parameter for, or one of another type is warned about.

### Native actions

`ai.register_action(s, Native_Action{name, params, state_size, start, tick, stop})`, in `register_world`, after `ai.register`, which clears the list. A code reload therefore makes it again, and a running action finds its procedures again by its name's hash.

- **Running:** the `ai actions` `Fixed` system, after `ai think`, runs on jobs by chunks of agents. For each agent whose native action is starting, it calls `start` and then `tick`. For one that runs, it calls `tick`. When `tick` gives `Succeeded` or `Failed`, it calls `stop`. An action without `tick` succeeds.
- **Arguments:** `start` gets them, each converted to its parameter's type: a float and an int convert, and a vector constant becomes a position. `ai.arg(a, name)` and `ai.arg_text(a, name)` read them. An action keeps what it needs between ticks in its state, `state_size` bytes up to `MAX_ACTION_STATE` (64), zero when it starts.
- **Writes:** an action writes the blackboard through `a.out`, and the world through its system's buffers, as any job does ([World: Command buffers](../world/ecs.md#command-buffers)).
- **Stopping one that ended early:** a native action that a decision replaced, or whose agent went, is stopped at the start of the next tick's `ai think`, with its state. Its agent may be gone.

### Script actions

```luau
local Bark = Action.define("bark", { line = Param.string("Halt!"), at = Param.entity() })

function Bark:start()
	Animation.trigger(self.entity, "bark")
	self:start_coroutine(function()
		wait(1)
		Animation.trigger(self.entity, "idle")
	end)
end

function Bark:tick(dt)
	return "succeeded"
end

function Bark:stop() end

return Bark
```

- **Defining:** `Action.define(name, params)` makes an action class. `Param.number`, `boolean`, `string`, `vector`, `entity` and `position` declare its parameters, with their defaults. An instance has `entity`, the agent, and a field for each parameter. The cooker reads the parameters as it reads behaviours' fields ([Content: Scripts](../content/kinds/scripts.md#scripts)), into the script's blob with the `Action` flag. An action is not a behaviour, so it cannot be added to an entity.
- **Finding:** an action exists once its module has run: the main script or a behaviour requires it. The prelude keeps each name's first class, so a module that is loaded again after an edit has its class patched in place.
- **Running:** in the scripts' fixed step, after the behaviours' `fixed_update`, through the step's fixed hook, which `ai.register_scripts` sets. In the order of the agents' slots, it stops the script actions that ended, starts each that a decision chose, with its parameters' defaults and then its arguments, and ticks it in the same tick. `tick(dt)` returns `"running"`, `"succeeded"`, `"failed"`, or nothing for running. An error in `start` or `tick` fails the action.
- **Coroutines:** `self:start_coroutine` in an action is owned by the action, and ends with it.
- **Arguments:** a float and an int are numbers, an enum is its name, and the others are as they are.

## The order in a tick

1. `ai perceive`: the perceivers see and hear, and their memories change ([Perception](perception.md#the-order-in-a-tick)).
2. `ai think`: the native actions that ended stop, and the decisions run.
3. `ai actions`: the native actions start and tick.
4. The other `Fixed` systems, such as `nav paths`, which the engine registers after the AI's.
5. The flush: the commands of the tick's jobs apply, in system order and then job order.
6. The scripts' fixed step: the behaviours' `fixed_update`, then the script actions.
7. Physics, then the tick's events: perception's `on_perceive` and `on_forget` among them.

## Determinism

An agent's thinks, actions and blackboard are the same on every run, on one job or many, and with any number of workers:

- The agents that think, and their order, depend on priority, the tick each last thought in, and the slot, never on an `Entity` value.
- Each think job writes only its own agents' module state. Its outputs go into the system's buffer in the agents' order, after every job is done.
- Native action jobs write only their own agents' actions. Their commands land in job order.
- Script actions run serially, in slot order.

The tests compare the thinks, chosen nodes, actions and values of 100 agents on one job and on eight workers, with budgets of 7 and 1000.

## Reload and restart

- **A code reload** keeps the pool: the values, the module states and the running actions. `ai.register` makes the systems, queries and job buffer again and clears the native actions and modules, which `register_world` registers again. The script actions' instances live in the VM, which a code reload keeps.
- **A soft restart** destroys the pool with the `Game`, and the VM with it. Agents start again from their defaults.
- **A recooked blackboard or decision**, by its blob's key, stops the agent's action and starts it again from its defaults.
- **A script hot reload** patches an action class in place, so its instances keep running with the new methods.

## Scripts

| Binding | What it does |
|---|---|
| `Blackboard.get(entity, key)` | The key's value: a number for a float or an int, a boolean, an enum's name, an `Entity` or nil, a `WorldPosition`, or a vector. Nil for an agent that is not ready. |
| `Blackboard.set(entity, key, value)` | Writes the key at once. A write to an agent that is not ready yet, as in `awake`, applies when it is. |
| `Agent.current_action(entity)` | The name of the action that the agent runs or starts, or nil |

An entity without an `Agent`, a key that the blackboard does not have, or a value of another type raises an error.

## Limits

- **Blackboard values set per entity in scenes** are not built: a script sets them in `awake`.
- **Blackboards shared by a group of agents** are not built: each agent has its own.
- **Edit runs no `Fixed` systems**, so agents think only in Play.
- **Inactive agents** do not think, and their actions do not tick, until they are active again.
