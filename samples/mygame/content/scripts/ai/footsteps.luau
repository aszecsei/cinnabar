--!strict
-- The noise of its character's steps: at each stride that it walks on the ground, a quiet noise with its own tag, so an
-- agent near enough hears where it is without seeing it (see docs/ai/perception.md#hearing).
local Footsteps = Behaviour.define("Footsteps", {
	-- Meters between two steps.
	stride = Field.number(0.8),
	-- Meters within which agents hear a step.
	loudness = Field.number(4),
	-- The tag of its noises, in the project's perception.tags.
	tag = Field.string("Player"),
})

function Footsteps:start()
	self.last = self.entity.transform.position
	self.walked = 0
end

function Footsteps:fixed_update(dt: number)
	local here = self.entity.transform.position
	local moved = here - self.last
	self.last = here
	if not Physics.is_grounded(self.entity) then
		return
	end
	self.walked += vector.magnitude(vector.create(moved.x, 0, moved.z))
	if self.walked >= self.stride then
		self.walked -= self.stride
		Perception.noise(here, self.loudness, self.tag, self.entity)
	end
end

return Footsteps
