--!strict
-- The agents' flight (see ai/wary.decision): of a few reachable points within range meters, it runs to the one that is
-- furthest from what it flees, and succeeds when it arrives. It fails when there is nothing to flee or no point, and
-- when its move fails or something replaces it.
local AgentBody = require("./agent_body")

local Flee = Action.define("flee", {
	from = Param.entity(),
	range = Param.number(12),
})

-- How many points it weighs.
local CHOICES = 8

function Flee:start()
	self.ticket = nil
	local from: Entity? = self.from
	local away = if from and from:is_alive() then from.transform else nil
	if not away then
		return
	end
	local here = self.entity.transform.position
	local threat = away.position
	local best: WorldPosition? = nil
	local furthest = -1
	for _ = 1, CHOICES do
		local point = Navigation.random_point(here, self.range, AgentBody.AGENT_TYPE)
		if point then
			local distance = vector.magnitude(point - threat)
			if distance > furthest then
				best, furthest = point, distance
			end
		end
	end
	if best then
		self.ticket = Navigation.move_to(self.entity, best)
	end
end

function Flee:tick(dt: number)
	if not self.ticket then
		return "failed"
	end
	local status = Navigation.move_status(self.entity, self.ticket)
	if status == "arrived" then
		return "succeeded"
	end
	return if status == "pending" or status == "moving" then "running" else "failed"
end

return Flee
