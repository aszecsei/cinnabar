--!strict
-- A coroutine that the game resumes once per frame. It stays suspended across code reloads of the game DLL: its count
-- keeps going, and Game.greeting shows the new code.
local greeting = require("./greeting")

local count = 0
while true do
	count += 1
	if count % 120 == 0 then
		Debug.log(greeting.line(count, Game.frame()))
	end
	coroutine.yield()
end
