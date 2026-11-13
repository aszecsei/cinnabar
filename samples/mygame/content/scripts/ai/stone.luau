--!strict
-- A thrown stone (see thrower.luau). It flies at the velocity that its thrower gives it, once its body is made in its
-- first tick. Each knock that is fast enough makes a loud noise, which draws the agents that hear it (see
-- docs/ai/perception.md#hearing), and a sound. A stone that hits an agent with Health hurts it once. It goes after a
-- while.
local Health = require("./health")

local Stone = Behaviour.define("Stone", {
	-- Meters within which agents hear a knock.
	loudness = Field.number(15),
	-- Meters a second below which a knock makes no noise, so a stone that rolls is quiet.
	quiet_speed = Field.number(2),
	damage = Field.number(35),
	sound = Field.asset("audio"),
	-- Seconds before it goes.
	lifetime = Field.number(20),
})

function Stone:start()
	self.age = 0
	self.hit = false
end

-- Throws the stone at the velocity, in its next tick.
function Stone:throw(velocity: vector)
	self.launch = velocity
end

function Stone:fixed_update(dt: number)
	-- The physics tick after the scripts' fixed step makes the body, so the first tick has none.
	if self.launch and self.age > 0 then
		Physics.set_velocity(self.entity, self.launch)
		self.launch = nil
	end
	self.age += dt
	if self.age > self.lifetime then
		self.entity:destroy()
	end
end

function Stone:on_collision_enter(other: Entity, point: WorldPosition, normal: vector, velocity: vector, impulse: number)
	local speed = vector.magnitude(velocity)
	if speed < self.quiet_speed then
		return
	end
	Perception.noise(point, self.loudness, "Noise", self.entity)
	if self.sound then
		Audio.play(self.sound, point, math.clamp(speed / 10, 0.2, 1), "Sfx")
	end
	local health = other:get(Health)
	if health and not self.hit then
		self.hit = true
		health:hurt(self.damage)
	end
end

return Stone
