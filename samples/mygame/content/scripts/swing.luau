--!strict
-- Swings its entity open and shut about a hinge at one edge, as a door does, so that the shadow cache scene's door casts a
-- shadow that moves (see docs/rendering/lighting-and-shadows.md#caching). The hinge is half the width to the entity's
-- left, along its own x, where it starts.
local Swing = Behaviour.define("Swing", {
	-- Degrees that it opens.
	angle = Field.number(100),
	-- Seconds of one swing open and shut.
	period = Field.number(4),
	-- Meters from the hinge to the middle of the entity.
	half_width = Field.number(0.5),
})

local WORLD_UP = vector.create(0, 1, 0)

function Swing:start()
	self.clock = 0
	self.closed = self.entity.transform.rotation
	self.hinge = self.entity.transform.position + self.closed * vector.create(-self.half_width, 0, 0)
end

function Swing:fixed_update(dt: number)
	self.clock += dt
	local open = 0.5 - 0.5 * math.cos(self.clock / self.period * 2 * math.pi)
	local rotation = Quaternion.angle_axis(self.angle * open, WORLD_UP) * self.closed
	local transform = self.entity.transform
	transform.rotation = rotation
	transform.position = self.hinge + rotation * vector.create(self.half_width, 0, 0)
end

return Swing
