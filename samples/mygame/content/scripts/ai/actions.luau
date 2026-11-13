--!strict
-- The guard scene's script actions. An action exists once its module has run, so the main script requires this (see
-- docs/ai/agents.md#script-actions).
require("./bark")
require("./look_around")
require("./next_patrol_point")
require("./patrol")
require("./keep_distance")
require("./flee")

return nil
