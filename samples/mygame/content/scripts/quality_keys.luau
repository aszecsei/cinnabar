--!strict
-- The sample's quality keys, as a settings menu sets the quality, through the Render bindings (see
-- docs/scripting/api.md#render): F9 takes the next preset, Shift+F9 turns traced shadows on or off, Ctrl+F9 takes the
-- next ambient occlusion technique, Ctrl+Shift+F9 the next render scale, and F6 the next anti-aliasing technique that
-- the device runs. Each saves the quality to the user settings file, which the game reads back. hello.luau calls
-- update every frame. Anti-aliasing is not Alt+F9, which the NVIDIA app takes for itself.
local AMBIENT_OCCLUSION = { "Off", "Gtao", "Ssao", "Hbao" }
local RENDER_SCALES = { 1, 0.75, 2 / 3, 0.5 }

-- after is the value after one in a list, or the first after the last or when the list does not have it.
local function after<T>(list: { T }, value: T): T
	local i = table.find(list, value) or 0
	return list[i % #list + 1]
end

-- next_scale is the scale after the largest of RENDER_SCALES that is at most the current one.
local function next_scale(scale: number): number
	for i, s in RENDER_SCALES do
		if scale >= s - 1e-3 then
			return RENDER_SCALES[i % #RENDER_SCALES + 1]
		end
	end
	return RENDER_SCALES[1]
end

local function update()
	local anti_aliasing = Input.was_pressed(Key.F6)
	if not Input.was_pressed(Key.F9) and not anti_aliasing then
		return
	end
	local shift = Input.is_down(Key.LeftShift) or Input.is_down(Key.RightShift)
	local control = Input.is_down(Key.LeftControl) or Input.is_down(Key.RightControl)
	local q = Render.quality()
	if anti_aliasing then
		Render.set_quality({ aa = after(Render.caps().aa, q.aa) })
	elseif shift and control then
		Render.set_quality({ render_scale = next_scale(q.render_scale) })
	elseif shift then
		Render.set_quality({ ray_traced_shadows = not q.ray_traced_shadows })
	elseif control then
		Render.set_quality({ ao = after(AMBIENT_OCCLUSION, q.ao) })
	else
		Render.set_quality({ preset = after(Render.presets(), q.preset) })
	end
	q = Render.quality()
	Debug.log(
		"quality",
		q.preset,
		"traced shadows",
		q.ray_traced_shadows,
		"ambient occlusion",
		q.ao,
		"anti-aliasing",
		q.aa,
		"render scale",
		q.render_scale,
		"(F9 takes the next preset, Shift+F9 turns traced shadows on or off, Ctrl+F9 takes the next ambient occlusion, Ctrl+Shift+F9 the next render scale, F6 the next anti-aliasing)"
	)
	if not Render.save_quality() then
		Debug.warn("could not save the quality")
	end
end

return { update = update }
