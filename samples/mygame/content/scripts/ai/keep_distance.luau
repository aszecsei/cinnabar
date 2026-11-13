--!strict
-- The agents' wary watch (see ai/wary.decision): it keeps the agent about range meters from what it watches, and faces
-- it. Twice a second, it walks back to the range when the other comes closer, and in when the other goes further. It
-- runs until its decision picks something else, and fails when there is nothing to watch.
local AgentBody = require("./agent_body")

local KeepDistance = Action.define("keep_distance", {
	from = Param.entity(),
	range = Param.number(6),
})

-- Seconds between its moves, and the meters by which the distance may differ from the range before it moves.
local INTERVAL = 0.5
local SLACK = 1

function KeepDistance:start()
	self.wait = 0
	self.body = self.entity:get(AgentBody)
end

function KeepDistance:tick(dt: number)
	local from: Entity? = self.from
	if not from or not from:is_alive() then
		return "failed"
	end
	local agent: Entity = self.entity
	local away = from:offset_to(agent)
	local flat = vector.create(away.x, 0, away.z)
	if self.body then
		self.body:look(-flat)
	end
	self.wait -= dt
	if self.wait > 0 then
		return "running"
	end
	self.wait = INTERVAL
	local distance = vector.magnitude(flat)
	if math.abs(distance - self.range) > SLACK then
		local direction = if distance > 1e-3 then flat / distance else vector.create(1, 0, 0)
		local there = from.transform
		local goal = there and Navigation.nearest(there.position + direction * self.range, AgentBody.AGENT_TYPE)
		if goal then
			Navigation.move_to(agent, goal)
		end
	end
	return "running"
end

function KeepDistance:stop()
	if self.body then
		self.body:look(nil)
	end
end

return KeepDistance
