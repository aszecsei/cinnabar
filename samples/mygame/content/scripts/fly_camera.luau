--!strict
-- Flies its camera with the first gamepad that is connected, to try the gamepads out (see docs/core/input.md#gamepads).
-- The left stick moves it along the way that it looks, the right stick turns it, the right trigger lifts it, the left
-- trigger lowers it, and the right bumper hurries it. It goes through walls: nothing here collides.
local FlyCamera = Behaviour.define("FlyCamera", {
	-- Meters a second with a stick all the way over.
	speed = Field.number(3),
	-- How many times faster it goes while the right bumper is down.
	boost = Field.number(4),
	-- Degrees a second with the right stick all the way over.
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

function FlyCamera:update(dt: number)
	local pad = first_gamepad()
	if not pad then
		return
	end
	local transform = self.entity.transform

	local turn = self.turn_rate * dt
	self.yaw += Input.gamepad_axis(pad, GamepadAxis.RightX) * turn
	self.pitch = math.clamp(self.pitch - Input.gamepad_axis(pad, GamepadAxis.RightY) * turn, -MAX_PITCH, MAX_PITCH)
	transform.rotation = Quaternion.angle_axis(self.yaw, WORLD_UP) * Quaternion.angle_axis(self.pitch, WORLD_RIGHT)

	local along = transform.forward * Input.gamepad_axis(pad, GamepadAxis.LeftY)
	local across = transform.right * Input.gamepad_axis(pad, GamepadAxis.LeftX)
	local lift = Input.gamepad_axis(pad, GamepadAxis.RightTrigger) - Input.gamepad_axis(pad, GamepadAxis.LeftTrigger)
	local speed = self.speed * (Input.gamepad_is_down(pad, GamepadButton.RightBumper) and self.boost or 1)
	self.entity:move((along + across + WORLD_UP * lift) * speed * dt)
end

return FlyCamera
