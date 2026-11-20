# Cutscenes

Cutscenes are `.cutscene` text files in the content roots. A cutscene has bindings and tracks on one time axis:

- A **binding** is an entity that the cutscene acts on. It possesses an entity that already exists in a scene, or it spawns an entity from a prefab.
- A **track** acts on one binding, or on none. Camera cuts and sub-sequences act on no binding.
- A track holds **sections**. A section holds keyed **channels**, and a clip, a sound or a sub-sequence when its track's kind names one.

`just cutscenes` runs `cook cutscenes --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`. The daemon cooks cutscenes like any other kind (`tools/cook/cutscenes.odin`).

This page describes the asset. [Cinematics](../../cinematics/README.md) describes how the game resolves its bindings. The player, its tracks and the cutscene editor are not built yet.

```
cutscene 1
# Times are ticks, 60000 a second.
length = 600000
rate = 30

binding 1 "Walking Fox"
	possess = @f496b929575035d9c2626ed56d3165ba/79cea6d7586e3f48
binding 2 "Extra Guard"
	spawn = $0d9b84a2116a5529c2cd33741edd33a4
	position = [150000000002, 0, 1.5]

track 1 transform "Fox walks"
	binding = 1
	when_finished = keep
	section 1 0 600000
		ease_in = 15000
		channel position_x
			key 0 0 linear
			key 600000 4 cubic 0.5 0
track 2 audio "Bark"
	binding = 2
	section 2 360000 420000
		asset = $7ce894b4b95e68b918869459e5cd9c93
```

`samples/mygame/content/cutscenes/intro.cutscene` is a longer example. It plays `fox_walk.cutscene` as a sub-sequence.

## Time

Every time in the text and in the blob is a whole number of **ticks**, `i32`, at `CUTSCENE_TICKS_PER_SECOND` (60000) a second.

- A frame at 24, 25, 30, 48, 50 or 60 fps is a whole number of ticks.
- An `i32` holds about 9.9 hours.
- A tick in the text is a whole number from 0 to 2147483647. `1.5`, `-1` and `2147483648` are problems.

## The text

- **The first line** is `cutscene 1`. A `#` starts a comment, except inside quotes. Indents make the text easier to read, but the parser ignores them.
- **Blocks.** These lines start a block:
  - `binding <id> "<name>"`
  - `track <id> <kind> "<name>"`
  - `section <id> <start> <end>`, which belongs to the track before it
  - `channel <name>`, which belongs to the section before it
- **Keys.** A `key <time> <value> <interp> [<in> <out>]` line belongs to the channel before it.
- **Settings.** A `<name> = <value>` line is a setting of the innermost block. Before the first binding or track, it is a setting of the cutscene. A block's settings come before its child blocks, so a track's setting after its first section is a problem. A setting comes once in each block.
- **IDs** are whole numbers from 1 to 2147483647. The editor and the runtime address bindings, tracks and sections by their IDs, not by their order, so a reorder or an insert does not break a reference.
  - Two bindings cannot have the same ID, and two tracks cannot have the same ID.
  - Each section's ID is unique in the whole cutscene.
- **Names** are quoted. Each binding has a name that no other binding has, so that a binding can be named in place of its ID. A track's name can be empty.

### The cutscene

| Setting | Value | Default |
|---|---|---|
| `length` | Ticks, from 1 | Needed |
| `rate` | The display frame rate: 24, 25, 30, 48, 50 or 60. It changes no time in the blob. | 30 |
| `clock` | `game`, which the game's time scale and pause change, or `real` | `game` |
| `range` | `[<start>, <end>]` in ticks: the part that plays. 0 ≤ start < end ≤ length. | `[0, <length>]` |

### Bindings

A binding has `possess` or `spawn`, and not both.

| Setting | For | Value | Default |
|---|---|---|---|
| `possess` | Possessed | `@<scene guid>/<id>` or `@<scene guid>/<path>`, as a reference to another scene's entity in a scene file (see [World: References across scenes](../../world/scenes.md#references-across-scenes)). A path, `<instance>#<entity>`, names an entity inside a prefab instance. | — |
| `policy` | Possessed | `required`: the cutscene fails when the entity is missing. `optional`: the binding's tracks do nothing. See [Cinematics: A missing binding](../../cinematics/bindings.md#a-missing-binding). | `required` |
| `spawn` | Spawned | `$<guid>` of a prefab | — |
| `parent` | Spawned | The ID of a spawned binding before this one | None |
| `position` | Spawned | `[x, y, z]` in meters, from the parent when it has one. The cooker converts it to `World_Position` units (2^-24 m), as a world does. | `[0, 0, 0]` |
| `rotation` | Spawned | `[x, y, z, w]`, a quaternion of length 1 (within 1e-3), which the cooker normalizes | `[0, 0, 0, 1]` |
| `scale` | Spawned | `[x, y, z]`, none of them 0 | `[1, 1, 1]` |

A parent must come before its child, so parents cannot form a cycle. [Cinematics: Bindings](../../cinematics/bindings.md) describes how the game resolves both kinds.

### Tracks

| Setting | Value | Default |
|---|---|---|
| `binding` | The ID of a binding | None |
| `muted` | `true` or `false`. A muted track does nothing. | `false` |
| `when_finished` | `restore`: the player puts back the fields that the track wrote. `keep`: they stay as the cutscene left them. | `restore` |

The kind of a track decides whether it takes a binding, and what each of its sections names with `asset`. The kinds have no data of their own yet, besides their channels and assets:

| Kind | Binding | Section's asset |
|---|---|---|
| `transform` | Needed | None |
| `property` | Needed | None |
| `animation` | Needed | An animation clip, a sub-asset of a glTF model |
| `camera_cut` | None | None |
| `audio` | Optional | A sound |
| `event` | Optional | None |
| `sub_sequence` | None | A cutscene |
| `presentation` | None | None |

### Sections

`section <id> <start> <end>` has its start and end on the cutscene's time, with 0 ≤ start < end ≤ length.

| Setting | Value | Default |
|---|---|---|
| `ease_in`, `ease_out` | Ticks. Together they are at most the section's duration. | 0 |
| `weight` | A number from 0 to 1 | 1 |
| `asset` | `$<guid>`. Needed for a kind that names an asset, and a problem for the others. | — |

### Channels and keys

`channel <name>` starts a curve of the section. Its name is letters, digits and `_`, and no other channel of the section has it. Its track's kind will give the names their meaning; for now, any name is good. A channel has at least one key.

`key <time> <value> <interp> [<in> <out>]`:
- **The time** is in ticks from the section's start, from 0 to the section's duration. So a section moves without a change to its keys. Each key comes after the one before it.
- **The value** is a finite number.
- **The interpolation** goes from this key to the next: `constant`, `linear` or `cubic`. A cubic key has an in and an out tangent, in value per second. The other keys have none.

## The blob

A `Cutscene_Blob` (`lib/engine/asset/format/cutscene.odin`) holds the length, the rate, the clock and the range. It then holds five flat tables:

- **`Cutscene_Binding`:**
  - its ID, kind, name and the name's hash (`animation_graph_hash`), and its policy;
  - the scene's GUID and the entity's scene ID (a path folds to one with `scene_path_id_of`), or the prefab's GUID;
  - its parent's index or `CUTSCENE_NONE`;
  - its position as `[3]i64` `World_Position` units, its rotation and its scale.
- **`Cutscene_Track`:** its ID, kind, name, binding's index or `CUTSCENE_NONE`, flags (`.Muted`), when-finished, and its first section and count.
- **`Cutscene_Section`:** its ID, start, end, eases, weight, asset GUID (zero for a kind that names none), and its first channel and count.
- **`Cutscene_Channel`:** its name and the name's hash, and its first key and count.
- **`Cutscene_Key`:** its time from the section's start, its value, its interpolation and its two tangents.

Each track's sections follow those of the track before it. The same is true of each section's channels and each channel's keys. `cutscene_track_sections`, `cutscene_section_channels` and `cutscene_channel_keys` give one record's part of the next table.

`cutscene_view` checks the kind, the layout and that every slice is inside the blob. It also checks every record, so a reader can index the tables without checks of its own:
- the length, rate, clock and range;
- that each binding's parent is a spawned binding before it;
- that each track's binding suits its kind;
- that the tables split exactly, with no gaps and no overlaps;
- each section's times, eases, weight and asset against its kind;
- that every channel has keys;
- that each key is inside its section, comes after the key before it, has a known interpolation and has finite numbers.

`blob_references` gives the prefabs of the spawned bindings and the sections' clips, sounds and sub-sequences, so a bundle carries them. A possessed binding's scene is not a reference: the cutscene plays in a level that has the scene loaded, and its bundle does not pull in the level.

- **Problems** have their line. They include:
  - a first line that is not `cutscene 1`, or a cutscene without a `length`;
  - a line that is not a block, a key or a setting, or a section, channel or key outside its block;
  - an unknown setting, a setting given twice, or a setting after its block's children;
  - an ID that is not from 1 to 2147483647, or that is taken;
  - a binding's name that is empty or taken;
  - a time that is not a whole number of ticks, a range outside the length, or a section that does not start before it ends inside the length;
  - a binding with neither `possess` nor `spawn`, or both, or a setting for the other kind of binding;
  - a parent that is not a spawned binding before this one;
  - a position outside the bounds of a `World_Position`, a rotation that is not of length 1, or a scale of 0;
  - a track's kind that is unknown, a track without the binding that its kind needs, a binding that its kind does not take, or a binding ID that no binding has;
  - eases longer than the section, or a weight outside 0 to 1;
  - a section without the asset that its kind needs, or with one that its kind does not take;
  - a channel's name that is not a name or is taken, or a channel without keys;
  - a key's time outside its section or not after the key before it, a value that is not finite, an unknown interpolation, or tangents that are missing or not wanted;
  - a GUID that names no asset, or an asset of the wrong kind: a possessed scene that is not a scene, a spawned prefab that is not a prefab, a clip that is not an animation, a sound that is not a sound, or a sub-sequence that is not a cutscene;
  - a cycle of sub-sequences, which each cutscene in it reports at the line that names the next, with the path, such as `sub-sequence cycle: game/a.cutscene -> game/b.cutscene -> game/a.cutscene`;
  - sub-sequences that nest deeper than `CUTSCENE_MAX_DEPTH` (8), at the line of the first one on the deepest path, with the path;
  - more than `MAX_CUTSCENE_BINDINGS` (1024) bindings, `MAX_CUTSCENE_TRACKS` (1024) tracks, `MAX_CUTSCENE_SECTIONS` (8192) sections, `MAX_CUTSCENE_CHANNELS` (65536) channels or `MAX_CUTSCENE_KEYS` (2^20) keys.
- **A cutscene with a problem** keeps its old blob, so the running game keeps the last good version.
- **Sub-sequences.** The cooker reads each sub-sequence's source, not its blob, so the order of the passes does not matter. A pass that cooks one cutscene checks every cutscene, because a cycle or a depth is a property of all the cutscenes that it reaches.
- **The cooker does not check** that a possessed entity is in its scene, because that needs the scene's prefabs expanded. The binding's policy says what to do when the entity is missing at run time ([Cinematics: A missing binding](../../cinematics/bindings.md#a-missing-binding)).
- **Dependencies.** The cooker adds each GUID that the cutscene names to its dependencies, the possessed scenes included. So a fix to one of these assets cooks the cutscene again.
- **The cache key** covers the cooker version, the layout, the source path, the source and the GUID.
- **Hot reload:** a cooked cutscene reaches the game as any blob does (see [Blobs and loading: Loading](../blobs-and-loading.md#loading)). Nothing plays a cutscene yet, so nothing reacts to a new blob.
- **The editor** shows cutscenes among the animation in the content browser, with a clapperboard icon, and opens them as text in the script editor until a cutscene editor exists. **New Cutscene**, in the content browser's menu and in the Gameplay tab's New Asset group, makes a cutscene of 10 s at 30 frames a second.
