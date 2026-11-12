--!strict
-- Walks its character with W, A, S and D or the first gamepad's left stick, along the ground as its camera sees it, and
-- jumps with Space or the gamepad's A while it is on the ground. The character's controller does the rest: it climbs
-- steps, stops at walls and slides along them, stands on what moves, and pushes what is light enough (see
-- docs/physics/design.md#characters). The controller adds gravity, so this asks only for the walk and the jump.
local Player = Behaviour.define("Player", {
	-- The camera whose view the walk follows. Without one, W walks along +z.
	camera = Field.entity(),
	-- Meters a second.
	speed = Field.number(4),
	-- Meters a second upward at the start of a jump.
	jump_speed = Field.number(5),
})

local WORLD_UP = vector.create(0, 1, 0)

local function first_gamepad(): number?
	for pad = 1, 4 do
		if Input.gamepad_connected(pad) then
			return pad
		end
	end
	return nil
end

-- The way that is forward on the ground: the camera's forward without its pitch.
local function ground_forward(camera: Entity?): vector
	local transform = camera and camera.transform
	if not transform then
		return vector.create(0, 0, 1)
	end
	local forward = transform.forward
	local flat = vector.create(forward.x, 0, forward.z)
	return vector.magnitude(flat) > 1e-3 and vector.normalize(flat) or vector.create(0, 0, 1)
end

function Player:fixed_update(dt: number)
	local ahead, aside = 0, 0
	local jump = false
	if not Ui.wants_input() then
		ahead = (Input.is_down(Key.W) and 1 or 0) - (Input.is_down(Key.S) and 1 or 0)
		aside = (Input.is_down(Key.D) and 1 or 0) - (Input.is_down(Key.A) and 1 or 0)
		jump = Input.was_pressed(Key.Space)
		local pad = first_gamepad()
		if pad then
			ahead += Input.gamepad_axis(pad, GamepadAxis.LeftY)
			aside += Input.gamepad_axis(pad, GamepadAxis.LeftX)
			jump = jump or Input.gamepad_was_pressed(pad, GamepadButton.A)
		end
	end

	local forward = ground_forward(self.camera)
	local right = vector.create(forward.z, 0, -forward.x)
	local walk = forward * ahead + right * aside
	if vector.magnitude(walk) > 1 then
		walk = vector.normalize(walk)
	end
	local velocity = walk * self.speed
	if jump and Physics.is_grounded(self.entity) then
		velocity += WORLD_UP * self.jump_speed
	end
	Physics.move_character(self.entity, velocity, true)

	-- It faces the way it walks.
	local transform = self.entity.transform
	if transform and vector.magnitude(walk) > 0.1 then
		transform.rotation = Quaternion.look_rotation(walk, WORLD_UP)
	end
end

return Player
