# UI documents

UI documents are `.ui` text files in the content roots: a tree of boxes, text and images with named styles, which a `Ui_Document` puts on the screen. `just ui` runs `cook ui --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`, and the daemon cooks them like any other kind (`tools/cook/ui_documents.odin`). The editor's New UI Document makes one from a template, and opens one in the script editor.

**In this document:** [The format](#the-format) · [Elements](#elements) · [Attributes](#attributes) · [Values](#values) · [Styles](#styles) · [Templates](#templates) · [The cook](#the-cook) · [The blob](#the-blob)

## The format

```xml
ui 1
<!-- A pause menu. -->
<ui modal="true" cancel="resume" focus="resume" font=$5f1c0a9e00b14cf8a1d6e0c2a4b8f310 size="20" color="#fff">
	<style name="button" fill="#1c2030e0" radius="6" padding="10 16" border="1 #ffffff30"/>
	<style name="button:focus" fill="#e2423a" border="2 #fff"/>

	<column id="pause" anchor="center" gap="8" padding="24" fill="#0b0d14f0" radius="12">
		<text size="32">Paused</text>
		<button id="resume" click="resume">Resume</button>
		<button id="quit" click="quit">Quit</button>
	</column>
</ui>
```

The first line that is not blank is `ui 1`, the format's version (`UI_TEXT_VERSION`). Then comes one `<ui>` element, the root, which every other element is in.

The rest is XML's elements, attributes, comments (`<!-- -->`) and entities (`&lt;`, `&gt;`, `&amp;`, `&quot;`, `&apos;`, and `&#…;` and `&#x…;` by code point), without a prolog, namespaces, CDATA or a DTD. Two things are looser than XML:

- **An attribute's value may go without quotes** when it has no space and no `>`, as `font=$<guid>` does. A quoted value takes `"` or `'`.
- **Text collapses:** each run of whitespace in an element's text is one space, and the text's ends are trimmed.

The parser (`format.ui_parse`, `lib/engine/asset/format/ui_text.odin`) gives every problem with its line and column, and goes on after one, so the editor shows them all at once. A warning does not stop the cook.

## Elements

| Element | What it is |
|---|---|
| `ui` | The root: a stack as large as the UI, which its children are anchored in. It alone takes `cancel`, `focus` and `modal`. |
| `style` | A named set of attributes (see [Styles](#styles)). Only a child of `<ui>`, with no children of its own. |
| `box` | A box whose `direction` lays out its children: `column` unless it says otherwise. |
| `row`, `column` | A box that lays out its children side by side, or one under the other. |
| `stack` | A box whose children are each in all of it, placed by their `anchor`. |
| `text` | Text: its own text, or its `text` attribute. It holds no elements. |
| `image` | A box whose `image` is the point of it. It holds no elements. |
| `button` | A row that takes focus and clicks. Text in it becomes a `<text>` of its own, its only child; a button holds text or elements, not both. |
| `field` | One line of text that the player edits. Its text, or its `text` attribute, is its first value. It holds no elements. |
| `template` | An element that scripts copy into the document, which is not in it until they do (see [Templates](#templates)). Only a child of `<ui>`. |

Any box shows a `fill`, a `border` and an `image`; `image` and `text` are only the boxes that are mostly that.

## Attributes

Besides these, an element takes `id`, which scripts and other attributes name it by, and `style`, the styles that it takes (see [Styles](#styles)). An id is lowercase letters, digits, `_` and `-`, and is the document's only one of its name. A style takes `name` instead of either.

An attribute on an element that it means nothing on, such as `placeholder` on a box, is a warning. One that is not an attribute, or is given twice, is an error.

**Layout.**

| Attribute | Takes | On | Meaning |
|---|---|---|---|
| `width`, `height` | length | boxes | The box's size. |
| `min_width`, `max_width`, `min_height`, `max_height` | length | boxes | Limits on the box's size. |
| `padding` | edges | all | Room between the box's edges and its content. |
| `gap` | number | containers | Room between a row's or column's children. |
| `direction` | `column`, `row`, `stack` | `box`, `button` | How a box lays out its children. |
| `align` | `start`, `center`, `end`, `space_between` | containers | Where a row or column puts its children along its direction. |
| `cross` | `start`, `center`, `end`, `stretch` | containers | Where a row or column puts its children across its direction; `stretch` fills it. |
| `anchor` | `top_left`, `top`, `top_right`, `left`, `center`, `right`, `bottom_left`, `bottom`, `bottom_right`, `fill` | boxes | Where the box is in a stack. In a row or column it is a warning, as it places nothing there. |
| `offset` | offset | boxes | Pixels that move the box from where its anchor puts it. |
| `visible` | boolean | boxes | Whether the box and what is in it show, and take room. |
| `clip` | boolean | containers | Whether the box cuts off what is in it at its edges. |
| `overflow` | `visible`, `scroll` | containers | Whether a row or column lets out what does not fit in it, or scrolls it along its direction (see [UI: Scrolling](../../ui/design.md#scrolling)). On a stack it does nothing. |
| `scroll_bar` | boolean | containers | Whether a box that scrolls shows its bar (see [Scroll bars](#scroll-bars)). It does unless this is `false`. |

The containers are `box`, `row`, `column`, `stack` and `button`. The boxes are those, `text`, `image` and `field`.

**Paint.**

| Attribute | Takes | Meaning |
|---|---|---|
| `fill` | paint | The box's color, or a gradient. |
| `radius` | corners | The corners' radii. |
| `border` | border | A line inside the box's edges, of a width and a color. |
| `opacity` | number, 0 to 1 | How much the box and what is in it show. |
| `image` | a texture | An image that fills the box. |
| `tint` | color | A color that the image is multiplied by. |
| `slice` | edges | The image's margins in its texels, which make it a nine-slice: its corners keep their size and its edges and middle stretch. |

**Text,** which every element under one takes, unless it gives its own.

| Attribute | Takes | Meaning |
|---|---|---|
| `font` | a font | The font (see [Fonts](fonts.md#fonts)). Text with no font draws nothing. |
| `size` | number, 1 to 1000 | The font's size: pixels to an em at a UI scale of 1. |
| `color` | color | The text's color. |
| `text_align` | `start`, `center`, `end` | Where each line is in the box. |
| `line_height` | number, 0.5 to 4 | The lines' spacing, as a multiple of the font's. |
| `wrap` | boolean | Whether text breaks into lines at the box's width. |

**Content and interaction.**

| Attribute | Takes | On | Meaning |
|---|---|---|---|
| `text` | text | `text`, `button`, `field` | The element's text, as its own text gives it. |
| `placeholder` | text | `field` | What an empty field shows. |
| `max_length` | whole number | `field` | The most characters that a field takes. |
| `focusable` | boolean | boxes | Whether the box takes focus. A button and a field do. |
| `disabled` | boolean | boxes | Whether the box ignores input, and its styles' `disabled` variants apply. |
| `click` | event | boxes | The script event that a click sends. |
| `changed`, `submit` | event | `field` | The events that an edit and Enter send. |
| `nav_up`, `nav_down`, `nav_left`, `nav_right` | id | boxes | Where focus goes from the box in a direction, in place of the nearest box there. |
| `cancel` | event | `ui` | The event that B or Escape sends. |
| `focus` | id | `ui` | What takes focus first. It is a box that takes focus. |
| `modal` | boolean | `ui` | Whether the document takes all input while it shows. |

## Values

| Kind | Text | Examples |
|---|---|---|
| number | A decimal number, in the attribute's range. | `12`, `0.5` |
| whole number | A number from 0 with no fraction. | `16` |
| boolean | `true` or `false`. | |
| length | Pixels from 0 at a UI scale of 1; a percent of the parent's size; `fit`, the content's size; or `fill`, a share of what is left in the parent, by an optional weight above 0. | `120`, `50%`, `fit`, `fill`, `fill 2` |
| edges | One to four numbers from 0, as CSS takes them: all four; top and bottom, then the sides; the top, the sides and the bottom; or top, right, bottom and left. | `8`, `10 16`, `1 2 3 4` |
| corners | Like edges, in the order top left, top right, bottom right and bottom left. | `6`, `12 12 4 4` |
| offset | One or two numbers, x and y; one is both. | `-4 2` |
| color | `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`, as a designer picks it, sRGB-encoded with straight alpha; or `none`. | `#fff`, `#1c2030e0` |
| paint | A color, or `linear(<degrees>, <color>, <color>)`: a gradient from the first color to the second, at 0 degrees left to right and at 90 top to bottom. | `linear(90, #2a3048, #1c2030)` |
| border | A width from 0 and a color, or `none`. | `1 #ffffff30` |
| font, texture | `$` and the asset's 32 hex digits. | `$5f1c0a9e00b14cf8a1d6e0c2a4b8f310` |
| event | A name of lowercase letters, digits and `_` that does not start with a digit: a behaviour's handler of it is `on_<name>`. | `resume` |
| text | Any text. `{name}` is a binding, whose value a script sets, and `{{` and `}}` are a brace each. A `{` that no `}` closes, or a binding that is not a name, is an error. | `Score: {score}` |

`format.ui_parse_value` parses each, for the cooker and for a script that sets an attribute, so both take the same text.

## Styles

```xml
<style name="button" fill="#1c2030e0" radius="6"/>
<style name="button:focus" fill="#e2423a"/>
<style name="danger" fill="#802020"/>
<button style="danger" click="quit">Quit</button>
```

A style is a set of attributes with a name. An element takes its styles in order:

1. The style named for its element, such as `button`, if there is one. Every element of that kind takes it.
2. The styles that its `style` attribute names, separated by spaces.

A later style's attribute replaces an earlier one's, and the element's own attributes replace them all. A name is lowercase letters, digits, `_` and `-`, and is the document's only style of its name. A style that does not exist is an error.

**A variant** is a style named for a base style and a state, `<base>:hover`, `:focus`, `:press` or `:disabled`, which applies while the element is in that state, after the base styles. A variant is not named in a `style` attribute: it applies with its base. One with no base is a warning, as nothing takes it. Since an element's own attributes win, an attribute that changes with the state belongs in a style, not on the element.

### Scroll bars

```xml
<style name="scroll_track" fill="#ffffff10" width="6" padding="2" radius="3"/>
<style name="scroll_thumb" fill="#ffffff50" radius="3"/>
<style name="scroll_thumb:hover" fill="#ffffff90"/>
<column id="saves" height="300" padding="0 12 0 0" overflow="scroll"/>
```

A box that scrolls draws a bar over its content, a track with a thumb in it (see [UI: Scrolling](../../ui/design.md#scrolling)). Every bar in a document takes the document's style named `scroll_track` for its track and `scroll_thumb` for its thumb, as an element takes the style named for its element. A bar uses only these attributes of them:

| Attribute | Track | Thumb |
|---|---|---|
| `fill`, `border`, `radius`, `opacity` | Its paint. | Its paint. |
| `width` | Its thickness in pixels. | |
| `padding` | How far it is in from the box's edges. | How far it is in from the track's edges. |

Without these styles, the track is clear, 6 pixels thick and 2 in from the box's edges, and the thumb is `#ffffff60`. Both have a radius of 3. Their variants apply: `:hover` while the pointer is over the box, `scroll_thumb:press` while the thumb is dragged, and `:disabled` while the box is disabled. The bar takes no room, so give the box padding on the bar's side to keep its content out from under it.

## Templates

```xml
<template id="slot">
	<row gap="8" focusable="true" click="slot_chosen">
		<text id="label">Empty</text>
	</row>
</template>
```

A template is an element that the document does not show: a script copies it into the document, under an element that it names, as many times as it likes. It is a child of `<ui>`, it has an id, it holds one element, and it takes no other attributes. Its ids are its own, apart from the document's, as each copy's are; `nav_*` in it names ids in it.

## The cook

The cooker parses the document with `format.ui_parse`, and reports each of its problems at its line and column. Then it checks the assets that attributes name: a `font` that is not a font, or an `image` that is not a texture, is an error, and one that is not in the content roots is a warning, as it may come later. A document's fonts and images are its dependencies.

**The cache key** covers the cooker version, the source path, the layout, the source and the GUID. A document with errors keeps its old blob, so the running game keeps the last good version.

**Limits:** a document has at most `MAX_UI_NODES` (4096) elements, which nest at most `MAX_UI_DEPTH` (64) deep.

**The tests' documents** are in `lib/engine/asset/format/testdata/ui`, which the editor's tests read too (see [UI editor](../../editor/ui-editor.md#the-file)): `<!-- problem -->` at the end of each line that reports an error, `<!-- warning -->` on each that reports a warning, and in a document without errors, `<!-- nodes: ui column text ... -->`, its nodes' elements in order.

## The blob

`Ui_Blob` holds four arrays and the source path:

- **Nodes,** in the order of a walk that visits each element before its children, the root first. Each is its element, whether it is in a template, its parent's index, the index past its subtree, its line, its id, its attributes and its styles.
- **Styles,** each its name, its attributes and its variant for each state.
- **Attributes** (`Ui_Prop`), each its attribute and its value's text.
- **Style refs:** the styles that each node takes, in order.

A value stays text: the runtime parses it with `format.ui_parse_value` when it builds the document, as it does a script's. A button's text is a `text` node of its own after it.
