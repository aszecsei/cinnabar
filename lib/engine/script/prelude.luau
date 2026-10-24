--!strict
-- The engine prelude: Behaviour.define and Field. The runtime runs it once at init, and tools/cook runs it to read the
-- fields of each behaviour, so both see the same classes. native holds the engine's procedures. The cooker's raise an
-- error, because a module's top level must not call into the engine. See docs/scripting.md#behaviours.
local native = ...

local Field = {}

local function field(kind: string, default: any)
	return table.freeze({ __field = kind, default = default })
end

function Field.number(default: number?)
	return field("number", default or 0)
end

function Field.boolean(default: boolean?)
	return field("boolean", default or false)
end

function Field.string(default: string?)
	return field("string", default or "")
end

function Field.vector(default: vector?)
	return field("vector", default or vector.zero)
end

function Field.entity()
	return field("entity", nil)
end

-- The names that every instance has, so a behaviour cannot declare them.
local RESERVED = { entity = true, transform = true, enabled = true }

-- The methods that every instance has.
local base = {
	start_coroutine = native.start_coroutine,
	stop_coroutine = native.stop_coroutine,
	stop_all_coroutines = native.stop_all_coroutines,
}

local Behaviour = {}

-- Behaviour.define makes a behaviour class. An instance's metatable is its class. Methods are found in the class
-- first, so a call does not reach the engine. enabled is never stored in the instance, so its reads and writes reach
-- the engine, which runs on_enable and on_disable.
function Behaviour.define(name: string, fields: { [string]: any }?)
	if type(name) ~= "string" then
		error("Behaviour.define takes the class name first", 2)
	end
	local schema = {}
	for key, spec in fields or {} do
		if type(key) ~= "string" or type(spec) ~= "table" or spec.__field == nil then
			error(`field {key} of {name} needs a Field value, such as Field.number(0)`, 2)
		end
		if RESERVED[key] then
			error(`{name} cannot have a field named {key}`, 2)
		end
		schema[key] = spec
	end

	local class = {}
	class.__behaviour = name
	class.__fields = table.freeze(schema)
	class.__index = function(self, key)
		local value = rawget(class, key)
		if value ~= nil then
			return value
		end
		if key == "enabled" then
			return native.get_enabled(self)
		end
		return base[key]
	end
	class.__newindex = function(self, key, value)
		if key == "enabled" then
			native.set_enabled(self, value)
		elseif key == "entity" or key == "transform" then
			error(`{key} is read-only`, 2)
		else
			rawset(self, key, value)
		end
	end
	return class
end

return table.freeze(Behaviour), table.freeze(Field)
