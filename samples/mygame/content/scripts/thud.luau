--!strict
-- Logs the bodies that land on its entity, with the impact's impulse (see docs/physics/design.md#scripts). The main
-- scene attaches it to the short box, which the falling boxes land on.
local Thud = Behaviour.define("Thud", {
	-- How many landings it logs, so a pile that settles does not fill the log.
	limit = Field.number(8),
})

function Thud:on_collision_enter(other: Entity, point: WorldPosition, normal: vector, velocity: vector, impulse: number)
	self.count = (self.count or 0) + 1
	if self.count <= self.limit then
		Debug.log("thud", self.count, other, "lands at", vector.magnitude(velocity), "m/s with impulse", impulse)
	end
end

return Thud
