--!strict
-- Flies its camera with the keyboard and the first gamepad that is connected, to try the inputs out (see
-- docs/core/input.md#gamepads). W and S, or the left stick, move it along the way that it looks, A and D, or the left stick,
-- move it to the side, E and Q, or the right and left triggers, lift and lower it, the arrow keys, or the right stick, turn
-- it, and Shift, or the right bumper, hurries it. It goes through walls: nothing here collides. It stands still while the UI
-- takes the input, as the pause menu does.
local FlyCamera = Behaviour.define("FlyCamera", {
	-- Meters a second with a stick all the way over.
	speed = Field.number(3),
	-- How many times faster it goes while Shift or the right bumper is down.
	boost = Field.number(4),
	-- Degrees a second with the right stick or an arrow key all the way over.
	turn_rate = Field.number(90),
})

local WORLD_UP = vector.create(0, 1, 0)
local WORLD_RIGHT = vector.create(1, 0, 0)
-- Straight up or down would leave no way to tell left from right.
local MAX_PITCH = 89

local function first_gamepad(): number?
	for pad = 1, 4 do
		if Input.gamepad_connected(pad) then
			return pad
		end
	end
	return nil
end

-- It keeps the turn as two angles, positive to the right and down, so that it never rolls.
function FlyCamera:start()
	local forward = self.entity.transform.forward
	self.yaw = math.deg(math.atan2(forward.x, forward.z))
	self.pitch = math.deg(-math.asin(forward.y))
end

local function key_axis(positive: any, negative: any): number
	return (Input.is_down(positive) and 1 or 0) - (Input.is_down(negative) and 1 or 0)
end

function FlyCamera:update(dt: number)
	if Ui.wants_input() then
		return
	end
	local transform = self.entity.transform
	local pad = first_gamepad()

	local turn_x = key_axis(Key.Right, Key.Left)
	local turn_y = key_axis(Key.Down, Key.Up)
	local ahead = key_axis(Key.W, Key.S)
	local aside = key_axis(Key.D, Key.A)
	local lift = key_axis(Key.E, Key.Q)
	local hurry = Input.is_down(Key.LeftShift) or Input.is_down(Key.RightShift)
	if pad then
		turn_x += Input.gamepad_axis(pad, GamepadAxis.RightX)
		turn_y -= Input.gamepad_axis(pad, GamepadAxis.RightY)
		ahead += Input.gamepad_axis(pad, GamepadAxis.LeftY)
		aside += Input.gamepad_axis(pad, GamepadAxis.LeftX)
		lift += Input.gamepad_axis(pad, GamepadAxis.RightTrigger) - Input.gamepad_axis(pad, GamepadAxis.LeftTrigger)
		hurry = hurry or Input.gamepad_is_down(pad, GamepadButton.RightBumper)
	end

	local turn = self.turn_rate * dt
	self.yaw += turn_x * turn
	self.pitch = math.clamp(self.pitch + turn_y * turn, -MAX_PITCH, MAX_PITCH)
	transform.rotation = Quaternion.angle_axis(self.yaw, WORLD_UP) * Quaternion.angle_axis(self.pitch, WORLD_RIGHT)

	local speed = self.speed * (hurry and self.boost or 1)
	self.entity:move((transform.forward * ahead + transform.right * aside + WORLD_UP * lift) * speed * dt)
end

return FlyCamera
