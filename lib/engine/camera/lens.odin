package camera

import "cinnabar:engine/ecs"
import "cinnabar:engine/render"

// register makes the "cinematic lens" system, which writes each Cinematic_Camera's field of view into its Camera (see
// render.set_cinematic_fov). It runs in the Late stage, after the cutscenes' exclusive system and the scripts, and
// before advance reads the cameras. Call it after the world's components are registered, in init and in on_reload.
register :: proc(w: ^ecs.World) {
	ecs.register_system(w, {
		name = "cinematic lens",
		stage = .Late,
		procedure = proc(ctx: ^ecs.System_Context) {render.set_cinematic_fov(ctx.world)},
		reads = {render.CINEMATIC_CAMERA_ID},
		writes = {render.CAMERA_ID},
	})
}
