--!strict
-- The agents' look about (see ai/guard.decision): it stops the agent, which turns its head to one side and to the
-- other for the seconds, and then succeeds. Its AgentBody does the turning.
local AgentBody = require("./agent_body")

local LookAround = Action.define("look_around", {
	seconds = Param.number(2),
	-- Degrees to each side that it looks.
	angle = Param.number(60),
})

local WORLD_UP = vector.create(0, 1, 0)

function LookAround:start()
	Navigation.stop(self.entity)
	self.body = self.entity:get(AgentBody)
	local forward = self.entity.transform.forward
	local flat = vector.create(forward.x, 0, forward.z)
	self.ahead = if vector.magnitude(flat) > 1e-3 then vector.normalize(flat) else vector.create(0, 0, 1)
	self.clock = 0
end

function LookAround:tick(dt: number)
	self.clock += dt
	local turn = math.sin(self.clock / self.seconds * 2 * math.pi) * self.angle
	if self.body then
		self.body:look(Quaternion.angle_axis(turn, WORLD_UP) * self.ahead)
	end
	return if self.clock >= self.seconds then "succeeded" else "running"
end

function LookAround:stop()
	if self.body then
		self.body:look(nil)
	end
end

return LookAround
