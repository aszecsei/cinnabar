--!strict
-- Follows its target from behind and above, looking at it. The mouse turns it while its right button is down, and so
-- does the first gamepad's right stick. It eases towards where it should be, which hides the target's moves in fixed
-- ticks between frames.
local FollowCamera = Behaviour.define("FollowCamera", {
	target = Field.entity(),
	-- Meters from the point it looks at.
	distance = Field.number(6),
	-- Meters above the target's position that it looks at.
	height = Field.number(1.5),
	-- Degrees a pixel of the mouse, and a second with the stick all the way over.
	mouse_rate = Field.number(0.2),
	turn_rate = Field.number(120),
	-- How quickly it eases: the fraction of the way left that it closes in a second is 1 - e^-ease.
	ease = Field.number(12),
})

local WORLD_UP = vector.create(0, 1, 0)
local WORLD_RIGHT = vector.create(1, 0, 0)
local MIN_PITCH = -20
local MAX_PITCH = 70

local function first_gamepad(): number?
	for pad = 1, 4 do
		if Input.gamepad_connected(pad) then
			return pad
		end
	end
	return nil
end

-- It keeps its turn as two angles, positive to the right and down, so that it never rolls.
function FollowCamera:start()
	local transform = self.entity.transform
	local forward = transform and transform.forward or vector.create(0, 0, 1)
	self.yaw = math.deg(math.atan2(forward.x, forward.z))
	self.pitch = math.clamp(math.deg(-math.asin(forward.y)), MIN_PITCH, MAX_PITCH)
end

function FollowCamera:update(dt: number)
	local transform = self.entity.transform
	local target: Entity? = self.target
	local target_transform = target and target.transform
	if not transform or not target_transform then
		return
	end

	if not Ui.wants_input() then
		if Input.is_down(Key.MouseRight) then
			local delta = Input.mouse_delta
			self.yaw += delta.x * self.mouse_rate
			self.pitch += delta.y * self.mouse_rate
		end
		local pad = first_gamepad()
		if pad then
			self.yaw += Input.gamepad_axis(pad, GamepadAxis.RightX) * self.turn_rate * dt
			self.pitch -= Input.gamepad_axis(pad, GamepadAxis.RightY) * self.turn_rate * dt
		end
		self.pitch = math.clamp(self.pitch, MIN_PITCH, MAX_PITCH)
	end

	local rotation = Quaternion.angle_axis(self.yaw, WORLD_UP) * Quaternion.angle_axis(self.pitch, WORLD_RIGHT)
	local focus = target_transform.position + WORLD_UP * self.height
	local wanted = focus + rotation * vector.create(0, 0, -self.distance)
	local t = 1 - math.exp(-self.ease * dt)
	transform.position = WorldPosition.lerp(transform.position, wanted, t)
	transform.rotation = Quaternion.look_rotation(focus - transform.position, WORLD_UP)
end

return FollowCamera
