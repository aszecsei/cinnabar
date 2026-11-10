--!strict
-- Walks a sprite from side to side in the 2D scene: it plays the sheet's walk by name, turns around at each end, and
-- stands for a moment with the idle (see docs/rendering/2d.md#scripts).
local SpriteWalker = Behaviour.define("SpriteWalker", {
	-- Meters that it goes to each side of where it started.
	width = Field.number(4),
	-- Meters a second.
	speed = Field.number(2),
	-- Seconds that it stands at each end.
	rest = Field.number(1),
})

function SpriteWalker:start()
	self.offset = 0
	self.direction = 1
	self.resting = 0
	Sprites.play(self.entity, "walk")
end

function SpriteWalker:update(dt: number)
	if self.resting > 0 then
		self.resting -= dt
		if self.resting <= 0 then
			self.direction = -self.direction
			local sprite = self.entity:get(SpriteRenderer)
			if sprite then
				sprite.flip_x = self.direction < 0
			end
			Sprites.play(self.entity, "walk")
		end
		return
	end
	local step = self.direction * self.speed * dt
	if math.abs(self.offset + step) > self.width then
		step = self.direction * self.width - self.offset
		self.resting = self.rest
		Sprites.play(self.entity, "idle")
	end
	self.offset += step
	self.entity:move(vector.create(step, 0, 0))
end

return SpriteWalker
