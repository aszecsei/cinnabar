# Processes and projects

The processes the editor runs, the game projects that it opens, why it is built with Avalonia, the C# projects and what each owns, and how the editor recovers from a crash of any of its processes.

**In this document:** [Processes](#processes) · [Projects](#projects) · [UI framework](#ui-framework) · [C# projects](#c-projects) · [Crash recovery](#crash-recovery)

## Processes

- **Host:** the editor starts the host inside a Windows Job Object, so the host exits when the editor exits. If the host crashes, the editor stays up, reports the crash and offers to restart the host (see [Crash recovery](#crash-recovery)).
- **Cook daemon:** when its window opens, the editor also starts the cook daemon in a Job Object, with `--link <port>` for the cook link, and the cache, the definition file, DXC, the shader include directories and the content roots that its own command line names (`--cache`, `--definitions`, `--dxc`, `--include` and `--root`; without roots, the sample's and the engine's) (see [Content pipeline](../content/daemon-and-operations.md#cook-daemon)). The daemon cooks what changes, sends its index and problems to the editor, and does the content browser's asset operations. It keeps each asset's `.meta` file with it. The Restart Cook Daemon command starts it again. `ChildProcess` in `Cinnabar.Editor.Content` runs both children in their Job Objects.
- **Standalone:** `host.exe` also runs without the editor, in its own window.
- **Arguments:** the editor starts the host in its own directory with the game, `--content <dir>` for the loose cache that the daemon writes and `--project <file>` for the project's settings, so the editor's working directory never matters to it, and `--shared <name>` for the viewport (see [GPU](../gpu/presentation.md#presentation)), `--link <port>` for the editor link, and `--adapter <luid>` (see [Viewport](viewport.md#viewport)). Run Game starts a second host the same way, without the shared mode and the link.
- **The editor's command line:** a project's folder (see [Projects](#projects)), or `--host`, `--game` and `--scene`, and for the cook daemon `--cook <cook.exe>`, `--cache <dir>`, `--definitions <file>` and `--root <name>=<dir>`, which can repeat. Each has the repository's default, relative to the repository root, which the editor finds above its own executable (see [Building and running](../overview/building-and-running.md#build-layout)), and `just edit` passes them all. `--material <file>`, which can repeat, opens a material or a material function in the material editor once the cook daemon's index has it, `--effect <file>` an effect in an effect preview, `--animation-graph <file>` an animation graph in its editor, and `--ui-document <file>` a UI document in the UI editor.

## Projects

A game is a project: a folder with `project.settings` and `content/`, anywhere (see [Getting started](../overview/getting-started.md#a-project)). The editor opens one project, and runs `cinnabar.exe` from the engine's checkout to make, build and export it, so the editor and the command line build the same files.

- **The engine's checkout** is `CINNABAR_ROOT`, or the folder above the editor's executable that has `lib/engine/content` (`ProjectLayout.EngineRoot`). Its `build/dev` has the host and `standard.dll`, and its `build/tools` has the cooker and `cinnabar.exe`.
- **Starting:** `editor` with no arguments shows the welcome window. `editor <project>`, with a folder or its `project.settings`, shows it too, and opens the project at once. The full command line, which `just edit` and `cinnabar edit` give, opens the editor without it.
- **The welcome window** (`Projects/WelcomeWindow.cs`) has New Project, Open Project and the recent projects. Opening a project runs `cinnabar build <project>` and shows its output. When it succeeds, the editor opens with `EditorOptions.ForProject`, and the welcome window closes. A build that fails stays in the window, with its output, as when the project's Odin does not compile.
- **New Project** asks for a name, a folder to put it in and a template (`Projects/NewProjectDialog.cs`). It runs `cinnabar new <folder>/<name> --name <name> --template <template>`, and then opens the project as above.
- **Recent projects** are in `recent-projects.txt` in the editor's settings, the latest first, at most 10 (`Shell/RecentProjects.cs`). The editor adds a project each time it opens one, whichever way. A folder that is no longer a project is not listed.
- **`EditorOptions.ForProject`** gives the paths that `cinnabar.exe` builds: the host and, without a `game/` folder, `standard.dll` from the engine; the project's `build/dev/game.dll` with one; the project's `build/cache`, `build/types/cinnabar.d.luau` and `content` root beside the engine's; and the scene that `game.main_scene` names. The editor's autosaves, captures and automation file go in the project's `build/editor`.
- **The Home tab's Project group:** Build Project (Ctrl+B) runs `cinnabar build`, which builds the project's Odin and its scripts' types. The host reloads a new DLL by itself, and the cook daemon keeps the content cooked meanwhile. Export runs `cinnabar export`, which writes a release into the project's `build/release` (see [Getting started: Releases](../overview/getting-started.md#releases)). It cooks the saved files, so save the scene first. Open Project starts a new editor with another project's folder, and closes this one, which asks about unsaved changes as a close does.
- **One run at a time:** `ProjectTool` runs `cinnabar.exe`, with its state as one value, `Idle` or `Running` with the command and its process. Build Project and Export are disabled while a run goes on. The tool's output goes to the console, and its end says whether it succeeded. Closing the editor stops a run.

## UI framework

The editor uses Avalonia on .NET 10, not WPF. The deciding factor is the viewport.

- **WPF cannot show a D3D12 texture directly.** `D3DImage` takes only D3D9Ex surfaces, so each frame would go from D3D12 through D3D11 to a legacy shared texture and into D3D9Ex: an extra copy, BGRA8 only, and pacing tied to WPF's render thread. A child swapchain in an `HwndHost` avoids the copy, but WPF content cannot draw over it (the airspace problem), so the tool palette and the stats overlay would each need their own window.
- **Avalonia imports external GPU images into its compositor.** `ICompositionGpuInterop` imports D3D11 textures, so the viewport is an ordinary composited control, and other controls draw over it. On Windows the import needs a keyed mutex, which a D3D12 resource cannot have, so the editor copies each frame once (see [Viewport](viewport.md#viewport)).
- **What WPF has that Avalonia lacks** is a mature ribbon and a wider set of third-party controls. The editor builds its own ribbon (see [Ribbon](shell-and-panels.md#ribbon)), and it would build its own property grid in either framework, because the types come from the DLL over the link and not from CLR objects.
- Avalonia also runs on other platforms, though the editor runs on Windows only.

## C# projects

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
- **Editor crash:** the editor saves each dirty scene to its autosave folder every 30 s, `build/editor/autosave/` in the project or `build/obj/editor/autosave/` in the engine's repository with `just edit`, and when a transaction ends if 30 s have passed. An autosave is named for its scene's file and a hash of its full path. When a scene opens and its autosave is newer than its file, the editor offers to restore it. Restoring makes the scene dirty, because its file lacks the changes. Saving the scene, undoing back to its file, choosing not to save it, or discarding the offer deletes the autosave.
- **Cook daemon crash:** the editor reports it in the console and starts the daemon again, which scans the roots and sends a new snapshot. A daemon that exits less than 10 s after it starts, as when another cook holds the cache, is not started again, so the editor does not start it over and over. The status bar shows its exit code, and Restart Cook Daemon starts it.
- **A link that fails:** the host session and the cook session each have one state, with a value for each case: waiting for the viewport (the host only), stopped, failed to start, connecting, handshaking, linked, refused, timed out, link lost, and exited. A state keeps its process, its link, its reason or its exit code. One method changes the state, checks that the change is allowed, and ends what the old state had: its deadline, its link and its process.
  - **Refused:** the process sent `Refused`, as an old build does after a change to the protocol. The editor stops the process and shows the reason. A restart does not fix it, so the editor does not try again.
  - **Timed out:** the process did not send its `Welcome` within 30 s of its start or of a lost link. One deadline covers the connect and the handshake. The editor stops the process.
  - **Link lost:** the link closed while the process runs. The editor connects again. A host that links again is a new link, so the editor sends its scene again.
  - The status bar names the state, with the reason or the exit code. Restart Host and Restart Cook Daemon start the process again.
- **Code reload:** the host sends the types again. **Soft restart:** the host also sends a restart event, and the editor sends the snapshot again (see [Document model](document-and-scenes.md#document-model)).
