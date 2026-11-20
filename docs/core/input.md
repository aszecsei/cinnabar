# Input

How window messages and gamepads become the `core.Input` that the game and scripts read, and how the editor's input takes the same path.

`core` translates the window's keyboard and mouse messages into `core.Input`: the keys and buttons that are down, the ones pressed or released since the previous frame, and the mouse position, delta and wheel. `Platform_API.input` gives the state at the start of the frame. A key that goes down and up within one frame is in both `pressed` and `released`. Losing focus releases every key and every gamepad button, and ends any IME composition. In shared mode the window is hidden, so the input is empty until the editor link sends input: `core.queue_input` takes `Input_Event`s from the host, and the next frame applies them after the window's own messages.

`core.Key` is the one enum of keys and mouse buttons. Scripts see it as `Key` ([Scripting](../scripting/api.md#engine-libraries)), and the editor's `Editor_Input` messages carry its values ([Editor](../editor/document-and-scenes.md#modes)).

## Gamepads

`Input.gamepads` has `MAX_GAMEPADS` slots, each with whether a pad is `connected`, the `Gamepad_Button`s that are `down`, `pressed` and `released`, and the `Gamepad_Axis` values. A stick's axes run from -1 to 1, positive right and up, and a trigger's from 0 to 1. The dead zones are XInput's documented ones, and `input_gamepad_set` applies them for both the window and the editor: the stick's dead zone is radial, and the axes rescale so that they start from 0 at its edge and still reach 1.

**Stick directions.** A stick pushed one way and a trigger pulled are also digital inputs: `Gamepad_Direction` has the four ways of each stick (`Left_Stick_Up` is the stick pushed up, positive on its Y axis) and the two triggers. `Gamepad` has `direction_down`, `direction_pressed` and `direction_released` for them, which `input_gamepad_set` derives from the axes after the dead zones, so the window and the editor give the same. A direction engages when its axis passes `STICK_ENGAGE` (0.5), and lets go when it falls under `STICK_RELEASE` (0.35), so a stick near the edge does not chatter. The UI's navigation uses the same two values. A pad that goes, or a window that loses focus, releases its directions.

The pads come from XInput, so a pad that XInput does not see, such as a PlayStation or a Switch pad without a mapper like Steam Input, is not a gamepad here. `Gamepad_Buttons` is the bits of XInput's `wButtons`.

A pad can be plugged in or pulled out at any time. `gamepad_poll` reads each connected slot in every frame, and one empty slot in turn every 250 ms, because `XInputGetState` on an empty slot can take milliseconds. So a new pad is found within a second. A pad that goes releases its buttons, its axes go to 0, and its slot is no longer connected.

XInput answers any process, so the window polls only while it is the foreground window. Losing focus keeps the pads connected.

In shared mode the hidden window is never the foreground window, so the host does not poll. The editor polls XInput instead, while the viewport has focus in play mode and the editor's window is active, and sends what changed as `Gamepad` events. The host disconnects every slot when the link drops.

A game vibrates a pad with `Platform_API.gamepad_rumble(slot, low, high, seconds)`, which scripts call as `Input.gamepad_rumble(pad, low, high, seconds)`. `low` is the low-frequency motor, the left one, and `high` is the high-frequency motor, the right one. Each runs from 0 to 1, and `seconds` is cut to `MAX_RUMBLE_SECONDS` (10), so a game that stops asking leaves a pad that stops by itself. A new call replaces the slot's rumble, and a call of 0 seconds ends it. The host owns the motors, not the game: `Platform.rumble` holds one `Maybe(Rumble)` per slot, so no rumble is `nil` and not a zero command, and the motors stop even if the game's DLL is unloaded or fails. Once a frame, in `begin_frame`, `rumble_update` ends the rumbles that are over and returns the motor speeds of the slots whose speeds differ from what `Rumbles.sent` says each pad was last told. Only those go to `XInputSetState`, and `rumble_update` is the only writer of `sent`. A pad's rumble is dropped, and its motors told to stop, when the pad is gone and when the window is not the foreground window, and it does not come back with the focus. A soft restart and `core.shutdown` stop every motor.

Rumble does not reach a pad while the game plays in the editor. The hidden window of shared mode is never the foreground window, so the host drops every rumble, and the editor sends the pad readings one way only, as `Gamepad` events, with no message back to the pad.

The sample's `fly_camera.luau` is a behaviour on the camera of each of its scenes, to try a pad out: the left stick moves the camera, the right stick turns it, the triggers lift and lower it, and the right bumper hurries it.

## Actions

Games let the player remap controls, so scripts can name what they read. `Input_Actions` in `input_actions.odin` holds up to `MAX_INPUT_ACTIONS` (32) actions. Each has a name of at most `INPUT_ACTION_NAME_CAPACITY` (24) bytes, the `defaults` that the game gave it and the `current` bindings, each at most `MAX_ACTION_BINDINGS` (8). It has no strings or pointers, so it stays across a code reload; the script runtime keeps it as `Runtime.input_actions`.

**Bindings.** A `Binding` is a kind and a code: a `Key` (a mouse button is a key, so it can be bound), a `Gamepad_Button`, or a `Gamepad_Direction`. Its string is the kind and the name that scripts see, which is the enum's name without underscores: `key:W`, `key:Up`, `key:Escape`, `key:PageUp`, `pad:DpadUp`, `pad:Start`, `pad:A`, `pad:LeftStickUp`, `pad:RightTrigger`. Names are case sensitive. `binding_parse` reads a string and `binding_format` writes one into a buffer of `BINDING_FORMAT_CAPACITY` bytes.

**Queries.** `action_down`, `action_pressed`, `action_released` and `action_value` read an action by its index in `Input_Actions` (`input_actions_find` gives it). An action is down while any of its bindings is. `action_value` is 1 for a key or a button that is down, and for a stick direction or a trigger it is the push, 0 to 1, so a script can use a stick as an axis. With a pad, only that pad is read, with its buttons and directions and not the keys; without one, the keys and every pad are. `input_actions_define` makes an action, or, for a name that exists, updates its defaults and keeps its current bindings, so a hot reload does not undo what the player set. `input_actions_set` and `input_actions_reset` change the current bindings.

**Any key.** `any_pressed` gives the binding of a key, button or direction that went down since the previous frame, on the keyboard, the gamepads or both, so a settings screen can wait for "press the new key". It does not read the mouse.

**Persistence is the game's.** The engine saves no bindings. A game can keep `table.concat(Input.bindings(name), ",")` in its own save data and call `Input.set_bindings` when it starts.

**The ABI.** `Input` crosses the DLL boundary by value inside the type of `Platform_API.input`, and `layout.hash` does not follow procedure types. So `abi_hash` hashes `Input`'s layout too, and a DLL built with a different `Input` is refused.

UI navigation does not use actions (see [UI](../ui/design.md#input-and-focus)).

### Contexts

A cutscene must stop the player from moving and attacking, but still let the player skip, pause and open menus. An input context is a named set of actions that it lets through. Each player has a stack of contexts. `Input_Contexts` in `input_contexts.odin` holds them inside `Input_Actions`, so the queries above read through them. Its zero value has no pushes, and then every action reads as it would without contexts.

- **Contexts.** `input_contexts_define` makes a context with a mode and a set of actions:
  - `Only` allows the actions that it names and blocks the others;
  - `Pass` allows the actions that it names, and lets the context below it decide for the others;
  - `All` allows every action.

  `default` is under every stack and allows every action. The game cannot define it. A game has at most `MAX_INPUT_CONTEXTS` (16) other contexts. Scripts define contexts as they define actions (`Input.define_context`), and a context can name only actions that are defined. A new definition of a context that is on a stack changes the stack at once.
- **Stacks.** A player is a gamepad slot, and the keys are the first player's. `input_contexts_push` puts a context on the stacks of a set of players and gives an `Input_Context_Token`. `input_contexts_pop` takes that push off, wherever it is in the stacks. So a cutscene that ends early gives back the input, even if a menu pushed after it. A token is never given twice, so a pop through a stale token does nothing. The stacks share one array of at most `MAX_INPUT_CONTEXT_PUSHES` (32) pushes, in push order. A push keeps who pushed it, for the editor, and the behaviour that owns it. One proc, `change_stack`, changes the pushes and the definitions.
- **Reads.** The top push on a player's stack decides for that player. `Only` and `All` decide alone. `Pass` decides for the actions that it names and passes the others down. A blocked action is up, not pressed and not released, with a value of 0. A query with a pad reads through that pad's stack. A query without a pad reads each player through its own stack: the keys and pad 1 through the first player's, and each other pad through its own.
- **Held actions.** When a change of the stacks allows an action again, the action is held for each player that it was blocked for (`Input_Contexts.held`). A held action is down while its bindings are down, but it is not pressed or released. `input_contexts_settle` lets it go at the first input where its bindings are quiet: none down, pressed or released. So a key that is down when a cutscene ends does not fire. A tap during the cutscene does not fire either, when a later fixed tick gets its edges (see [Time](../world/time.md#fixed-and-variable-rate)). The script runtime settles when it sets its input and when a phase or a tick ends. It counts the edges that wait for the next tick as active, so a tap stays held until a tick has had it. The settle at the end lets go of an action whose bindings were quiet when its context went, so a press in the next frame is a press.
- **Owners.** A push from a script belongs to the code that made it: a behaviour, by its callbacks and coroutines; a script action, by its callbacks and coroutines; or one run of a main script. When the owner ends, its pushes are popped: a behaviour when it is destroyed, an action when it stops, and a main script when it ends, stops or restarts after a hot reload. Each script phase also pops the pushes of owners that are gone, so a lost handle cannot lock the input. A push from code that nothing owns, such as the `wait_until` predicate of a main script or an action, must pop itself. A new script VM starts with empty stacks.
- **The editor** shows the pushes in the Resource Monitor, the top first, with each pusher and its pads (see [Editor](../editor/shell-and-panels.md#resource-monitor)).

Contexts do not change UI navigation. A modal document takes the UI's input, not actions, and scripts still ask `Ui.wants_input()`.

## Text and IME

`Input.text` is the characters typed since the previous frame, in UTF-8. It comes from the window's `WM_CHAR` messages, so it follows the keyboard layout, dead keys and Shift, and it has what an IME commits. Control characters are not text: Backspace, Enter and the like are keys in `core.Key`.

`Input.composition` is what an IME is composing, which is not text yet, and `composition_cursor` is the number of bytes of it before the cursor. It is state: it stays from frame to frame until the IME commits it, which moves it into `text`, or gives it up.

`Input_Text` holds its bytes inside the value, up to `INPUT_TEXT_CAPACITY`, because `Input` crosses the DLL boundary by value. What does not fit is dropped, a whole code point at a time.

Outside the editor, Windows draws the composition and the IME's candidates at their default position. The IME is on whenever the player has it on: there is no way to ask for text or to place the candidates, so a player whose IME is open types into it, and the keys that it takes do not reach the game as keys.

In shared mode the window gets no characters, so the viewport sends them as `Text` and `Composition` events ([Viewport](../editor/viewport.md)). The viewport takes the IME only while the game has the input, and shows the composition itself, because Avalonia does not show the system's composition window. A key that may type a character stays unhandled, or Avalonia drops the character, and `ShortcutCommand` keeps such a key from the editor's shortcuts.
