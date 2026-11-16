# Users and workflows

Who the editor is for, what each kind of user does in it, and the rule that says where a control is. Read it before you add a command, a panel or a menu, so that the new control goes where its user looks for it.

**In this document:** [Who the editor is for](#who-the-editor-is-for) · [Where a control lives](#where-a-control-lives) · [What each user reaches](#what-each-user-reaches)

## Who the editor is for

A team that makes a game has people with different work, and each of them uses a different part of the editor most of the day. The editor's ribbon tabs, its workspaces and its menus are arranged for these kinds of user. One person can be several of them.

| Kind of user | The work | What must be at hand |
|---|---|---|
| Level designer | Blocks out spaces, sculpts terrain, places entities and prefabs, sets up triggers and volumes, and plays the level to test it | The tools, mesh mode and the Landscape tool in the viewport, a fast way to add a common entity, the outliner, prefabs, Play |
| Environment artist | Dresses a level with meshes, materials and effects, and edits the level's geometry and its texture mapping | The content browser, mesh mode's tools, the Face panel, the material editor |
| Lighting artist | Places lights and reflection probes, sets the sky, the sun, the fog and the clouds, and sets the exposure and the post-processing | The lights and the atmosphere, the Atmosphere panel, the views that show light and shadow alone, a viewport's quality |
| Technical artist | Writes materials and effects, and finds what makes a frame slow | The material editor, the views that show cost, a viewport's quality, the profiler and the resource monitor |
| Sound designer | Places the sounds of a level and the point that they are heard from | The audio components, the content browser, Play |
| Gameplay designer | Makes agents, their decisions and their navigation, and the menus and the HUD | The gameplay entities, the decision editor, the UI editor, the Navigation Path tool, Play |
| Gameplay programmer | Writes behaviours and native components, adds the game's own commands, and builds and reloads the game | Scripts, the behaviours of an entity, the console, the build, the profiler |
| Project owner | Runs the game in its own window, sets the project's output and quality, and exports a release | The project's settings, the export, the host and the cook daemon |

## Where a control lives

A control is where the thing that it changes is. This is the one rule, and it has four cases.

| What the control changes | Where it is | Examples |
|---|---|---|
| One viewport | That viewport's [toolbar](viewport.md#toolbar) | Which way the view looks, its projection, the debug view, the features that it draws, its quality, its exposure |
| How every scene view edits | The Scene's [tool strip](viewport.md#tool-strip), with mesh mode's shelf beside it | The tool, the gizmo's space, snapping, Object or Mesh mode, the mesh tools, the landscape brush |
| The selection | The [properties panel](shell-and-panels.md#properties), a row's menu in the [outliner](shell-and-panels.md#outliner), and the Home tab's Edit, Visibility and Prefab groups | A field, Add Component, Duplicate, Hide, Make Prefab |
| The scene, the project or the window | The [ribbon](shell-and-panels.md#ribbon) | Save, the [Add](shell-and-panels.md#add) menu, the atmosphere, Export, the panels and the workspace |

Three more rules follow from the first one.

- **A control is in one place.** The view's name is in the viewport's toolbar, so it is not under the view gizmo and not in the ribbon. A control that is in two places has two states to keep the same, and its user must learn which one to trust. The exceptions are entry points, such as a kind of entity that is in the Add menu and also on the tab of the discipline that adds it most.
- **A control is a command.** Every control runs a command with an ID, so the [command palette](shell-and-panels.md#commands) finds it from anywhere, a key binding can run it, and a game can add its own (see [Game commands](shell-and-panels.md#game-commands)). The box beside the ribbon's tabs opens the palette.
- **What every user needs is always in view.** Play, Pause, Step and Stop are beside the ribbon's tabs, whatever tab shows and while the ribbon is collapsed.

## What each user reaches

The ribbon has a tab for each kind of work, under the band of its discipline: Art, Design or Audio. A [workspace](shell-and-panels.md#workspaces) arranges the panels for a kind of work and shows its tab.

| Kind of user | Ribbon tab | Workspace | Elsewhere |
|---|---|---|---|
| Level designer | Home | Level Design | The tool strip, the Block tool and mesh mode in the Scene; the [Add](shell-and-panels.md#add) menu; the outliner's row menus |
| Environment artist | Environment (Art) | Environment Art | Mesh mode's shelf and the Face panel (see [Mesh editing](mesh-editing.md#mesh-mode)); the content browser's tags |
| Lighting artist | Lighting (Art) | Lighting | A viewport's Shading menu, with its Lighting, Shadows and Indirect Light groups, and its Show menu's Exposure; the Atmosphere and Weather Map panels |
| Technical artist | Scripting (Design), for the profiler | Performance | A viewport's Shading menu's Cost group and its Quality menu; the [material editor](material-editor.md#material-editor) |
| Sound designer | Audio (Audio) | Level Design | The Add Component picker's Audio folder; the content browser's Audio filter |
| Gameplay designer | Gameplay (Design) | Level Design | The [decision editor](decision-editor.md#decision-editor) and the [UI editor](ui-editor.md#ui-editor); the Navigation Path tool in the tool strip |
| Gameplay programmer | Scripting (Design), and the game's own tabs | Scripting | The Add Component picker's Behaviours folder; the console |
| Project owner | Project | General | The status bar's host and cook states |

To add a control for one of these users:

1. Decide what the control changes, and so which of the four places it goes in.
2. Register its command (see [Commands](shell-and-panels.md#commands)).
3. For the ribbon, add it to the tab of the user who needs it most, in `DefaultRibbon`. For a viewport's setting, add it to `ViewportOptions`, and the toolbar and the command both have it. For a tool of the Scene, add it to `SceneToolStrip` or `MeshToolShelf`.
4. A test, `WhatIsAViewportsOrTheScenesIsNotInTheRibbon`, fails when a viewport's or the Scene's command is put in the ribbon.
