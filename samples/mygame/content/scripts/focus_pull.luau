--!strict
-- Pulls its camera's focus from one entity to another and back, as a focus puller would, so the focus scene shows the
-- depth of field follow it (see docs/rendering/post-processing.md#depth-of-field). It eases the Camera's
-- focus_distance between the two entities' distances along the camera's axis.
local FocusPull = Behaviour.define("FocusPull", {
	-- The entities that the focus moves between.
	near = Field.entity(),
	far = Field.entity(),
	-- Seconds that the focus holds on each, and that a pull takes.
	hold = Field.number(2),
	pull = Field.number(1.5),
})

function FocusPull:start()
	self.clock = 0
	self.to_far = true
end

-- distance is an entity's distance along the camera's axis, or nil without the entity.
function FocusPull:distance(target: Entity?): number?
	if not target then
		return nil
	end
	return vector.dot(self.entity:offset_to(target), self.entity.transform.forward)
end

function FocusPull:update(dt: number)
	local camera = self.entity:get(Camera)
	local from = self:distance(if self.to_far then self.near else self.far)
	local to = self:distance(if self.to_far then self.far else self.near)
	if not camera or not from or not to then
		return
	end
	self.clock += dt
	local t = math.clamp((self.clock - self.hold) / self.pull, 0, 1)
	t = t * t * (3 - 2 * t)
	camera.focus_distance = from + (to - from) * t
	if self.clock >= self.hold + self.pull then
		self.clock = 0
		self.to_far = not self.to_far
	end
end

return FocusPull
