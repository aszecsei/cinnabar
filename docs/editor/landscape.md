# Landscape

Terrain sculpting and hole painting in the editor: the Landscape tool paints a terrain's height map and hole mask with a brush in the viewport, each stroke shows at once and collides at once, undo keeps each stroke's changed tiles, and saving writes the PNGs that the cooker cooks. Read [Rendering: Surfaces](../rendering/surfaces.md), [Viewport](viewport.md) and [Mesh editing](mesh-editing.md#live-meshes) first.

**In this document:** [Design](#design) · [The terrain](#the-terrain) · [Height maps and masks](#height-maps-and-masks) · [The tool](#the-tool) · [Brushes](#brushes) · [Strokes](#strokes) · [Holes](#holes) · [Live textures](#live-textures) · [Saving](#saving) · [The sample](#the-sample) · [Limits](#limits)

## Design

1. **A terrain is a patch surface with a height map.** The terrain is a `Surface_Renderer` whose `height_map` names a `height` texture, and whose material displaces by that texture (see [Surfaces: Collision](../rendering/surfaces.md#collision)). The tools paint that texture and the `hole_mask`. Nothing about the scene format changes: the maps are ordinary texture assets, PNGs in a content root, which the cooker cooks.
2. **The editor owns the texels and runs the brushes.** As with meshes, the host can lose its world at any time, so the editor's C# holds each map, runs the brushes on the CPU, and keeps the undo history. The brushes are therefore testable under `dotnet test` without a host. The host only builds and draws what it is sent. A GPU brush would need the texels back for undo and saving; at the sizes a terrain's map has, a CPU brush is fast enough.
3. **The host draws, and collides with, unsaved maps.** Saving and waiting for the cook takes too long for a stroke, so the editor sends each stroke's texels over the link, and the game puts a blob of them in the asset runtime in place of the cooked one ([Live textures](#live-textures)). The renderer and a `Height_Field` collider read the asset by its version, so both take the new texels as they take a recooked blob.
4. **The tool is in the tool strip, not the ribbon.** It changes how every scene view edits, so by the rule of [Users and workflows](workflows.md#where-a-control-lives) its button is in the Scene's tool strip and its brush is in a shelf beside it, as mesh mode's tools are.

## The terrain

`LandscapeSurface` (`Cinnabar.Editor.Document/Landscape`) is a `Surface_Renderer` as the tools read it from the scene: its entity, `size`, `cell`, `height_range`, `height_map` and `hole_mask`.

- **The selection.** The tools paint the one selected entity of the scene when it has a `Surface_Renderer`. While there is one, the editor's context `selection.terrain` is set (see [Shell: Ribbon](shell-and-panels.md#ribbon)).
- **Heights.** A height map's texel of 0 is `height_range.x` and 65535 is `height_range.y`, in meters above the surface's plane, as a `Height_Field` collider reads it. The texture's `uv0` is 0 to 1 across the rectangle, along the entity's x and z.
- **Picking.** `LandscapePick` casts the camera's ray against the height map at once, as mesh mode picks its meshes: it goes into the entity's space, clips to the box of the rectangle and its heights, marches half a cell at a time, and halves the last step until it is close. It reads the map as the vertex shader does at the finest level: bilinear, clamped, mip 0. It skips a place where the hole mask reads 0.

## Height maps and masks

`LandscapeMap` is one map that the tools paint: its GUID, its file, its kind (`Height` or `Mask`) and its texels, a `HeightGrid` of 16-bit values, row-major from the top.

- **Opening.** The first stroke on a map reads its PNG with the editor's own reader (`Png`, in `Cinnabar.Editor.Document`), which reads 8- and 16-bit gray, gray with alpha, RGB and RGBA without a palette or interlacing, and takes the first channel, widened to 16 bits. A map that cannot be read is an error in the console.
- **Revisions.** Each stroke, and so each undo and redo of one, has a revision of its own. The map is dirty while its revision is not the one its file has, so an undo back to the file makes it clean.
- **Tiles.** Undo keeps a stroke's changed tiles of 32 by 32 texels (`HeightGrid.Tile`), not the whole map.

## The tool

The Landscape tool is `tool.landscape`, L in a scene view, and a button of the [tool strip](viewport.md#tool-strip). Mesh mode has no such tool.

- **The shelf** (`LandscapeShelf`) is beside the tool strip while the tool is on, with four choices: the brush (`landscape.brush`), its radius in meters (`landscape.radius`), its strength (`landscape.strength`) and its falloff (`landscape.falloff`). Each is a command, so the command palette has them too. Without a terrain selected, the shelf says to select one.
- **The brush ring.** Over the terrain, the game draws two circles where the brush is: its radius, and inside it, where its strength starts to fall off. The editor sends `Landscape_Overlay` when the ring moves, and hides it off the terrain or when the tool goes.
- **Clicks.** With the tool and a terrain selected, a press on the terrain starts a stroke, a drag paints, and the release ends it. A press off the terrain selects as the Select tool does.

## Brushes

`LandscapeStroke` paints dabs with a weight that is 1 inside the part of the radius that does not fall off, 0 past the radius, and a smooth step between. A dab's radius is in the map's texels: the brush's meters as a share of the surface's size, so a map whose texels are not square on the surface takes a dab that is not round in texels.

| Brush | What a dab does |
|---|---|
| Raise | Adds 1% of the height range at full strength, by the weight |
| Lower | Takes away the same |
| Smooth | Moves each texel toward the mean of its 3 by 3 neighbours, as they were before the dab |
| Flatten | Moves each texel toward the height where the stroke started |
| Ramp | A straight slope from where the stroke started to where it is, as wide as the brush, drawn again at each step over what the map was |
| Noise | Adds value noise of an 8-texel cell, the same at a place for every stroke |
| Hole | Paints holes into the hole mask: 0 within the radius |
| Fill | Paints the hole mask solid: 65535 within the radius |

## Strokes

- **The stroke.** A press keeps a copy of the map as it was. A drag paints dabs a quarter of the radius apart from the last hit to the new one, or for a ramp, only the last. Each step sends the rectangle that it changed to the game, so the stroke shows at once.
- **Undo.** The release puts one entry on the scene's undo stack: a `LandscapeOperation` with each changed tile's texels before and after, beside the scene's operations, as a `MeshOperation` is beside them (see [Mesh editing](mesh-editing.md#undo-and-saving)). Its label names the brush. Undo and redo write the tiles and send them to the game.
- **Cancel.** Escape, a lost mouse capture, a change of the tool, the selection or the mode puts the stroke's tiles back and leaves no entry.

## Holes

The Hole and Fill brushes paint the `hole_mask`, which [Surfaces: Holes](../rendering/surfaces.md#holes) describes.

- **A surface without a mask gets one.** The first Hole stroke on a surface whose `hole_mask` is none makes a new mask: one texel for each finest cell, `ceil(size / cell)` a side, all solid, named for the entity, `<name>_holes.png`, beside the height map or the scene. The release names it in the `Surface_Renderer`'s `hole_mask` in the same undo entry, so an undo takes the mask out with the hole.
- **Saving a new mask** writes its PNG and its `.meta`: `usage = mask`, `[mip_map] kernel = box` and `[sampler] wrap = clamp`, as the surface's holes need. A new mask that an undo took out of the scene is not written.
- **Collision.** A `Height_Field` collider reads the live mask too, so a hole painted in Edit lets a body fall through it in Play before the scene is saved.

## Live textures

The game's side is `lib/engine/editor/live_texture.odin`.

- **`Live_Texture`** is a whole map: its GUID, its usage (`Height` or `Mask`), its size and its 16-bit texels. The editor sends it before a map's first stroke, and again for every live map after a new game state ([Editor link](link.md#a-new-game-state)).
- **`Live_Texture_Region`** is a rectangle of texels, a stroke's step, an undo or a redo, for a map that a `Live_Texture` gave.
- **Each message** builds a blob: `R16_Unorm` texels with box-filtered mips down to 1 by 1 (`format.texture_box_chain_r16`), clamped. A mip's texel is the mean of the four under it, rounded up, so a mask's mip reads 0 only where every texel under it does, as the cooker's box mips of a mask do. The game puts the blob in the asset runtime with `asset.set_live`, as a new version of the asset (see [Content: Live blobs](../content/blobs-and-loading.md#live-blobs)). The renderer's residency streams a texture again when its version changes, and a `Height_Field` collider's body is made again when its maps' versions change, so the stroke draws and collides at once. A mask that is not cooked yet loads from the live blob.
- **`Release_Live_Texture`** ends a live map: `asset.clear_live` loads the cooked blob again. The editor sends it for each map that is saved, clean, and whose cooked blob is current, after the cook daemon's next cook. A new connection ends every live map.
- **The brush ring** is `Landscape_Overlay`, which the game keeps in its `Session` and the helpers draw.

## Saving

Saving the scene saves every dirty map that the scene names, after the scene and its meshes, through a temporary file: a height map as a 16-bit gray PNG and a mask as an 8-bit gray PNG, which the cooker reads as it reads any texture (see [Content: Textures](../content/kinds/textures.md#textures)). The map stays live until its cooked blob is current. Closing the scene closes its maps, with their unsaved strokes, as it closes its meshes.

## The sample

The playground (`samples/mygame/content/scenes/playground.scene`) has Hills, a 64 m terrain past the floor's far edge, with `height_range = [0, 8]`, a `Height_Field` collider, and `playground_terrain.material`, which displaces by the same map. The player walks off the floor and up the hills. `just sample-textures` writes the hills' starting map, `playground_hills.png`; sculpt it further with the Landscape tool and save.

## Limits

- **Each step sends a rectangle, and the game builds a blob of the whole map** with its mips, which the renderer streams whole and the physics remakes whole. That is fine for maps of a few hundred texels a side. Larger maps would want a tile copy on the GPU and a collider that changes in place.
- **The live mips are box-filtered.** A height map's cooked mips are Kaiser-filtered, so its far patches can differ a little until the saved map is cooked.
- **The ring is flat**, across the surface's plane at the brush's center, not draped over the terrain.
- **Material layers and foliage are not painted yet.** The tools paint a height map and a hole mask only.
