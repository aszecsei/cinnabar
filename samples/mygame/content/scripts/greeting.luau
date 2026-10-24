--!strict
-- The text that scripts/hello.luau logs.
local greeting = {}

function greeting.line(count: number, frame: number): string
	return `{Game.greeting()} after {count} resumes, at frame {frame}`
end

return greeting
