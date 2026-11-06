--!strict
-- The HUD's behaviour, on the entity whose Ui_Document is ui/hud.ui (see docs/ui/design.md#scripts): it binds the frame
-- rate, which it smooths over about half a second of real time, so it reads the same while the world is paused.
local Hud = Behaviour.define("Hud")

-- How much of each frame's rate goes into the shown one.
local SMOOTHING = 0.05

function Hud:start()
	self.last = Time.real_time
	self.fps = 60
end

function Hud:update(_dt: number)
	local now = Time.real_time
	local step = now - self.last
	self.last = now
	if step > 0 then
		self.fps += (1 / step - self.fps) * SMOOTHING
	end
	Ui.bind(self.entity, "fps", math.floor(self.fps + 0.5))
end

return Hud
