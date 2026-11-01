--!strict
-- Walks its fox back and forth by its animation graph's speed (see docs/animation/design.md#scripts). Its speed rises
-- from standing to a run and falls back over each cycle, and the graph blends the fox's walk and run by it; halfway up,
-- it pulls the look trigger, and the fox stops to look about. The graph only reports what it did: this behaviour moves
-- the fox, and logs the graph's events, its footsteps and its states' entries and exits.
local FoxWalker = Behaviour.define("FoxWalker", {
	-- Meters a second at the top of a cycle, which the graph reaches its run at.
	top_speed = Field.number(3),
	-- Seconds of one cycle, from standing to the top speed and back.
	cycle = Field.number(12),
	-- Meters it walks from its start before it goes back there.
	distance = Field.number(8),
	-- How many events it logs, so the log does not fill.
	limit = Field.number(24),
})

function FoxWalker:start()
	self.home = self.entity.transform.position
	self.clock = 0
	self.walked = 0
	self.logged = 0
	self.looked = false
end

function FoxWalker:fixed_update(dt: number)
	self.clock += dt
	local phase = (self.clock % self.cycle) / self.cycle
	if phase < 0.1 then
		self.looked = false
	end
	local speed = self.top_speed * 0.5 * (1 - math.cos(phase * 2 * math.pi))
	Animation.set_float(self.entity, "speed", speed)
	if not self.looked and phase > 0.25 then
		self.looked = true
		Animation.trigger(self.entity, "look")
	end
	-- It moves only while the graph walks or runs: standing and looking about, it stays where it is.
	if Animation.state(self.entity) == "move" then
		local step = speed * dt
		self.entity:move(self.entity.transform.forward * step)
		self.walked += step
		if self.walked > self.distance then
			self.walked = 0
			self.entity:teleport(self.home)
		end
	end
end

function FoxWalker:on_animation_event(name: string, side: string?)
	self.logged += 1
	if self.logged <= self.limit then
		Debug.log("fox", name, side or "", "in", Animation.state(self.entity) or "")
	end
end

return FoxWalker
