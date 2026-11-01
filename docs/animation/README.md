# Animation

Skeletal animation on skinned meshes: the animation graph that poses a skeleton from clips, raises events and reports root motion, in `lib/engine/anim/graph`, and the components and systems that run it in fixed ticks, in `lib/engine/anim`. Skins, clips and graphs are content: see [Content: Skins and animations](../content/kinds/skins-and-animations.md#skins-and-animations) and [Animation graphs](../content/kinds/animation-graphs.md#animation-graphs).

## Documents

| Document | What it covers |
|---|---|
| [Design](design.md) | What the graph does and does not do, the instance and its samples, ticks and presentation, transitions and fades, blends, events, root motion, and the components and systems that run graphs on entities. |

## Overview

| Package | Side | Responsibility |
|---|---|---|
| `lib/engine/anim/graph` | Game | The graph: from its blob, its clips, an instance and a tick's seconds, it gives the instance's next state, the tick's events and root motion, and the pose between two ticks. It imports nothing from the world, scripts or the renderer. |
| `lib/engine/anim` | Game | `Animator` and `Root_Motion`, the `animate` system in the `Fixed` stage, the events for systems and scripts, and the poses that `Frame_Desc.skins` takes. |

The data flow: in a fixed tick, the graph moves each instance from its parameters and gives the tick's events and root motion. When a frame is presented, each instance's samples are posed between the last two ticks and blended, and the renderer skins the mesh with the palette.

## References

- Unity, [*Animator Controller*](https://docs.unity3d.com/Manual/class-AnimatorController.html): parameters, triggers that a transition consumes, exit times, transitions from any state, and the freeze of an interrupted transition, which the state machine follows.
- Unreal Engine, [*Animation Notifies*](https://dev.epicgames.com/documentation/en-us/unreal-engine/animation-notifies-in-unreal-engine) and [*Root Motion*](https://dev.epicgames.com/documentation/en-us/unreal-engine/root-motion-in-unreal-engine): events at a clip's times, raised by the clip that weighs most, and root motion that the pose leaves out and gameplay applies.
- Guillaume Blanc, [ozz-animation](https://github.com/guillaumeblanc/ozz-animation): sampling and blending local poses by weight, with rotations on one side, before composing them.
- Glenn Fiedler, [*Fix Your Timestep!*](https://gafferongames.com/post/fix_your_timestep/): stepping in fixed ticks and presenting between the last two.
