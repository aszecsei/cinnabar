# Possession

When a cutscene possesses an entity, the systems that usually move the entity must stop fighting the cutscene. The entity's behaviours, its AI agent, its navigation agent and its physics body hold still while the cutscene drives it. The game's input and HUD step aside. The cutscene chooses what to suspend, and the end of the player gives all of it back.

This document describes the binding's suspension in `lib/engine/cutscene/bindings.odin`, the player's hold in `lib/engine/cutscene/possession.odin`, and the world's `Suspended` component in `lib/engine/ecs/suspended.odin`. Read [Bindings](bindings.md) and [Player](player.md) first.

**In this document:** [Suspension](#suspension) · [The settings](#the-settings) · [Behaviours](#behaviours) · [AI](#ai) · [Navigation](#navigation) · [Physics](#physics) · [The whole cutscene](#the-whole-cutscene) · [Giving it back](#giving-it-back) · [Procedures](#procedures)

## Suspension

A system is suspended on an entity while a holder holds it. The world keeps the count of holders for each system in the entity's `Suspended` component (ID 11):

| System (`ecs.Suspend`) | While it is suspended |
|---|---|
| `Behaviours` | The behaviours get no `update`, `fixed_update`, `start` or events, as if `enabled` were false. |
| `AI` | The `Agent` does not think or act. |
| `Navigation` | The `Nav_Agent` leaves its crowd, and its move stops. |
| `Physics` | A dynamic body is kinematic. A character leaves the simulation. |
| `Ui` | The `Ui_Document` is hidden. |

- **Counts.** `ecs.suspend(w, e, systems, keep_velocity)` adds one holder to each system, and `ecs.resume(w, e, systems)` takes one away. They give the systems that started or ended. When `Physics` ends, `resume` also gives whether any of its holders asked to keep the body's velocity. A system acts on the entity again only when no holder suspends it. So two cutscenes that suspend one entity both release it before it runs again.
- **The one writer.** `suspend` and `resume` are the only procedures that change `Suspended`. The entity loses the component when every count is 0.
- **Not saved.** `Suspended` is in no category, and `scene.is_derived` names it, so a scene's text cannot set it and the editor does not show it. A despawned entity takes its counts with it.
- **Systems read it.** Each system asks `ecs.suspended(w, e, system)`. No system writes an authored field, such as `enabled`, `Rigid_Body.motion` or `Ui_Document.visible`. So a script or the editor that changes one of these fields during the cutscene keeps its change, and a restore never undoes it.

## The settings

A binding suspends a set of systems on its entity. The cutscene's `suspend` setting is the default for each binding, and a binding's own `suspend` replaces it ([Content: Cutscenes](../content/kinds/cutscenes.md#bindings)). The default of the cutscene is every system: `[behaviours, ai, navigation, physics]`. `suspend = []` suspends nothing.

- **The entity only.** A binding suspends its own entity, not the entity's children. Bind a child to suspend it too.
- **When.** A binding suspends its systems when it resolves, in `Loading` (`set_binding`, the one writer of a binding's state). A possessed binding holds its entity from then on. A spawned binding holds its entity from the moment that it spawns, while the entity is still hidden. So a spawned guard does not start its patrol when it shows.
- **A Ready player.** A player that waits in `Ready` already holds its bindings. Load a cutscene just before it plays, or set its bindings' `suspend` to `[]`.
- **A reload** that changes a binding resolves the bindings again ([Player: Hot reload](player.md#hot-reload)). The old bindings release their entities and the new ones hold them in the same `update`, before any system or script phase runs. So a system that both suspend does not run between them, and a behaviour gets no `on_enable`.

## Behaviours

A suspended entity's behaviours stop as they do for `enabled = false`:
- `on_disable` runs when the first holder suspends them, and `on_enable` runs when the last holder resumes them, in the next script phase. The ECS log carries the change (`Log_Kind.Suspended` and `.Resumed`), as it carries activity ([Scripting: Enabled state](../scripting/behaviours.md#enabled-state)).
- `self.enabled` keeps its value. A script that sets `enabled` during the cutscene changes what the behaviour does after the cutscene.
- A behaviour that is added to a suspended entity starts suspended.
- A spawned entity's behaviours get `awake` when the entity shows. They get `on_enable` and `start` only when the cutscene ends.
- **Coroutines keep running,** as for `enabled = false`. A patrol in a coroutine goes on. Put a patrol that a cutscene must stop in `update`, or in an AI agent.

## AI

A suspended `Agent` does not think, and its native and script actions do not start, tick or stop ([AI: Agents](../ai/agents.md#the-order-in-a-tick)).
- It keeps its blackboard and the action that its last think chose. When the last holder resumes it, the action goes on and the agent thinks when its next think is due.
- Perception goes on, so the agent remembers what it saw during the cutscene.
- An action that moved the agent finds the move stopped, if navigation was suspended too. `move_to` then fails, and the next think chooses again.

## Navigation

A suspended `Nav_Agent` leaves its crowd ([AI: Navigation: The crowd system](../ai/navigation.md#the-crowd-system)):
- It is not in the crowd's snapshot, so the other agents do not avoid it.
- Its move stops: its status is `Idle`, and its character's walk velocity is set to zero once.
- A move that something sends while the agent is suspended stops in the same tick.
- When the last holder resumes it, it waits for a move.

## Physics

- **A dynamic body** becomes kinematic. The cutscene moves the entity through its `Transform`, so the body moves there in the tick and pushes the bodies in its way. Gravity does not move it. Its `Rigid_Body` stays dynamic, so the sync makes the body again, with the same shapes, when the suspension starts and when it ends ([Physics: The physics tick](../physics/design.md#the-physics-tick)).
- **At the end,** the body is dynamic again at rest. A binding with `keep_velocity = true` keeps the velocity that the body last moved at, so a body that flies out of the cutscene keeps flying. `Suspended` remembers that a holder asked for it until the last holder of `Physics` resumes the body, so with two cutscenes the body keeps its velocity if either asked, whichever ends first.
- **A static or kinematic body** does not change.
- **Joints** follow the body that the sync makes again, as for any change of a body.
- **A character** leaves the simulation, as an inactive entity's character does. A write of its `Transform` places it. When it is resumed, it is in the simulation again, at the place where the cutscene left it.

## The whole cutscene

Two settings of the cutscene act on the game and not on a binding ([Content: Cutscenes](../content/kinds/cutscenes.md#the-cutscene)):

| Setting | What the player does |
|---|---|
| `input_context` | Pushes this input context for every player ([Core: Input: Contexts](../core/input.md#contexts)). The default is `"cutscene"`. `""` pushes none. |
| `hide_ui` | Hides each `Ui_Document` whose document is in the list, active or not, such as the HUD. |

- **The game defines the context.** Define a context named `cutscene` with the `Only` mode, and let it allow the skip action and the pause menu's action. Every cutscene then blocks gameplay input with no setting. A context that the game did not define is not pushed. A cutscene that names another context logs a warning about it.
- **When.** The player takes the hold (`take_hold`) when it leaves `Ready` for `Playing` or `Skipping`, at the same time as it shows its spawned entities. A player that waits in `Ready` holds no input and hides nothing.
- **Hiding** is the `Ui` suspension, so two cutscenes that hide the HUD both end before it shows again, and `visible` keeps the value that a script gave it.
- The player keeps what it took in `Player_Live.hold`: the push's token and the entities that it hid. A document that appears after the cutscene starts is not hidden.
- A reload that changes these settings changes them for the next play, not for a player that holds them.

## Giving it back

One procedure gives everything back. `give_back` runs when a live player goes to `Restored` or `Failed`, and `reset` (a soft restart, or a new level) goes through it too ([Player: Reset](player.md#reset)). It:
1. restores the fields that the tracks set to restore wrote;
2. releases the hold: pops the input context and shows the hidden documents (`release_hold`);
3. releases the bindings (`release_bindings`): each binding resumes what it suspended, and then the spawned entities are despawned.

A binding resumes only an entity that is still alive. A failure in `Loading` releases the bindings that already resolved, so nothing stays suspended. For example, a cutscene whose second binding is missing gives back the first binding's entity.

## Procedures

| Procedure | What it does |
|---|---|
| `ecs.suspend(w, e, systems, keep_velocity = false) -> started` | Adds a holder of each system, and gives the systems that it suspended. |
| `ecs.resume(w, e, systems) -> (ended, keep_velocity)` | Takes a holder of each system away, and gives the systems that no holder suspends now, and whether a body keeps its velocity. |
| `ecs.suspended(w, e, system) -> bool` | Whether a holder suspends a system on an entity. |
| `take_hold(s, w, live)`, `release_hold(s, w, hold)` | Push and pop the cutscene's input context, and hide and show its documents. |
