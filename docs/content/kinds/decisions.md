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
node 2 action
	position = [200, -80]
	when = health < 0.3 and (has_target or mood == alert)
	action = flee(from = target, speed = 4)
	set mood = alert
node 3 action
	when = target != none and distance(self, target) < 10
	action = bark(line = "Halt!", at = target)
```

**In this document:** [The text](#the-text) · [Shared parts](#shared-parts) · [Techniques](#techniques) · [The cook](#the-cook) · [The blob](#the-blob)

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
