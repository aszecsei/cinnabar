--!strict
-- The agents' bark (see ai/guard.decision and docs/ai/agents.md#script-actions). It stops the agent, turns it to what it
-- barks at, and barks. On an agent with an Animator, the graph's bark state plays, and its bark event plays the sound
-- (see agent_body.luau). Without one, the sound plays at once. It succeeds when the bark is over. It needs an AgentBody.
local AgentBody = require("./agent_body")

local Bark = Action.define("bark", {
	-- What it barks at.
	at = Param.entity(),
	-- Seconds that the bark takes.
	seconds = Param.number(1.2),
})

function Bark:start()
	local agent: Entity = self.entity
	Navigation.stop(agent)
	self.left = self.seconds
	self.body = agent:get(AgentBody)
	local at: Entity? = self.at
	if self.body and at and at:is_alive() then
		self.body:look(agent:offset_to(at))
	end
	if agent:has(Animator) then
		Animation.trigger(agent, "bark")
	elseif self.body then
		self.body:bark()
	end
	Debug.log("bark", agent, "at", at)
end

function Bark:tick(dt: number)
	self.left -= dt
	return if self.left <= 0 then "succeeded" else "running"
end

function Bark:stop()
	if self.body then
		self.body:look(nil)
	end
end

return Bark
