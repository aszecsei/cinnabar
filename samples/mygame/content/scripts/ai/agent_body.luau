--!strict
-- The body of one of the guard scene's agents (see docs/ai/README.md#the-sample). The crowd moves the agent's character,
-- and this turns it to face the way that it walks, or, while it stands, the way that its action asks it to look. It
-- gives the agent's animation graph its speed, so the fox walks and runs as fast as it moves, and plays the bark at the
-- graph's bark event. It keeps where the agent started, which the patrols walk around. The agents' actions reach it
-- with self.entity:get(AgentBody).
local AgentBody = Behaviour.define("AgentBody", {
	-- Degrees a second that it turns at.
	turn_rate = Field.number(360),
	-- The sound of its bark.
	bark_sound = Field.asset("audio"),
})

-- The agents' agent type in the project's nav.agents.
AgentBody.AGENT_TYPE = "Human"

local WORLD_UP = vector.create(0, 1, 0)
-- Meters a second below which the agent stands, and faces where its action asks.
local STANDING = 0.3

function AgentBody:start()
	self.home = self.entity.transform.position
	self.looking = nil
	self.animated = self.entity:has(Animator)
end

-- A reachable point on the navmesh within radius meters of where the agent started, or nil.
function AgentBody:patrol_point(radius: number): WorldPosition?
	return Navigation.random_point(self.home, radius, AgentBody.AGENT_TYPE)
end

-- Asks the body to face along direction while it stands, or with nil to face the way that it walks.
function AgentBody:look(direction: vector?)
	self.looking = direction
end

-- Plays the bark's sound where the agent stands.
function AgentBody:bark()
	if self.bark_sound then
		Audio.play(self.bark_sound, self.entity.transform.position, 1, "Sfx")
	end
end

function AgentBody:fixed_update(dt: number)
	local velocity = Navigation.velocity(self.entity)
	local walk = vector.create(velocity.x, 0, velocity.z)
	local speed = vector.magnitude(walk)
	if self.animated then
		Animation.set_float(self.entity, "speed", speed)
	end
	local facing = if speed > STANDING then walk else self.looking
	local transform = self.entity.transform
	if facing and transform and vector.magnitude(facing) > 1e-3 then
		local goal = Quaternion.look_rotation(vector.normalize(facing), WORLD_UP)
		transform.rotation = Quaternion.rotate_towards(transform.rotation, goal, self.turn_rate * dt)
	end
end

function AgentBody:on_animation_event(name: string)
	if name == "bark" then
		self:bark()
	end
end

return AgentBody
