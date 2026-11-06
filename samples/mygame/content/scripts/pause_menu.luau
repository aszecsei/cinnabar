--!strict
-- The pause menu's behaviour, on the entity whose Ui_Document is ui/pause.ui (see docs/ui/design.md#scripts). Escape or a
-- gamepad's Start shows the menu and pauses the world; Resume, B or Escape hides it and runs the world again. Quality
-- takes the next render preset, as F9 does, and the name field greets whoever types into it.
local PauseMenu = Behaviour.define("PauseMenu")

-- after is the value after one in a list, or the first after the last or when the list does not have it.
local function after(list: { string }, value: string): string
	local i = table.find(list, value) or 0
	return list[i % #list + 1]
end

local function start_pressed(): boolean
	for pad = 1, 4 do
		if Input.gamepad_was_pressed(pad, GamepadButton.Start) then
			return true
		end
	end
	return false
end

function PauseMenu:show(visible: boolean)
	local document = self.entity:get(UiDocument)
	if document then
		document.visible = visible
	end
	Game.set_paused(visible)
	-- The Escape that closes the menu must not open it again in the same frame.
	self.changed = Time.frame
end

function PauseMenu:start()
	Ui.bind(self.entity, "name", "stranger")
end

function PauseMenu:update(_dt: number)
	Ui.bind(self.entity, "quality", Render.quality().preset)
	local document = self.entity:get(UiDocument)
	if document and not document.visible and self.changed ~= Time.frame and (Input.was_pressed(Key.Escape) or start_pressed()) then
		self:show(true)
	end
end

function PauseMenu:on_resume(_id: string)
	self:show(false)
end

function PauseMenu:on_quality(_id: string)
	Render.set_quality({ preset = after(Render.presets(), Render.quality().preset) })
	if not Render.save_quality() then
		Debug.warn("could not save the quality")
	end
end

function PauseMenu:on_name_changed(_id: string, text: string)
	Ui.bind(self.entity, "name", text ~= "" and text or "stranger")
end

function PauseMenu:on_name_submitted(_id: string, text: string)
	Debug.log("the pause menu's name is", text)
end

return PauseMenu
