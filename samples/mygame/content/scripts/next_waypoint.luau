--!strict
-- The guard's action that picks its next waypoint: it writes the waypoint's place in the blackboard's waypoint key, and
-- succeeds. It fails when there are no waypoints (see ai/guard.decision and docs/ai/agents.md#script-actions).
local Waypoint = require("./waypoint")

local NextWaypoint = Action.define("next_waypoint", {})

-- The waypoint that each guard took last.
local taken = {}

function NextWaypoint:start()
	local count = Waypoint.count()
	self.found = count > 0
	if not self.found then
		return
	end
	local index = (taken[self.entity] or 0) % count + 1
	taken[self.entity] = index
	Blackboard.set(self.entity, "waypoint", Waypoint.position(index))
end

function NextWaypoint:tick(dt: number)
	return if self.found then "succeeded" else "failed"
end

return NextWaypoint
