# Bindings

A track acts on a binding, not on an entity. A binding is one of three kinds:
- **Possessed:** an entity that already exists in the world.
- **Spawned:** an entity that the cutscene makes from a prefab and despawns when it ends.
- **Provided:** an entity that a script gives when it plays the cutscene. The asset names no entity.

This document describes how bindings resolve and how tracks read them, in `lib/engine/cutscene/bindings.odin`. The text and the blob of a binding are in [Content: Cutscenes](../content/kinds/cutscenes.md#bindings).

**In this document:** [The states](#the-states) · [Resolving](#resolving) · [Possessed bindings](#possessed-bindings) · [Spawned bindings](#spawned-bindings) · [Provided bindings](#provided-bindings) · [Overrides](#overrides) · [A missing binding](#a-missing-binding) · [Entities that go](#entities-that-go) · [Procedures](#procedures)

## The states

`Bindings` holds one `Binding_State` for each binding of the blob, in the blob's order. The state is a union, and `set_binding` is the only procedure that writes it:

| State | Meaning |
|---|---|
| `nil` | Not resolved yet. |
| `Binding_Possessed{entity, hold}` | An entity that the cutscene does not own: an entity of a scene, or an override. A provided binding with an override is in this state. |
| `Binding_Spawned{entity, hold}` | The root of a prefab instance that the cutscene spawned. The cutscene owns it. |
| `Binding_Missing` | An optional binding whose entity was not found, or a provided binding that has no override in the editor's preview. Its tracks do nothing. |
| `Binding_Mapped` | A sub-sequence's binding that its section maps to a binding of the parent, by the parent's index. Its tracks act on the parent's binding's entity, which `tree_binding` finds. It suspends nothing: the parent's binding holds the entity ([Tracks: Sub-sequence tracks](tracks.md#sub-sequence-tracks)). |

`hold` is what the binding suspends on its entity, from the cutscene's settings: its systems, and whether a body keeps its velocity. `set_binding` suspends them when the binding enters the state and resumes them when it leaves, so a binding holds its entity exactly while it is resolved ([Possession](possession.md#the-settings)).

The states hold no strings and no pointers, so they survive a code reload. A failure is a `Binding_Failure`, which holds the binding's index and a reason: `Missing` or `Spawn_Failed`, and for a sub-sequence's binding, the sub-sequence's GUID.

## Resolving

`resolve_bindings` resolves every binding once, before the cutscene plays. The [player](player.md#loading-and-failures) calls it in `Loading`. It goes through the bindings in the blob's order, so a spawned binding's parent resolves before its child.

1. A sub-sequence's binding that its section maps (`Resolve.mapped`) is `Binding_Mapped`. A spawned binding under it spawns under the parent's entity.
1. If an override for the binding has an entity that is alive, the override wins ([Overrides](#overrides)).
2. If not, a possessed binding finds its entity, and a spawned binding spawns its prefab. A provided binding has no other source, so it is missing.
3. The resolution fails if a required binding is missing or a prefab does not spawn. On a failure it:
   - despawns what it already spawned, so nothing stays changed;
   - logs an error that names the binding;
   - gives the failure.

## Possessed bindings

A possessed binding names a scene's entity as `@<scene guid>/<id>`, as a [reference across scenes](../world/scenes.md#references-across-scenes) does.

- **The lookup.** The binding resolves in the first **ready** scene with the GUID (`scene.ready_number`), through the scene's IDs (`scene.find`). A scene that is still loading does not count.
- **Prefab instances.** The cooker's expansion gives an entity inside a prefab instance the scene ID `scene_path_id` of the instance and the entity. The blob folds a path `<instance>#<entity>` to that ID, so the same lookup finds the entity ([Editor: Prefabs: Expansion](../editor/prefabs.md#expansion)).
- **Sublevels.** A sublevel's part is a scene with its own GUID. A binding names an entity of a part by the part's GUID.
- **Two copies of a scene.** When two copies are loaded, the binding takes the first one that loaded, as a link does.
- **Ownership.** The cutscene does not own a possessed entity, so its release leaves the entity.

## Spawned bindings

A spawned binding names a prefab, a parent binding or none, and a start transform.

- **Ownership.** The binding spawns with `scene.spawn_prefab` and **no owner**. So it has no `Scene_Entity` or `Scene_Owned`, and a scene's unload does not take it. The cutscene owns it.
- **A parent.** If the parent has a live entity, the binding spawns under that entity. Its position, rotation and scale become its `Local_Transform`. If the parent has no live entity (for example, an override that is gone), the binding gives a warning. It then spawns with no parent, at its position in the world.
- **Hidden until it plays.** Every entity of the instance gets `ecs.Loading{LOADING_SCENE}`. A scene that loads in stages tags each of its entities in the same way ([World: Scenes: Loading in stages](../world/scenes.md#loading-in-stages)). So the entities are inactive, and their behaviours do not wake. Physics can still build their bodies early. No scene has the number `LOADING_SCENE`, so a cutscene's entities never hold back a scene's load.
- **Reveal.** `reveal_bindings` removes the tag. It settles each entity's pose, so the entities show without interpolating from where they spawned. Their behaviours get `awake`, `on_enable` and `start` in the next script phase, unless the binding suspends them ([Possession: Behaviours](possession.md#behaviours)). The player calls it when the cutscene starts to play or skips.
- **Release.** `release_bindings` forgets every binding, which resumes what each suspended, and then despawns each spawned root with its children, including the spawned bindings under it. The player calls it when it gives the world back, in `Restored` or `Failed`.
- **Gameplay code** gets a spawned entity from the player while the cutscene runs.

## Provided bindings

A provided binding is a slot for a script. The asset names no entity and no prefab. The script that plays the cutscene gives the entity with a `Binding_Override`, by the binding's name or ID (see [Scripts](scripts.md#playing)). So one cutscene works for any entity.

- **Ownership.** The binding is `Binding_Possessed` with the override, so the cutscene does not own the entity and does not despawn it.
- **Suspension.** The binding suspends what its `suspend` says, as a possessed binding does.
- **No override.** The binding is missing, and its `policy` decides what follows ([A missing binding](#a-missing-binding)).
- **The editor's preview.** No script plays the cutscene there, so a provided binding without an override is always `Binding_Missing`, with a warning, and the preview does not fail. The editor gives each user a stand-in entity for the slot (see [Editor: Cutscene editor: Bindings](../editor/cutscene-editor.md#bindings)). `Resolve.preview` turns this on.

## Overrides

When a caller plays the cutscene, it can give an entity for any binding, as a `Binding_Override`. The override names the binding by its ID (`Binding_Id`) or by its name.

- An override wins over the asset's reference, for a possessed binding and for a spawned one. A provided binding has no reference, so its override is its only source. An overridden binding is `Binding_Possessed`. The cutscene spawns nothing for it, and does not despawn the override.
- An override that names no binding of the cutscene gives a warning, and does nothing.
- An override whose entity is not alive gives a warning. The binding then resolves as the asset says.

## A missing binding

A possessed or provided binding's `policy` says what happens when its entity is not found:

| Policy | Result |
|---|---|
| `required` (the default) | The resolution fails with `Missing`, and the player goes to `Failed` with the binding's name. |
| `optional` | The binding is `Binding_Missing`, with one warning. Its tracks do nothing. |

A possessed binding is missing when no ready scene has its GUID, or when the scene has no entity with its ID. A provided binding is missing when the script gave no override for it, or gave one that is not alive. In the editor's preview a provided binding without an override is `Binding_Missing` whatever its policy.

## Entities that go

A binding resolves once. Tracks read it only through `binding_entity`, which gives the entity only while `ecs.is_alive` is true. A despawn changes the entity's generation, so the binding never reads a stale handle, even after the slot is used again.

- A script or the game can despawn a possessed entity during the cutscene. From then on, its binding gives no entity, and its tracks do nothing.
- An entity whose scene unloads during the cutscene is despawned with the scene, so the same rule applies.
- Something else can also despawn a spawned entity. Its binding then gives no entity, and the release skips it.

## Procedures

| Procedure | What it does |
|---|---|
| `resolve_bindings(b, resolve, overrides) -> Maybe(Binding_Failure)` | Resolves every binding ([Resolving](#resolving)). `Resolve` holds the world, its scenes, the scripts, the assets and the cutscene's blob. |
| `binding_entity(b, w, index) -> (entity, ok)` | Gives the binding's entity while it is alive. |
| `binding_index(data, blob, key) -> (index, ok)` | Gives the index of the binding with an ID or a name. |
| `reveal_bindings(b, w)` | Shows the spawned entities. |
| `release_bindings(b, w) -> int` | Forgets every binding, which resumes what each suspended, and despawns the spawned roots. After it, call the systems' `forget_despawned`, as after `scene.unload_scene`. |
| `destroy_bindings(b, w)` | Releases the bindings, so no spawned entity outlives them, and frees the states. |
