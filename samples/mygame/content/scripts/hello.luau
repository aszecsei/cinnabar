--!strict
-- A coroutine that the game resumes once per frame. It stays suspended across code reloads of the game DLL: its count
-- keeps going, and Game.greeting shows the new code. Space reverses the large triangles' spin.
local greeting = require("./greeting")

local count = 0
while true do
	count += 1
	if count % 120 == 0 then
		Debug.log(greeting.line(count, Game.frame()))
	end
	if Input.was_pressed(Key.Space) then
		for _, triangle in World.query(Spin) do
			local spin = triangle:get(Spin)
			spin.speed = -spin.speed
		end
		Debug.log("reversed the spin at", Time.time, "s")
	end
	coroutine.yield()
end
