# GOAP

The decision module of the `goap` technique, in `lib/engine/ai/goap`, and the plan runner, in `lib/engine/ai`, which the planning techniques share. When an agent thinks, the module picks the goal of the highest priority that is not yet true, searches for the cheapest plan of actions that reaches it, and runs the plan. Read [Agents](agents.md) and [Content: Decisions: GOAP](../content/kinds/decisions.md#goap) first. The second document gives the text, the goals, the actions, their tests and effects, and the data.

**In this document:** [Design](#design) · [Registering](#registering) · [A think](#a-think) · [Goals](#goals) · [The search](#the-search) · [The budget](#the-budget) · [The plan runner](#the-plan-runner) · [Replanning](#replanning) · [The plan for debugging](#the-plan-for-debugging) · [Determinism](#determinism) · [Reload and restart](#reload-and-restart) · [Limits](#limits)

## Design

1. **The agent finds its own way.** A designer gives actions preconditions and effects, and gives goals. The agent then finds the actions that reach a goal, in their order, such as getting a weapon before it attacks. No one writes the order.
2. **Planning has a fixed cost in each tick.** The search expands a budget of nodes in each tick, shared among the agents that search. Many agents that plan again at once therefore spread their searches over ticks, and do not make a spike.
3. **The state is in the agent.** The phase, the plan, the expected world state and the search, with its open and closed nodes, are at offsets in the agent's module state, which the cooker sizes. A job cannot wait across frames ([Core: Job system](../core/jobs-and-memory.md#job-system)), so a search that does not end in its think goes on from that state in the next tick. The module holds no state of its own, so a code reload keeps every agent where it was.
4. **A plan is a list of actions, however it was made.** The plan runner reads only the actions, their preconditions and their effects, so the HTN technique can run its plans with the same runner.

## Registering

`goap.register(&g.ai)` registers the module for the `goap` technique. `register_world` calls it after `ai.register`, which clears the modules, so a code reload registers the module again.

The module has a `check`, which `ai` calls before an agent starts with a decision ([Agents: Thinking](agents.md#thinking)). It runs `format.goap_check`, so `think` reads only data whose counts, indices, intervals, offsets and keys were checked. If the check refuses the data, the agent waits, and `ai` gives a warning once.

The module also has `searching`, which tells the think system whether the agent's state holds a search, and `plan`, which gives the agent's goal and plan ([Agents: Planning](agents.md#planning)).

## A think

1. **The world state** is read from the agent's values: one value for each planning key ([Content: Decisions: Tests and effects](../content/kinds/decisions.md#tests-and-effects)). If a goal failed, and a planning key now differs from the world state that it failed in, every goal can be tried again.
2. **A running plan** goes through the runner ([The plan runner](#the-plan-runner)). When it is done, or the runner asks to plan again, the agent has no plan. The effects that the runner writes in this think are in the world state from now on, though they apply to the blackboard only after the tick.
3. **The current goal** is picked ([Goals](#goals)).
4. **If the agent runs a plan for another goal**, the module stops the plan's action, and the agent has no plan.
5. **If the agent searches for another goal**, the search stops. Otherwise the search goes on, within the agent's share of the budget ([The search](#the-search)). A plan that it finds starts. A search that fails marks its goal failed, and the current goal is picked again without it.
6. **If the agent has no plan and there is a current goal**, a search for it begins. It expands no node until the next think, which has a share of the budget ([The budget](#the-budget)).

## Goals

Each goal's priority is computed in each think. A goal whose `when` does not hold has priority 0. Otherwise its priority is its `priority` times its considerations' scores, each made up for their count by the compensation factor, as a utility option's score is ([Utility: Scoring](utility.md#scoring)). The considerations are utility's: the same inputs, ranges and curves, and the module scores them with utility's own procedures.

The **current goal** is the goal with the highest priority above 0 whose desired state is not true in the world state, and that did not fail. Of equal priorities, it is the first goal in the text. When no goal is current, the agent does nothing.

A goal **fails** when a search for it does not find a plan. The module keeps the failed goals and the world state that the last one failed in. A failed goal is not current again until a planning key differs from that state, so an agent does not search for a goal that it cannot reach in each think.

## The search

The search is a regressive A* (Orkin), in `lib/engine/ai/goap/search.odin`. It reads only the technique's data, so a tool can plan as the runtime does.

- **A node** is a state that the search regressed to: an interval of values for each planning key. A key that the state does not constrain is free. The **root** is the goal's desired state.
- **The search begins** with the world state, the actions whose `when` holds, and each action's cost, all as they are when it begins. A cost from a key below `MIN_COST` (0.001) counts as `MIN_COST`.
- **An action leads to a node** when at least one of its effects touches a key that the node constrains, and no effect contradicts the node: a `set` must give a value in the key's interval. The state before the action frees the keys that it sets, shifts the intervals of the keys that it adds to, and then takes the action's preconditions. If a precondition contradicts the state, the action does not lead there.
- **A node is found** when the world state is in all of its intervals. The plan is the actions on the way from it back to the root, which is the order that they run in.
- **The order:** the search takes the open node of the lowest `f`, the cost from the goal plus the heuristic, and the first made of equal ones. It makes the children of a node in the actions' order, so the actions' order breaks ties, and a plan is the same on every run.
- **The heuristic** is the count of keys that the world state does not satisfy, times the least cost of an effect among the usable actions, which is an action's cost over its count of effects. No plan can satisfy a key for less, so the heuristic never overestimates, and the plan that the search finds is the cheapest.
- **A node of a state that the search has** is not made again. If the new way to it costs less, the node takes the new way and is open again.
- **The search fails** when no node is open, or when a new node does not fit in the `max_nodes` nodes of the state. A node at a depth of `max_plan` makes no children, so a plan is at most `max_plan` actions.

## The budget

Each technique has a plan budget: the nodes that its agents expand in a tick, `ai.DEFAULT_PLAN_BUDGET` (256) by default, which `ai.set_plan_budget(s, .Goap, nodes)` changes. The think system shares it among the agents that think in the tick and whose state holds a search ([Agents: Planning](agents.md#planning)). A search that is not done thinks again in the next tick, whatever the agent's interval, so it ends in the fewest ticks that the budget gives.

A search begins in one think and expands from the next. A new plan therefore costs at least one tick more than its search.

## The plan runner

The runner is in `lib/engine/ai/plan.odin`. A plan is the actions' indices in the agent's module state, and the runner keeps the step that runs and the world state that the plan expects now. A module calls:

- **`ai.plan_start`** with a plan that it made. The runner checks the plan from the world state now: each action's preconditions in its turn, with the effects of the actions before it, and the goal's tests after the last. It checks the first action's `when` too. If the plan holds, it expects the world state now, and starts the first action with its `set` writes. If the plan does not hold, the GOAP module searches again from the world state now.
- **`ai.plan_think`** in each think while the plan runs:
  - **The action runs:** the runner checks the keys that the rest of the plan depends on against the world state that it expects ([Replanning](#replanning)).
  - **The action succeeded:** the runner writes the action's effects to the blackboard, and the expected world state gains them. It then checks the next action's `when` and preconditions against the world state as the effects leave it, and starts it. After the last action, the plan is done.
  - **The action failed,** or another action replaced it: the runner asks to plan again.

The **effects are writes.** When an action succeeds, the runner writes its effects to the blackboard, so the blackboard follows the plan's state: a `set` writes its value, and an add writes the key's value with the add. An action therefore does not write its own effects. A start applies after the tick, so the runner sees the action that it started from the next think.

## Replanning

The agent plans again when:
- **its action fails**, or something else replaces it;
- **the next action's `when` or preconditions do not hold** when its turn comes;
- **a planning key that the rest of the plan depends on is not the value that the plan expects.** The keys that it depends on are those that the preconditions of the actions from the step that runs test, and those that the goal tests. The runner stops the running action. A change that keeps a plan possible, such as ammo that goes from 5 to 4, makes the agent plan again too, since a better plan may now exist.
- **another goal becomes current**, of a higher priority, or because the plan's goal is no longer the current one. The module stops the running action.

A `set` line on an action cannot write a planning key: the cook refuses it, since the change would make the agent plan again at once. An action that writes a planning key itself, besides its effects, also makes the agent plan again.

## The plan for debugging

`ai.plan(s, entity)` gives the agent's plan as an `ai.Plan_View`: the current goal's decision node ID, or 0; each goal's priority in the last think; the plan's actions, each its decision node ID and its action's name; the step that runs; the node count of the last search that ended; and whether the agent searches now. A module gives these through `Module.plan`. Scripts read the same through `Agent.plan(entity)` ([Agents: Scripts](agents.md#scripts)), and the decision editor's live view is to read them too.

## Determinism

The module writes only the agent's module state and the outputs of its `Think_Context`. It reads the blackboard as it was at the think. The agents' shares of the budget depend only on the order of the agents that think and their states, never on a job ([Agents: Planning](agents.md#planning)). The search's order depends only on `f` and the order in which nodes are made. A plan is therefore the same on one job or many. The tests compare the module state and the values of 60 agents that search, fail, plan again and change goals, with a budget of 7 nodes, on one job and on eight workers.

## Reload and restart

- **A code reload** keeps the phase, the search, the plan, its step, the failed goals and the running action. The action is neither started again nor stopped.
- **A recooked decision or blackboard** starts the agent again from its blackboard's defaults, with no plan.
- **A soft restart** starts every agent again.

## Limits

- **The state is small.** A search's nodes are in the agent's module state, at most `MAX_DECISION_STATE` (4096) bytes, and each node takes 16 bytes and 8 for each planning key. With 4 keys, a search holds about 60 nodes. The cook reports a decision whose state does not fit.
- **The world state is ints.** Planning keys are bools, ints and enums, at most `MAX_PLAN_KEYS` (32). Floats, entities and positions are not planned over, but conditions can read them: a `when` on an action keeps it out of a search, and on a goal keeps the goal from being current.
- **Tests are intervals.** Each key's tests make one interval, so `!=` is only for bools.
- **Costs are read when the search begins.** A cost key that changes during a search changes the next search.
- **One goal at a time.** A plan reaches one goal. The module does not plan for several goals together.
- **A failed goal waits for a change.** A goal fails until a planning key changes, even when the change that would make it possible is in a key that is not planned over.
