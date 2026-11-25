# Cutscenes

Cutscenes are `.cutscene` text files in the content roots. A cutscene has bindings and tracks on one time axis:

- A **binding** is an entity that the cutscene acts on. It possesses an entity that already exists in a scene, or it spawns an entity from a prefab.
- A **track** acts on one binding, or on none. Camera cuts and sub-sequences act on no binding.
- A track holds **sections**. A section holds keyed **channels**, and a clip, a sound or a sub-sequence when its track's kind names one.

`just cutscenes` runs `cook cutscenes --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`. The daemon cooks cutscenes like any other kind (`tools/cook/cutscenes.odin`).

This page describes the asset. [Cinematics](../../cinematics/README.md) describes how the game resolves its bindings, evaluates its tracks and plays it, and [Cinematics: Tracks](../../cinematics/tracks.md) the curve and the kinds of track that are built. The [cutscene editor](../../editor/cutscene-editor.md) opens it in a tab, which is built in steps.

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
			key 600000 4 bezier 0.5 0
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
- A tick in the text is a whole number from 0 to 2147483647. It is in the digits 0 to 9 alone, so `1.5`, `-1`, `1_000` and `2147483648` are problems.

## The text

- **The first line** is `cutscene 1`. A `#` starts a comment at the line's start or after a space or a tab, except inside quotes. So a color is quoted, as `"#ff8800"`. A `#` inside a word is not a comment, so a `possess` path, `@<guid>/<instance>#<entity>`, is whole, and `x = 1 # note` still ends at the comment. Both rules are `format.strip_comment`: the other text formats call it plainly, and this one with `hash_in_word`. Indents make the text easier to read, but the parser ignores them.
- **Blocks.** These lines start a block:
  - `binding <id> "<name>"`
  - `track <id> <kind> "<name>"`
  - `marker <id> <time> "<name>"` (see [Markers](#markers))
  - `section <id> <start> <end>`, which belongs to the track before it
  - `channel <name>`, which belongs to the section before it
  - `trigger <id> <time> <name>` and `range <id> <start> <end> <name>`, which belong to the event track before them
- **Keys.** A `key <time> <value> <interp> [<in> <out>]` line belongs to the channel before it.
- **Settings.** A `<name> = <value>` line is a setting of the innermost block. Before the first binding or track, it is a setting of the cutscene. A block's settings come before its child blocks, so a track's setting after its first section is a problem. A setting comes once in each block.
- **IDs** are whole numbers from 1 to 2147483647. The editor and the runtime address bindings, tracks and sections by their IDs, not by their order, so a reorder or an insert does not break a reference.
  - Two bindings cannot have the same ID, and two tracks cannot have the same ID.
  - Each section's ID is unique in the whole cutscene.
  - Each trigger's and range's ID is unique among the cutscene's triggers and ranges.
  - Each marker's ID is unique among the cutscene's markers.
- **Names** are quoted. Each binding has a name that no other binding has, so that a binding can be named in place of its ID. A track's name can be empty.

### The cutscene

| Setting | Value | Default |
|---|---|---|
| `length` | Ticks, from 1 | Needed |
| `rate` | The display frame rate: 24, 25, 30, 48, 50 or 60. It changes no time in the blob. | 30 |
| `clock` | `game`, which the game's time scale and pause change, or `real` | `game` |
| `range` | `[<start>, <end>]` in ticks: the part that plays. 0 ≤ start < end ≤ length. | `[0, <length>]` |
| `suspend` | What each binding suspends on its entity when it does not say: a list of `behaviours`, `ai`, `navigation` and `physics`, each at most once. `[]` is none. See [Cinematics: Possession](../../cinematics/possession.md#the-settings). | `[behaviours, ai, navigation, physics]` |
| `input_context` | The quoted name of the input context that the cutscene pushes while it plays, at most 24 bytes. `""` is none. | `"cutscene"` |
| `hide_ui` | `[$<guid>, ...]`: the UI documents that the cutscene hides while it plays, such as the HUD | `[]` |
| `skip` | What a player can skip: `anywhere`, to the end of the range; `none`; or `[[<start>, <end>], ...]`, ranges in ticks, in time order and not overlapping, inside the length, each of which a skip in it goes to the end of. See [Cinematics: Skipping](../../cinematics/skipping.md#the-policy). | `anywhere` |
| `skip_fade` | Ticks: the length of a skip's fade out, of its fade in when play goes on, and of the fade back after a skip to the end. 0 jumps at once. | 0 |
| `skip_color` | The color of a skip's fade: a quoted `"#rrggbb"` or `"#rgb"`, without alpha. See [Cinematics: Skipping](../../cinematics/skipping.md#the-fade). | `"#000000"` |

### Bindings

A binding has one of `possess`, `spawn` and `provided`.

| Setting | For | Value | Default |
|---|---|---|---|
| `possess` | Possessed | `@<scene guid>/<id>` or `@<scene guid>/<path>`, as a reference to another scene's entity in a scene file (see [World: References across scenes](../../world/scenes.md#references-across-scenes)). A path, `<instance>#<entity>`, names an entity inside a prefab instance. | — |
| `policy` | Possessed, Provided | `required`: the cutscene fails when the entity is missing. `optional`: the binding's tracks do nothing. See [Cinematics: A missing binding](../../cinematics/bindings.md#a-missing-binding). | `required` |
| `spawn` | Spawned | `$<guid>` of a prefab | — |
| `provided` | Provided | `true`. A script gives the binding's entity when it plays the cutscene, by the binding's name or ID (see [Cinematics: Provided bindings](../../cinematics/bindings.md#provided-bindings)). Any other value is a problem. | — |
| `parent` | Spawned | The ID of a spawned binding before this one | None |
| `position` | Spawned | `[x, y, z]` in meters, from the parent when it has one. The cooker converts it to `World_Position` units (2^-24 m), as a world does. | `[0, 0, 0]` |
| `rotation` | Spawned | `[x, y, z, w]`, a quaternion of length 1 (within 1e-3), which the cooker normalizes | `[0, 0, 0, 1]` |
| `scale` | Spawned | `[x, y, z]`, none of them 0 | `[1, 1, 1]` |
| `suspend` | Both | What the binding suspends on its entity, as the cutscene's `suspend` | The cutscene's |
| `keep_velocity` | Both | `true`: a body that physics suspension made kinematic keeps its last velocity at the end. `false`: it is at rest. | `false` |
| `look_at`, `look_at_offset`, `look_at_damping`, `follow`, `follow_offset`, `follow_damping`, `focus` | Both | The binding's constraints as a camera, as a camera cut section's (see [Sections](#sections)). Only a binding that a camera cut section shows takes them. | None |

A parent must come before its child, so parents cannot form a cycle. A provided binding has no entity or prefab in the asset, so `parent` and the start transform are a problem for it. [Cinematics: Bindings](../../cinematics/bindings.md) describes how the game resolves the three kinds.

### Tracks

| Setting | Value | Default |
|---|---|---|
| `binding` | The ID of a binding | None |
| `muted` | `true` or `false`. A muted track does nothing. | `false` |
| `when_finished` | `restore`: the player puts back the fields that the track wrote. `keep`: they stay as the cutscene left them. | `restore` |
| `component` | A property track's component, by its stable ID in decimal, as a scene names it. Needed for a property track, and a problem for the others. | — |
| `field` | A property track's field, by its quoted name, with dots between the names of nested fields, such as `"light.intensity"`. Needed for a property track, and a problem for the others. | — |
| `space` | A transform track's space: `relative`, from its binding's own pose; `absolute`, from its `origin`; or `relative <id>`, from the binding with that ID, which is not the track's own. A problem for the other kinds. See [Cinematics: Transform tracks](../../cinematics/tracks.md#transform-tracks). | `relative` |
| `origin` | `[x, y, z]` in meters: an absolute transform track's origin. The cooker converts it to `World_Position` units (2^-24 m). A problem for the other spaces and kinds. | `[0, 0, 0]` |
| `gain` | An audio track's gain, a number from 0, which multiplies its sections' gains. A problem for the other kinds. | 1 |
| `time_scale` | What an audio track's sounds do under a time scale other than 1: `follow`, the pitch follows the scale; `free`, they play at their own rate and come back to the cutscene's time when the scale is 1 again ([Cinematics: Audio tracks](../../cinematics/tracks.md#audio-tracks)). A problem for the other kinds. | `follow` |
| `letterbox_aspect` | A presentation track's letterbox bars: `camera`, they take the aspect of the camera that the cut track shows, while it shows one; `sections`, they take the sections' aspect ([Cinematics: Presentation tracks](../../cinematics/tracks.md#presentation-tracks)). A problem for the other kinds. | `sections` |

The cooker cannot see a property track's field, because native components exist only in the game's code. The game checks that the field can animate when it loads the cutscene ([Cinematics: Property tracks](../../cinematics/tracks.md#property-tracks)).

The kind of a track decides whether it takes a binding, and what each of its sections names with `asset`. Besides their channels and assets, only property, transform, audio and event tracks, and animation, camera cut, audio, sub-sequence and presentation sections, have data of their own. A binding has at most one animation track, and a cutscene has at most one camera cut track, muted or not:

| Kind | Binding | Section's asset |
|---|---|---|
| `transform` | Needed | None |
| `property` | Needed | None |
| `animation` | Needed | An animation clip, a sub-asset of a glTF model |
| `camera_cut` | None | None; each section names a camera binding |
| `audio` | Optional | A sound |
| `event` | Optional | None; it has triggers and ranges, not sections |
| `sub_sequence` | None | A cutscene |
| `presentation` | None | None; each section has a kind |

### Sections

`section <id> <start> <end>` has its start and end on the cutscene's time, with 0 ≤ start < end ≤ length.

| Setting | Value | Default |
|---|---|---|
| `ease_in`, `ease_out` | Ticks. Together they are at most the section's duration. | 0 |
| `weight` | A number from 0 to 1 | 1 |
| `pre_roll`, `post_roll` | Ticks before the start and after the end in which the section holds its first and last values ([Cinematics: Sections and blending](../../cinematics/evaluation.md#sections-and-blending)) | 0 |
| `asset` | `$<guid>`. Needed for a kind that names an asset, and a problem for the others. | — |
| `blend` | `absolute`: the section blends over the sections below it. `additive`: it adds its value to theirs. Only transform and property sections can be additive. | `absolute` |
| `offset` | An animation or audio section's ticks into its clip or sound, where the section starts | 0 |
| `speed` | An animation section's clip time per the cutscene's time: a number above 0 | 1 |
| `loop` | `true`: past its clip's or sound's end, an animation or audio section starts it again, and past its trim's end, a sub-sequence section starts its trim again. `false`: an animation section holds the clip's last pose, an audio section is silent, and a sub-sequence section holds its trim's end. | `false` |
| `root_motion` | What an animation section does with its clip's root motion: `bake`, the root moves in the mesh; `apply`, the track moves the binding by it; `in_place`, the clip plays in place. See [Cinematics: Animation tracks](../../cinematics/tracks.md#animation-tracks). | `bake` |

`offset` is for animation and audio sections, `loop` for those and sub-sequence sections, and `speed` and `root_motion` for animation sections only. On a section of another kind, each one is a problem.

An audio section has settings of its own ([Cinematics: Audio tracks](../../cinematics/tracks.md#audio-tracks)). It has no `pre_roll` or `post_roll`, and each of these settings on a section of another kind is a problem:

| Setting | Value | Default |
|---|---|---|
| `bus` | A whole number from 0, Master, to 16: n is the nth of the project's `audio.buses`, as `Audio_Source.bus` | 0 |
| `min_distance`, `max_distance` | Meters from 0, the max farther than the min: full gain at `min_distance` and nearer, silent at `max_distance` and farther, when the track has a binding | 1, 50 |
| `plays_through_skip` | `true`: the sound plays on to the section's end through a skip, and past the cutscene's end, at its own rate. `false`: a skip fades it out, and the end stops it. | `false` |

A camera cut section has settings of its own ([Cinematics: Camera cut tracks](../../cinematics/tracks.md#camera-cut-tracks)):

| Setting | Value | Default |
|---|---|---|
| `camera` | The ID of the binding whose camera the section shows. Needed. | — |
| `blend_in`, `blend_out` | `<ticks> [curve]`: a blend from gameplay into a section that is first or follows a gap, or from a section that is last or comes before a gap back to gameplay. The curve is `linear`, `smooth`, `ease_in` or `ease_out`. A blend in is at most the section's duration. | 0, a cut |
| `blend_on_skip` | `true`: a skip that ends the cutscene blends out with this section's `blend_out`, whichever shot shows. `false`: it cuts. Only the last section's setting counts. | `false` |
| `look_at`, `follow`, `focus` | The ID of a binding that the camera looks at, follows or focuses on. Not the camera itself. | None |
| `look_at_offset`, `follow_offset` | `[x, y, z]` in meters in the target's space | `[0, 0, 0]` |
| `look_at_damping`, `follow_damping` | Ticks over which the constraint takes hold from the section's start | 0 |

A camera cut section cuts: it has no `ease_in`, `ease_out`, `weight`, `pre_roll`, `post_roll`, `blend` or channels, and it starts at or after the end of the section before it. Each of the camera cut settings on a section of another kind is a problem.

A sub-sequence section plays the cutscene that its `asset` names, and has settings of its own ([Cinematics: Sub-sequence tracks](../../cinematics/tracks.md#sub-sequence-tracks)):

| Setting | Value | Default |
|---|---|---|
| `trim` | `<start> [<end>]`: the span of the child's time that the section plays, in ticks on the child's time. Without an end, it plays to the end of the child's range. | The child's range |
| `scale` | The child's time per this cutscene's time: a number above 0 | 1 |
| `loop` | `true`: past the trim's end, the child's time starts the trim again. `false`: it holds at the trim's end. | `false` |
| `bind <child id> = <id>` | A line that gives the child's binding with the first ID to this cutscene's binding with the second, so the child's tracks act on it. Each of the child's bindings at most once. A binding that no line names resolves on its own. | None |
| `name` | Quoted text: the shot's name, which the editor's bar, breadcrumbs and shot list show. The blob does not keep it. | The child's file name |

```
track 4 sub_sequence "Opening shot"
	section 4 0 300000
		asset = $497bcb7bb533b902877cd8d56fbf97cd
		trim = 0 240000
		scale = 1.25
		bind 1 = 1
```

A sub-sequence section has no `offset`, `speed`, `root_motion` or channels, and starts at or after the end of the section before it on its track. Its `ease_in`, `ease_out` and `weight` scale the weights of the child's sections. `trim`, `scale`, `bind` and `name` on a section of another kind are problems, and so is a `name` that is not quoted text. A `bind` comes before the section's channels.

A presentation section has a `kind` and settings of its own ([Cinematics: Presentation tracks](../../cinematics/tracks.md#presentation-tracks)). A section without a `kind` is a problem:

| Setting | For | Value | Default |
|---|---|---|---|
| `kind` | All | `fade`, `letterbox` or `subtitle` | Needed |
| `color` | Fade | A quoted `"#rrggbb"` or `"#rgb"`, without alpha | `"#000000"` |
| `speaker` | Subtitle | The quoted name of the speaker | `""` |
| `text` | Subtitle | The quoted line. Needed. | — |
| `key` | Subtitle | The quoted key of the line in a string table | `""` |
| `audio` | Subtitle | The ID of a section of an audio track of the cutscene. The editor moves the subtitle with that section. | None |

```
track 10 presentation "Presentation"
	section 13 30000 174000
		kind = subtitle
		speaker = "Narrator"
		text = "The fox walks this path every evening."
		audio = 10
```

Each of these settings on a section of another track is a problem. So is a `color` on a letterbox or a subtitle, and a `speaker`, `text`, `key` or `audio` on a fade or a letterbox.

### Triggers and ranges

An event track has no sections and no `when_finished`. It has `trigger <id> <time> <name>` and `range <id> <start> <end> <name>` blocks ([Cinematics: Event tracks](../../cinematics/tracks.md#event-tracks)):
- **The name** is letters, digits and `_`. A trigger sends `on_<name>`, and a range sends `on_<name>_begin` and `on_<name>_end`.
- **The times** are inside the length, and a range starts before it ends. The cooker sorts a track's triggers and ranges by their start.
- **The binding.** An event track's binding must not suspend `behaviours`, so its behaviours get its events.

| Setting | Value | Default |
|---|---|---|
| `value` | `<kind> <value>`: `number <n>`, `bool true` or `bool false`, `string "<text>"`, `vector [x, y, z]`, `entity <binding id>`, `position [x, y, z]` in meters, or `asset $<guid>`. A trigger or a range has at most 4, in order. This setting can come more than once. | None |
| `fire_on_seek` | `true`: a forward seek that crosses it sends it | `false` |
| `fire_when_skipped` | `true`: a skip that crosses it sends it | `false` |

### Markers

A `marker <id> <time> "<name>"` block is a named, colored point on the cutscene's time, such as a beat of the music. The [cutscene editor](../../editor/cutscene-editor.md#markers) shows it on its ruler, snaps to it and jumps to it. Nothing at run time reads markers yet. They are not an animation clip's markers, which raise events ([Cinematics: Animation tracks](../../cinematics/tracks.md#animation-tracks)).
- **It belongs to the cutscene,** as a binding or a track does, wherever it is in the text. So a setting after it is its own, and a section, a trigger or a range after it is a problem until the next track.
- **The time** is inside the length. **The name** is quoted and not empty. A cutscene has at most `MAX_CUTSCENE_MARKERS` (1024).
- **The text** may hold markers in any order. The blob holds them in time order, and at one time, in ID order. The editor keeps them in time order.

| Setting | Value | Default |
|---|---|---|
| `color` | A quoted `"#rrggbb"` or `"#rgb"`, without alpha | `"#f5a623"`, amber |

```
marker 1 180000 "Music swells"
	color = "#336699"
```

### Channels and keys

`channel <name>` starts a curve of the section. Its name is letters, digits and `_`, and no other channel of the section has it. A channel has at least one key. Its track's kind gives the names their meaning:
- **Property tracks:** `value`, for a number and for a field that steps, or a vector's numbers as `x`, `y` and `z`, or `r`, `g` and `b`. A section keys `value` alone or one vector's names, and not both sets.
- **Transform tracks:** `position_x`, `position_y` and `position_z` in meters, `rotation_x`, `rotation_y` and `rotation_z` in degrees, and `scale_x`, `scale_y` and `scale_z`.
- **Camera cut tracks:** none.
- **Audio tracks:** `gain`, from 0, and `pitch`, from 0.1 to 4.
- **Presentation tracks:** a fade's `opacity`, from 0 to 1; a letterbox's `aspect`, from 1 to 4, and `amount`, from 0 to 1. A subtitle has no channels. The cooker checks the ranges of the keys. `cutscene_view` checks only the names and the structure, so the runtime clamps a value to its range.
- **Event tracks:** no channels: they have triggers and ranges.
- **The other kinds** take any name for now.

A channel's settings come before its keys:
- **`pre_infinity`** is what the curve does before its first key, and **`post_infinity`** after its last: `constant`, which is the default, `linear`, `cycle`, `cycle_offset` or `oscillate` ([Cinematics: Curves](../../cinematics/tracks.md#curves)).
- An audio track's `pitch` takes only `constant`, and a channel of assets takes `constant`, `cycle` or `oscillate`.

```
channel position_y
	post_infinity = cycle
	key 0 0 auto
	key 30000 0.25 auto
	key 60000 0 auto
```

`key <time> <value> <interp> [<slope> | <in> <out>] [weights <in> <out>] [teleport]`:
- **The time** is in ticks from the section's start, from 0 to the section's duration. So a section moves without a change to its keys. Each key comes after the one before it.
- **The value** is a finite number. A whole number with more than 24 bits, which an `f32` does not hold exactly, is a problem.
- **An asset's value** is `$<guid>`, for a property track that animates an asset field. The key is `constant`, and every key of its channel is an asset.
- **The interpolation** goes from this key to the next: `constant`, `linear`, `bezier` or `auto` ([Cinematics: Curves](../../cinematics/tracks.md#curves)).
- **A Bezier key** has one slope, for unified tangents, or an in and an out slope apart, for broken ones, in value per second. `weights <in> <out>`, each from 0 to 1, weights its tangents. The other keys have no tangents.
- **`teleport`**, last, marks a transform track's key: an evaluation that crosses it moves the entity at once ([Cinematics: Transform tracks](../../cinematics/tracks.md#transform-tracks)).

```
key 0 0 auto
key 30000 2 bezier 0.5
key 45000 1 bezier 2 -1 weights 0.25 0.75
key 50000 3 linear teleport
key 60000 $0d9b84a2116a5529c2cd33741edd33a4 constant
```

## The blob

A `Cutscene_Blob` (`lib/engine/asset/format/cutscene.odin`) holds the length, the rate, the clock, the range, the name of its input context, the GUIDs of the documents that it hides (`cutscene_hide_ui`), and its skip policy, skip ranges (`cutscene_skip_ranges`, at most `MAX_CUTSCENE_SKIP_RANGES`, 256), skip fade and `skip_color`, an opaque `Ui_Color` that took the place of a reserved word. It then holds eleven flat tables:

- **`Cutscene_Binding`:**
  - its ID, kind, name and the name's hash (`animation_graph_hash`), and its policy;
  - what it suspends, with the cutscene's default applied, and its flags (`.Keep_Velocity`);
  - the scene's GUID and the entity's scene ID (a path folds to one with `scene_path_id_of`), or the prefab's GUID;
  - its parent's index or `CUTSCENE_NONE`;
  - its position as `[3]i64` `World_Position` units, its rotation and its scale.
- **`Cutscene_Track`:** its ID, kind, name, binding's index or `CUTSCENE_NONE`, flags (`.Muted`, and `.Follow_Camera` for a presentation track whose bars take the camera's aspect), when-finished, its first section and count, for a property track its component's stable ID and its field's name and `scene_field_hash`, and for a transform track its space (`Cutscene_Space`), its origin as `[3]i64` `World_Position` units, and the index of the binding that it is relative to, or `CUTSCENE_NONE`. An audio track has its gain and its `time_scale` (`Cutscene_Audio_Scale`: `Follow` or `Free`). The other kinds have 0 and `Follow` there. An event track has its first event and count, and no sections. The other kinds have no events.
- **`Cutscene_Section`:** its ID, start, end, eases, weight, pre-roll and post-roll, asset GUID (zero for a kind that names none), its first channel and count, and its flags (`.Additive`, `.Loop`, `.Blend_On_Skip`, `.Plays_Through_Skip`). A section of a kind that plays its asset's time (`cutscene_track_plays`: animation, audio and sub-sequence) also has its offset into the asset in ticks, its speed, which is 1 for an audio section, and its root motion (`Cutscene_Root_Motion`: `Bake`, `Apply` or `In_Place`). The other kinds have zeros there. A sub-sequence section's offset and speed are its trim's start and its scale, and it has its trim's end, or 0 for the end of the child's range, in `trim_end`. The other kinds have 0 there. A camera cut section has its camera's binding index, and its blends in and out in ticks with their curves (`Cutscene_Blend_Curve`). The other kinds have `CUTSCENE_NONE` and zeros there. An audio section has its bus and its `min_distance` and `max_distance`. The other kinds have zeros there.
- **`Cutscene_Constraint`:** its kind (`Look_At`, `Follow` or `Focus`), the index of the camera cut section or of the binding that holds it (the other is `CUTSCENE_NONE`), its target binding's index, its offset and its damping in ticks. `cutscene_constraints` gives them, at most `MAX_CUTSCENE_CONSTRAINTS` (8192): the bindings' first, then the sections'.
- **`Cutscene_Channel`:** its name and the name's hash, its first key and count, its flags (`.Guids`, when its keys' values are indexes into the GUIDs), and its `pre_infinity` and `post_infinity`.
- **`Cutscene_Key`:** its time from the section's start, its value, its interpolation, its flags (`.Broken`, `.Weighted`, `.Teleport`), and its in and out slopes and weights.
- **`Cutscene_Event`:** a trigger or a range of an event track: its ID, its start and end on the cutscene's time (a trigger's end is its start), its flags (`.Range`, `.Fire_On_Seek`, `.Fire_When_Skipped`), its name, and its first value and count. At most `MAX_CUTSCENE_EVENTS` (8192).
- **`Cutscene_Binding_Map`:** a sub-sequence section's `bind`: the section's index, the child's binding by its ID in the child, and this cutscene's binding by its index. At most `MAX_CUTSCENE_BINDING_MAPS` (65536), in section order. `cutscene_section_maps` gives one section's. A child's binding is by its ID, so a child that is cooked again, with its bindings in another order, keeps its maps.
- **`Cutscene_Presentation`:** a row of 40 bytes for each section of a presentation track, in section order, by the section's index: its kind (`Cutscene_Presentation_Kind`: `Fade`, `Letterbox` or `Subtitle`), a fade's color, opaque, a subtitle's speaker, text and key, and the index of the audio section that it belongs to, or `CUTSCENE_NONE`. The other kinds have zeros and `CUTSCENE_NONE` there. `cutscene_presentations` gives the rows, and `cutscene_presentation_of` the row of a section.
- **`Cutscene_Marker`:** a marker's ID, time, name and opaque `Ui_Color`, in time order and then ID order. `cutscene_markers` gives them, at most `MAX_CUTSCENE_MARKERS` (1024).
- **`Cutscene_Event_Value`:** its kind (`Cutscene_Value_Kind`: `Number`, `Bool`, `String`, `Vector`, `Entity`, `Position` or `Asset`), and the field that the kind holds: `index` for a bool (0 or 1), a binding's index or an index into the GUIDs, `text`, `number`, `vector`, or `position` in `World_Position` units. The other fields are zero.

The blob also holds `cutscene_guids`: the assets that keys and asset values name, each once, at most `MAX_CUTSCENE_GUIDS` (65536).

Each track's sections follow those of the track before it. The same is true of each section's channels, each channel's keys, each event track's events and each event's values. `cutscene_track_sections`, `cutscene_section_channels`, `cutscene_channel_keys`, `cutscene_track_events` and `cutscene_values_of` give one record's part of the next table.

`cutscene_view` checks the kind, the layout and that every slice is inside the blob. It also checks every record, so a reader can index the tables without checks of its own:
- the length, rate, clock and range, and that the hidden documents are whole GUIDs;
- the skip policy, a fade of 0 or more, and skip ranges only for the `Ranges` policy, each inside the length and after the one before it;
- that each binding's parent is a spawned binding before it, and that it suspends and flags only known things;
- that each track's binding suits its kind;
- that the tables split exactly, with no gaps and no overlaps;
- each section's times, eases, rolls, weight and asset against its kind;
- that a section of a kind that plays its asset has an offset from 0 and a finite speed above 0, that only an animation section has a root motion other than `Bake`, and that the other kinds have no offset, speed or `.Loop`;
- that only property tracks name a field and key assets, and that only transform and property sections are additive;
- that an audio track's gain is from 0 and finite, that an audio section has a speed of 1, no rolls, a bus up to `MAX_CUTSCENE_BUS` (16) and a `max_distance` past its `min_distance` from 0, that its channels are `gain`, with keys from 0, and `pitch`, with keys from 0.1 to 4, and that the other kinds have no gain, time scale policy, bus, distances or `.Plays_Through_Skip`;
- that a cutscene has at most one camera cut track, whose sections name a binding, have a weight of 1 and no eases, rolls, channels or additive blend, follow one another without overlap, blend in only after a gap or first, blend out only before a gap or last, and blend out on a skip only with a blend out, and that the other kinds' sections have no camera, blends or `.Blend_On_Skip`;
- that each constraint is on one cut section or one binding, of a known kind, with a target that is a binding and not its camera, a finite offset and a damping of 0 or more, and that a focus has neither;
- that only a transform track has a space other than `Relative`, that only an absolute track has an origin, inside the bounds of a `World_Position`, and that only a track relative to another binding names one, which is not its own;
- that a sub-sequence track's sections do not overlap and have no channels, that a section's trim ends after its offset or is 0, that only a sub-sequence section has a trim's end, and that each map is on a sub-sequence section, in section order, names a binding of the blob and maps a child's binding at most once for its section;
- a `skip_color` that is opaque, `.Follow_Camera` only on a presentation track, and the presentation rows: one for each section of a presentation track, in section order and for no other; a fade's color opaque and the other kinds' color zero; strings inside the blob, and only on a subtitle; a subtitle's audio section the index of a section of an audio track; and the channels of each kind (`opacity`; `aspect` and `amount`; none);
- that every channel has keys;
- that a channel's infinity modes are known ones, constant on an audio track's `pitch`, and not `linear` or `cycle_offset` on a channel of assets;
- that only an event track has events, that it has no sections and does not keep, that each event is inside the length, in start order on its track, with a name, a range's end after its start and a trigger's at it, known flags and at most 4 values, and that each value has a known kind, holds only its kind's field, and names a binding or a GUID that the blob has;
- that each key is inside its section, comes after the key before it, has a known interpolation and flags and has finite numbers, that a key that is not a Bezier key has no tangents, that only a weighted key has weights, from 0 to 1, that only a transform track's keys teleport, and that a key that names an asset is constant and names one of the GUIDs.

`blob_references` gives the prefabs of the spawned bindings, the sections' clips, sounds and sub-sequences, and the assets that keys and asset values name, so a bundle carries them. A possessed binding's scene is not a reference: the cutscene plays in a level that has the scene loaded, and its bundle does not pull in the level. A hidden document is not a reference either: the HUD that a cutscene hides is the level's or the game's.

- **Problems** have their line. They include:
  - a first line that is not `cutscene 1`, or a cutscene without a `length`;
  - a line that is not a block, a key or a setting, or a section, channel or key outside its block;
  - an unknown setting, a setting given twice, or a setting after its block's children;
  - an ID that is not from 1 to 2147483647, or that is taken;
  - a binding's name that is empty or taken;
  - a time that is not a whole number of ticks, a range outside the length, or a section that does not start before it ends inside the length;
  - a binding with neither `possess` nor `spawn`, or both, or a setting for the other kind of binding;
  - a `skip` that is not `anywhere`, `none` or a list of ranges, a skip range outside the length or that does not start before it ends, skip ranges out of order or that overlap, or a `skip_fade` that is not a whole number of ticks;
  - a `suspend` that is not a list of known systems, each at most once, a `keep_velocity` that is not `true` or `false`, an `input_context` that is not a quoted name of at most 24 bytes, or a `hide_ui` that is not a list of GUIDs;
  - a parent that is not a spawned binding before this one;
  - a position outside the bounds of a `World_Position`, a rotation that is not of length 1, or a scale of 0;
  - a track's kind that is unknown, a track without the binding that its kind needs, a binding that its kind does not take, or a binding ID that no binding has;
  - a property track without `component` and `field`, a `component` that is not a stable ID in decimal, a `field` that is not a quoted dotted name, or either one on a track of another kind;
  - a `space` that is not `absolute`, `relative` or `relative <id>`, a `relative <id>` that names no binding or the track's own, an `origin` that is not three numbers inside the bounds of a `World_Position` or that is not for `space = absolute`, or either one on a track that is not a transform track;
  - a cycle of transform tracks relative to other bindings, which each track in it reports at its `space` line, with the path, such as `relative bindings form a cycle: Fox -> Ship -> Fox`;
  - a `blend` that is not `absolute` or `additive`, or an additive section of a kind other than transform or property;
  - an `offset` that is not a whole number of ticks, a `speed` that is not a number above 0, a `loop` that is not `true` or `false`, a `root_motion` that is not `bake`, `apply` or `in_place`, an `offset` or a `loop` on a section that is not an animation or audio section, or a `speed` or a `root_motion` on one that is not an animation section;
  - a `gain` that is not a number from 0, or a `time_scale` that is not `follow` or `free`, or either one on a track that is not an audio track;
  - a `bus` that is not a whole number from 0 to 16, a distance that is not a number from 0, a `max_distance` not past the `min_distance`, a `plays_through_skip` that is not `true` or `false`, or any of them on a section that is not an audio section; a `pre_roll` or `post_roll` on an audio section; and an audio channel that is not `gain` or `pitch`, a gain key below 0, or a pitch key outside 0.1 to 4;
  - a `trigger` or a `range` that is not `trigger <id> <time> <name>` or `range <id> <start> <end> <name>`, a range that does not start before it ends, either one outside the length or before any track, or on a track that is not an event track; a `section` or a `when_finished` on an event track; an event track's binding that suspends `behaviours`;
  - a `value` that is not one of its kinds' forms, an `entity` value that names no binding, more than 4 values, or a `fire_on_seek` or `fire_when_skipped` that is not `true` or `false`;
  - a second animation track on one binding, at its `track` line, with the line of the first;
  - a second camera cut track, at its `track` line, with the line of the first;
  - a camera cut section without `camera`, or one that names no binding, with a setting that blends sections or a channel, that overlaps the section before it, that blends in or out where it meets another section, with a blend in longer than itself, or with `blend_on_skip` but no `blend_out`;
  - a camera cut setting or a constraint on a section of another kind, or a constraint on a binding that no camera cut section shows;
  - a constraint's target that names no binding or the camera itself, or an offset or a damping without its constraint;
  - eases longer than the section, a pre-roll or post-roll that is not a whole number of ticks, or a weight outside 0 to 1;
  - a section without the asset that its kind needs, or with one that its kind does not take;
  - a channel's name that is not a name or is taken, or a channel without keys;
  - a property track's channel that is not `value`, `x`, `y`, `z`, `r`, `g` or `b`, or a section that keys more than one set of them;
  - a transform track's channel that is not one of its nine;
  - a key marked `teleport` on a track that is not a transform track;
  - a key's time outside its section or not after the key before it, a value that is not finite or not exact as an `f32`, an unknown interpolation, slopes that are missing, not finite or not wanted, or weights that are not from 0 to 1;
  - a key of an asset that is not constant, a channel whose keys are not all assets or all numbers, or a key of an asset on a track that is not a property track;
  - a GUID that names no asset, or an asset of the wrong kind: a possessed scene that is not a scene, a spawned prefab that is not a prefab, a clip that is not an animation, a sound that is not a sound, a sub-sequence that is not a cutscene, or a hidden document that is not a UI document. A key's asset can be of any kind: nothing checks it against the field's kind yet;
  - a `trim` that is not one or two whole numbers of ticks, with the end after the start, a `scale` that is not a number above 0, a `bind` that is not `bind <id> = <id>`, a `bind` of a child's binding that the section binds already or to an ID that no binding has, a `bind` after the section's channels, an `offset`, `speed` or `root_motion` or a channel on a sub-sequence section, a sub-sequence section that starts before the one before it ends, or a `trim`, `scale` or `bind` on a section of another kind;
  - checked against the child's text, at the line that sets them: a trim outside the child's range, a `bind` of an ID that the child has no binding with, and a `bind` that gives a camera to an animated entity, or an animated entity to a camera. The cooker sees a binding's kind in its own cutscene: a camera where its camera cut track shows it, and an entity with an `Animator` where an animation track drives it. It does not look into prefabs and scenes;
  - a cycle of sub-sequences, which each cutscene in it reports at the line that names the next, with the path, such as `sub-sequence cycle: game/a.cutscene -> game/b.cutscene -> game/a.cutscene`;
  - sub-sequences that nest deeper than `CUTSCENE_MAX_DEPTH` (8), at the line of the first one on the deepest path, with the path;
  - a `skip_color` or a `color` that is not a quoted `#rrggbb` or `#rgb` without alpha, which includes an unquoted one, since the `#` starts a comment;
  - a `letterbox_aspect` that is not `camera` or `sections`, or on a track that is not a presentation track;
  - a presentation section without a `kind`, a `kind` that is not `fade`, `letterbox` or `subtitle`, a `color` on a section that is not a fade, a `speaker`, `text`, `key` or `audio` on a section that is not a subtitle, a subtitle without `text`, an `audio` that names no section of an audio track of the cutscene, and a presentation setting on a section of another track;
  - a presentation channel that its kind does not take, a channel on a subtitle, a fade's key outside 0 to 1, a letterbox's amount key outside 0 to 1, or its aspect key outside 1 to 4;
  - more than `MAX_CUTSCENE_BINDINGS` (1024) bindings, `MAX_CUTSCENE_TRACKS` (1024) tracks, `MAX_CUTSCENE_SECTIONS` (8192) sections, `MAX_CUTSCENE_CHANNELS` (65536) channels, `MAX_CUTSCENE_KEYS` (2^20) keys, `MAX_CUTSCENE_EVENTS` (8192) triggers and ranges or `MAX_CUTSCENE_GUIDS` (65536) keyed assets.
- **A cutscene with a problem** keeps its old blob, so the running game keeps the last good version.
- **Sub-sequences.** The cooker reads each sub-sequence's source, not its blob, so the order of the passes does not matter. A pass that cooks one cutscene checks every cutscene, because a cycle, a depth, a trim and a bind depend on the cutscenes that it reaches. A child's blob is a reference, not a copy: a cutscene that plays it loads it, and a cook of the child alone reaches every cutscene that plays it.
- **The cooker does not check** that a possessed entity is in its scene, because that needs the scene's prefabs expanded. The binding's policy says what to do when the entity is missing at run time ([Cinematics: A missing binding](../../cinematics/bindings.md#a-missing-binding)).
- **Dependencies.** The cooker adds each GUID that the cutscene names to its dependencies, the possessed scenes included. So a fix to one of these assets cooks the cutscene again.
- **The cache key** covers the cooker version (`cutscenes 15`), the layout, the source path, the source and the GUID.
- **Hot reload:** a cooked cutscene reaches the game as any blob does (see [Blobs and loading: Loading](../blobs-and-loading.md#loading)). A cutscene that plays evaluates the new blob at its current time, and the fields of the tracks that the new blob removed go back ([Cinematics: Hot reload](../../cinematics/evaluation.md#hot-reload)). So does a cutscene that plays a reloaded sub-sequence.

- **The editor** shows cutscenes among the animation in the content browser, with a clapperboard icon, and opens them in the [cutscene editor](../../editor/cutscene-editor.md). **New Cutscene**, in the content browser's menu and in the Gameplay tab's New Asset group, makes a cutscene of 10 s at 30 frames a second with an empty camera cut track, `CUTSCENE_TEMPLATE`, and opens it.
