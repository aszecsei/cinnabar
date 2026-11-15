--!strict
-- The sample's display keys, as an options menu sets the display, through the Display bindings (see
-- docs/scripting/api.md#display): F5 takes the next window mode, Shift+F5 the next resolution (the window's size in
-- Windowed, the display mode in Fullscreen), Ctrl+F5 turns HDR on or off, and Ctrl+Shift+F5 takes the next paper white.
-- Each saves the display to the user settings file, which the game reads back. hello.luau calls update every frame.
local PAPER_WHITES = { 80, 150, 200, 300, 400, 500 }

-- after is the value after one in a list, or the first after the last or when the list does not have it.
local function after<T>(list: { T }, value: T): T
	local i = table.find(list, value) or 0
	return list[i % #list + 1]
end

-- next_resolution is the resolution after the current size in the monitor's list, largest first, or the first.
local function next_resolution(width: number, height: number): { width: number, height: number }
	local sizes = Display.resolutions()
	for i, size in sizes do
		if size.width == width and size.height == height then
			return sizes[i % #sizes + 1]
		end
	end
	return sizes[1]
end

-- next_paper_white is the first of PAPER_WHITES above the current one, or the first.
local function next_paper_white(nits: number): number
	for _, white in PAPER_WHITES do
		if white > nits + 0.5 then
			return white
		end
	end
	return PAPER_WHITES[1]
end

local function update()
	if not Input.was_pressed(Key.F5) then
		return
	end
	local shift = Input.is_down(Key.LeftShift) or Input.is_down(Key.RightShift)
	local control = Input.is_down(Key.LeftControl) or Input.is_down(Key.RightControl)
	local state = Display.get()
	if shift and control then
		Display.set({ paper_white = next_paper_white(state.paper_white) })
	elseif control then
		Display.set({ hdr = not state.hdr })
	elseif shift then
		local size = next_resolution(state.width, state.height)
		Display.set({ width = size.width, height = size.height })
	else
		Display.set({ mode = after(Display.modes(), state.mode) })
	end
	state = Display.get()
	Debug.log(
		"display",
		state.mode,
		state.width,
		state.height,
		"hdr",
		state.hdr,
		"available",
		state.hdr_available,
		"paper white",
		state.paper_white,
		"(F5 takes the next window mode, Shift+F5 the next resolution, Ctrl+F5 turns HDR on or off, Ctrl+Shift+F5 takes the next paper white)"
	)
	if not Display.save() then
		Debug.warn("could not save the display")
	end
end

return { update = update }
