--!strict
-- Lays out its entity's children on a circle. It runs in the editor's Edit mode too, so the children move while a level
-- designer edits the radius, and what it writes there is an edit of the scene, which undoes with the edit that caused it
-- (see docs/scripting/behaviours.md#edit-mode). It writes only what differs, so it settles after one answer.
local Ring = Behaviour.define("Ring", {
	-- Meters from the entity to each child.
	radius = Field.number(2),
}, {
	edit_mode = true,
	category = "Tools/Layout",
})

function Ring:update()
	local children: { Entity } = {}
	for _, e in World.query(Transform) do
		if e.parent == self.entity then
			table.insert(children, e)
		end
	end
	for i, child in children do
		local angle = (i - 1) / #children * 2 * math.pi
		local transform = child.transform
		if transform ~= nil then
			transform.local_position = vector.create(math.cos(angle) * self.radius, 0, math.sin(angle) * self.radius)
		end
	end
end

return Ring
