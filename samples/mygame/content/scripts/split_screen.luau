--!strict
-- Sets up the split screen (see docs/rendering/frame.md and scripts/follow_camera.luau): two views side by side, each with
-- its player's camera. C or a gamepad's Y claims the overview camera for every view, which blends in and shows one full-screen
-- view; it is released after a few seconds of real time, and the split comes back.
local SplitScreen = Behaviour.define("SplitScreen", {
	-- The cameras of the left and the right view.
	left = Field.entity(),
	right = Field.entity(),
	-- The camera that a claim shows full screen.
	overview = Field.entity(),
	-- Seconds of real time that a claim lasts.
	seconds = Field.number(3),
})

-- Views push at this priority, so a claim with a higher one covers them.
local VIEW_PRIORITY = 10
local CLAIM_PRIORITY = 100

local CLAIM_BLEND = { duration = 1, curve = "smooth", clock = "real", out = 1 }

local function pad_pressed(): boolean
	for pad = 1, 4 do
		if Input.gamepad_connected(pad) and Input.gamepad_was_pressed(pad, GamepadButton.Y) then
			return true
		end
	end
	return false
end

function SplitScreen:start()
	self.tokens = {} :: { number }
	self.claim = nil :: number?
	Views.set_layout("side_by_side")
	table.insert(self.tokens, Views.push(1, self.left, VIEW_PRIORITY, nil, self.entity))
	table.insert(self.tokens, Views.push(2, self.right, VIEW_PRIORITY, nil, self.entity))
end

-- The claim's own coroutine: it holds the claim for its seconds and then gives the split back.
function SplitScreen:hold_claim(token: number)
	wait_realtime(self.seconds)
	if self.claim == token then
		Views.release(token)
		self.claim = nil
	end
end

function SplitScreen:update(_dt: number)
	if Ui.wants_input() then
		return
	end
	local held = self.claim
	if held and not Views.is_claimed(held) then
		self.claim = nil
		held = nil
	end
	if held then
		return
	end
	if Input.was_pressed(Key.C) or pad_pressed() then
		local token = Views.claim(self.overview, CLAIM_PRIORITY, CLAIM_BLEND, self.entity)
		self.claim = token
		self:start_coroutine(self.hold_claim, token)
	end
end

function SplitScreen:on_camera_removed(token: number, reason: string)
	Debug.log("split screen: a camera was removed", token, reason)
end

function SplitScreen:on_destroy()
	local claim = self.claim
	if claim then
		Views.release(claim)
		self.claim = nil
	end
	for _, token in self.tokens do
		Views.pop(token)
	end
	self.tokens = {}
	Views.set_layout("single")
end

return SplitScreen
