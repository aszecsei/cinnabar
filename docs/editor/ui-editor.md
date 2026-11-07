# UI editor

The UI editor edits a UI document (see [Content: UI documents](../content/kinds/ui-documents.md#ui-documents)) and shows it as the game draws it (see [UI: Design](../ui/design.md#design)). Each open one is a document beside the viewport, `UiEditorDocument`, over a `UiEditor` in the shell, which holds its state, so docking can rebuild the view, and tests drive the editor without a window.

**In this document:** [The file](#the-file) · [The canvas](#the-canvas) · [The tree](#the-tree) · [Properties](#properties) · [Styles](#styles) · [Bindings](#bindings) · [The game's side](#the-games-side)

## The file

`UiFile` reads a document's text as `lib/engine/asset/format/ui_text.odin` does, and keeps where each element, attribute and text is in it. It does not write the text again from a model: an edit changes a span of the text and reads it again.

- **Round trip:** a file reads and writes back as it was, with its comments, its blank lines, its quotes and each line's ending. Opening a file does not make it dirty.
- **Edits change only what they touch.** A new value goes between the attribute's quotes, and one without quotes keeps them off while it can. A new attribute goes at the end of the start tag, on the line of its last attribute, so an attribute on a second line of a tag changes that line only. A cleared attribute takes its line with it when it is alone on it. A new element goes on a line of its own, at its siblings' indent, or its parent's and one more, in the file's tab or spaces and line ending; a parent that closes itself opens for it. Removing an element takes its lines, a comment of its own on the lines right above it, and one of two blank lines that then meet. Moving one moves its lines and its comment, and shifts their indent by the change of depth. A copy gets ids of its own, `resume_2`. A new style goes after the root's last one.
- **Nodes are the cooker's.** `UiFile.Nodes` are the elements that the cooker makes nodes of, in its order: each before its children, the templates' too, and a button's text as a text node after the button. A node's index is therefore its index in the blob, which the game reports it by. An element that the cooker refuses, and what is in it, is no node.
- **It agrees with the cooker.** `lib/engine/asset/format/testdata/ui` has files that the cooker's tests and the editor's both read: a `<!-- problem -->` or `<!-- warning -->` on each line that the cooker reports, and in a file without errors a `<!-- nodes: ui column text ... -->` comment that lists its nodes' elements in order. The editor's tests find each marked line's element at its column.
- **It reads only the structure.** What a value means, and whether it is right, is the cooker's to say, so a document with problems still opens, with its problems on its elements. Only a file whose first line that is not blank is not `ui 1` is refused, and that opens in the script editor, with the reason in the console.
- **Undo:** each editor has its own undo stack of the text before and after each edit (`UiDocument`, a `GraphDocument`), and a color picker's session is one entry. Undo, Redo and Save act on the UI editor whose document is active. Save is disabled during a color picker's session or a drag, because its steps can still be put back (see [Document model](document-and-scenes.md#document-model)). A document is dirty when its position in its history is not the one that its file has, and its tab marks it with a dot.
- **Saving** writes the text through a temporary file, and the cook daemon then cooks it. A save that would replace what another program wrote asks first. Closing an editor with unsaved changes asks to save them. An open document follows its file when the content browser moves or renames it.
- **Opening:** a double click on a `.ui` file opens it here, and so does **New UI Document**, once the daemon has made the file. The toolbar opens the text in the script editor.

## The canvas

- **Layout:** a toolbar of the screen, its scale, the view and the background; the tree over the styles on the left; the canvas; and the properties over the bindings on the right.
- **The screen** is 1280×720, 1920×1080, 2560×1440, 3840×2160, or a custom size. The UI scale is the game's, `max(height / 1080, 0.5)` times a factor, which starts as the project's `ui.scale` (the user's file over the project's) and which the toolbar changes, from 0.25 to 4. The canvas lays the document out on that screen as a game of that size would, whatever the size of the pane.
- **The view.** The screen fits the canvas until the wheel zooms it, about the pointer, or the middle or right button pans it. **100%** shows a pixel of the screen for each pixel of the canvas, as the game draws it; **Fit** or F fits it again. The game draws the screen through the view, so text and edges are sharp at every zoom, and the preview stays within `gpu.MAX_PREVIEW_SIZE`.
- **Picking:** a click picks the topmost element that shows at the point: the last in the order that the game draws them whose rectangle, cut to its clip, holds the point (`UiCanvasGeometry.Pick`). The root is not picked. The selected element's rectangle is outlined, the band of its padding filled and the rectangle inside it dashed, and its clip dashed when it is not the screen's. The element under the pointer is outlined lightly, and an element with a problem has a dashed red frame.
- **The layout is the cooked text's.** The outlines come from where the game last drew the elements. That layout names the key of the blob that it drew, which for an unsaved text is the text's FNV-1a hash, so the editor outlines and picks only while the layout is of the text as it is; between an edit and the next drawing, there are no outlines.
- **Unsaved text:** a moment after each change, and when it opens, the editor sends the text to the cook daemon in `Cook_Preview`. Once one cooks, the editor opens the preview again with `unsaved`, so the game draws the preview area's blob. A text with errors leaves the last good one drawn. The answer's problems go on the element or the style at their line and column, and the others on the document. An answer about a text that has changed since is dropped.
- **Templates** do not draw, as scripts copy them with `Ui.add`; the canvas says so while one is selected.

## The tree

The document's elements, each under its parent, then its templates under their own heading. A row names the element's kind and id, such as `<button#resume>`, with its text, and a mark for its problems.

- A click selects an element, as a click on the canvas does.
- **Dragging** a row moves its element: before the row's element near its top edge, after it near its bottom edge, and into it, last, in its middle if it holds elements. An element cannot go into itself, into a text, an image, a field or a button with text, and a template stays under the root.
- **Add** puts an element of the palette (box, row, column, stack, text, image, button, field) into the selected element if it holds elements, or after it, and selects it. **Template** adds a template with a box in it. **Duplicate** (Ctrl+D) copies the selected element after itself, and **Delete** (Delete) takes it out and selects its parent. Deleting a button's text takes the text out of the button.

## Properties

The selected element's id, its styles, the states to preview, and its attributes by groups: layout, paint, text and interaction. The attributes are those that the cook daemon's `Welcome` lists (`ui_attributes`, from `format.UI_ATTRS`) for the element, so the editor knows none of its own.

- **What it sets itself** shows in its editor, with a × that clears it. **What it takes** from a style or a variant, or inherits from an ancestor, shows dim under it, with where it comes from: `from button:hover`, `from <ui>`. Setting it sets the element's own. The cascade is the runtime's, as far as the text says it (`UiCascade`): what the element inherits of its parent, its styles in order, their variants for the states that it shows, and its own attributes. The elements' defaults are the runtime's, so an attribute that nothing sets shows nothing.
- **Editors by kind:** a length takes pixels, a percent, `fit` or `fill` with a weight, and its menu offers them; a color or a paint has a swatch that opens a picker of hue, saturation, value and alpha over the encoded color, and its text, which takes `linear(...)`; a font or an image is a choice of the fonts or the textures in the content; an enum or a boolean is a choice; the rest are text, with a hint of what they take.
- **The id** is refused, with a warning in the console, if it is not lowercase letters, digits, `_` and `-`, or another element has it. **The styles** are a list of names; the + adds one.
- Below them, the element's problems, at their lines and columns.

## Styles

The document's styles, each with its variants under it, and how many elements take it: those of its kind, and those that name it. A click selects a style, and the properties show its own attributes and the elements that take it.

- A name and Enter add a style, or a variant such as `button:disabled`. **Variant** adds a variant of the selected style for a state that it has none for, and **Delete** takes the selected style out. Renaming a style renames its variants and the style lists that name it.
- **The state preview:** the properties' toggles show the selected element in hover, focus, press or disabled on the canvas, in place of the player's. Disabled is a state alone, as it is in play. The file does not keep them.

## Bindings

Each `{name}` that the document's text binds, in its `text` and `placeholder` attributes and its elements' text, with a value to preview it with. The canvas fills them in as `Ui.bind` would. The file does not keep them.

## The game's side

- **The preview.** A UI editor has one of the game's previews, at most four at once with the material, effect and animation graph previews (see [Rendering: Material previews](../rendering/materials.md#material-previews)). An `Open_Preview` of a UI document's GUID shows it; the blob's kind says that it is one. The game keeps the document in a slot of a `ui.State` of the editor package's own, built from the blob's bytes with `ui.open_document`, so no world syncs it, no input reaches it, and the game's UI is not touched. A new blob builds it again with `ui.set_document_data`, keeping its bindings. As no input reaches it, a scroll box shows its content from its start.
- **Drawing.** `render.Preview_Desc.ui` is a hook that the preview's frame calls: the renderer clears the background, dark or light, gives the hook a UI layer at the target's size, and puts the layer over the background with the output pass, as a frame's output does. The hook lays the document out on its screen at its scale (`ui.layout_one`), and draws it through the view (`ui.add_document_passes`), which `ui.hlsl` takes as a scale and an offset (see [UI: Drawing](../ui/design.md#drawing)). The preview is complete when every font, atlas and image that it draws was resident.
- **The link.** `Ui_Preview_Settings` takes the place of `Preview_Settings`: the screen's size, the UI scale, the view's scale and offset, the target's size, the background, the node that shows forced states and which, and the bindings' values. `Ui_Preview_Layout` comes back when it changes, at most twenty times a second: the blob's key, the scale, and each node's blob index, whether it shows, its rectangle, the rectangle inside its padding, and its clip, in the screen's pixels (see [Editor link](link.md#messages)).
- **States** are the document's `forced_node` and `forced`, which `node_states` puts in place of the player's; each runtime node keeps its blob index as `source`.
- **The cook:** `Cook_Preview` with a UI document's GUID runs `ui_check`, which reports what a cook would, with lines and columns, checks fonts and images against the daemon's index, and writes a text without errors into the preview area (see [Daemon](../content/daemon-and-operations.md#cook-daemon)).
