# Input

How window messages become the `core.Input` that the game and scripts read, and how the editor's input takes the same path.

`core` translates the window's keyboard and mouse messages into `core.Input`: the keys and buttons that are down, the ones pressed or released since the previous frame, and the mouse position, delta and wheel. `Platform_API.input` gives the state at the start of the frame. A key that goes down and up within one frame is in both `pressed` and `released`. Losing focus releases every key. In shared mode the window is hidden, so the input is empty until the editor link sends input: `core.queue_input` takes `Input_Event`s from the host, and the next frame applies them after the window's own messages.

`core.Key` is the one enum of keys and mouse buttons. Scripts see it as `Key` ([Scripting](../scripting/api.md#engine-libraries)), and the editor's `Editor_Input` messages carry its values ([Editor](../editor/document-and-scenes.md#modes)).
