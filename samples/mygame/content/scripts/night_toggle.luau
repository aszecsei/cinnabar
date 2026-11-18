--!strict
-- Turns the night scene's night sublevel on and off with N, unless the UI takes the keys (see
-- docs/world/sublevels.md#events). Sublevel.set_active queues the change for the next frame, and Sublevel.is_active
-- says what was asked at once, so a second press before the part is ready turns it off again. The sublevel's events
-- come to every behaviour that has their handlers, and this one logs them. Once the night is ready, the lantern that
-- the base refers to grows in over a second and sways; the reference reads nil while the part is not loaded.
local NightToggle = Behaviour.define("NightToggle", {
	-- The night part's lantern.
	lantern = Field.entity(),
	-- Seconds that the lantern takes to grow in once the night is ready.
	fade = Field.number(1),
})

local SUBLEVEL = "night"
local WORLD_UP = vector.create(0, 1, 0)

function NightToggle:start()
	self.shown = 0
	self.clock = 0
	self.ready = Sublevel.state(SUBLEVEL) == "ready"
end

local function describe(self, event: string)
	local lantern = self.lantern
	Debug.log("night", event, Sublevel.state(SUBLEVEL), "lantern in scene", if lantern then Scene.of(lantern) else "none")
end

function NightToggle:on_sublevel_loading(name: string)
	if name == SUBLEVEL then
		describe(self, "loading")
	end
end

function NightToggle:on_sublevel_ready(name: string)
	if name == SUBLEVEL then
		self.ready = true
		self.shown = 0
		describe(self, "ready")
	end
end

function NightToggle:on_sublevel_unloaded(name: string)
	if name == SUBLEVEL then
		self.ready = false
		describe(self, "unloaded")
	end
end

function NightToggle:on_sublevel_failed(name: string)
	if name == SUBLEVEL then
		self.ready = false
		describe(self, "failed")
	end
end

function NightToggle:update(dt: number)
	if not Ui.wants_input() and Input.was_pressed(Key.N) then
		local active = not Sublevel.is_active(SUBLEVEL)
		Sublevel.set_active(SUBLEVEL, active)
		Debug.log("night", if active then "asked for the night" else "asked for the day")
	end
	local lantern = self.lantern
	if not self.ready or not lantern then
		return
	end
	self.clock += dt
	self.shown = math.min(1, self.shown + dt / math.max(self.fade, 0.001))
	local transform = lantern.transform
	transform.scale = vector.create(0.4, 0.6, 0.4) * self.shown
	transform.rotation = Quaternion.angle_axis(10 * math.sin(self.clock * 2), WORLD_UP)
end

return NightToggle
