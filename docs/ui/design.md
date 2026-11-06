# Design

How the UI works: from a document on an entity to the pixels of the UI layer and back to the scripts. Read the [overview](README.md#overview) first, and [Content: UI documents](../content/kinds/ui-documents.md#ui-documents) for the format.

**In this document:** [Documents](#documents) · [The cascade](#the-cascade) · [Layout](#layout) · [Text](#text) · [Drawing](#drawing) · [Input and focus](#input-and-focus) · [Scripts](#scripts) · [Hot reload](#hot-reload) · [The frame](#the-frame) · [The sample](#the-sample)

## Documents

`Ui_Document` (component ID 112, see [World: ECS](../world/ecs.md#component-registry)) puts a document on the screen while its entity is active:

| Field | Meaning |
|---|---|
| `document` | The UI document asset. |
| `order` | Documents of a higher order draw over those of a lower one, and take input first. |
| `visible` | Whether the document shows. A script turns a menu on and off with it. |

`ui.State` is in `Game_State`. It has a slot for each document that shows, at most `MAX_DOCUMENTS` (32). `ui.sync` matches the slots to the world's `Ui_Document`s each frame, loads each document's blob, and builds its nodes.

**Building** copies the blob, which the asset runtime frees when it swaps it, and makes a node for each element that is not in a template. Each attribute's value is parsed then, with `format.ui_parse_value`, once. Then the scripts' changes to the tree are replayed: each copy of a template that `Ui.add` made, and each element that `Ui.remove` took out. The focus stays on the element of the same id.

**A node** has its element, its links to its parent, children and next sibling, its id, its attributes and styles, and what each frame works out: its style, its size and rectangle, its clip, its text. Nodes are referred to by index, and an index is good until the document is built again, which bumps its generation.

## The cascade

Each frame, each node's style is worked out from, in order, with each one over the ones before it:

1. The element's defaults (`default_style`): a button is a row centered both ways that takes focus; a field takes focus, clips, does not wrap, and is `DEFAULT_FIELD_WIDTH` (200) wide; text is `DEFAULT_TEXT_SIZE` (18) and white.
2. What it inherits of its parent's style: `font`, `size`, `color`, `text_align`, `line_height` and `wrap`.
3. Its styles' attributes, in order: the style named for its element, then those that its `style` attribute names.
4. Its styles' variants for each state that it is in, in the order hover, focus, press, disabled, each over all of its styles in order.
5. Its own attributes.
6. What scripts set on its id, last.

An element's own attribute holds in every state, so an attribute that changes with the state belongs in a style.

**States.** An element is in **Hover** while the pointer is over it, in **Press** while the pointer or Enter, Space or A holds it down, and in **Focus** while it has the focus and the player last moved with keys or a gamepad. The pointer hides the focus's style, so a menu clicked with a mouse does not show a ring; a field shows it either way, as the player types into it. A disabled element, or one under a disabled element, is in **Disabled** and no other state, and takes no input.

## Layout

`ui.layout` lays out every document that shows each frame, after the scripts, so what they set shows in the same frame. It works in the UI layer's pixels, and the root is the whole layer: a stack, whose children are placed by their anchors.

1. **The cascade** (above), and which nodes show: a node that is not `visible`, or whose parent does not show, is out of the layout and draws nothing.
2. **Text** is shaped (see [Text](#text)), which gives each text's width on one line.
3. **Fit, along x**, after the children: the size that a node's content needs. A row's is its children's sizes and its gaps, added; a column's or a stack's is the largest child's. A child counts at its pixels if it has them, at 0 if it is a percent, and otherwise at its own fit. A text's content is its width, and an image's its texture's size. Padding is added, and `min_width` and `max_width` clamp it.
4. **Resolve, along x**, before the children. In a row, children of pixels, percents of the row's content and `fit` take their sizes, and what is left after the gaps is shared among the `fill`s by weight. A fill that its min or max stops takes that size, and the rest is shared again among the others, as CSS's flexible boxes do. Across a row, and in a stack, `fill` takes the content's size, and so does `fit` when the row's `cross` is `stretch` or the stack child's `anchor` is `fill`.
5. **Wrap:** each text breaks into lines at the width that it resolved to.
6. **Fit and resolve, along y,** the same way, with the lines. An image's fit keeps its texture's shape at the width that it resolved to.
7. **Place:** a row or column puts its children one after the other, from where `align` says (`start`, `center`, `end`, or `space_between`, which spreads what is left between them), and across by `cross`. A stack puts each child by its `anchor`. `offset` moves a child from there. Each edge is then rounded to a whole pixel on its own, so neighbors share edges and leave no gaps.
8. **Clip:** a node's drawing is cut to its parent's clip, and a node with `clip`, or a field, cuts its children's to its rectangle as well.

There is no shrinking: children that need more than their parent has overflow it, and `clip` cuts them off.

### Scale

Every length in a document is in pixels at a UI scale of 1: sizes, padding, gaps, radii, borders, offsets, text sizes and nine-slice margins. The scale is `max(height / REFERENCE_HEIGHT, MIN_SCALE) × ui.scale`, from the UI layer's height (`REFERENCE_HEIGHT` is 1080 and `MIN_SCALE` 0.5) and the project's `ui.scale` (1), which `set_scale_factor` takes. So a document laid out for 1080p fills the same part of the screen at 720p and at 4K, with its text drawn at that size from its distance field, sharp either way.

## Text

**Fonts.** A font's blob holds its file, as shaping needs its tables (see [Fonts](../content/kinds/fonts.md#the-blob)). A font slot, of `MAX_FONTS` (16), holds kb_text_shape's font, placed from the file with `LoadFont` and `PlaceBlob` into memory of the slot's. It is placed again when the blob changes, and dropped by a code reload, as kb_text_shape is code in the game DLL. A font or document that does not load is tried again every `RETRY_INTERVAL` (1 s).

**Shaping.** Each frame, each text is shaped again, with kb_text_shape's context placed in `SHAPER_MEMORY` (1 MiB) of frame memory, so no context outlives a frame. kb_text_shape applies the font's GSUB and GPOS features, so text is kerned and takes its ligatures. A glyph keeps the byte of the text that its cluster starts at, which carets use. A text's bindings are filled in first: `{name}` is the value that `Ui.bind` gave, or nothing, and `{{` and `}}` are a brace each.

**Lines.** A line may break before the first character after spaces, a tab or a hyphen, and breaks at each line break. A line that would be wider than its box breaks at its last chance to, and the spaces at its end hang outside its width. Without `wrap`, a text breaks only at line breaks. A line is `(ascender − descender + line gap) × size × line_height` high, from the font's metrics, and its baseline is on a whole pixel. `text_align` places each line in the box.

**Sharpness.** A glyph's quad is its cell in the atlas, placed by its plane, at the text's size in pixels. The shader takes the median of the cell's three channels, which is 0.5 on the outline, and turns it into coverage by the field's range in pixels on the screen: `range × size / em_size`, at least 1. With the default `em_size` of 48 and `range` of 8, text is sharp from 6 pixels to an em up, at every scale, and its corners stay sharp as it grows, as the median keeps them.

## Drawing

`ui.add_passes`, which the game calls from its `ui` hook (see [Rendering: Layers and output](../rendering/layers-and-output.md#ui)), lays the documents out at the frame's output size and draws them all in one draw call.

**The batch.** Each `Instance` (96 bytes) is a rectangle in the layer's pixels, its clip, its corners' radii, its UVs, its colors, its kind and its texture. The documents draw from the lowest order up, and each tree draws each node before its children: its box, its image, its text, and in a field its selection, its composition and its caret. A box draws if it has a fill or a border. An image draws once its texture is resident, as one instance or, with `slice`, nine, whose corners keep their size. A glyph draws once its font's atlas is resident. Instances of no size, or outside their clip, are left out, and a frame has at most `MAX_UI_INSTANCES` (16384). The instances go into the frame's upload ring, and the pass draws six vertices for each.

**The shader** (`ui.hlsl`) pulls each instance from the upload buffer. Its vertex shader grows a rectangle by a pixel for its antialiased edge and cuts it to its clip, with the UVs of the rectangle as it was, so a cut never stretches an image. Its pixel shader discards what is outside the clip, and draws:

| Kind | How |
|---|---|
| Rectangle | A rounded box's signed distance, with each corner's radius, gives the coverage of its edge, and a band of `border` inside it is the border. The fill is a color, or a gradient from one color to the other along its angle, blended in sRGB-encoded values. The border and the fill blend premultiplied, so a clear fill shows nothing of the border through it. |
| Image | The same box, with the texture in place of the fill, times `tint`. A color texture samples as linear light, so it is encoded again for the layer. |
| Glyph | The median of the atlas's red, green and blue, with the range in screen pixels, as in [Text](#text). |

**The view.** The pass draws an instance's pixel `p` at `p * view_scale + view_offset` in its target, which the game's UI takes as a scale of 1. The UI editor's preview lays a document out on a screen of its own size and draws it into a smaller target, zoomed and panned (see [UI editor](../editor/ui-editor.md#the-games-side)). The pixel shader works out the clip and the distances in the instance's pixels and scales them to the target's, so an edge is one target pixel wide at any zoom.

Colors are as a designer picks them, sRGB-encoded with straight alpha, and each node's `opacity` times its ancestors' multiplies their alpha. The output is premultiplied, which the `Premultiplied` blend takes.

## Input and focus

`ui.handle_input` reads a frame's input against the last frame's layout, which is what the player saw, before the scripts run. Its events go out with `ui.flush_events`, which sends each to its document's entity with `script.send`, so the script phase that follows delivers them.

**Scope.** The documents that show take input, the highest order first. A document whose root is `modal` takes all of it while it shows, and none goes to those under it. When one comes to show, the focus goes into it, to its root's `focus` element or its first that takes focus, and the focus that was before is kept on a stack of `MAX_FOCUS_STACK` (8); when it goes, the focus goes back.

**The pointer.** The element under the pointer that takes it, the topmost, is hovered: one that clicks, takes focus, or is a button or a field, and is not disabled. A press takes the focus if the element takes focus, and a release over the element that the press was on clicks it. A press anywhere else stops a field's editing.

**Navigation.** The arrows, the d-pad and the left stick move the focus; the stick points a way past `STICK_ENGAGE` (0.5) on its larger axis, and lets go under `STICK_RELEASE` (0.35). A held direction moves once, then again after `NAV_DELAY` (0.4 s), and then every `NAV_REPEAT` (0.1 s), in real time. The focus goes to the element that the focused one's `nav_up`, `nav_down`, `nav_left` or `nav_right` names, or else to the nearest that takes focus beyond its edge that way, by the gap that way plus twice the gap across. Tab and Shift+Tab follow the tree. With nothing focused, the first move focuses the document's first element. Enter, Space and A click the focused element; B and Escape send the `cancel` event of the topmost document that has one, with an empty id.

**Fields.** A click on a field, or activating it, starts editing it. Committed text, with what an IME committed, goes in at the caret, over the selection, up to `max_length` characters. Backspace, Delete, Left and Right repeat after `NAV_DELAY` every `KEY_REPEAT` (0.033 s); Shift selects and Ctrl steps by words; Home and End go to the ends. The value is the field's `text`, set as a script's `Ui.set_text` would, so it outlives a rebuild. Each edit sends the field's `changed` event with its id and its text, and Enter its `submit` event, and stops editing. Escape, B and Tab stop editing. What an IME is composing draws at the caret, underlined, and is not part of the value until it commits. The caret goes between clusters, so in a ligature it is at its start or its end, and the field scrolls to keep it in view. While a field is being edited, or a modal document shows, `Ui.wants_input()` is true, which a game's own controls check.

## Scripts

The `Ui` library reaches a document by its entity and its elements by their ids:

| Function | What it does |
|---|---|
| `Ui.set(entity, id, attribute, value)` | Sets an attribute from text, as a document gives it. A value that the attribute does not take raises the parser's message. |
| `Ui.set_text(entity, id, text)` | Sets a text's, a field's or a button's text attribute. |
| `Ui.set_visible(entity, id, visible)` | Shows or hides an element. |
| `Ui.focus(entity, id?)` | Moves the focus to an element, or takes it away. |
| `Ui.get_text(entity, id)` | A field's value, or a text's or a button's text with its bindings filled in, or nil. |
| `Ui.bind(entity, name, value)` | Sets the value of `{name}` in every text of the document. A number or a boolean is written as Luau would. |
| `Ui.add(entity, parent, template)` | Copies a template under an element, and gives the copy's id, `<template>#<n>`. An element in the copy is `<template>#<n>.<id>`. |
| `Ui.remove(entity, id)` | Takes an element out. A copy goes, with what was set on it and in it. |
| `Ui.wants_input()` | Whether the UI takes the player's input: a modal document shows, or a field is being edited. |

A behaviour on the document's entity gets its events: `click="resume"` calls `on_resume(id)`, and a field's `changed` and `submit` call theirs with the id and the text. What a script sets on an id that no element has now is kept, with a warning, and applies when one comes.

```lua
local Pause = Behaviour.define("Pause")

function Pause:update(dt)
	Ui.bind(self.entity, "fps", math.floor(1 / dt))
end

function Pause:on_resume(id)
	self.entity:get(UiDocument).visible = false
end
```

## Hot reload

- **A new version of a document** builds it again, with the scripts' attributes, copies and removals, its bindings, and the focus on the same id. A copy whose template or parent is gone is left out.
- **A new version of a font** places its shaper again. A new version of the shader recreates the pipeline (`ui.sync_pipelines`).
- **A code reload** keeps the documents, their nodes and what scripts set, which are all in host memory, and drops the fonts' shapers, which the next text places again (`ui.on_reload`). The `Ui` library is defined again with the game's other bindings.
- **A soft restart** starts the UI from nothing.

## The frame

A game calls the UI at these points of its frame (the sample's are in `samples/mygame/game.odin`):

| When | Call |
|---|---|
| `init` | `ui.init(&s.ui, platform, &s.assets, &s.renderer.residency)`, and `ui.register_components` with the others |
| Its `Register_Proc` | `ui.register_scripts(r, &s.ui)` |
| Each frame, before the script phase | `ui.sync`, then `ui.handle_input` with the frame's input and the real time, then `ui.flush_events` |
| With its pipelines | `ui.sync_pipelines` |
| Its `ui` hook | `ui.add_passes(&s.ui, f)` |
| `on_reload` | `ui.on_reload`, and `ui.sync_pipelines(force = true)` |
| `shutdown` | `ui.destroy` |

## The sample

`samples/mygame`'s main scene has two documents, on the entities HUD and Pause Menu, in Fira Sans (`content/fonts`, under the SIL Open Font License beside it):

- **The HUD** (`content/ui/hud.ui`, `hud.luau`) is a panel in the top left with an accent stripe, which shows the frame rate that its behaviour binds, smoothed over real time.
- **The pause menu** (`content/ui/pause.ui`, `pause_menu.luau`) is modal, with order 10, and hidden until Escape or a gamepad's Start shows it. It pauses the world through the sample's `Game.set_paused`, which makes the world take no time while the script phase and the UI run on. Resume, B or Escape hides it. Quality takes the next render preset and saves it, as F9 does. The name field greets whoever types into it, through a binding.
- `fly_camera.luau` and `hello.luau` leave the gamepad and Space and Tab alone while `Ui.wants_input()`.
- `ui.scale` in the project's settings multiplies the UI scale.
