package audio

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// Engine components have small explicit IDs (see docs/world/ecs.md#component-registry).
AUDIO_SOURCE_ID :: ecs.Component_Id(96)
AUDIO_LISTENER_ID :: ecs.Component_Id(97)

// Audio_Source plays a sound at its entity's presented pose, while its entity is active. See
// docs/audio/design.md#sources-and-the-listener.
Audio_Source :: struct {
	sound:        format.Guid `asset:"audio"`,
	// 0 is Master, and n is the nth of the project's audio.buses.
	bus:          u8 `editor:"range=0,16"`,
	// Plays while this is set. A sound that is not looping clears it when it ends, and setting it again plays it again.
	playing:      bool,
	loop:         bool,
	// Placed in the world, and heard from the listener. Otherwise it plays as it is, at full gain.
	spatial:      bool,
	// Walls between it and the listener muffle it. It casts a ray from the listener, so a collider can block it.
	occluded:     bool,
	gain:         f32 `editor:"range=0,4"`,
	pitch:        f32 `editor:"range=0.1,4"`,
	// Full volume at min_distance and nearer, and silence at max_distance and farther, in meters.
	min_distance: f32 `editor:"range=0,100"`,
	max_distance: f32 `editor:"range=0,1000"`,
}

DEFAULT_AUDIO_SOURCE :: Audio_Source {
	playing      = true,
	spatial      = true,
	occluded     = true,
	gain         = 1,
	pitch        = 1,
	min_distance = 1,
	max_distance = 50,
}

// Audio_Listener is where the world is heard from: its entity's presented pose. The first one in the world counts.
Audio_Listener :: struct {}

// register_components registers the components that this package reads. Call it from the game's component registration
// procedure.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Audio_Source, AUDIO_SOURCE_ID, DEFAULT_AUDIO_SOURCE)
	ecs.register_component(r, Audio_Listener, AUDIO_LISTENER_ID)
}
