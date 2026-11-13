--!strict
-- A place on a guard's round. The waypoints put themselves in order when they start, and next_waypoint.luau takes
-- them in turn (see ai/guard.decision).
local Waypoint = Behaviour.define("Waypoint", {
	-- Where it comes on the round: the lowest first.
	order = Field.number(0),
})

local waypoints = {}

function Waypoint:start()
	table.insert(waypoints, { order = self.order, entity = self.entity })
	table.sort(waypoints, function(a, b)
		return a.order < b.order
	end)
end

function Waypoint:on_destroy()
	for i = #waypoints, 1, -1 do
		if waypoints[i].entity == self.entity then
			table.remove(waypoints, i)
		end
	end
end

-- How many waypoints there are.
function Waypoint.count(): number
	return #waypoints
end

-- Where the waypoint at an index is, from 1.
function Waypoint.position(index: number)
	return waypoints[index].entity.transform.position
end

return Waypoint
