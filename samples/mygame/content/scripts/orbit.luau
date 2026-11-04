--!strict
-- Carries its entity from side to side in fixed ticks, as a thing that moves in the world does, so that the audio scene's
-- hum goes behind the wall and comes out again (see docs/audio/design.md#the-sample).
local Orbit = Behaviour.define("Orbit", {
	-- Meters that it goes to each side of where it started.
	width = Field.number(7),
	-- Seconds of one trip there and back.
	period = Field.number(14),
})

function Orbit:start()
	self.clock = 0
	self.offset = 0
end

function Orbit:fixed_update(dt: number)
	self.clock += dt
	local offset = self.width * math.sin(self.clock / self.period * 2 * math.pi)
	self.entity:move(vector.create(offset - self.offset, 0, 0))
	self.offset = offset
end

return Orbit
