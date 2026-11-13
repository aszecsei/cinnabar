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

**In this document:** [The text](#the-text) · [Shared parts](#shared-parts) · [Techniques](#techniques) · [Behavior trees](#behavior-trees) · [Utility](#utility) · [GOAP](#goap) · [The cook](#the-cook) · [The blob](#the-blob)

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
| `utility` | `UTILITY_READER` (`tools/cook/utility.odin`) | `lib/engine/ai/utility` ([AI: Utility](../../ai/utility.md)) |
| `goap` | `GOAP_READER` (`tools/cook/goap.odin`) | `lib/engine/ai/goap` ([AI: GOAP](../../ai/goap.md)) |
| `htn` | None yet | None yet |

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

## Utility

A `utility` decision is a set of options. When the agent thinks, the module scores each option from its considerations, and runs the best one ([AI: Utility](../../ai/utility.md)).

```
decision 1
technique = utility
blackboard = $0123456789abcdef0123456789abcdef
pick = weighted
within = 0.2
momentum = 0.25

# Attack the best enemy that it perceives, flee when hurt, and otherwise patrol.
node 1 option
	action = attack(at = target)
	weight = 2
	considerations = 4, 5
	target = target
	target_tag = enemy
	cooldown = 1.5
node 2 option
	when = health < 30
	action = flee
	considerations = 6
	set mood = alert
node 3 option
	action = patrol
	weight = 0.2
node 4 consideration
	input = health
	range = [0, 100]
	curve = logistic
node 5 consideration
	input = distance(self, target)
	range = [0, 30]
	curve = table
	points = [0, 1], [0.3, 0.9], [1, 0]
node 6 consideration
	input = health
	range = [0, 100]
	curve = polynomial
	slope = -1
	exponent = 2
	y_shift = 1
```

### Settings

| Setting | Values | What it does |
|---|---|---|
| `pick` | `best` (the default) or `weighted` | `best` runs the option with the highest score, the first of equal ones. `weighted` picks at random among the options whose score is at least the best times `1 - within`, each in proportion to its score. |
| `within` | A fraction from 0 to 1 (0.1 by default) | The band of a weighted pick. Only with `pick = weighted`. |
| `momentum` | A fraction of 0 or more (0.25 by default) | The running option's score is multiplied by `1 + momentum`. Another option cuts in only when its score is above that. |

### Options

An `option` node names an action and how to score it:

| Field | Values | What it does |
|---|---|---|
| `action` | An action reference | The action that the option runs ([Action references](#action-references)). Required. |
| `weight` | A number of 0 or more (1 by default) | Multiplies the option's score. |
| `considerations` | `<id>, <id>, ...` | The consideration nodes that score the option. One consideration can serve several options. An option without considerations scores its weight. |
| `when` | A condition | A guard: when it does not hold, the option scores 0. |
| `set <key> = <value>` | Writes | Applied when the option starts. |
| `cooldown` | A time: seconds, or a float or an int key | After the option ends, it scores 0 until this time passes. |
| `target` | An entity key | The option is scored once for each entity that the agent perceives now ([AI: Perception](../../ai/perception.md#memory)). While each entity is scored, the key holds it, for the guard and the considerations. The best entity is written into the key when the option wins. |
| `target_tag` | A tag's name, from `perception.tags` | With `target`, only the perceived entities of this tag. |

An option's **score** is its weight times the product of its considerations' scores. Each consideration's score is first made up for the count of the option's considerations, so that an option with more considerations does not score lower only for that. With `n` considerations, a score `s` becomes `s + (1 - s) × (1 - 1/n) × s`. This is Dave Mark's compensation factor. For example, 0.5 with two considerations becomes 0.625.

### Considerations

A `consideration` node reads an input, normalizes it over its range to 0 to 1, and maps it through a curve:

| Field | Values | What it does |
|---|---|---|
| `input` | A float, int or bool key; `distance(<place>, <place>)`; or `since(<key>)` | The value to read. A bool is 0 or 1. `distance` is the meters between two places, each `self`, an entity key or a position key. An entity that is none, dead or without a `Transform` is infinitely far. `since` is the seconds since the key's value last changed, or since the agent started. Required. |
| `range` | `[min, max]`, with min and max not equal | Normalizes the input: min becomes 0 and max becomes 1, and the values beyond them are clamped. A range can go down, as `[30, 0]` does. `[0, 1]` by default. A bool takes no range. |
| `curve` | `linear`, `polynomial`, `logistic`, `logit`, `step` or `table` | The response curve. Required. |
| `slope`, `exponent`, `x_shift`, `y_shift` | Numbers (1, 1, 0 and 0 by default) | The curve's parameters. `exponent` is above 0. |
| `points` | `[x, y], [x, y], ...` | A table's points, at least 2 and at most `MAX_UTILITY_POINTS` (32), in the order of their x. |

For an input `x` from 0 to 1, with `u = x - x_shift`, a curve gives `slope × f(u) + y_shift`, clamped to 0 to 1. A result that is not a number is 0.

| Curve | `f(u)` |
|---|---|
| `linear` | `u` |
| `polynomial` | `u ^ exponent` |
| `logistic` | `1 / (1 + e^(-10 × exponent × (u - 0.5)))`, an S through (0.5, 0.5) |
| `logit` | `0.5 + ln(u / (1 - u)) / (10 × exponent)`, the inverse of `logistic` |
| `step` | 1 when `u` is 0.5 or more, else 0 |
| `table` | The line through the points, raised to the exponent. Beyond the points, it is the first or the last point's y. Where two points have one x, it is the later point's y. |

`linear` and `step` have no `exponent`.

### Problems

The reader reports these problems at their lines, in addition to the shared problems ([The cook](#the-cook)):
- a setting other than `pick`, `within` and `momentum`, a value that a setting does not take, and `within` without `pick = weighted`;
- a decision without options;
- an unknown kind or field, or a field that the node's kind does not take, such as `curve` on an option, or `when`, `action` or `set` lines on a consideration;
- an option without `action`, and a consideration without `input` or `curve`;
- a consideration ID that no node has, a node that is not a consideration, a consideration that an option lists twice, and a consideration that no option lists;
- a key that the blackboard does not have, or a key of a type that the field does not take: an input that is not a float, an int or a bool, a place that is not an entity or a position, a `target` that is not an entity, and a `cooldown` key that is not a float or an int;
- `target_tag` without `target`;
- a `range` on a bool's input, or a range whose min and max are equal;
- `exponent` on `linear` or `step`, an `exponent` of 0 or less, `points` on a curve that is not `table`, and a `table` without points;
- fewer than 2 points, more than 32 points, or points that are not in the order of their x;
- a negative `weight` or `cooldown`.

### The utility's data

The technique's data (`lib/engine/asset/format/utility.odin`) is a `Utility_Header`, then the `Utility_Option`s, the `Utility_Consideration`s, the links from each option to its considerations, and the `Utility_Point`s of the tables. The options and the considerations are in the text's order.
- **An option** has its decision node, which holds its guard, its action and its writes. It also has its weight, its range of links, its target's slot or `DECISION_NONE`, its tag's hash, its cooldown, and the offsets of its state.
- **A consideration** has its decision node, for its ID. It also has its input and its slots (`UTILITY_SELF` is the agent), its range, its curve and parameters, and its range of points.

The reader lays out the module state:
1. `Utility_Running` (8 bytes): the running option, plus 1, so a zero state runs none.
2. A `Utility_Option_State` (24 bytes) for each option: the tick that its cooldown ends, its best target, and its last score.
3. A `Utility_Link_State` (8 bytes) for each link of each option: the last normalized input and score of each consideration.

The header holds the layout hash, the pick, `within` and `momentum`. `format.utility_check` refuses data of another layout, links, points and nodes out of range, an option without an action, states outside the module state, and keys of types that the data does not read. The module does this check before an agent starts with the decision.

## GOAP

A `goap` decision is a set of goals and actions over planning keys. When the agent thinks, the module picks the goal of the highest priority that is not yet true, searches for the cheapest plan of actions whose effects reach it, and runs the plan ([AI: GOAP](../../ai/goap.md)).

```
decision 1
technique = goap
blackboard = $0123456789abcdef0123456789abcdef
keys = armed, ammo, near, down
max_nodes = 48
max_plan = 6

# Down the target when there is one, more so when healthy, and otherwise keep ammo.
node 1 goal
	when = target != none
	desired = down
	priority = 10
	considerations = 20
node 2 goal
	desired = ammo >= 5
node 10 action
	action = pick_up(item = "rifle")
	effects = armed = true, ammo += 6
	cost = 2
node 11 action
	action = attack(at = target)
	when = can_see_target
	preconditions = armed and ammo > 0 and near
	effects = down = true, ammo -= 1
	set mood = alert
node 12 action
	action = move_to(key = "target")
	preconditions = not near
	effects = near = true
	cost = travel_cost
node 20 consideration
	input = health
	range = [0, 100]
	curve = linear
```

### Settings

| Setting | Values | What it does |
|---|---|---|
| `keys` | `<key>, <key>, ...` | The planning keys: bool, int and enum keys of the blackboard, at most `MAX_PLAN_KEYS` (32). The planner's world state is their values. Required. |
| `max_nodes` | A count from 1 to `MAX_GOAP_NODES` (1024), 64 by default | The most nodes that a search holds. The cook sizes the agents' state from it. |
| `max_plan` | A count from 1 to `MAX_PLAN_LENGTH` (32), 8 by default | The most actions in a plan. |

### Goals

A `goal` node is a state that the agent wants:

| Field | Values | What it does |
|---|---|---|
| `desired` | Tests ([Tests and effects](#tests-and-effects)) | The state that the goal wants. A goal whose desired state is true is not current. Required. |
| `priority` | A number of 0 or more (1 by default) | The goal's weight. The current goal is the one with the highest priority. |
| `considerations` | `<id>, <id>, ...` | Consideration nodes, as utility's ([Considerations](#considerations)), whose scores multiply the priority, each made up for their count by the compensation factor, as an option's score is. One consideration can serve several goals. |
| `when` | A condition | A guard: when it does not hold, the goal's priority is 0. |

### Actions

An `action` node is an action that a plan can hold:

| Field | Values | What it does |
|---|---|---|
| `action` | An action reference | The action that runs ([Action references](#action-references)). Required. |
| `preconditions` | Tests | What must hold before the action runs. |
| `effects` | Effects ([Tests and effects](#tests-and-effects)) | What the action changes. When the action succeeds, the plan runner writes them to the blackboard. Required. |
| `cost` | A number above 0, or a float or an int key (1 by default) | The cost that a plan adds up. A key is read when a search begins. |
| `when` | A condition | A guard over any keys: an action whose guard does not hold when a search begins is not in the search, and the runner checks it again before the action starts. |
| `set <key> = <value>` | Writes | Applied when the action starts. A `set` does not write a planning key: effects change those. |

A `consideration` node takes the fields of a utility consideration ([Considerations](#considerations)).

### Tests and effects

The world state holds one value for each planning key: a bool is 0 or 1, an int is itself, and an enum is the index of its name.

- **Tests** are joined by `and`. Each is `<key>` or `not <key>` for a bool, or `<key> <op> <value>`. The operators are `==`, `<`, `<=`, `>` and `>=` for an int, `==` for an enum, and `==` and `!=` for a bool. A value is an integer, `true` or `false`, or one of an enum's names. Each key's tests make one interval of values, so `ammo > 2 and ammo <= 9` is the interval 3 to 9.
- **Effects** are separated by commas. `<key> = <value>` sets a key, and `<key> += <n>` and `<key> -= <n>` add to an int key. An action changes each key once.

Tests and effects name only planning keys.

### Problems

The reader reports these problems at their lines, in addition to the shared problems ([The cook](#the-cook)):
- a setting other than `keys`, `max_nodes` and `max_plan`, a count out of range, and a decision without `keys`;
- a planning key that the blackboard does not have, that is not a bool, an int or an enum, that `keys` names twice, or more than 32 of them;
- a decision without goals or without actions, more than `MAX_GOAP_GOALS` (32) goals, or more than `MAX_GOAP_ACTIONS` (256) actions;
- an unknown kind or field, or a field that the node's kind does not take, such as `effects` on a goal;
- a goal without `desired`, and an action without `action` or `effects`;
- `set` lines on a goal or a consideration, and a `set` of a planning key on an action;
- a test or an effect of a key that is not a planning key, an operator that the key's type does not take, a value that is not of the key's type, tests of one key that can never hold together, an add to a key that is not an int, and an effect that changes a key twice;
- a `cost` of 0 or less, or a cost key that is not a float or an int, and a negative `priority`;
- a consideration ID that no node has, a node that is not a consideration, a consideration that a goal lists twice, and a consideration that no goal lists, and the problems of a consideration, as utility's reader reports them;
- a state of more than `MAX_DECISION_STATE` bytes, with its size and the search's size, at the `max_nodes` line, or at the `keys` line without one.

### The GOAP data

The technique's data (`lib/engine/asset/format/goap.odin`) is a `Goap_Header`, then the planning keys' slots, the `Plan_Action`s, the `Goap_Goal`s, the `Plan_Test`s, the `Plan_Effect`s, and the goals' considerations, links and points, which are utility's records. The goals and the actions are in the text's order. The records that the planning techniques share are in `lib/engine/asset/format/plan.odin`.
- **An action** has its decision node, which holds its guard, its action and its writes. It also has its cost, a constant or a key's slot, and its ranges of tests and effects.
- **A goal** has its decision node, its priority, its range of links, and its range of tests.
- **A test** is a planning key's index and an interval, `lo` to `hi`. **An effect** is a planning key's index, `Set` or `Add`, and a value.

`format.goap_state` lays out the module state from the counts, and the cook sizes it with the same procedure:
1. `Goap_Agent` (16 bytes): the phase, `Idle`, `Searching` or `Running`; the goal, plus 1; the node count of the last search; and the failed goals.
2. `Plan_Run` (16 bytes): the plan runner's step, the plan's length, and the planning keys that the rest of the plan depends on.
3. Each goal's last priority, the world state that the failed goals failed in, the plan's actions (2 bytes each), and the world state that the plan expects.
4. The search: `Goap_Search` (its node count and the heuristic's unit), its world state, a bit for each action that it may use, each action's cost, and `max_nodes` nodes, each a `Goap_Node` (16 bytes) and an interval (8 bytes) for each planning key.

The header holds the layout hash, the counts, `max_nodes` and `max_plan`. `format.goap_check` refuses data of another layout, counts out of their limits, a state smaller than the layout, an action without an action or effects or with a cost of 0 or less, a goal without tests or with a negative priority, indices and tests out of range, keys of types that the data does not read, and effects that do not fit their keys. The module does this check before an agent starts with the decision.

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
