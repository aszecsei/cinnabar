# Perceptions

Perceptions are `.perception` text files in the content roots. A perception names the tags that an agent's `Perceiver` notices, and the rows that fill the agent's blackboard keys from what it perceives.

`just perceptions` runs `cook perceptions --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`. The daemon cooks perceptions like any other kind (`tools/cook/perceptions.odin`).

A `Perceiver` names its perception by GUID. Several perceivers can share one. How agents perceive, and how the rows fill their keys, is in [AI: Perception](../../ai/perception.md#filling-the-blackboard).

```
perception 1
# A guard's senses.
notices Player, Noise_Maker
target = nearest Player
threat = nearest seen Enemy
target_position = position target
target_visible = visible target
target_since = since target
heard = heard noise
heard_position = loudest noise
```

## The text

- **The first line** is `perception 1`. A `#` starts a comment, except inside quotes.
- **`notices <Tag>, <Tag>...`** names the tags that the perceiver notices, each once, at most `MAX_PERCEPTION_NOTICES` (32). It comes at most once. Without it, every tag is noticed. A tag is a word, which the project's `perception.tags` gives ([AI: Perception: Tags](../../ai/perception.md#tags)).
- **Each other line is a row:** `<key> = <source>`. The key is a word, which no other row fills. A perception has at most `MAX_PERCEPTION_ROWS` (32) rows.

### Rows

| Source | The key's type | What it writes |
|---|---|---|
| `nearest <Tag>` | `entity` | The nearest remembered entity with the tag, those perceived now first, or none. `any` is every tag. |
| `nearest seen <Tag>` | `entity` | The same, among those seen now |
| `nearest heard <Tag>` | `entity` | The same, among those heard now |
| `position <row>` | `position` | The last position of the entity that a `nearest` row chose. Nothing when it chose none. |
| `visible <row>` | `bool` | Whether that entity is seen now |
| `since <row>` | `float` | The seconds since that entity was last perceived, or 0 |
| `heard noise [<Tag>]` | `bool` | Whether a noise with the tag, or any, was heard in this tick |
| `loudest noise [<Tag>]` | `position` | Where the loudest noise with the tag, or any, was heard in this tick. Nothing when there was none. |

`<row>` is the key of a `nearest` row before it.

The cooker does not read the agent's blackboard or the project's tags, which can change without a cook. The runtime checks each row's key against the agent's blackboard, and each tag against `perception.tags`, and warns about those that do not fit.

## The blob

A `Perception_Blob` (`lib/engine/asset/format/perception.odin`) holds:
- **The notices:** the tags' names.
- **The rows**, in order. Each has its key's name and its `animation_graph_hash`, which the runtime finds the key by, its source, its tag's name and hash, empty for any, and the index of the `nearest` row that it reads.
- **The source path.**

The view checks that every slice is inside the blob, and that each row's source is known and reads only a `nearest` row before it.

- **Problems** have their line. They include:
  - a first line that is not `perception 1`;
  - a second `notices`, a tag twice, or a name that is not a word;
  - a row without `=`, a key that another row fills, or two keys with the same hash;
  - an unknown source, or a source with the wrong words;
  - a `position`, `visible` or `since` whose row is not a `nearest` row before it;
  - too many rows or tags.

  A perception with a problem keeps its old blob, so the running game keeps the last good version.
- **The cache key** covers the cooker version, the layout, the source path, the source and the GUID.
- **The editor** opens a perception in the script editor. It is among the scripts in the content browser.
