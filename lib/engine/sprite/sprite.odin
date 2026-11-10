// Package sprite plays the animations of the Sprite_Renderers (see docs/rendering/2d.md#animation): a system that moves
// each playing one on, and what names a sheet's animations and frames, for the Sprites script library. The renderer
// draws the sprites; it knows nothing of scripts, so this package is beside it, as anim is.
package sprite

import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"

// State is the sprites' animation state, in Game_State: the assets, and the sheets that a name was looked up in.
State :: struct {
	assets: ^asset.Assets,
	sheets: render.Sprite_Sheets,
}

// Found is what looking a name up in a sprite's sheet gave.
Found :: enum u8 {
	// The sprite has no sheet, or its sheet is not cooked, so there is nothing to look in.
	No_Sheet,
	// The sheet has nothing of that name.
	No_Name,
	Ok,
}

// register makes the animate sprites system, and the state's table of sheets the first time. Call it after the world's
// components are registered, in init and in on_reload.
register :: proc(s: ^State, w: ^ecs.World, assets: ^asset.Assets) {
	s.assets = assets
	if s.sheets.handles == nil {
		render.sprite_sheets_init(&s.sheets, w.platform)
	}
	ecs.register_system(w, {name = "animate sprites", stage = .Update, procedure = animate, terms = {ecs.write(w, render.Sprite_Renderer)}, data = s})
}

// destroy gives back the sheets that were loaded.
destroy :: proc(s: ^State) {
	render.sprite_sheets_destroy(&s.sheets, s.assets)
}

// animate moves each playing Sprite_Renderer that has an animation on by the frame's time, at its speed.
animate :: proc(ctx: ^ecs.System_Context) {
	it := ecs.query_iter(ctx.world, ctx.query, ctx.first_chunk, ctx.chunk_count)
	for view in ecs.query_next(&it) {
		for &sprite in ecs.column(view, 0, render.Sprite_Renderer) {
			if sprite.playing && sprite.animation != 0 {
				sprite.time += ctx.dt * max(sprite.speed, 0)
			}
		}
	}
}

// play starts the animation of a name in the sprite's sheet from its first frame, or lets one that is playing already
// go on, unless restart says to start it again.
play :: proc(s: ^State, sprite: ^render.Sprite_Renderer, name: string, restart := false) -> Found {
	data, blob, ok := render.sprite_sheet_blob(&s.sheets, s.assets, sprite.sheet)
	if !ok {
		return .No_Sheet
	}
	index, found := format.sprite_sheet_find_animation(data, blob, name)
	if !found {
		return .No_Name
	}
	if restart || int(sprite.animation) != index + 1 {
		sprite.time = 0
	}
	sprite.animation, sprite.playing = u16(index + 1), true
	return .Ok
}

// stop holds the sprite on the frame that it shows.
stop :: proc(sprite: ^render.Sprite_Renderer) {
	sprite.playing = false
}

// set_frame shows the frame of a name in the sprite's sheet, in place of any animation.
set_frame :: proc(s: ^State, sprite: ^render.Sprite_Renderer, name: string) -> Found {
	data, blob, ok := render.sprite_sheet_blob(&s.sheets, s.assets, sprite.sheet)
	if !ok {
		return .No_Sheet
	}
	index, found := format.sprite_sheet_find_frame(data, blob, name)
	if !found {
		return .No_Name
	}
	sprite.frame, sprite.animation, sprite.time = u16(index), 0, 0
	return .Ok
}

// animation_name is the name of the animation that the sprite plays or holds, or "" without one. The name is in the
// sheet's blob, so do not keep it across frames.
animation_name :: proc(s: ^State, sprite: render.Sprite_Renderer) -> string {
	if sprite.animation == 0 {
		return ""
	}
	data, blob, ok := render.sprite_sheet_blob(&s.sheets, s.assets, sprite.sheet)
	animations := format.sprite_sheet_animations(data, blob) if ok else nil
	if int(sprite.animation) > len(animations) {
		return ""
	}
	return string(format.blob_bytes(data, animations[sprite.animation - 1].name))
}

// finished is whether the sprite's animation, one that does not loop, has shown its last frame for its whole time. A
// sprite without an animation has finished.
finished :: proc(s: ^State, sprite: render.Sprite_Renderer) -> bool {
	if sprite.animation == 0 {
		return true
	}
	data, blob, ok := render.sprite_sheet_blob(&s.sheets, s.assets, sprite.sheet)
	if !ok {
		return false
	}
	_, over := format.sprite_sheet_frame_at(data, blob, int(sprite.animation) - 1, sprite.time)
	return over
}
