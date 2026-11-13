# Behavior trees

The decision module of the `behavior_tree` technique, in `lib/engine/ai/behavior_tree`. When an agent thinks, the module checks the guards that abort, and then resumes the agent's tree from its running nodes. Read [Agents](agents.md) and [Content: Decisions: Behavior trees](../content/kinds/decisions.md#behavior-trees) first. The second document gives the text, the nodes and the decorators.

**In this document:** [Design](#design) · [Registering](#registering) · [A think](#a-think) · [Aborts](#aborts) · [Actions](#actions) · [Time](#time) · [Repeats](#repeats) · [Determinism](#determinism) · [Reload and restart](#reload-and-restart) · [Last results](#last-results) · [The sample](#the-sample) · [Limits](#limits)

## Design

1. **The tree is data, in depth-first order.** The cooker writes the nodes as an array, with each node's subtree as a range. A node's children and its subtree are found by index, and aborting a subtree is one loop over its range.
2. **The state is in the agent.** Each node has 16 bytes of state, and its timers, at offsets in the agent's module state, which the cooker sizes. The module holds no state of its own. A code reload therefore keeps every tree where it was ([Agents: Reload and restart](agents.md#reload-and-restart)).
3. **Every value comes from the blackboard or the node.** Guards, conditions, times and action arguments read the agent's keys or the node's constants. The tree calls no script.
4. **Priority is order.** A node is higher in priority than the nodes after its subtree. Aborts use this order, as Unreal's observer aborts do.

## Registering

`behavior_tree.register(&g.ai)` registers the module for the `behavior_tree` technique. `register_world` calls it after `ai.register`, which clears the modules, so a code reload registers the module again.

The module has a `check`, which `ai` calls before an agent starts with a decision ([Agents: Thinking](agents.md#thinking)). It runs `format.tree_check`, so `think` reads only data whose indices, ranges, offsets and time keys were checked. If the check refuses the data, the agent waits, and `ai` gives a warning once.

## A think

A node's status is `Idle`, `Running`, `Again` (a repeat that starts at the next think), `Succeeded` or `Failed`. A zero state is `Idle`, so an agent that starts or starts again begins at the root.

When the agent thinks, the module resumes the root if it runs. If the root does not run, the module starts it. A tree that ended therefore starts again at the next think.

**Starting a node:**
1. If the node is cooling down, or its guard does not hold, it fails without running ([Decorators](../content/kinds/decisions.md#decorators)).
2. The node runs. A `time_limit` notes the tick.
3. Its kind starts:
   - A sequence or a selector starts its first child.
   - A parallel starts each child in order, until its policy ends it.
   - An action asks to start its action reference.
   - A wait notes its end tick.
   - A set asks for its writes and succeeds.
   - A condition succeeds or fails.

**Resuming a node that runs:**
1. If the node's `time_limit` has passed, the module aborts the node, and the node fails.
2. If the node's guard has `abort = self` or `both`, and the guard does not hold, the module aborts the node, and the node fails.
3. A selector checks its earlier children whose guards abort lower priorities ([Aborts](#aborts)).
4. The node's kind continues:
   - A sequence or a selector resumes its running child. When that child ends, it starts the next child, until the composite ends.
   - A parallel resumes its running children.
   - An action reads the agent's action ([Actions](#actions)).
   - A wait succeeds when its end tick comes.

**When a node ends**, its repeat, its `invert` and its `force` apply, in this order, and its cooldown starts. **Aborting a node** stops each running node in its subtree. Each one becomes `Idle` and starts its cooldown. An action that runs is stopped.

## Aborts

The guards of the running nodes, and of the earlier children of the running selectors, are checked as the think goes down the tree, before the nodes below them resume. A higher abort therefore comes before the checks below it.

| `abort` | When the module checks it | What it does |
|---|---|---|
| `none` | When the node starts | A node whose guard does not hold fails without running. |
| `self` | Also, while the node runs | When the guard becomes false, the module aborts the node, and the node fails. Its parent continues as for any failure. |
| `lower` | Also, while its selector runs a later child | When the guard becomes true, and the node is not cooling down, the module aborts the running child, and the selector starts this node. |
| `both` | Both | Both. |

`lower` and `both` are only for a selector's children, which the cooker checks. A later child of a sequence runs only after the earlier children succeeded, so cutting in there has no meaning. The selector's first earlier child whose guard holds cuts in, so the highest priority comes first.

## Actions

An agent runs one action at a time ([Agents: Actions](agents.md#actions)). An action node asks for its start when it starts. The start applies after the tick, so the node sees its action running from the next think. Then, at each think, the node reads `Think_Context.action`:
- **its own reference, running:** the node runs;
- **its own reference, ended:** the node ends with the action's result;
- **another reference:** something replaced its action, and the node fails.

An aborted action node asks to stop the action. A parallel ends its running children in the same way, and the cooker refuses a parallel in which more than one child can run an action.

## Time

Waits, cooldowns and time limits count world ticks (`world.clock.tick`). A time in seconds becomes ticks at the clock's tick rate, rounded to the nearest tick. A time from a key is read when the node starts a wait, or when the node ends for a cooldown. A time limit reads its key at each check. A node sees time pass only when the agent thinks. A wait of 0.5 s therefore ends at the first think on or after its end tick.

## Repeats

A node with `repeat` runs its kind again each time it succeeds, until it has succeeded the count of times. A node that repeats `forever` never succeeds. Its guard and its cooldown are not checked between repeats: they apply to the node, not to each run. A `time_limit` counts from the node's first start.

If a run ends in the same think in which it started, the node does not run again at once. It becomes `Again`, and runs at the next think. A think therefore never loops, even for a `set` that repeats `forever`.

## Determinism

The module writes only the agent's module state and the outputs of its `Think_Context`. It reads the blackboard as it was at the think, so a tree gives the same result on one job or many ([Agents: Determinism](agents.md#determinism)). The tests compare the module state and the values of 60 agents, on one job and on eight workers.

## Reload and restart

- **A code reload** keeps each node's state, timers and running action. The sequence goes on from its running child, and the running action is neither started again nor stopped.
- **A recooked decision or blackboard** starts the agent again from its blackboard's defaults, with every node `Idle`.
- **A soft restart** starts every agent again.

## Last results

Each node's state keeps how the node last ended, for the [decision editor](../editor/decision-editor.md#live-view): `Succeeded` or `Failed`, which is the result that it gave its parent, after its invert and force, or `Aborted` when an abort stopped it while it ran. A guard or a cooldown that fails a node sets `Failed`. Starting a node again keeps the old result until the node ends. The module's `nodes` hook gives each node that runs or has a result, by its decision node's ID ([Agents: The editor](agents.md#the-editor)). The result is a byte of the node's padding, so the state keeps its size.

## The sample

`samples/mygame`'s guard scene, which F7 cycles to, has a guard whose tree (`content/ai/guard.decision`) chases the player that it sees, with `move_to` and an abort of both, and barks when it is close, with a guard that cuts into the chase. A noise that it remembers draws it, with an abort of lower. When it loses sight of the player, or hears their steps, it searches where it last perceived them. Otherwise it patrols between random points that the `next_patrol_point` script action picks, and looks about at each. H swaps the tree with an HTN over the same blackboard and actions ([AI: The sample](README.md#the-sample)). Select the guard in the decision editor while the game plays to see its running branch ([Editor: Decision editor](../editor/decision-editor.md#live-view)).

## Limits

- **Writes apply after the tick.** A node after a `set` in the same think reads the old values. It reads the new values from the next think.
- **One action at a time.** A `parallel` can run at most one action, and the other children wait, test or write.
- **Decorators are fields.** A node has at most one of each. A node with two guards needs a parent node.
- **No subtrees from other decisions**, and no services that run while a branch runs. A script or a perception writes the keys that the guards read.
