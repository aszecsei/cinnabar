# Decision editor

The decision editor edits a decision (see [Content: Decisions](../content/kinds/decisions.md#decisions)) in a view that fits its technique, and shows the selected agent running it while the game plays (see [AI: Agents](../ai/agents.md#agents)). A behavior tree and an HTN domain are trees on a canvas. A utility decision is a list of options, with a graph of each consideration's curve. A GOAP decision is tables of goals and actions, with a plan preview. The blackboard editor edits a blackboard's keys in a table (see [Content: Blackboards](../content/kinds/blackboards.md#blackboards)). Each open one is a document beside the viewport, `DecisionEditorDocument` or `BlackboardEditorDocument`, over a `DecisionEditor` or a `BlackboardEditor` in the shell, which holds its state, so docking can rebuild the view, and tests drive the editor without a window. Both are built as the [animation graph editor](animation-graph-editor.md#animation-graph-editor) is.

**In this document:** [The file](#the-file) · [The canvas](#the-canvas) · [Utility](#utility) · [GOAP](#goap) · [HTN](#htn) · [Blackboards](#blackboards) · [Problems](#problems) · [Live view](#live-view)

## The file

`DecisionFile` reads a decision's text as whole lines, each in the block that `tools/cook/decisions.odin` would read it in: a setting, such as `technique` or `blackboard`, each node with its fields and its writes, and the rest. It reads the same structure for every technique. `BlackboardFile` reads a blackboard's text as its lines, each key's line on its own. The line model, `TextLine`, is the animation graph's.

- **Round trip:** a file reads and writes back as it was, with its comments, its blank lines and each line's ending. An edit changes only the value of a field, keeping its indent and its comment, or adds or removes the lines of a block. Opening a file does not make it dirty, and a node without a `position` gets a place on the canvas that is not written. A list of IDs, such as `children`, keeps each ID as it is written, so `0x10` stays `0x10`.
- **It reads only the structure.** What a block's lines mean, and whether they are right, is the cooker's to say, so a decision with problems still opens, with its problems on its nodes. Only a file whose first line that is not a comment is not `decision 1` in the first column, or `blackboard 1`, is refused, and that opens in the script editor, with the reason in the console.
- **It agrees with the cooker.** `tools/cook/testdata/decisions` has decisions and blackboards that the cooker's tests and the editor's both read, with a comment on each line that the cooker reports, a list of the nodes or the keys that it reads, and `# problem node N` on the lines of node N. The rules that they pin are where a block ends (a comment in the first column does not end it), what is not a node (a bad or a repeated `node` line, whose indented lines then belong to no node), and which line of a repeated field counts: the first, unlike an animation graph's.
- **Undo, Save, dirty state, closing and following renames** are `GraphDocument`'s, shared with the material, animation graph and UI editors (see [Animation graph editor: The file](animation-graph-editor.md#the-file)). A save that would replace what another program wrote asks first, as `TextGraphDocument` checks for each editor that keeps a file's lines.
- **New assets:** the content browser's **New Blackboard**, and **New Decision** with a submenu of the techniques, make their files from the cooker's templates and open them in their editors. A new decision names no blackboard, which is a problem until the panel picks one.

## The canvas

- **Layout:** the decision's technique, its blackboard, the problems that are on no node, and the [live](#live-view) blackboard on the left; the technique's view in the middle; and the selected node's fields on the right. The middle is this canvas for a behavior tree and an [HTN](#htn) domain, the options for [utility](#utility), and the goals and actions for [GOAP](#goap). It changes when the `technique` setting does.
- **The canvas** (`BehaviorTreeCanvas`) draws a behavior tree from the top down. An edge leaves a composite's foot, turns across, and arrives at the top of each child, with the child's place among its siblings, since the children's order is the order in which their parent runs them. A node is where its `position` puts it. A node without one has its place in a tree laid out from the top down: each leaf in the next column, each composite over the middle of its children, and each root, a node that no composite lists, after the one before it. The geometry and the hit test are `BehaviorTreeGeometry` in `Cinnabar.Editor.Tools`.
- **Shapes:** a composite is square, with its mark of how it runs (→ a sequence, ? a selector, ⇉ a parallel) and a foot under it; an action is rounded and names its action; a wait is a pill; a set has notched corners and its writes; and a condition has cut corners and its condition. Each decorator is a band across the top of its node, in the order that they apply: `when` with its `abort`, `cooldown`, `time_limit`, `repeat`, `invert` and `force`.
- **Mouse and keys** are the graph canvas's, which the animation graph editor shares (`NodeGraphCanvas`): the left button selects (Shift adds, Ctrl toggles), drags what is selected, and drags a box; the right or middle button pans; the wheel zooms about the mouse; Delete deletes what is selected, F frames the tree, and Escape cancels a drag. A drag from a composite's foot to another node makes it a child: it leaves its old parent, and goes among its new siblings by its place from left to right. A node does not become a child of one below it, and a leaf has no children. A drag from a foot to an empty place opens the add menu, and what it adds is the composite's last child.
- **Order:** a composite's children run from left to right. When a drag of nodes ends, each moved node's parent sorts its `children` by their places, in the drag's undo entry, so dragging a node past a sibling reorders them.
- **The add menu** opens with Space, Tab or a right click without a drag, and filters as the user types, by every word of the query (`NodePicker`, which the material editor shares). It has the technique's kinds of node and an action node for each action: the native actions that the game registered, which the link's `Agent_Actions` lists, and the script actions that the cook index names with their parameters. A native action hides a script action of its name, as at run time ([AI: Agents: Actions](../ai/agents.md#actions)).
- **Deleting** a node takes it out of the `children` of the composites that list them, in one undo entry.
- **Details:** an action is picked from the actions, and each of its parameters is a constant, typed in, or a key of the blackboard of a type that fits it, picked from a list (a number takes a float or an int key, an entity also `self`). An argument that the action has no parameter for shows to be removed. A condition, a `when` included, and a time are text boxes that complete the blackboard's keys. A set's writes are each a key and a value. A parallel has its policy, and every node has its decorators.
- **Other techniques:** a technique that the editor does not know opens on the canvas, with its nodes without their links, and their fields in the details as the file writes them.

## Utility

A utility decision's view (`UtilityView`) is its settings, `pick`, `within` and `momentum`, and its options as a list in the file's order. Each option is a card with its action, its weight, its guard, its target and its cooldown, and its considerations as cards in the order that it lists them.

- **A consideration's card** has its input, its curve's kind, and a small graph of the curve (`CurveGraph`). The x axis is the input from 0 to 1, with its `range` at the ends, and the y axis is the score. The editor evaluates the curve as the runtime does, so the graph shows what an agent scores (`ResponseCurve` in `Cinnabar.Editor.Tools`, from `lib/engine/ai/utility/utility.odin`).
- **Handles:** a drag of a handle changes the fields that it stands for, in one undo entry, and Escape puts them back. A field that returns to its default is removed.
  - The **origin**, where the shape starts, moves `x_shift` and `y_shift`. A logistic's or a logit's origin is its middle.
  - The **end**, at the right edge, sets the `slope` that reaches it.
  - The **bend** sets the `exponent` whose curve passes it: at 0.5 for a polynomial, and at 0.75 for a logistic or a logit, which are 0.5 at 0.5 whatever their exponent. Linear and step curves have no bend.
  - A **table** has a handle at each point instead, which moves between its neighbors. A double click adds a point on the line, and a right click on a point removes it, from 2 to 32 points.
- **Typed fields:** the details show every field of the selected option or consideration, whether the file writes it or not: an option's action, weight, guard, target, tag, cooldown and writes, and a consideration's input, range, curve, slope, exponent, shifts and points. A change of the curve's kind removes the fields that the new kind does not take, and a new table starts as a line from [0, 0] to [1, 1].
- **Editing:** **Add Option** adds an option, **+ Consideration** adds a linear one to its option, and × takes a consideration out of its option. The consideration is deleted unless another option lists it. A delete takes a node out of the lists that name it. Considerations that no option lists show under the options, to be used or deleted.

## GOAP

A GOAP decision's view (`GoapView`) is its settings, `keys`, `max_nodes` and `max_plan`, its goals as cards, its actions as a table, and the plan preview.

- **Goals:** each card has the goal's desired state, priority and guard, which complete the blackboard's keys, and its considerations as cards, as an option's are ([Utility](#utility)).
- **Actions:** a row each, with its action, preconditions, effects, cost and guard. A click on a row selects the action, and the details pick its action and arguments as a tree's are.
- **Add Goal** and **Add Action** add a node, and × deletes one.

### Plan preview

The plan preview shows the plan that an agent would make, without the game.

- **The setup:** a goal, and the start state. Each planning key has a check box for a bool, a number for an int, or a choice of names for an enum. A key starts at its blackboard default, and ↺ puts it back. The setup is the editor's, and is not in the file or the undo history.
- **The answer:** the next check of the decision sends the setup as the `Cook_Preview`'s plan query ([Daemon](../content/daemon-and-operations.md#cook-daemon)). The daemon plans with the runtime's search, `search.whole` in `lib/engine/ai/goap/search`, and answers with the plan as a chain of actions. A click on an action selects it. When no plan reaches the goal, the answer is the plan of the closest search, and the planning keys that it needs and the start state does not have ([AI: GOAP: The search](../ai/goap.md#the-search)).
- **What it cannot know:** a guard reads the agent's values and the world, so every action is usable in the preview. A cost key has its blackboard default.
- **An answer is for its setup and its text.** A change of either hides the answer until the next one comes. A decision with problems does not plan.

## HTN

An HTN domain is a tree on the canvas, as a behavior tree is, from the `root` task down. A compound task lists its methods in their order of preference. A method has its guard as a band, its preconditions as a row, and its subtasks in order. A primitive task, an `action`, is a leaf, with its action, preconditions and effects.

- **Links:** a drag from a task's foot to a method makes it the task's method, and a method leaves its old task, since it has one. A drag from a method's foot to a task or an action makes it a subtask. A subtask stays the subtask of other methods, and a task can be its own subtask, since tasks can recur. A task lists only methods, and a method lists only tasks and actions.
- **Order:** as in a behavior tree, a task's methods and a method's subtasks go from left to right, and a drag of nodes orders them again.
- **Layout:** a node that several methods list, or a task that recurs, has its place under the first parent that reaches it, and an edge from each of the others.

## Blackboards

A `.blackboard` opens in a table: each key's name, its type, an enum's names and its default, in the order of their slots, with the problems of each key's line. **Add Key** adds one of a type, and the arrows move a key up or down a slot.

- **Renaming a key** renames it in the decisions that name the blackboard and read the key, after asking which ones. Each changes in its own decision editor, which opens for a closed one, with one undo entry, and stays unsaved to be looked over and saved. A rename changes the words that name the key: in conditions, times, writes, the values of action arguments, and the planning techniques' keys, tests and effects. It does not change argument names, action names or quoted strings, so `move_to(key = "target")`, which names a key by text, is renamed by hand.
- **A decision's keys** are those of its blackboard's open editor, with what it has not saved, or else its file's, so a new key is offered as soon as it is added.

## Problems

A moment after each change, and when it opens, each editor sends its text to the cook daemon in `Cook_Preview`, which checks it and writes nothing (see [Daemon](../content/daemon-and-operations.md#cook-daemon)). A decision is checked against its blackboard's source as the cook reads it. The answer's problems go on their nodes by the lines of the text that it was given, as a dashed red frame and in the details, and the others on the panel, with their lines. A blackboard's problems go on their keys' rows. An answer about a text that has changed since is dropped, as another check follows. Closing the editor cancels a check that waits and drops the answer of one that runs.

## Live view

While the game plays or is paused, the selected entity's `Agent` shows on the canvas when it runs this decision. Otherwise the panel says why not, or which decision it runs.

- **The link.** The game sends `Agent_View` for each watched entity once after the watch, then when it changes: the decision's GUID, each node that runs or has a result, by its ID in the text, with whether it runs and its last result, and each key of the blackboard with its type and its value as text (see [Editor link](link.md#messages)). A utility agent also sends each option's last score, the option that runs, and each consideration's input and score. A GOAP or an HTN agent sends its plan: its goal and the goals' priorities, the plan's actions, its step, an HTN plan's methods, and whether it searches. The scores are rounded to three decimals, so a score that only drifts does not send a new view. It finds the blobs as an Animator's view does, and checks them against the agent's, so a decision that has changed since the agent started it shows nothing. When the agent or its decision goes, one empty view says so, and an entity without one sends an empty view after its watch.
- **A behavior tree** lights the frame of each node that runs, and the edges between them, which is the running branch. A dot on a node's header is its last result: green for a success, red for a failure, and yellow for an abort, which the behavior tree keeps until the node runs again ([AI: Behavior trees](../ai/behavior-trees.md)).
- **Utility:** each option's card shows its score, and the option that runs is marked. A green dot on each consideration's curve is its input and its score.
- **GOAP:** the current goal is marked, and each goal shows its priority. The live plan is a chain of actions, with the step that runs lit, and its action is marked in the table.
- **HTN:** the plan is a path through the tree, dashed: each task that it broke down, the method that it chose, and the plan's actions. The action that runs is lit.
- **It only looks.** The panel lists the blackboard's values as the game sent them, and nothing there writes to the game.
- **The sample:** play the sample's guard scene, open `ai/guard.decision`, and select the guard: its patrol, chase and search light in turn as the intruder walks past the cover ([AI: Behavior trees: The sample](../ai/behavior-trees.md#the-sample)).
- **Saving during play** makes a new blob, so the agent stops its action and starts the decision again from its blackboard's defaults (see [AI: Agents: Reload and restart](../ai/agents.md#reload-and-restart)).
