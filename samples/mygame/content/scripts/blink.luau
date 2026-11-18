--!strict
-- Hides and shows another entity in turns, so that the shadow cache scene's crate's shadow goes and comes back in the
-- frame that it does (see docs/rendering/lighting-and-shadows.md#caching). It is on an entity of its own, since a hidden
-- entity's behaviours do not run.
local Blink = Behaviour.define("Blink", {
	-- The entity that it hides and shows.
	target = Field.entity(),
	-- Seconds that the target is shown, and then hidden.
	period = Field.number(1.5),
})

function Blink:start()
	self.clock = 0
	-- An entity field reads nil while its entity is inactive, so the blinker keeps the one that it hides.
	self.crate = self.target
end

function Blink:update(dt: number)
	self.clock += dt
	if self.clock < self.period or not self.crate then
		return
	end
	self.clock -= self.period
	self.crate:set_active(not self.crate.active_self)
end

return Blink
