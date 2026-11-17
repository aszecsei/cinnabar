--!strict
-- Logs the streaming events that its entity gets: the World_Streamer's, which has this behaviour (see
-- docs/world/scenes.md#streaming). Each line has the scene's number and Scene.state, which is "loading" while the scene is
-- not shown, "ready" once it is, and nil once it is gone.
local StreamLog = Behaviour.define("StreamLog", {})

local function describe(event: string, number: number, scene: Asset)
	Debug.log("stream", event, number, scene, Scene.state(number) or "gone")
end

function StreamLog:on_scene_loading(number: number, scene: Asset)
	describe("loading", number, scene)
end

function StreamLog:on_scene_ready(number: number, scene: Asset)
	describe("ready", number, scene)
end

function StreamLog:on_scene_unloaded(number: number, scene: Asset)
	describe("unloaded", number, scene)
end

function StreamLog:on_scene_failed(number: number, scene: Asset)
	describe("failed", number, scene)
end

return StreamLog
