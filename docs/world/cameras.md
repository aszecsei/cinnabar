# Cameras

The game's views, their layout, and the camera stack of each view. Systems push cameras onto a view's stack, and the stack shows the highest one, with a cut or a blend when its choice changes. A full-screen claim takes every view, for a cutscene, and its release gives the layout back. The code is `lib/engine/camera` (the `camera` package). The game package keeps one `camera.Views` in `Game.views` and draws what it gives each frame.

**In this document:** [Views and layouts](#views-and-layouts) · [Stacks](#stacks) · [Tokens](#tokens) · [Blends](#blends) · [Claims](#claims) · [The frame](#the-frame) · [Scripts](#scripts) · [Several views](#several-views)

## Views and layouts

- **A game view** is a normalized rect of the window and a camera stack. The game has 1 to `MAX_VIEWS` (5) views: the renderer's own view and its `MAX_EXTRA_VIEWS` extra views.
- **A layout** sets the views' rects. `Layout` is a `Preset` or a `Custom` set of rects:
  - `Single`: one full-screen view. This is the zero value, so a game that sets no layout has one view, as before.
  - `Side_By_Side`: two views, left and right.
  - `Over_Under`: two views, top and bottom.
  - `Grid_4`: four views in a grid.
  - `Custom`: up to `MAX_VIEWS` rects that the game sets itself.
- **`set_layout`** is the only writer of the layout. It frees the renderer's `View_State` of each view that goes.
- **The layout stays when a level changes.** It is like the number of players, not part of a level. A script that sets a layout sets `single` again when it goes, as the sample's `split_screen.luau` does in `on_destroy`.
- **A new world from the editor starts the views again.** When the editor's scene replaces the game's world, at Play, at Stop and when a scene opens, the old world's behaviours end without their callbacks, so they cannot set the layout back. The game's `editor_poll` runs between frames, after the editor's messages. There `camera.follow_world` sees that `editor.world_loads` changed and calls `camera.reset`, before the new world's behaviours start, so their pushes and layout stay. The reset gives one full-screen view, no pushes or claims, and a cut in the first frame. The old tokens stay stale, and their owners hear nothing.
- **`pixel_rect`** gives a rect in a window's pixels. It rounds each edge, so views that share an edge in the layout share it in pixels, and the presets cover the window with no gap.
- **View 0 is the own view.** It does the work that the renderer does once a frame: the render origin, the view model, the particles' step and collision, the sky's cubemap and the lookup table's bake (see [Rendering: Views in rects](../rendering/frame.md#views-in-rects)). Views 1 and up are extra views. `camera.view_state` makes each one's `View_State` when it first draws, and `camera.destroy` frees them at shutdown.

## Stacks

- **A push** puts a camera entity on one view's stack, with a priority: `push(views, world, view, camera, priority, blend, blend_out, owner)`. It fails when the view is not 0 to `MAX_VIEWS - 1`, when the entity is not alive or has no `Camera`, or when `MAX_ENTRIES` (64) pushes and claims are held. A view that the layout does not show takes pushes too.
- **The choice** is the entry with the highest priority. On a tie, the last push wins.
- **With no entries**, a view shows the world's first `Camera`, as `collect` finds it, and keeps it while it lives. A scene with one camera and no pushes draws as it did before stacks. With no camera at all, it shows a default view from the origin.
- **A system needs no knowledge of the others.** A death camera, a vehicle camera and a dialogue camera each push with their own priority, and the highest one shows.

## Tokens

This follows [State with a lifecycle](../overview/conventions.md#state-with-a-lifecycle).

- **A push gives a `Camera_Token`**: a slot and a generation. `pop(token)` removes that entry. Each use of a slot counts its generation up, so a token never matches a later entry. A pop through a stale token does nothing.
- **A claim gives a `Claim_Token`**, a different type, so a push's token cannot release a claim.
- **`is_pushed` and `is_claimed`** say whether a token's entry is still held.
- **The pusher learns when its entry is removed for it.** When the camera entity despawns or loses its `Camera`, `advance` removes the entry and adds an `Ended` with the token, the reason (`Despawned`) and the owner. `ended` gives this frame's list. The game sends the owner's behaviours `on_camera_removed(token, reason)`, with the token's number and `"despawned"`. A pop or a release by the pusher sends nothing, because the pusher ended the entry itself.

## Blends

- **A change of choice cuts or blends.** `Blend` is a duration in seconds, a `Curve` (`Linear`, `Smooth`, `Ease_In` or `Ease_Out`) and a `Clock`. A duration of 0 or less is a cut. `CUT` is the zero `Blend`.
- **Which blend.** When the old choice is still held but outranked, the change uses the new choice's blend in. When the old choice was popped, released or despawned, the change uses the old choice's blend out. A change to or from the fallback camera uses the same rule.
- **What blends.** `blend_views` blends the position, the rotation (a slerp on the short arc) and the lens: the field of view and near plane of a perspective view, the height and planes of an orthographic one, and the view model's field of view and near plane. Two views of different projections take the new one's at once. [#532](https://github.com/aszecsei/cinnabar/issues/532) adds its lens fields here.
- **A moving camera** blends from where it is: a blend reads the old camera's presented pose each frame. If the old camera goes during the blend, the blend keeps its last pose.
- **A blend that starts during another blend** starts from the current blended pose, not from the old camera.
- **The clock** is the pusher's choice. `Game` is the world's step, which is 0 while the game is paused and in the editor's Edit. `Real` is the host's frame time, for cameras that ignore pause.
- **A cut** has no interpolation across it. The view's `cut` flag goes to the renderer, which drops the view's histories, last camera and adapted exposure in that frame (see [Rendering: Views](../rendering/frame.md#views)). A cut stays pending until a frame that carries it is drawn: the game calls `camera.drawn` after it draws, so a frame that is not drawn, as with a minimized window, passes the cut on to the next.

## Claims

- **A full-screen claim** takes every view, for a cutscene: `claim(views, world, camera, priority, blend, blend_out, owner)`. While a claim is held, the layout shows one full-screen view, which shows the claims' stack. The claims are a stack of their own, so the highest claim shows.
- **On release**, the layout and each view's stack come back as they were, once the release's blend out ends. The views' stacks keep their entries during the claim.
- **A claim, a release and a new layout** change the views' rects. Every view cuts in that frame, so no view's histories smear across the change.
- **A blend into or out of a claim** is in the full-screen view. A claim blends in from what the first view shows, and a release blends back to the first view's camera with the claim's blend out. The layout comes back when that blend ends, with a cut. With one view, as in most games, the release ends where the game's view is, and the cut changes nothing that shows.

## The frame

- **`advance`** runs once a frame, after `Hooks.update`, so every push of the frame shows in it. It is the only writer of what the stacks choose and show. In order, it:
  1. removes the entries whose camera is gone, and records each in `ended`;
  2. finds the fallback camera again if it is gone;
  3. chooses each stack's top, and starts a cut or a blend when it changed;
  4. steps the blends by their clocks, and writes each stack's view;
  5. gives `Frame_Views`: each shown view's index, rect, view and `cut`.
- **The game draws `Frame_Views`.** `describe_frame` makes view 0 the frame's own view and each other view an extra view, both in rects of the window, with the project's hooks and settings (see [Rendering: Views in rects](../rendering/frame.md#views-in-rects)). One full view has no rect, as before.
- **`view_of`** is pure. It gives what a view shows now, for code that runs before `advance` in a frame. `game.camera_view(g, index)` calls it.
- **`append_positions`** gives the cameras of every view, shown or not, and of the claims. The streaming policy takes them as sources (see [World streaming: The policy](streaming.md#the-policy)).

## Scripts

The `Views` library. Views are 1-based in scripts.

| Call | What it does |
|---|---|
| `Views.push(view, camera, priority, blend?, owner?)` | Pushes a camera onto a view's stack, and gives its token as a number. |
| `Views.pop(token)`, `Views.is_pushed(token)` | Pops an entry, or says whether it is still held. |
| `Views.claim(camera, priority?, blend?, owner?)` | Claims every view with a camera, and gives its token. |
| `Views.release(token)`, `Views.is_claimed(token)` | Releases a claim, or says whether it is still held. |
| `Views.set_layout(name)` | `"single"`, `"side_by_side"`, `"over_under"` or `"grid_4"`. |
| `Views.count()`, `Views.camera(view)` | How many views the layout has, and the camera that a view shows. |

- `blend` is a table: `{duration = 1, curve = "smooth", clock = "real", out = 0.5}`. `out` is the blend out's duration, with the same curve and clock. A missing `out` is a cut.
- A token is the number `generation * 64 + slot`, which a script keeps and passes back.
- The owner's behaviours get `on_camera_removed(token, reason)` when the entry is removed for them.

## Several views

What else follows each view:

- **Audio:** each source is heard at its nearest `Audio_Listener`. A split-screen game puts one on each player's camera (see [Audio: Sources and the listener](../audio/design.md#sources-and-the-listener)).
- **Streaming:** each view's camera is a source (see [World streaming: The policy](streaming.md#the-policy)).
- **The UI:** a `Ui_Document` with a `view` lays out in that view's rect, at its scale. One with view 0 uses the window (see [UI: Scale](../ui/design.md#scale)).
- **Rendering:** each view culls and chooses its level of detail from its own camera, and keeps its own histories and exposure (see [Rendering: Views in rects](../rendering/frame.md#views-in-rects)).
- **The editor's Game view** shows the whole layout (see [Editor: Views](../editor/viewport.md#views)).
