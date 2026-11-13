--!strict
-- An agent's health, which it keeps in its blackboard's health key, so its decision weighs it (see ai/wary.decision).
-- A stone that hits it hurts it (see stone.luau), and it gets its health back slowly.
local Health = Behaviour.define("Health", {
	max = Field.number(100),
	-- Points a second that it gets back.
	regeneration = Field.number(3),
})

function Health:start()
	self.value = self.max
	Blackboard.set(self.entity, "health", self.value)
end

function Health:fixed_update(dt: number)
	if self.value < self.max then
		self.value = math.min(self.max, self.value + self.regeneration * dt)
		Blackboard.set(self.entity, "health", self.value)
	end
end

function Health:hurt(points: number)
	self.value = math.max(0, self.value - points)
	Blackboard.set(self.entity, "health", self.value)
end

return Health
