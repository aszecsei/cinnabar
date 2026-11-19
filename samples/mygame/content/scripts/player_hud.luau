--!strict
-- The HUD of one player of the split screen, on the entity whose Ui_Document is ui/hud_player.ui and whose view is that
-- player's (see docs/ui/design.md#scripts): it binds the player's number and how far along +x the player has walked.
local PlayerHud = Behaviour.define("PlayerHud", {
	-- The player's entity, which has scripts/player.luau.
	player = Field.entity(),
	-- The label that this document shows: the player's number.
	label = Field.number(1),
})

function PlayerHud:start()
	local player: Entity? = self.player
	local transform = player and player.transform
	self.origin = transform and transform.position or WorldPosition.origin
end

function PlayerHud:update(_dt: number)
	local player: Entity? = self.player
	local transform = player and player.transform
	local distance = 0
	if transform then
		distance = (transform.position - self.origin).x
	end
	Ui.bind(self.entity, "player", self.label)
	Ui.bind(self.entity, "distance", math.floor(distance + 0.5))
end

return PlayerHud
