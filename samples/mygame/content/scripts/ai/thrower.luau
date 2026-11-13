--!strict
-- Throws a stone with E or the first gamepad's right bumper, ahead of its character as its camera sees it, a little
-- upward. Where the stone lands, it makes a loud noise, which draws the agents (see stone.luau).
local Stone = require("./stone")

local Thrower = Behaviour.define("Thrower", {
	stone = Field.asset("prefab"),
	-- The camera whose view the throw follows. Without one, it throws the way that its character faces.
	camera = Field.entity(),
	-- Meters a second.
	speed = Field.number(11),
	-- Degrees above the ground that it throws at.
	lift = Field.number(20),
	-- The most stones at once. The oldest goes when another is thrown.
	most = Field.number(6),
})

local WORLD_UP = vector.create(0, 1, 0)
-- Where the stone starts: above the character's feet, and ahead of it.
local HAND_HEIGHT = 1.5
local HAND_REACH = 0.6

local function first_gamepad(): number?
	for pad = 1, 4 do
		if Input.gamepad_connected(pad) then
			return pad
		end
	end
	return nil
end

function Thrower:start()
	self.stones = {}
end

function Thrower:fixed_update(dt: number)
	if not self.stone or Ui.wants_input() then
		return
	end
	local pad = first_gamepad()
	local throw = Input.was_pressed(Key.E) or (pad ~= nil and Input.gamepad_was_pressed(pad, GamepadButton.RightBumper))
	if not throw then
		return
	end
	local transform = self.entity.transform
	local view = self.camera and self.camera.transform
	local forward = if view then view.forward else transform.forward
	local flat = vector.create(forward.x, 0, forward.z)
	flat = if vector.magnitude(flat) > 1e-3 then vector.normalize(flat) else vector.create(0, 0, 1)
	local direction = vector.normalize(flat + WORLD_UP * math.tan(math.rad(self.lift)))
	local start = transform.position + WORLD_UP * HAND_HEIGHT + flat * HAND_REACH
	local stone = World.spawn(self.stone, start)
	local thrown = stone:get(Stone)
	if thrown then
		thrown:throw(direction * self.speed)
	end
	table.insert(self.stones, stone)
	if #self.stones > self.most then
		local oldest = table.remove(self.stones, 1)
		if oldest and oldest:is_alive() then
			oldest:destroy()
		end
	end
end

return Thrower
