# Processes and projects

The processes the editor runs, why it is built with Avalonia, the C# projects and what each owns, and how the editor recovers from a crash of any of its processes.

**In this document:** [Processes](#processes) · [UI framework](#ui-framework) · [Projects](#projects) · [Crash recovery](#crash-recovery)

## Processes

- **Host:** the editor starts the host inside a Windows Job Object, so the host exits when the editor exits. If the host crashes, the editor stays up, reports the crash and offers to restart the host (see [Crash recovery](#crash-recovery)).
- **Cook daemon:** when its window opens, the editor also starts the cook daemon in a Job Object, with `--link <port>` for the cook link, and the cache, the definition file, DXC, the shader include directories and the content roots that its own command line names (`--cache`, `--definitions`, `--dxc`, `--include` and `--root`; without roots, the sample's and the engine's) (see [Content pipeline](../content/daemon-and-operations.md#cook-daemon)). The daemon cooks what changes, sends its index and problems to the editor, and does the content browser's asset operations. It keeps each asset's `.meta` file with it. The Restart Cook Daemon command starts it again. `ChildProcess` in `Cinnabar.Editor.Content` runs both children in their Job Objects.
- **Standalone:** `host.exe` also runs without the editor, in its own window.
- **Arguments:** the editor starts the host in its own directory with the game, `--content <dir>` for the loose cache that the daemon writes and `--project <file>` for the project's settings, so the editor's working directory never matters to it, and `--shared <name>` for the viewport (see [GPU](../gpu/presentation.md#presentation)), `--link <port>` for the editor link, and `--adapter <luid>` (see [Viewport](viewport.md#viewport)). Run Game starts a second host the same way, without the shared mode and the link.
- **The editor's command line:** `--host`, `--game` and `--scene`, and for the cook daemon `--cook <cook.exe>`, `--cache <dir>`, `--definitions <file>` and `--root <name>=<dir>`, which can repeat. Each has the repository's default, relative to the repository root, which the editor finds above its own executable (see [Building and running](../overview/building-and-running.md#build-layout)), and `just edit` passes them all. `--material <file>`, which can repeat, opens a material or a material function in the material editor once the cook daemon's index has it, and `--effect <file>` an effect in an effect preview.

## UI framework

The editor uses Avalonia on .NET 10, not WPF. The deciding factor is the viewport.

- **WPF cannot show a D3D12 texture directly.** `D3DImage` takes only D3D9Ex surfaces, so each frame would go from D3D12 through D3D11 to a legacy shared texture and into D3D9Ex: an extra copy, BGRA8 only, and pacing tied to WPF's render thread. A child swapchain in an `HwndHost` avoids the copy, but WPF content cannot draw over it (the airspace problem), so the tool palette and the stats overlay would each need their own window.
- **Avalonia imports external GPU images into its compositor.** `ICompositionGpuInterop` imports D3D11 textures, so the viewport is an ordinary composited control, and other controls draw over it. On Windows the import needs a keyed mutex, which a D3D12 resource cannot have, so the editor copies each frame once (see [Viewport](viewport.md#viewport)).
- **What WPF has that Avalonia lacks** is a mature ribbon and a wider set of third-party controls. The editor builds its own ribbon (see [Ribbon](shell-and-panels.md#ribbon)), and it would build its own property grid in either framework, because the types come from the DLL over the link and not from CLR objects.
- Avalonia also runs on other platforms, though the editor runs on Windows only.

## Projects

The editor is in `src/editor`. Only the application project references Avalonia. The others are plain .NET libraries, so tests run without UI.

| Project | Responsibility |
|---|---|
| `Cinnabar.Editor.Link` | The link client: the connection, framing, the wire format, and the messages that the generator writes from the editor link's and the cook link's schemas. |
| `Cinnabar.Editor.Link.Generator` | The Roslyn source generator that turns each link's schema into C# records with their readers and writers, each link in its own namespace. |
| `Cinnabar.Editor.Model` | The type registry and the mirror of the host's world: entities, hierarchy, and the watched field values. It is updated only from link events. |
| `Cinnabar.Editor.Document` | Scenes: the scene file's reader and writer, the snapshot that the host loads, operations, the undo stack, save, and autosave. Materials: the material file's reader and writer, the material document with its undo, and the catalog that gives each node its pins. |
| `Cinnabar.Editor.Content` | The cook daemon's process and its cook link, the mirror of the daemon's asset index, and the asset operations. It is updated only from cook link events. |
| `Cinnabar.Editor.Tools` | The viewport's tools: the editor camera, the gizmo's hit test and drag math, snapping, and the pose edits that a drag makes. The node canvas's geometry and hit test. |
| `Cinnabar.Editor.Commands` | The command registry. The ribbon, menus, shortcuts and the command palette all run commands from it. |
| `Cinnabar.Editor` | The Avalonia application: the shell, docking, the ribbon, the panels and the viewport. |
| `Cinnabar.Editor.Tests` | Tests for the libraries and for the shell, which has no controls of its own, so a test can build one without a window. |

`just editor` builds the solution with `dotnet build`, `just edit` builds everything and starts the editor with the game's `scenes/main.scene`, and `just test` runs the editor's tests with the engine's. Build output goes to `build/obj/dotnet`. The editor's settings are in `%LOCALAPPDATA%\cinnabar\editor`.

## Crash recovery

- **Host crash:** the document is in the editor, so nothing is lost. The editor reports the crash with the end of the host's log, and restarts the host. The link connects again, the editor sends the snapshot, and the camera and the selection stay.
- **Editor crash:** the editor saves each dirty scene to `build/obj/editor/autosave/` every 30 s, and when a transaction ends if 30 s have passed. An autosave is named for its scene's file and a hash of its full path. When a scene opens and its autosave is newer than its file, the editor offers to restore it. Restoring makes the scene dirty, because its file lacks the changes. Saving the scene, undoing back to its file, choosing not to save it, or discarding the offer deletes the autosave.
- **Cook daemon crash:** the editor reports it in the console and starts the daemon again, which scans the roots and sends a new snapshot. A daemon that exits less than 10 s after it starts, as when another cook holds the cache, is not started again, so the editor does not start it over and over. The status bar shows its exit code, and Restart Cook Daemon starts it.
- **Code reload:** the host sends the types again. **Soft restart:** the host also sends a restart event, and the editor sends the snapshot again (see [Document model](document-and-scenes.md#document-model)).
