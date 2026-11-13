# Decisions

Decisions are `.decision` text files in the content roots. A decision is how an agent picks its actions, by one technique over its blackboard: a behavior tree, utility scores, a GOAP planner or an HTN planner. The parts that every technique uses are shared: conditions over the blackboard's keys, action references and blackboard writes. The rest of a decision is the technique's own.

`just decisions` runs `cook decisions --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`. The daemon cooks decisions like any other kind (`tools/cook/decisions.odin`, with the shared parts in `tools/cook/conditions.odin`).

An `Agent` names its decision and its blackboard ([Blackboards](blackboards.md#blackboards)). A technique's module runs the decision when the agent thinks ([AI: Agents: Thinking](../../ai/agents.md#thinking)).

```
decision 1
technique = behavior_tree
blackboard = $0123456789abcdef0123456789abcdef

node 1 selector
	position = [0, 0]
	children = 2, 4, 5
node 2 sequence
	position = [200, -80]
	when = health < 0.3 and (has_target or mood == alert)
	abort = lower
	children = 3, 6
node 3 set
	set mood = alert
node 6 action
	action = flee(from = target, speed = 4)
node 4 action
	when = target != none and distance(self, target) < 10
	action = bark(line = "Halt!", at = target)
	cooldown = 5
node 5 wait
	seconds = 1
```

**In this document:** [The text](#the-text) · [Shared parts](#shared-parts) · [Techniques](#techniques) · [Behavior trees](#behavior-trees) · [The cook](#the-cook) · [The blob](#the-blob)

## The text

- **The first line** is `decision 1`. A `#` starts a comment, except inside quotes.
- **`technique = <technique>`** is `behavior_tree`, `utility`, `goap` or `htn`. Another name is a problem.
- **`blackboard = $<guid>`** is the blackboard's GUID, from its `.meta` file. The decision's keys are that blackboard's.
- **Other `<setting> = <value>` lines** before the nodes are the technique's.
- **Nodes.** `node <id> <kind>` starts a node, with an ID above 0 that no other node has. The kind is a word that the technique reads. The node's block is the lines indented under it:
  - `when = <condition>`, `action = <action>` and `set <key> = <value>` are the shared parts.
  - `position = [x, y]` is where an editor draws the node, which the cooker does not read.
  - Other `<field> = <value>` lines are the technique's. A field is set once in a node.

## Shared parts

Every technique reads the same three parts, which the cook turns into records that name keys by slot.

### Conditions

A condition is true or false, over the agent's blackboard and the world:

- **Comparisons** of two values of one type: `<`, `<=`, `>`, `>=`, `==` and `!=`. Floats and ints compare as numbers, with all six. Bools, enums and entities compare only with `==` and `!=`.
- **Values:** a key's name, a number, `true` or `false`, `none` (the entity that is none), `self` (the agent), or one of an enum key's names beside it, as in `mood == alert`.
- **`distance(a, b)`**: the meters between two places, each `self`, an entity key or a position key. An entity that is none, dead or without a `Transform` is infinitely far.
- **A bool key** on its own is a condition, as in `has_target`.
- **`and`, `or`, `not` (or `!`) and parentheses** combine conditions.

Positions and vectors appear only in `distance`. A condition's stack is at most `MAX_DECISION_STACK` (16) deep.

### Action references

`<name>(<argument> = <value>, ...)`, or `<name>` without arguments, names an action and the arguments that it starts with ([AI: Agents: Actions](../../ai/agents.md#actions)). Each value is:
- a constant: a number, a quoted string, `true` or `false`, `none`, or `[x, y, z]`;
- a key's name, whose value is read when the action starts;
- or `self`.

The cook does not check the action's name or its parameters: actions are native code or scripts, which the game has. The runtime checks them when the decision loads.

### Blackboard writes

`set <key> = <value>` writes a key when the technique says to. The value is a constant of the key's type, as a default is written ([Blackboards: The text](blackboards.md#the-text)), another key of its type, or `self` for an entity. A node's writes are applied in the order of their lines.

## Techniques

The cook reads the header, the nodes and their shared parts, and gives the rest to the technique's reader: the other header lines, and each node's kind and other fields. The reader:
- reports its problems at their lines;
- may parse conditions, action references and writes of its own fields, such as a planner's preconditions, with the shared parsers (`decision_condition`, `decision_action` and `decision_write`);
- writes the technique's data for the blob, and sizes the module state that each agent keeps, at most `MAX_DECISION_STATE` (4096) bytes.

Each technique adds its reader to `TECHNIQUE_READERS` in `tools/cook/decisions.odin`, and its module at runtime. A decision of a technique that has no reader yet is a problem.

| Technique | Reader | Module |
|---|---|---|
| `behavior_tree` | `BEHAVIOR_TREE_READER` (`tools/cook/behavior_trees.odin`) | `lib/engine/ai/behavior_tree` ([AI: Behavior trees](../../ai/behavior-trees.md)) |
| `utility`, `goap`, `htn` | None yet | None yet |

## Behavior trees

A `behavior_tree` decision is a tree of nodes. Composites run their children, leaves act or test, and decorators on any node change when it runs and what it gives. When the agent thinks, the tree checks the guards that abort, and then it resumes from its running nodes ([AI: Behavior trees](../../ai/behavior-trees.md)).

```
decision 1
technique = behavior_tree
blackboard = $0123456789abcdef0123456789abcdef

# Attack a close target, chase a seen one, search where it was last seen, and patrol.
node 1 selector
	children = 2, 5, 6, 9
node 2 sequence
	when = target != none and distance(self, target) < 2
	abort = both
	children = 3, 4
node 3 action
	action = attack(at = target)
	cooldown = 1.5
node 4 wait
	seconds = 0.5
node 5 action
	when = can_see_target
	abort = lower
	action = move_to(key = "target")
	time_limit = 10
node 6 sequence
	when = searching
	children = 7, 8
node 7 action
	action = move_to(key = "last_seen")
node 8 set
	set searching = false
node 9 action
	action = patrol
	repeat = forever
```

### Nodes

| Kind | Fields | What it does |
|---|---|---|
| `sequence` | `children` | Runs its children in order until one fails. It then fails. It succeeds when the last child succeeds. |
| `selector` | `children` | Runs its children in order until one succeeds. It then succeeds. It fails when the last child fails. |
| `parallel` | `children`, `policy` | Runs its children together. With `policy = one`, it succeeds when one child succeeds, and fails when all fail. With `policy = all`, it succeeds when all succeed, and fails when one fails. When it ends, it stops the children that still run. |
| `action` | `action` | Starts its action reference, and runs until the action ends. It ends with the action's result ([AI: Agents: Actions](../../ai/agents.md#actions)). |
| `wait` | `seconds` | Runs for its seconds, and then succeeds. |
| `set` | `set` lines | Writes its keys and succeeds. Only a `set` node has `set` lines. |
| `condition` | `condition` | Succeeds when its condition holds, and fails when it does not. |

- **`children = <id>, <id>, ...`** lists a composite's children by their IDs, in their order. The first child is the highest priority. A child has one parent. The **root** is the one node that no node lists.
- **`condition = <condition>`** is a condition, as a `when` is ([Conditions](#conditions)).
- **`seconds = <time>`** is a number of seconds, 0 or more, or the name of a float or an int key. The node reads the key when it starts.
- **`position = [x, y]`** is for the editor, as on any node.

### Decorators

Every kind of node takes these fields:

| Field | Values | What it does |
|---|---|---|
| `when` | A condition | A guard: the node starts only when the condition holds. When it does not hold, the node fails and does not run. |
| `abort` | `none` (the default), `self`, `lower` or `both` | The branches that the guard aborts while the agent thinks. `self`: when the guard becomes false, it aborts the node's own branch, which fails. `lower`: when the guard becomes true, it aborts the lower priority that runs, so the node cuts in. `both`: both. A node with `abort` has a `when`. `lower` and `both` are for a selector's children: the lower priorities are the later children of that selector. |
| `invert` | `true` or `false` | Changes the node's success to failure, and its failure to success. |
| `cooldown` | A time | After the node ends, by its result or by an abort, it fails without running until the cooldown passes. |
| `repeat` | A count of 1 or more, or `forever` | Runs the node again while it succeeds, until it has succeeded that count of times. A failure ends it. A node that repeats `forever` never succeeds. |
| `time_limit` | A time | When the node runs for longer than this time, the tree aborts it, and it fails. The time starts when the node starts, and it includes all the repeats. |
| `force` | `succeed` or `fail` | Gives this result, whatever the node's own result is. |

A node's result goes through its decorators in this order:
1. **Start:** if the node is cooling down, or its guard fails, it does not run. Its result is a failure.
2. **Repeat:** if the node succeeds and has repeats left, it runs again.
3. **Invert, then force:** these apply to every result, including a failure in step 1. Thus `force = succeed` with a `when` makes an optional step in a sequence.

### Problems

The reader reports these problems at their lines, in addition to the shared problems ([The cook](#the-cook)):
- a setting in the header: a behavior tree has no settings;
- a decision without nodes;
- an unknown kind or field, or a field that the node's kind does not take, such as `policy` on a `wait`;
- a missing field: `children`, `policy`, `action`, `seconds` or `condition`, or a `set` without `set` lines;
- `set` lines on a node that is not a `set`;
- a child ID that no node has, a child that one node lists twice, or a node that two nodes list;
- more than one root, or no root;
- a cycle: nodes that the root does not reach;
- a tree that is deeper than `MAX_TREE_DEPTH` (32);
- `abort` without `when`, and `abort = lower` or `both` on a node whose parent is not a selector;
- a `parallel` whose policy can never be met. With `one`, no child can succeed. With `all`, a child cannot succeed. A child cannot succeed when it repeats `forever` or has `force = fail`, unless `invert` or `force = succeed` changes this.
- a `parallel` with more than one child whose subtree holds an action: an agent runs one action at a time;
- a key that the blackboard does not have, or a `seconds`, `cooldown` or `time_limit` key that is not a float or an int;
- a time below 0, a `repeat` below 1, and a value that is not one of a field's words.

### The tree's data

The technique's data (`lib/engine/asset/format/behavior_tree.odin`) is a `Tree_Header`, and then the tree's `Tree_Node`s in depth-first order, the root first. Each node has:
- its decision node, which holds its guard, its action and its writes;
- its `end`, one past its subtree. Its first child is the node after it. Each next child is at the `end` of the child before it.
- its kind, its decorators, a `condition` node's condition, and its times, each a constant or the slot of a key;
- the offsets of its state and its timers in the agent's module state.

The reader lays out the module state: `TREE_STATE_SIZE` (16) bytes for each node, and then 8 bytes for each timer. The timers are the end of a `wait`, the start of a node with a `time_limit`, and the tick at which a node with a `cooldown` can start again. The header holds the layout hash of the data. `format.tree_check` refuses data of another layout, subtrees that do not nest, and offsets outside the state. It also refuses a time key that is not a float or an int. The module does this check before an agent starts with the decision.

## The cook

- **The blackboard:** the cook reads the blackboard's source, not its blob, and parses it as the blackboard's cook does, so every key in a condition, an argument or a write is checked against it. The decision depends on its blackboard, so a change to the blackboard cooks the decision again.
- **Problems** have their line. They include:
  - a missing or unknown technique, or a technique without a reader;
  - a missing blackboard, or a GUID that is not a blackboard's, or a blackboard with problems;
  - a key that the blackboard does not have, or a value of another type;
  - a condition that is not true or false, a comparison of two types, an ordered comparison of a non-number, or one of an enum's names that it does not have;
  - a node ID used twice, or a field set twice;
  - the technique's own.

  A decision with a problem keeps its old blob, so the running game keeps the last good version.
- **The cache key** covers the cooker version, the layout, the technique reader's version, the source path, the source, the GUID and the blackboard's own key, which covers its source.

## The blob

A `Decision_Blob` (`lib/engine/asset/format/decision.odin`) holds:
- **The technique**, the module state's size, the blackboard's GUID, and `blackboard_key`, the blackboard's cache key that the decision was cooked against. An agent uses a decision only with a blackboard blob of that key (`format.decision_check`), since its slots are that blackboard's.
- **Nodes**, each with its ID, its kind, its condition and action, or `DECISION_NONE`, and its range of writes.
- **Conditions**, each a range of **ops** in postfix order: `Key` pushes a slot's value, `Constant` a constant and `Self` the agent; `Distance` pops two places; a comparison pops two values of its type; `And`, `Or` and `Not` pop bools.
- **Constants**, each with its type and its bytes as the agent's values hold them, and a string's text.
- **Action references**, each with its name and `animation_graph_hash` of it, and its range of **arguments**, each with its name's hash, its source (a constant, a key or the agent) and its type.
- **Writes**, each a slot and a value's source.
- **The technique's data**, which only the technique reads, aligned to 16.

The view checks every index between the records. A decision blob names its blackboard among its references, so a level's bundle holds both ([Blobs and loading: Bundles](../blobs-and-loading.md#bundles)).

- **The editor** opens a decision in the script editor. It is among the scripts in the content browser.
