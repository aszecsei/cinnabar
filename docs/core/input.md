# Input

How window messages and gamepads become the `core.Input` that the game and scripts read, and how the editor's input takes the same path.

`core` translates the window's keyboard and mouse messages into `core.Input`: the keys and buttons that are down, the ones pressed or released since the previous frame, and the mouse position, delta and wheel. `Platform_API.input` gives the state at the start of the frame. A key that goes down and up within one frame is in both `pressed` and `released`. Losing focus releases every key and every gamepad button, and ends any IME composition. In shared mode the window is hidden, so the input is empty until the editor link sends input: `core.queue_input` takes `Input_Event`s from the host, and the next frame applies them after the window's own messages.

`core.Key` is the one enum of keys and mouse buttons. Scripts see it as `Key` ([Scripting](../scripting/api.md#engine-libraries)), and the editor's `Editor_Input` messages carry its values ([Editor](../editor/document-and-scenes.md#modes)).

## Gamepads

`Input.gamepads` has `MAX_GAMEPADS` slots, each with whether a pad is `connected`, the `Gamepad_Button`s that are `down`, `pressed` and `released`, and the `Gamepad_Axis` values. A stick's axes run from -1 to 1, positive right and up, and a trigger's from 0 to 1. The dead zones are XInput's documented ones, and `input_gamepad_set` applies them for both the window and the editor: the stick's dead zone is radial, and the axes rescale so that they start from 0 at its edge and still reach 1.

The pads come from XInput, so a pad that XInput does not see, such as a PlayStation or a Switch pad without a mapper like Steam Input, is not a gamepad here. `Gamepad_Buttons` is the bits of XInput's `wButtons`.

A pad can be plugged in or pulled out at any time. `gamepad_poll` reads each connected slot in every frame, and one empty slot in turn every 250 ms, because `XInputGetState` on an empty slot can take milliseconds. So a new pad is found within a second. A pad that goes releases its buttons, its axes go to 0, and its slot is no longer connected.

XInput answers any process, so the window polls only while it is the foreground window. Losing focus keeps the pads connected.

In shared mode the hidden window is never the foreground window, so the host does not poll. The editor polls XInput instead, while the viewport has focus in play mode and the editor's window is active, and sends what changed as `Gamepad` events. The host disconnects every slot when the link drops.

The sample's `fly_camera.luau` is a behaviour on the camera of each of its scenes, to try a pad out: the left stick moves the camera, the right stick turns it, the triggers lift and lower it, and the right bumper hurries it.

## Text and IME

`Input.text` is the characters typed since the previous frame, in UTF-8. It comes from the window's `WM_CHAR` messages, so it follows the keyboard layout, dead keys and Shift, and it has what an IME commits. Control characters are not text: Backspace, Enter and the like are keys in `core.Key`.

`Input.composition` is what an IME is composing, which is not text yet, and `composition_cursor` is the number of bytes of it before the cursor. It is state: it stays from frame to frame until the IME commits it, which moves it into `text`, or gives it up.

`Input_Text` holds its bytes inside the value, up to `INPUT_TEXT_CAPACITY`, because `Input` crosses the DLL boundary by value. What does not fit is dropped, a whole code point at a time.

Outside the editor, Windows draws the composition and the IME's candidates at their default position. The IME is on whenever the player has it on: there is no way to ask for text or to place the candidates, so a player whose IME is open types into it, and the keys that it takes do not reach the game as keys.

In shared mode the window gets no characters, so the viewport sends them as `Text` and `Composition` events ([Viewport](../editor/viewport.md)). The viewport takes the IME only while the game has the input, and shows the composition itself, because Avalonia does not show the system's composition window. A key that may type a character stays unhandled, or Avalonia drops the character, and `ShortcutCommand` keeps such a key from the editor's shortcuts.
