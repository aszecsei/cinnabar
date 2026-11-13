--!strict
-- Adds a crowd of guards with G or the first gamepad's X, at random points on the navmesh within radius meters of its
-- entity, and takes them away with the next press. With the scene's two agents, its count makes twenty, whose thinks
-- the think budget and their intervals spread over the ticks (see docs/ai/agents.md#thinking).
local AgentBody = require("./agent_body")

local Crowd = Behaviour.define("Crowd", {
	guard = Field.asset("prefab"),
	count = Field.number(18),
	radius = Field.number(12),
})

local function first_gamepad(): number?
	for pad = 1, 4 do
		if Input.gamepad_connected(pad) then
			return pad
		end
	end
	return nil
end

function Crowd:start()
	self.guards = {}
end

-- How many guards it added.
function Crowd:size(): number
	return #self.guards
end

function Crowd:update(dt: number)
	if not self.guard or Ui.wants_input() then
		return
	end
	local pad = first_gamepad()
	if not (Input.was_pressed(Key.G) or (pad ~= nil and Input.gamepad_was_pressed(pad, GamepadButton.X))) then
		return
	end
	if #self.guards > 0 then
		for _, guard in self.guards do
			if guard:is_alive() then
				guard:destroy()
			end
		end
		self.guards = {}
		return
	end
	local center = self.entity.transform.position
	for _ = 1, self.count do
		local point = Navigation.random_point(center, self.radius, AgentBody.AGENT_TYPE)
		if point then
			local turn = Quaternion.angle_axis(Random.range(0, 360), vector.create(0, 1, 0))
			table.insert(self.guards, World.spawn(self.guard, point, turn))
		end
	end
	Debug.log("crowd", #self.guards, "guards added")
end

return Crowd
