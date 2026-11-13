--!strict
-- Walks its agent through the doorway to the place across the door from where it started, and back. The agents cross
-- together: once every one of them arrived, they wait, and all cross again. The crowd finds the way, keeps the agents
-- apart and moves their characters (see docs/ai/navigation.md#crowds); this only says where to go.
local Crosser = Behaviour.define("Crosser", {
	-- The doorway, which the agent's place across is the mirror of its start in.
	door = Field.entity(),
	-- Seconds that the agents wait on each side once all arrived.
	wait = Field.number(2),
})

-- The crossings that every agent shares: how many agents there are, which crossing they are on, how many arrived in it,
-- and the seconds since the last one did.
local agents = 0
local crossing = 1
local arrived = 0
local waited = 0

function Crosser:start()
	local door = self.door and self.door.transform
	if not door then
		return
	end
	local home = self.entity.transform.position
	local offset = home - door.position
	self.places = { home, door.position + vector.create(-offset.x, offset.y, offset.z) }
	self.crossing = crossing
	self.arrived = false
	agents += 1
	Navigation.move_to(self.entity, self.places[if crossing % 2 == 1 then 2 else 1])
end

function Crosser:fixed_update(dt: number)
	if not self.places then
		return
	end
	if self.crossing ~= crossing then
		self.crossing = crossing
		self.arrived = false
		Navigation.move_to(self.entity, self.places[if crossing % 2 == 1 then 2 else 1])
		return
	end
	if not self.arrived and Navigation.arrived(self.entity) then
		self.arrived = true
		arrived += 1
		waited = 0
	end
	-- Every agent that arrived counts its share of the wait, so the wait is the same however many there are.
	if arrived == agents and self.arrived then
		waited += dt / agents
		if waited >= self.wait then
			arrived = 0
			crossing += 1
		end
	end
end

function Crosser:on_destroy()
	if self.places then
		agents -= 1
		if self.arrived and self.crossing == crossing then
			arrived -= 1
		end
	end
end

return Crosser
