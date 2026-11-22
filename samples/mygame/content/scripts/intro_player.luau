--!strict
-- Plays the intro cutscene with I in the animation scene, unless the UI takes the keys or the intro is playing (see
-- docs/cinematics/scripts.md). A coroutine waits for the intro's end and logs whether it was skipped; hold the skip
-- action to skip it. The intro possesses the walking fox and spawns its own guard and cameras, and gives the world back
-- when it ends. The player's lifecycle comes to this behaviour, its caller, as events, and the intro's story track sends
-- intro_seen to every behaviour.
local IntroPlayer = Behaviour.define("IntroPlayer", {
	-- The cutscene to play.
	cutscene = Field.asset("cutscene"),
})

function IntroPlayer:update(_dt: number)
	if Ui.wants_input() or not Input.was_pressed(Key.I) or self.playing or not self.cutscene then
		return
	end
	self.playing = true
	self:start_coroutine(function()
		local intro = Cutscene.play(self.cutscene)
		local skipped = wait_cutscene(intro)
		Debug.log("intro", intro:state() or "gone", if skipped then "skipped" else "played to its end", intro:error() or "")
		self.playing = false
	end)
end

function IntroPlayer:on_cutscene_started(_cutscene: Cutscene)
	Debug.log("intro started")
end

function IntroPlayer:on_cutscene_finished(_cutscene: Cutscene, skipped: boolean)
	Debug.log("intro finished", if skipped then "by a skip" else "")
end

function IntroPlayer:on_cutscene_failed(_cutscene: Cutscene, reason: string)
	Debug.warn("intro failed:", reason)
end

function IntroPlayer:on_intro_seen()
	Debug.log("the intro was seen")
end

return IntroPlayer
