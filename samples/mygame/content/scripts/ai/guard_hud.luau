--!strict
-- The guard scene's HUD, on the entity whose Ui_Document is ui/guard_hud.ui: the guard's decision and action, the wary
-- agent's action and health, and how many agents there are.
local Crowd = require("./crowd")
local DecisionSwitch = require("./decision_switch")

local GuardHud = Behaviour.define("GuardHud", {
	guard = Field.entity(),
	wary = Field.entity(),
	crowd = Field.entity(),
})

local function action_of(agent: Entity?): string
	if not agent or not agent:is_alive() then
		return "-"
	end
	return Agent.current_action(agent) or "-"
end

function GuardHud:update(dt: number)
	local guard: Entity? = self.guard
	local switch = guard and guard:get(DecisionSwitch)
	Ui.bind(self.entity, "decision", if switch then switch:current() else "-")
	Ui.bind(self.entity, "guard_action", action_of(guard))
	local wary: Entity? = self.wary
	Ui.bind(self.entity, "wary_action", action_of(wary))
	local health = if wary and wary:is_alive() then Blackboard.get(wary, "health") else nil
	Ui.bind(self.entity, "health", if type(health) == "number" then math.floor(health + 0.5) else "-")
	local crowd = self.crowd and self.crowd:get(Crowd)
	Ui.bind(self.entity, "agents", 2 + (if crowd then crowd:size() else 0))
end

return GuardHud
