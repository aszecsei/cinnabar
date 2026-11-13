# Perception

How agents see and hear, in `lib/engine/ai`. A `Perceiver` sees the `Perceivable`s in its cone that a ray from its eye reaches. It also hears the noises that gameplay makes. What it perceives goes into a short memory in the agent's pool slot. Its `.perception` asset's rows then fill the agent's blackboard from that memory. Read [Agents](agents.md), [Physics: Queries](../physics/design.md#queries) and [Content: Perceptions](../content/kinds/perceptions.md) first.

**In this document:** [Design](#design) · [Components](#components) · [Tags](#tags) · [Sight](#sight) · [Hearing](#hearing) · [Memory](#memory) · [Filling the blackboard](#filling-the-blackboard) · [The order in a tick](#the-order-in-a-tick) · [Determinism](#determinism) · [Scripts](#scripts) · [Drawing](#drawing) · [The sample](#the-sample) · [Limits](#limits)

## Design

1. **Perception writes the blackboard; decisions read it.** A decision does not query the senses. The `ai perceive` system fills the keys that the agent's `.perception` names, through the `ai commands` job buffer, as every other system's job does ([Agents: Blackboards](agents.md#blackboards)).
2. **Sight has a budget of rays in each tick.** The perceivers share it in turn, as audio occlusion shares its rays ([Audio: Occlusion](../audio/design.md#occlusion)). A crowd therefore costs a steady share of each tick, and each perceiver checks again when its turn comes.
3. **Hearing is gameplay's.** A noise is an event that gameplay makes, with a loudness that gameplay sets. It is not the volume of a sound in the mix.
4. **The memory lives in the pool.** It is in the agent's slot on the host's heap, so a code reload keeps it.

## Components

| Component | ID | Kind | Fields |
|---|---|---|---|
| `Perceiver` | 132 | Authoring | `perception`, the `.perception` asset by GUID; `sight_range` (20 m); `half_angle`, the degrees from the forward axis to the cone's edge (60); `eye_offset`, in the entity's frame (0, 1.7, 0); `sight_layers`, the physics layers that block sight and muffle noises (all); `memory`, the seconds that an entity is remembered (5); `hearing`, the sensitivity (1) |
| `Perceivable` | 133 | Authoring | `tag`, an index into the project's `perception.tags`; `point_count` (1) and `points.p0` to `points.p3`, the points of the body that sight checks, in the entity's frame (p0 is 0, 1, 0) |

- **A `Perceiver` needs an `Agent`.** Without one, or while the agent waits for its blobs, it perceives nothing.
- **The forward axis is +Z** of the perceiver's `Transform`.
- **A `Perceivable` with 0 points** is checked at its position.
- **An inactive perceiver** does not perceive, and its memory does not age. An inactive `Perceivable` is not seen.

## Tags

`perception.tags` in the project's settings names the tags in order, such as `perception.tags = Player, Enemy, Noise_Maker`. There are at most `MAX_TAGS` (32), with names of at most 31 characters.

- **A `Perceivable`'s tag** is an index into the list, as a `Collider`'s layer is an index into `physics.layers`.
- **A perception and a noise name tags in text.** `ai.prepare` finds a perception's names in the list in each frame, so a change to the settings applies in the next frame. A name that the list does not give is warned about once for each version of the blob, and dropped: from `notices`, or with its row.
- **The game gives the list** with `ai.set_tags`, when the project's settings change.

## Sight

In each tick, the `ai perceive` system:

1. **Finds the candidates.** It puts the active `Perceivable`s in a grid of cells of `SIGHT_CELL` (16 m). For each perceiver, it looks in the cells that its range overlaps. A candidate is a `Perceivable` other than the perceiver, with a tag that its perception notices, and with at least one point within the range and the cone from the eye. A perceiver keeps the nearest `MAX_SIGHT_TARGETS` (8), by the distance to the candidate's position and then by the order of the query. Each point of a candidate in the cone costs one ray.
2. **Shares the rays.** The budget is `DEFAULT_SIGHT_BUDGET` (64) rays in a tick, which `ai.set_sight_budget` changes. It is never below `MAX_PERCEIVER_RAYS` (32), so one perceiver's check always fits. From the slot after the perceiver that was visited last, the perceivers are visited in slot order while their rays fit in what is left. The first perceiver that does not fit goes first in the next tick. A perceiver without candidates costs nothing.
3. **Casts the rays.** For a visited perceiver, `physics.raycast_batch` casts one ray from the eye to each candidate point. The filter is `sight_layers`, and it ignores the perceiver's own body. A ray is clear when it hits nothing, or when it hits the target or one of the target's children. So neither body blocks. A candidate is seen when one of its rays is clear, which is how a target behind low cover is seen by its head.
4. **Keeps what it saw.** A seen entity stays seen until a ray finds it hidden. A perceiver that is not visited in a tick keeps seeing what it saw while it stays a candidate, and its position follows. An entity that leaves the cone or the range is no longer seen, without a ray. A new candidate waits for the perceiver's turn.

Without physics, or with a backend without queries, every ray is clear.

## Hearing

- **Making a noise:** `ai.noise(s, position, loudness, tag, source)` from frame code, `ai.write_noise(ai.job_writer(s, ctx), position, loudness, tag, source)` from a system's job, and `Perception.noise` from scripts. `source` is the entity that made it, or none.
- **When it is heard:** a noise lives for one tick. It is heard in the next tick's `ai perceive`. A noise from frame code before the ticks is heard in the first tick. A noise from a system's job or a script is heard in the tick after it.
- **Who hears it:** a perceiver that notices the noise's tag, and that is not its source, hears it within `loudness * hearing` meters of its eye. A wall halves that range. Within half the range, the noise is heard at once. Between half and the full range, one `physics.raycast` from the eye towards the noise decides. The ray stops `NOISE_SURFACE` (0.1 m) short of the noise, so the surface that a noise is made on, such as the floor under a step or the wall that a stone hits, does not block it. The ray ignores the perceiver and the source, and its filter is `sight_layers`. These rays are outside the sight budget, since noises are few.
- **What it gives:** a noise with a source updates that entity's memory entry, by hearing, at the noise's position. Every noise that is heard counts for the rows `heard noise` and `loudest noise`.

## Memory

Each agent keeps `Agent_Ready.perception`, a `Perception_Memory`, in its pool slot. The system makes it when the agent first perceives. It holds up to `MAX_MEMORY` (8) entries, in the order that the agent first perceived each:

| Field | What it is |
|---|---|
| `entity` | What was perceived |
| `position` | Where it was last perceived: its position for sight, the noise's for hearing |
| `since` | The seconds since it was last perceived |
| `tag` | Its tag, or the noise's |
| `sense` | The sense that it was last perceived by |
| `seen`, `heard` | Whether it is seen or heard now |

- **Forgetting:** an entry that is not perceived for longer than the perceiver's `memory` is forgotten. An entry whose entity went is forgotten at once.
- **A full memory** replaces the entry perceived longest ago that is not perceived now, which is forgotten. When every entry is perceived now, the new entity is not remembered.
- **Restarting:** the memory starts empty when the agent starts again, as when its blackboard is recooked.
- **Events:** the agent's behaviours get `on_perceive(entity, sense)`, where `sense` is `"sight"` or `"hearing"`, when it begins to perceive an entity: a new one, or one that it did not perceive in the last tick. They get `on_forget(entity)` when it forgets one. `ai.send_events` sends them from the frame code after each tick, so they arrive in the same tick ([Scripting: Events](../scripting/behaviours.md#events)).

## Filling the blackboard

The perception's rows fill the agent's keys in each tick, in their order ([Content: Perceptions](../content/kinds/perceptions.md#rows)).

- **A `nearest` row** chooses an entry with its tag: those perceived now first, then the nearest to the eye, then the first in the memory. `seen` and `heard` keep only those seen or heard now. It writes the entity, or none.
- **A row that reads a `nearest` row** writes the chosen entity's last position, whether it is seen now, or the seconds since it was perceived. With no entity, `position` writes nothing, `visible` writes false and `since` writes 0.
- **`heard noise`** writes whether a noise with the tag was heard in this tick. **`loudest noise`** writes the position of the loudest one, and nothing when there was none.
- **Checking:** a row whose key the blackboard does not have, or has of another type, is warned about when the agent first perceives, and again when either blob changes. The row is skipped.

## The order in a tick

1. `ai perceive`: the noises made since the last tick are taken, the sight rays are cast, and the memories are updated.
2. `ai think`, after it, and `ai actions` ([Agents: The order in a tick](agents.md#the-order-in-a-tick)).
3. The flush: perception's writes apply with the other commands, in system order and then job order. A decision reads them in the next tick's think.
4. The scripts' fixed step, physics, and then `ai.send_events`, before the tick's `fixed_events`.

## Determinism

What each agent perceives, and its blackboard, are the same on every run, on one job or many:

- The perceivers run in slot order, `PERCEIVE_BATCH` (16) to a job, twice: first to find their candidates, then to cast their rays and update their memories. The budget is shared serially between the two.
- Each job writes only its own perceivers' memories. Its commands and events are added after every job is done, in batch order, which is slot order.
- Candidates are ordered by distance and then by the order of the query, never by an `Entity` value.

The tests compare the memories and blackboards of 100 perceivers, with moving targets, walls and noises, on one job and on eight workers, with budgets of 32 and 1000.

## Scripts

| Binding | What it does |
|---|---|
| `Perception.noise(position, loudness, tag, source?)` | Makes a noise, which perceivers hear in the next tick. A tag that `perception.tags` does not give raises an error. |

A behaviour on an agent gets `on_perceive(entity, sense)` and `on_forget(entity)` ([Memory](#memory)).

## Drawing

The viewport's helpers draw a selected perceiver ([Editor: Viewport](../editor/viewport.md#viewport)):

- **In Edit:** its cone from its eye. A cone up to a half sphere is the circle at its range and four edges. A wider one is a sphere.
- **In Play and Paused:** the cone, the rays of its last sight check from its eye (green clear, red blocked), and a small sphere at each remembered entity's last position (green seen, yellow heard, grey remembered). Scene views keep the debug layer in these modes, and only selected perceivers draw there. The Game view has none.

`ai.perception_debug(s, entity)` gives an agent's memory for drawing.

## The sample

The sample's guard scene makes both kinds of noise from scripts: the player's steps, quiet `Player` noises whose source is the player, which keep the player in an agent's memory without sight, and a thrown stone's knocks, loud `Noise`s. Its fox guard sees from an eye 0.7 m up, so the low cover, 1.2 m high, hides the player's point at 1 m from it. The wary one's eye is at 1.7 m, so the low cover hides the player from it unless it is close ([AI: The sample](README.md#the-sample)).

## Limits

- **Sounds are not noises.** An `Audio_Source` or `Audio.play` makes no noise. Gameplay makes them.
- **Touch and damage** are not senses.
- **Teams do not share** what they know. Each agent has its own memory.
- **Hearing rays** are outside the sight budget.
- **Edit runs no `Fixed` systems**, so agents perceive only in Play.
