--!strict
--!native
-- Pulses a large triangle's brightness. Its update runs every frame, so it is compiled to machine code. A scene attaches it to a large triangle, and hello.luau turns it off and
-- on with Tab.
local Pulse = Behaviour.define("Pulse", {
	-- Pulses per second.
	rate = Field.number(1.5),
	-- How far the brightness swings, as a fraction of its own value.
	depth = Field.number(0.5),
})

function Pulse:start()
	self.base = self.entity:get(Triangle).brightness
	self.phase = 0
	self:start_coroutine(function()
		wait(3)
		Debug.log("pulsing", self.entity, "at", self.rate, "per second")
	end)
end

function Pulse:update(dt: number)
	self.phase += dt * self.rate * 2 * math.pi
	self.entity:get(Triangle).brightness = self.base * (1 + self.depth * math.sin(self.phase))
end

-- A script hot reload keeps the instance's state, such as phase, and runs the new update from the next frame.
function Pulse:on_reload()
	Debug.log("reloaded the pulse of", self.entity)
end

-- Disabled, the triangle goes back to its own brightness. A despawned triangle, as when a scene replaces the world,
-- is gone by the time on_disable runs, so there is nothing to restore.
function Pulse:on_disable()
	if self.base and self.entity:is_alive() then
		self.entity:get(Triangle).brightness = self.base
	end
end

return Pulse
