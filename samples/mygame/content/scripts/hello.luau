--!strict
-- The game's main script. The scheduler resumes it once per frame, and it stays suspended across code reloads of the
-- game DLL: its count keeps going, and Game.greeting shows the new code. Space reverses the large triangles' spin,
-- and Tab turns their Pulse off and on, unless the UI takes the keys, as the pause menu does. F9 and its modifiers change the render quality (see quality_keys.luau). It logs
-- gamepads that come and go, their A button, typed text and what an IME composes.
local greeting = require("./greeting")
local Pulse = require("./pulse")
local quality_keys = require("./quality_keys")
-- The guard scene's script actions exist once this has run (see ai/actions.luau).
require("./ai/actions")

local connected = { false, false, false, false }
local composition = ""

local function log_input()
	for pad = 1, #connected do
		local now = Input.gamepad_connected(pad)
		if now ~= connected[pad] then
			connected[pad] = now
			Debug.log("gamepad", pad, now and "connected" or "disconnected")
		end
		if Input.gamepad_was_pressed(pad, GamepadButton.A) then
			Debug.log("gamepad", pad, "pressed A")
		end
	end
	if Input.text ~= "" then
		Debug.log("typed", Input.text)
	end
	if Input.composition ~= composition then
		composition = Input.composition
		Debug.log("composing", composition)
	end
end

local count = 0
while true do
	count += 1
	if count % 120 == 0 then
		Debug.log(greeting.line(count, Game.frame()))
	end
	local keys = not Ui.wants_input()
	if keys and Input.was_pressed(Key.Space) then
		for _, triangle in World.query(Spin) do
			local spin = triangle:get(Spin)
			if spin then
				spin.speed = -spin.speed
			end
		end
		Debug.log("reversed the spin at", Time.time, "s")
	end
	if keys and Input.was_pressed(Key.Tab) then
		for _, triangle in World.query(Triangle) do
			local pulse = triangle:get(Pulse)
			if pulse then
				pulse.enabled = not pulse.enabled
			end
		end
	end
	log_input()
	quality_keys.update()
	coroutine.yield()
end
