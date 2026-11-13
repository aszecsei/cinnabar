--!strict
-- The agents' choice of where to patrol to next (see ai/guard.decision): a reachable point on the navmesh within radius
-- meters of where the agent started, which it writes in the blackboard's waypoint key, and succeeds. A move_to of
-- waypoint then walks there. It fails when the navmesh has no point there, or the agent has no AgentBody.
local AgentBody = require("./agent_body")

local NextPatrolPoint = Action.define("next_patrol_point", {
	radius = Param.number(8),
})

function NextPatrolPoint:start()
	local body = self.entity:get(AgentBody)
	local point = body and body:patrol_point(self.radius)
	self.found = point ~= nil
	if point then
		Blackboard.set(self.entity, "waypoint", point)
	end
end

function NextPatrolPoint:tick(dt: number)
	return if self.found then "succeeded" else "failed"
end

return NextPatrolPoint
