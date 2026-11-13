# HTN

The decision module of the `htn` technique, in `lib/engine/ai/htn`. When an agent thinks, the module breaks its root task down into a plan of actions, by the methods of each compound task in their order. It runs the plan with GOAP's plan runner. While the plan runs, the module breaks the root down again on each think, to find a better method. Read [Agents](agents.md), [GOAP](goap.md) and [Content: Decisions: HTN](../content/kinds/decisions.md#htn) first. The last gives the text, the tasks, methods and actions, and the data.

**In this document:** [Design](#design) · [Registering](#registering) · [A think](#a-think) · [Decomposition](#decomposition) · [The method traversal record](#the-method-traversal-record) · [The budget](#the-budget) · [Running a plan](#running-a-plan) · [Replanning](#replanning) · [The plan for debugging](#the-plan-for-debugging) · [Determinism](#determinism) · [Reload and restart](#reload-and-restart) · [Limits](#limits)

## Design

1. **The designer gives the structure.** A task names the ways to do it, in order of preference, such as an attack in melee when the target is close and a ranged attack otherwise. The plan follows that structure. The planner does not search for the order of the actions, as GOAP does.
2. **A better way cuts in.** Each plan keeps the methods that it chose. While it runs, the module looks for a plan of earlier methods, and replaces the running plan when it finds one. A guard who searches drops the search when it sees the player.
3. **Planning has a fixed cost in each tick.** A decomposition takes a budget of steps in each tick, shared among the agents that decompose, as GOAP's search does ([GOAP: The budget](goap.md#the-budget)).
4. **The state is in the agent.** The phase, the plan, its record and the decomposition are in the agent's module state, which the cooker sizes. The module holds no state of its own, so a code reload keeps every agent where it was.
5. **One runner.** The plan is a list of actions, which GOAP's plan runner runs ([GOAP: The plan runner](goap.md#the-plan-runner)).

## Registering

`htn.register(&g.ai)` registers the module for the `htn` technique. `register_world` calls it after `ai.register`, which clears the modules, so a code reload registers the module again.

The module has a `check`, which runs `format.htn_check` before an agent starts with a decision ([Agents: Thinking](agents.md#thinking)). If the check refuses the data, the agent waits, and `ai` gives a warning once. It also has `searching`, which is true while the agent decomposes, and `plan` ([Agents: Planning](agents.md#planning)).

## A think

1. **The world state** is read from the agent's values: one value for each planning key, as GOAP's ([Content: Decisions: Tests and effects](../content/kinds/decisions.md#tests-and-effects)).
2. **A running plan** goes through the runner. When it is done, or the runner asks to plan again, the agent has no plan, and a decomposition that looks for a better plan stops. The effects that the runner writes in this think are in the world state from now on.
3. **Without a plan**, the agent begins a decomposition of the root, the `Planning` phase. It takes no step until the next think, which has a share of the budget ([The budget](#the-budget)).
4. **While the agent plans**, the decomposition goes on within the agent's share of the budget. A plan that it finds starts if it still holds from the world state now ([Running a plan](#running-a-plan)). Otherwise a new decomposition begins from the world state now. A decomposition that fails leaves the agent without a plan, and the agent begins again at its next think.
5. **While a plan runs**, the agent begins a decomposition that looks for a better plan, the `Checking` phase. In the next think it goes on with it ([The method traversal record](#the-method-traversal-record)). A better plan replaces the running one. When the decomposition finds none, the plan runs on, and the next think begins another.

## Decomposition

The decomposition is a total-order forward decomposition, as SHOP's (Nau et al.), in `lib/engine/ai/htn/decompose.odin`. It reads only the technique's data and the world state.

- **It begins** with the world state, and with the methods and actions whose `when` holds, all as they are when it begins. It works on a copy of the world state, and its to-do list starts with the root task.
- **A compound task** takes the first of its methods, in its order, that the decomposition may use and whose preconditions hold in the copy. The method's subtasks go on the to-do list, in their order, before the rest.
- **A primitive task**, an action, must be usable, and its preconditions must hold in the copy. Its effects then apply to the copy, and it joins the plan.
- **It backtracks** when a task fails: a compound task with no method left, or an action whose preconditions do not hold. It goes back to the last method that it chose, which may be of a task that it finished, and tries that task's next method. With no choice left, it fails.
- **It keeps no snapshots.** A backtrack begins again from the world state that the decomposition began in, takes its recorded choices again up to the one that it retries, and goes on from there. The state of a decomposition is therefore small and of a fixed size.
- **A step** is one task taken from the to-do list, the replayed ones among them. Each step counts against the budget.
- **It is found** when the to-do list is empty. The plan is the actions in the order that the decomposition took them.

## The method traversal record

Each decomposition keeps its record: for each compound task that it broke down, in its order, the index of the method that it chose, among the task's methods (Humphreys). The running plan keeps the record of the decomposition that made it.

A record is better than another when, at the first place where they differ, its method is earlier. On each think while a plan runs, the module decomposes the root again from the world state now, bounded by the running plan's record:
- While the new choices are equal to the record, a task takes no method after the record's at that place. An earlier method makes the record better, and the decomposition then goes on without a bound.
- A decomposition that ends with a record equal to the running plan's has found the same plan, which goes on. So does one that fails.
- A decomposition that finds a better record replaces the running plan, if its plan holds from the world state now and its first action's `when` holds. Its first action replaces the running one. When it is the same action reference that runs, the action goes on, and is not started again.

The decomposition goes only as far as it takes to find a better record, or to find that there is none.

## The budget

The `htn` technique has its own plan budget, `ai.DEFAULT_PLAN_BUDGET` (256) steps in each tick by default, which `ai.set_plan_budget(s, .Htn, steps)` changes. The think system shares it among the agents that think in the tick and that decompose, in the `Planning` or the `Checking` phase ([Agents: Planning](agents.md#planning)). An agent that decomposes thinks again in the next tick, whatever its interval.

A decomposition begins in one think and takes steps from the next. A new plan therefore costs at least one tick more than its decomposition. While a plan runs, the agent decomposes in every other think at least: one think begins the decomposition, and the next takes its steps.

## Running a plan

The module runs a plan with GOAP's runner, `ai.plan_start` and `ai.plan_think`, without a goal ([GOAP: The plan runner](goap.md#the-plan-runner)). The runner writes each action's effects to the blackboard when the action succeeds. It checks the next action's `when` and preconditions before it starts the action.

## Replanning

The agent decomposes the root again, from the world state as it is, when:
- **its plan is done**;
- **its action fails**, or something else replaces it;
- **the next action's `when` or preconditions do not hold** when its turn comes;
- **a planning key that the rest of the plan depends on is not the value that the plan expects.** The runner stops the action ([GOAP: Replanning](goap.md#replanning)).

A better record replaces the plan without a stop when its first action is the action that runs ([The method traversal record](#the-method-traversal-record)).

## The plan for debugging

`ai.plan(s, entity)` gives the agent's plan as an `ai.Plan_View`. An HTN plan has no goal, so `goal` is 0 and `goals` is empty. While a plan runs, `steps` are its actions, each its decision node ID and its action's name, and `step` is the step that runs. `methods` are its record, each a task's decision node ID and the ID of the method that it chose, in the order of the decomposition. `nodes` is the steps of the last decomposition that ended, and `searching` is whether the agent decomposes now. Scripts read the same through `Agent.plan(entity)` ([Agents: Scripts](agents.md#scripts)), and the decision editor's live view is to read them too.

## Determinism

The module writes only the agent's module state and the outputs of its `Think_Context`. It reads the blackboard as it was at the think. A decomposition's order depends only on the data, the world state and the usable methods and actions when it began. The agents' shares of the budget depend only on their order and their states. A plan is therefore the same on one job or many. The tests compare the module state and the values of 60 agents that decompose, backtrack, fail, find better methods and plan again, with a budget of 7 steps, on one job and on eight workers.

## Reload and restart

- **A code reload** keeps the phase, the plan, its record, the decomposition and the running action. The action is neither started again nor stopped.
- **A recooked decision or blackboard** starts the agent again from its blackboard's defaults, with no plan.
- **A soft restart** starts every agent again.

## Limits

- **The decomposition is bounded.** At most `MAX_HTN_DEPTH` (32) methods are nested on the to-do list, a record holds at most `MAX_HTN_RECORD` (64) choices, and a plan holds at most `max_plan` actions. A method that needs more fails, and the decomposition backtracks. This bounds a task that recurs.
- **A long search is slow, not costly.** A domain whose decompositions fail deep in many ways takes many steps. The budget spreads them over ticks, but the plan comes late.
- **A plan's own effects can make an earlier method possible.** The record check then finds a better plan, which replaces the running one, as any better plan does. A domain whose methods test the effects of their own actions can switch plans part of the way through.
- **Preconditions are read during a decomposition.** A method whose preconditions stop holding while its plan runs does not stop the plan. The runner checks the actions' preconditions, and the record check finds a better method.
- **Guards are read when a decomposition begins.** A `when` that changes during a decomposition changes the next one.
- **No goal.** The module decomposes its root task, and does not check that a plan reaches a state. A plan that is done makes the agent decompose the root again.
- **No partial order.** The subtasks of a method are done in their order, and the module does not interleave the subtasks of two methods.
