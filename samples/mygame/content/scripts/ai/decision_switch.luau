--!strict
-- Swaps its agent's decision with H or the first gamepad's Y: from the first decision to the second and back (see
-- docs/ai/agents.md#scripts). Both read the same blackboard and start the same actions, so the agent does the same
-- things, decided another way. The agent starts again with the decision it swaps to.
local DecisionSwitch = Behaviour.define("DecisionSwitch", {
	first = Field.asset("decision"),
	second = Field.asset("decision"),
	-- Names for the HUD and the log.
	first_name = Field.string("behavior tree"),
	second_name = Field.string("HTN"),
})

local function first_gamepad(): number?
	for pad = 1, 4 do
		if Input.gamepad_connected(pad) then
			return pad
		end
	end
	return nil
end

-- The name of the decision that the agent runs.
function DecisionSwitch:current(): string
	return if Agent.decision(self.entity) == self.second then self.second_name else self.first_name
end

function DecisionSwitch:update(dt: number)
	if not self.first or not self.second or Ui.wants_input() then
		return
	end
	local pad = first_gamepad()
	if not (Input.was_pressed(Key.H) or (pad ~= nil and Input.gamepad_was_pressed(pad, GamepadButton.Y))) then
		return
	end
	local next = if Agent.decision(self.entity) == self.second then self.first else self.second
	Agent.set_decision(self.entity, next)
	Debug.log("decision", self.entity, "runs its", self:current())
end

return DecisionSwitch
