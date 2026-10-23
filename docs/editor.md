# Editor

The editor is a separate C# application with native Windows UI. It runs `host.exe` as a child process and controls it through the editor link. See [Architecture](architecture.md#editor) for the overview.

## Processes

- **Host:** the editor starts the host inside a Windows Job Object, so the host exits when the editor exits. If the host crashes, the editor stays up, reports the crash and offers to restart the host.
- **Cook daemon:** the editor also starts the cook daemon. It asks the daemon to create, move and re-import assets, and the daemon keeps each asset's `.meta` file with it.
- **Standalone:** `host.exe` also runs without the editor, in its own window.

## Editor link

The editor link is a message connection between the editor and the host. It uses TCP. Locally it runs over loopback; later, the same protocol connects to a host on another machine or a console.

- The host serves the link by calling the editor procedures in `Game_API`: enumerate entities, describe and edit component fields, and run editor commands.
- **Introspection goes through the DLL.** Type info for game-side types exists only in the DLL's image. The editor never reflects over game types itself.
- Messages identify component types by their [stable ID](world.md#ecs).

## Viewport

- The host renders the game into a D3D12 shared texture and signals a shared fence. The editor opens both handles and displays the texture in its viewport panel.
- The editor sends input to the host over the editor link.
- The editor does not reparent the host's window into its own. Windows attaches the input queues of a cross-process parent and child window, so a stall in the game would freeze the editor UI.
