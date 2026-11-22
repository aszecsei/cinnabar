# Scripts

Scripts start most cutscenes: from a trigger volume, a dialogue choice or the end of a fight. The `Cutscene` library plays a cutscene asset and gives it entities to possess. It returns a handle, through which the script controls the player and reads its state. The player sends its lifecycle to behaviours as events, and `wait_cutscene` waits for its end in a coroutine. `Sublevel` is the model ([World: Sublevels: Scripts](../world/sublevels.md#scripts)).

This document describes `lib/engine/cutscene/scripts.odin`. Read [Player](player.md) and [Bindings](bindings.md) first.

**In this document:** [Playing](#playing) · [The handle](#the-handle) · [Events](#events) · [Waiting](#waiting) · [Event keys](#event-keys) · [An example quest step](#an-example-quest-step) · [Registration](#registration)

## Playing

`Cutscene.play(cutscene, options?)` makes a [player](player.md) of a cutscene asset and returns its handle. `cutscene` is an `Asset`, as `Field.asset("cutscene")` gives it. The player loads in the next frame's `update`, and plays as soon as it is ready.

| Option | Type | What it does |
|---|---|---|
| `bindings` | `{ [string]: Entity }` | Gives an entity to each binding, by the binding's name. It overrides the asset's reference ([Bindings: Overrides](bindings.md#overrides)). One cutscene then works for every companion. A name that the cutscene does not have is logged, and play goes on. |
| `priority` | whole number | Sets the player's priority. A higher priority wins a field that two players write ([Player: Conflicts](player.md#conflicts)). The default is 0. |
| `start` | number | Sets where the player starts, in seconds on the cutscene's time. The player seeks there once it is ready, so only the event keys marked `fire_on_seek` before it fire. A time outside the range is clamped to it. |
| `wait_ready` | boolean | When true, the player loads and then holds in `"ready"` until `:play()` (the player's `load`). Load a cutscene a little before it plays, so that it starts without a hitch. |

- **Errors.** A key that is not an option raises an error, and so does a value of the wrong type. Then nothing plays.
- **A full state.** When all `MAX_PLAYERS` (32) slots hold players that have not ended, `play` raises an error.
- **The caller.** The entity of the behaviour that calls `play` is the player's caller, and gets its [events](#events). A main script or a script action has no caller.

## The handle

The handle is a `Cutscene`, a light userdata. It holds the player's slot and generation ([Player: Handles](player.md#handles)), and no pointer, so it survives a code reload. Two handles to one player are equal (`==`).

| Method | What it does |
|---|---|
| `:play()` | Plays a `"ready"` player. A loading player plays once it is ready. |
| `:pause()`, `:resume()` | Stops the player's time, and plays on from it. |
| `:stop()` | Ends the player without the rest of the cutscene. The player is `"finishing"` at once, and the next `update` gives the world back. |
| `:skip()` | Skips as the cutscene's skip policy says ([Skipping](skipping.md)). Returns whether the player skips. It returns false at a time that cannot be skipped. |
| `:state()` | `"loading"`, `"ready"`, `"playing"`, `"paused"`, `"skipping"`, `"finishing"`, `"restored"` or `"failed"`. |
| `:error()` | The reason for `"failed"`. One of: `"missing"`, `"not_a_cutscene"`, `"reference_missing"`, `"bad_nesting"`, `"binding_missing"`, `"spawn_failed"`. The log has the asset or the binding. |
| `:time()`, `:length()` | The player's time, and the cutscene's length, in seconds on the cutscene's time. Both are nil before `"ready"` and after the world is given back. |
| `:binding(name)` | The entity of a binding, by its name, while it is alive. This includes a spawned one. |

**Stale handles.** A handle is stale when its player is gone:
- A `"restored"` or `"failed"` player keeps its slot until a new player needs it. So `:state()` reports the end for a while, but not forever.
- A new level and a soft restart reset every player ([Player: Reset](player.md#reset)).

A stale handle's commands do nothing. `:state()` and the other readers return nil, and `:skip()` returns false.

The cooker type checks the methods against the `Cutscene` type in the definitions file. Its options are `CutsceneOptions`, and its states are `CutsceneState`.

## Events

A player sends its lifecycle to behaviours, through `script.send`. Each event goes to the entities of the cutscene's own bindings (not those of its sub-sequences) and to its caller. An entity that is both gets the event once.

| Event | When | Who gets it |
|---|---|---|
| `on_cutscene_started(cutscene)` | The player first plays or skips, from `"ready"`. A resume, and the fade in after a skip range, are not a start. | The possessed and spawned bindings' entities, and the caller |
| `on_cutscene_finished(cutscene, skipped)` | The player gave the world back and is `"restored"`. This includes a stop while it loaded. `skipped` is true when a skip took it to its end. | The possessed bindings' entities, and the caller. The spawned entities are gone. |
| `on_cutscene_failed(cutscene, reason)` | The player failed. `reason` is what `:error()` returns. | The possessed bindings' entities that had resolved, and the caller |

- **Suspended behaviours.** A binding that suspends `behaviours` holds its entity from `"loading"` on ([Possession: The settings](possession.md#the-settings)). A suspended behaviour gets no events, so it misses `on_cutscene_started`. It does get `on_cutscene_finished` and `on_cutscene_failed`: they are delivered in the next script phase, after the player resumed its behaviours.
- **What `skipped` means.** It is true only when a skip took the player to its end. It is false in these cases:
  - a `:stop()` during a skip's fade;
  - a skip to the end of a skip range, after which the cutscene plays to its end.
- **A native caller.** A cutscene that native code plays sends the same events to its bindings, without a caller.

## Waiting

`wait_cutscene(cutscene)` waits in a coroutine until the player is `"restored"` or `"failed"`, or its handle is stale. It returns whether a skip took the player to its end:

| How the wait ends | Returns |
|---|---|
| `"restored"` | The `skipped` of `on_cutscene_finished` |
| `"failed"`, or a stale handle | false |

- **Where it works.** It works only in a coroutine that the engine runs, as `wait` does ([Scripting: Behaviours: Coroutines](../scripting/behaviours.md#coroutines)).
- **Code reloads.** The waiting coroutine holds only the handle, and the poll that ends the wait is registered again after a code reload (`script.light_poll`). So a wait survives a reload.
- **`wait_until`.** `wait_until` works with `:state()` too, such as `wait_until(function() return c:state() == "ready" end)`.

## Event keys

An event track's keys call `on_<name>(args...)` on their binding's behaviours. A track without a binding sends them to every behaviour that has the handler, as `script.broadcast` does ([Tracks: Event tracks](tracks.md#event-tracks)). The binding must not suspend `behaviours`.

## An example quest step

A trigger volume starts the step. The companion that is with the player now plays the cutscene's Companion binding. The quest moves on when the cutscene ends, whether it was skipped or not.

```lua
local Quest = require("./quest")

local GateScene = Behaviour.define("GateScene", {
	cutscene = Field.asset("cutscene"),
	gate = Field.entity(),
})

function GateScene:on_trigger_enter(other)
	if self.played or other ~= Quest.player() then
		return
	end
	self.played = true
	self:start_coroutine(function()
		local c = Cutscene.play(self.cutscene, {
			bindings = { Companion = Quest.companion(), Gate = self.gate },
		})
		local skipped = wait_cutscene(c)
		if c:state() == "failed" then
			Debug.warn("the gate scene failed:", c:error())
		end
		Quest.advance("gate_opened", { skipped = skipped })
	end)
end

-- An event key on the cutscene's master event track, at the moment the gate opens.
function GateScene:on_gate_open()
	self.gate:send("open")
end

return GateScene
```

## Registration

`cutscene.register_scripts(runtime, state)` defines the following, which `game.register_scripts` calls, so each reload defines them again:
- `Cutscene.play` and `wait_cutscene`;
- the `Cutscene` handle's methods, as light userdata methods;
- its poll.

The definitions file declares them: `Cutscene.play` and `wait_cutscene` with the game's bindings, and the `Cutscene` type, `CutsceneOptions` and `CutsceneState` in the engine's part ([Scripting: Types and tooling](../scripting/tooling-and-hot-reload.md#types-and-tooling)).
