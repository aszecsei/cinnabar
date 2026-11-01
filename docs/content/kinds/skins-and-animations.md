# Skins and animations

A glTF model's skins and animations are sub-assets of the model, beside its meshes (see [Meshes](meshes.md#meshes)): each skin is a `Skin` with a `skin.<name>` line in the model's `.meta` file, and each animation is an `Animation` with an `animation.<name>` line. A mesh that a node draws with a skin has a third vertex stream, its joints and weights. The cooker makes them in `tools/cook/skins.odin`, beside the meshes, and the format is in `lib/engine/asset/format/skin.odin` and `animation.odin`. An `Animator` plays a clip on a skinned `Mesh_Renderer` (see [Playback](#playback)).

## Skins

- **One skin asset per glTF skin**, named for the skin, else `skin_<index>`, with the same rules as mesh names. A skin without joints is left out, with a warning.
- **Joints** are the glTF skin's joints and every ancestor of theirs, so that each joint's pose is relative to its parent's, and a root's to the mesh's space. The ancestors are joints that no vertex follows, with an identity inverse bind matrix; a clip can move them too, as an armature node's root motion does. The joints are ordered by depth, parents first, which the runtime composes in one pass.
- **Each joint** has its parent's index, or -1 for a root, its inverse bind matrix as three rows of a 3x4 matrix, its rest pose as a translation, a quaternion and a scale (a node with a matrix is decomposed), its node's name, and a sphere (see below).
- **Axes and scale:** the joints are converted as the vertices are (see [Meshes](meshes.md#meshes)). With M, the mirror of x times the `scale` import setting, each matrix X becomes M · X · M⁻¹: a translation negates x and scales, a quaternion (x, y, z, w) becomes (x, -y, -z, w), and a scale stays.
- **Spheres:** each joint's sphere is about every vertex of the skin's meshes that it influences, in the joint's space at bind time. Posed by their joints, the spheres hold the posed mesh, so the runtime's bound for culling is their union. A joint that influences no vertex has a radius of -1.
- **The mesh's node transform** is not used, as glTF specifies for skinned meshes: the joints place the vertices.

## Skin stream

A skinned mesh has the `Skinned` flag and a third stream beside its positions and attributes, which starts at 16 bytes like them. Depth and shadow passes still read the positions only.

| Stream | Contents | Size |
|---|---|---|
| Skin | Four joint indices in `u16`, into the skin's joints in its order, then their four weights in `unorm16`, which add up to 65535 | 16 bytes |

- **Which skin:** a mesh's skin is the first node's that draws it with one. A mesh drawn with two skins takes the first, with a warning.
- **Influences:** `JOINTS_0` and `WEIGHTS_0`, and `JOINTS_1` and `WEIGHTS_1` when the file has them. The four largest weights stay, normalized; the largest takes what rounding leaves, so the sum is exact. A vertex with no weight follows the skin's first joint.
- **Welding and levels of detail:** the joints and weights are part of the vertex, so welding keeps vertices with other influences apart, and every level of detail shares the vertices, so each level is skinned the same (see [Meshlets](meshes.md#meshlets)).
- **No impostor:** a skinned mesh bakes no impostor, which would show its rest pose. With `impostor = true` it warns.
- **`combine = true`** bakes the nodes into one mesh, which leaves no skin to pose it: its skins and animations are left out, with a warning.

## Animations

- **One clip per glTF animation**, named for the animation, else `animation_<index>`, for the skin whose joints most of its channels move. An animation that moves no joint of a skin is left out, with a warning.
- **Channels** each move one part of one joint: its translation, rotation or scale, with their keys' times in seconds and their values in the engine's axes. They are ordered by joint, then by part. A clip has its skin's GUID and its count of joints, which the runtime checks against the skin.
- **Left out, with a warning:** channels on nodes that are not the skin's joints, morph target weights, and a second channel of a joint's part.
- **Interpolation:** `STEP` and `LINEAR` stay as they are; rotations slerp. `CUBICSPLINE` is sampled at 30 keys a second, and at its last key, into linear keys, with rotations normalized.
- **Duration:** from 0 to the clip's last key. Before a channel's first key the first holds, and after its last the last.
- **The cache key** is the model's, with the skin and animation layouts. A model is up to date when every mesh, skin and animation has a blob with its key, and it cooks them all into memory before it writes any.

## Playback

An `Animator` (component 80) plays an animation graph on an entity, or without one, a clip, looping or held, and the entity's `Mesh_Renderer` draws the clip's skin's mesh. [Animation](../../animation/design.md#the-ecs) describes the ticks, the presentation between them, events and root motion.

- **The palette.** Presentation samples each of the entity's clips over the skin's rest pose and blends them. It composes the joints, parents first, into a palette of joint matrices: each a joint's posed matrix times its inverse bind matrix. It poses the joints' spheres into the bound. `Frame_Desc.skins` takes the poses, and the renderer skins the entity's mesh with them (see [Rendering: Skinned meshes](../../rendering/gpu-scene.md#skinned-meshes)).
- **Without a pose,** a skinned mesh draws in its rest pose. That is the case for an entity whose graph, clips or skin are not loaded, whose clips are not of one skin, or that has no Animator.
