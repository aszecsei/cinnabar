package ui

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// Engine components have small explicit IDs (see docs/world/ecs.md#component-registry).
UI_DOCUMENT_ID :: ecs.Component_Id(112)

// Ui_Document puts a UI document on the screen while its entity is active. Its entity's behaviours get the document's
// events, such as on_resume for click="resume", and scripts reach its elements through it (see
// docs/ui/design.md#documents).
Ui_Document :: struct {
	document: format.Guid `asset:"ui"`,
	// Documents of a higher order draw over those of a lower one, and take input first.
	order:    i32 `editor:"range=-100,100"`,
	visible:  bool,
}

DEFAULT_UI_DOCUMENT :: Ui_Document {
	visible = true,
}

// register_components registers the components that this package reads. Call it from the game's component registration
// procedure.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Ui_Document, UI_DOCUMENT_ID, DEFAULT_UI_DOCUMENT)
}
