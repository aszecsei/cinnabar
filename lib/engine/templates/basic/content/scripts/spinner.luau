--!strict
-- Turns its entity about the world's up axis. It is a behaviour, which the main scene attaches to the cube (see
-- docs/scripting/behaviours.md). Save a change while the game runs, and the game takes it at once.
local Spinner = Behaviour.define("Spinner", {
	-- Degrees per second.
	speed = Field.number(45),
})

function Spinner:start()
	Debug.log("spinning", self.entity, "at", self.speed, "degrees per second")
end

function Spinner:update(dt: number)
	local transform = self.entity:get(Transform)
	if transform then
		transform.rotation = Quaternion.angle_axis(self.speed * dt, vector.create(0, 1, 0)) * transform.rotation
	end
end

return Spinner
