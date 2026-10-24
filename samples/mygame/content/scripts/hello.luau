--!strict
-- The game's main script. The scheduler resumes it once per frame, and it stays suspended across code reloads of the
-- game DLL: its count keeps going, and Game.greeting shows the new code. Space reverses the large triangles' spin,
-- and Tab turns their Pulse off and on.
local greeting = require("./greeting")
local Pulse = require("./pulse")

local count = 0
while true do
	count += 1
	if count % 120 == 0 then
		Debug.log(greeting.line(count, Game.frame()))
	end
	if Input.was_pressed(Key.Space) then
		for _, triangle in World.query(Spin) do
			local spin = triangle:get(Spin)
			if spin then
				spin.speed = -spin.speed
			end
		end
		Debug.log("reversed the spin at", Time.time, "s")
	end
	if Input.was_pressed(Key.Tab) then
		for _, triangle in World.query(Triangle) do
			local pulse = triangle:get(Pulse)
			if pulse then
				pulse.enabled = not pulse.enabled
			end
		end
	end
	coroutine.yield()
end
