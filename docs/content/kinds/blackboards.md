# Blackboards

Blackboards are `.blackboard` text files in the content roots. A blackboard declares the typed keys that an agent's decision reads and that its actions and scripts write. Each key has a slot and an offset in the agent's values, which the cooker gives, so a lookup is an index.

`just blackboards` runs `cook blackboards --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`. The daemon cooks blackboards like any other kind (`tools/cook/blackboards.odin`).

An `Agent` names its blackboard, and so does its decision ([Decisions](decisions.md#decisions)). Several decisions can read the same blackboard. How agents use their values is in [AI: Agents](../../ai/agents.md#blackboards).

```
blackboard 1
# A guard's knowledge.
float health = 1
int ammo = 30
bool has_target
enum mood (calm, alert, angry) = calm
entity target
position last_seen = [0, 0, 0]
vector heading = [0, 0, 1]
```

## The text

- **The first line** is `blackboard 1`. A `#` starts a comment, except inside quotes.
- **Each line after it is a key:** `<type> <name> [= <default>]`. An enum is `enum <name> (<value>, <value>...) [= <default>]`. A name is a word, which no other key has.
- **A key's slot** is its line's order among the keys. A blackboard has at most `MAX_BLACKBOARD_KEYS` (256) keys, and its values are at most `MAX_BLACKBOARD_SIZE` (4096) bytes.

| Type | Holds | Default | Without a default |
|---|---|---|---|
| `float` | An `f32` | A number | 0 |
| `int` | An `i32` | A whole number | 0 |
| `bool` | A `u8` of 1 or 0 | `true` or `false` | `false` |
| `enum` | A `u32`: the index of one of its names | One of its names | Its first name |
| `entity` | An `ecs.Entity` | `none` only: a script or an action sets it | none |
| `position` | A `World_Position` | `[x, y, z]`, in meters | The origin |
| `vector` | A `[3]f32` | `[x, y, z]` | Zero |

Blackboard values set per entity in a scene are not built. A script sets them in `awake` ([AI: Agents: Scripts](../../ai/agents.md#scripts)).

## The blob

A `Blackboard_Blob` (`lib/engine/asset/format/blackboard.odin`) holds:
- **Keys**, in slot order. Each has its name, `animation_graph_hash` of the name (FNV-1a, 32 bits), which scripts and native code find it by, its type, its offset, and an enum's range of names.
- **Enum names.**
- **The defaults:** the bytes that an agent's values start with, `values_size` of them, a multiple of 8. Each key is at its type's alignment, after the one before it (`format.blackboard_offsets`).

The view checks that each key lies inside the values at its alignment, and that each enum's names are in the blob.

- **Problems** have their line. They include:
  - an unknown type, or a `string` key;
  - a name that another key has, or two names with the same hash;
  - a default that does not fit its type;
  - an enum without names, with a name twice, or with a default that is not one of its names;
  - too many keys, or values too large.

  A blackboard with a problem keeps its old blob, so the running game keeps the last good version.
- **The cache key** covers the cooker version, the layout, the source path, the source and the GUID. A decision keeps its blackboard's key ([Decisions: The cook](decisions.md#the-cook)).
- **The editor** opens a blackboard in the script editor. It is among the scripts in the content browser.
