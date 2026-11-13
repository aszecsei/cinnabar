--!strict
-- The agents' patrol in one action, for a decision that runs one action at a time, as a utility decision does (see
-- ai/wary.decision): it picks a point as next_patrol_point does, walks there, and succeeds when it arrives, or after
-- the seconds. It fails when there is no point, or when its move fails or something replaces it.
local AgentBody = require("./agent_body")

local Patrol = Action.define("patrol", {
	radius = Param.number(8),
	seconds = Param.number(15),
})

function Patrol:start()
	local body = self.entity:get(AgentBody)
	local point = body and body:patrol_point(self.radius)
	self.left = self.seconds
	self.ticket = nil
	if point then
		Blackboard.set(self.entity, "waypoint", point)
		self.ticket = Navigation.move_to(self.entity, point)
	end
end

function Patrol:tick(dt: number)
	if not self.ticket then
		return "failed"
	end
	self.left -= dt
	local status = Navigation.move_status(self.entity, self.ticket)
	if status == "arrived" or self.left <= 0 then
		return "succeeded"
	end
	return if status == "pending" or status == "moving" then "running" else "failed"
end

return Patrol
