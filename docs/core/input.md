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

The sample's `fly_camera.luau` is a behaviour on the camera of each of its scenes, to try a pad out: the left stick moves the camera, the right stick turns it, the triggers lift and lower it, and the right bumper hurries it.

## Actions

Games let the player remap controls, so scripts can name what they read. `Input_Actions` in `input_actions.odin` holds up to `MAX_INPUT_ACTIONS` (32) actions. Each has a name of at most `INPUT_ACTION_NAME_CAPACITY` (24) bytes, the `defaults` that the game gave it and the `current` bindings, each at most `MAX_ACTION_BINDINGS` (8). It has no strings or pointers, so it stays across a code reload; the script runtime keeps it as `Runtime.input_actions`.

**Bindings.** A `Binding` is a kind and a code: a `Key` (a mouse button is a key, so it can be bound), a `Gamepad_Button`, or a `Gamepad_Direction`. Its string is the kind and the name that scripts see, which is the enum's name without underscores: `key:W`, `key:Up`, `key:Escape`, `key:PageUp`, `pad:DpadUp`, `pad:Start`, `pad:A`, `pad:LeftStickUp`, `pad:RightTrigger`. Names are case sensitive. `binding_parse` reads a string and `binding_format` writes one into a buffer of `BINDING_FORMAT_CAPACITY` bytes.

**Queries.** `action_down`, `action_pressed`, `action_released` and `action_value` read an action by its index in `Input_Actions` (`input_actions_find` gives it). An action is down while any of its bindings is. `action_value` is 1 for a key or a button that is down, and for a stick direction or a trigger it is the push, 0 to 1, so a script can use a stick as an axis. With a pad, only that pad is read, with its buttons and directions and not the keys; without one, the keys and every pad are. `input_actions_define` makes an action, or, for a name that exists, updates its defaults and keeps its current bindings, so a hot reload does not undo what the player set. `input_actions_set` and `input_actions_reset` change the current bindings.

**Any key.** `any_pressed` gives the binding of a key, button or direction that went down since the previous frame, on the keyboard, the gamepads or both, so a settings screen can wait for "press the new key". It does not read the mouse.

**Persistence is the game's.** The engine saves no bindings. A game can keep `table.concat(Input.bindings(name), ",")` in its own save data and call `Input.set_bindings` when it starts.

**The ABI.** `Input` crosses the DLL boundary by value inside the type of `Platform_API.input`, and `layout.hash` does not follow procedure types. So `abi_hash` hashes `Input`'s layout too, and a DLL built with a different `Input` is refused.

UI navigation does not use actions (see [UI](../ui/design.md#input-and-focus)).

## Text and IME

`Input.text` is the characters typed since the previous frame, in UTF-8. It comes from the window's `WM_CHAR` messages, so it follows the keyboard layout, dead keys and Shift, and it has what an IME commits. Control characters are not text: Backspace, Enter and the like are keys in `core.Key`.

`Input.composition` is what an IME is composing, which is not text yet, and `composition_cursor` is the number of bytes of it before the cursor. It is state: it stays from frame to frame until the IME commits it, which moves it into `text`, or gives it up.

`Input_Text` holds its bytes inside the value, up to `INPUT_TEXT_CAPACITY`, because `Input` crosses the DLL boundary by value. What does not fit is dropped, a whole code point at a time.

Outside the editor, Windows draws the composition and the IME's candidates at their default position. The IME is on whenever the player has it on: there is no way to ask for text or to place the candidates, so a player whose IME is open types into it, and the keys that it takes do not reach the game as keys.

In shared mode the window gets no characters, so the viewport sends them as `Text` and `Composition` events ([Viewport](../editor/viewport.md)). The viewport takes the IME only while the game has the input, and shows the composition itself, because Avalonia does not show the system's composition window. A key that may type a character stays unhandled, or Avalonia drops the character, and `ShortcutCommand` keeps such a key from the editor's shortcuts.
