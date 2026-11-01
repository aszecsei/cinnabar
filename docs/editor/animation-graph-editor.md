# Animation graph editor

The animation graph editor edits an animation graph (see [Content: Animation graphs](../content/kinds/animation-graphs.md#animation-graphs)). Each open one is a document beside the viewport, `AnimationGraphEditorDocument`, over an `AnimationGraphEditor` in the shell, which holds its state, so docking can rebuild the view, and tests drive the editor without a window.
