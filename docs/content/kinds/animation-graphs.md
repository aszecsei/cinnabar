# Animation graphs

Animation graphs are `.animation_graph` text files in the content roots. A graph has:
- parameters that gameplay sets;
- the clips that it plays, each with the events at its times;
- a state machine whose states each play a clip or a blend of clips, with transitions that cross-fade between them.

Clips are the Animation sub-assets of models (see [Skins and animations](skins-and-animations.md#animations)). `just animation_graphs` runs `cook animation_graphs --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`. The daemon cooks graphs like any other kind (`tools/cook/animation_graphs.odin`).

The runtime does not play graphs yet; `Animator` plays one clip (see [Playback](skins-and-animations.md#playback)).

```
animation_graph 1
root_motion = "b_Root_00"
entry = idle

param speed float 0
param look trigger

clip survey = $3918fb8bad25fb7d58abb5d2a6f2cadd
clip walk = $dea303d3f0374a9e56b0bb58f4a85315
	event 0.2 footstep "left"
	event 0.55 footstep "right"
clip run = $cf6a8cd8cc1591bd3e6e09437d5754a1

node 1 state
	position = [0, 0]
	name = idle
	motion = survey
node 2 state
	name = move
	motion = @10.pose
	enter_event = started
node 10 blend_1d
	parameter = speed
	input.0 = walk
	at.0 = 0.4
	input.1 = run
	at.1 = 3
node 20 transition
	from = idle
	to = move
	when = speed > 0.1
	duration = 0.25
node 21 transition
	from = any
	to = idle
	when = look
	duration = 0.2
```

## The text

- **The first line** is `animation_graph 1`. A `#` starts a comment, except inside quotes.
- **`entry = <state>`** is the state that the graph starts in. It is required.
- **`root_motion = "<joint>"`** names the joint whose motion the graph reports as root motion. Without it, the graph reports none.
- **Parameters.** `param <name> float [<default>]`, `param <name> bool [true|false]` and `param <name> trigger` declare at most `MAX_ANIMATION_GRAPH_PARAMETERS` (16) parameters. A float starts at 0 and a bool at false, unless a default is given. A trigger is set for the graph's next tick only, so it has no default.
- **Clips.** `clip <name> = $<guid>` names an Animation sub-asset. Each line indented under it is an event: `event <time> <name> [<argument>]...`.
  - The time is in seconds from the clip's start.
  - The name is a word.
  - At most `MAX_ANIMATION_GRAPH_ARGS` (2) arguments follow, each a number or a quoted string.
  - The cooker orders a clip's events by their times.
- **Nodes.** `node <id> <kind>` starts a node, with an ID above 0 that no other node has. Its block is the `<field> = <value>` lines indented under it. Every node may have a `position`, where an editor draws it, which the cooker does not read.

| Node | Field | Values | Default |
|---|---|---|---|
| `state` | `name` | A word, unique among the states. `any` is not a state's name. | required |
| | `motion` | A clip's name, or `@<id>.pose` of a `blend_1d` node. | required |
| | `speed` | How fast the motion plays, from 0. | 1 |
| | `loop` | `true`, or `false` to hold at the end. | `true` |
| | `enter_event`, `exit_event` | A word: the event that the graph raises when it enters or leaves the state. | none |
| `blend_1d` | `parameter` | A float parameter. | required |
| | `input.<n>`, `at.<n>` | A clip's name, and the parameter's value where that clip plays alone. Between two values, the two clips blend. There are 2 to `MAX_ANIMATION_GRAPH_POINTS` (8) inputs, numbered from 0, and no two have the same value. | required |
| `transition` | `from` | A state, or `any` for every state but the one in `to`. | required |
| | `to` | A state other than `from`. | required |
| | `when` | Conditions joined by `and`. A condition is one of:<br>- a trigger's name;<br>- a bool's name, or `!` and a bool's name;<br>- a float's name, then `>`, `<`, `==` or `!=`, then a number. | none |
| | `exit_time` | How many plays of the from state's motion pass before the transition can be taken. A transition from `any` has none. | none |
| | `duration` | The cross-fade, in seconds. | 0 |

A transition has a `when`, an `exit_time` or both, or it would be taken at every tick. A state's transitions are tried in the order of their lines, and then the transitions from `any`.

## The blob

An `Animation_Graph_Blob` (`lib/engine/asset/format/animation_graph.odin`) holds records:
- **Parameters**, each with its name and `animation_graph_hash` (FNV-1a, 32 bits) of the name, which gameplay finds it by.
- **Clips**, with their markers.
- **Events**, with their arguments.
- **States**, each with its motion's points.
- **Transitions**, grouped by their from state in the states' order. The transitions from `any` are last, from `first_any`.
- **Conditions.**

A state and a transition keep their node's ID, which an editor or a debugger names them by. The view checks every index between the records.

- **Problems** have their line. They include:
  - an unknown name;
  - a state, parameter or clip named twice;
  - two names with the same hash;
  - a condition that does not fit its parameter's kind;
  - a blend's inputs out of number;
  - a transition to its own state.

  A graph with a problem keeps its old blob, so the running game keeps the last good version.
- **The cooker does not read the clips' blobs.** A marker past its clip's end and a root motion joint that the skin does not have are found when the game loads the graph.
- **The cache key** covers the cooker version, the layout, the source path, the source and the GUID. The graph depends on its clips.
- **The editor** opens a graph's text in the script editor. **New Animation Graph** makes one from a template: a speed parameter and one state, whose clip's GUID the author fills in.
