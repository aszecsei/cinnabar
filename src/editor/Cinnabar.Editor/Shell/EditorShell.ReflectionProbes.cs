using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Operation = Cinnabar.Editor.Document.Operation;
using SceneEntity = Cinnabar.Editor.Document.SceneEntity;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The reflection probes in the editor (see docs/editor/viewport.md#reflection-probes): the selected probe's box handles, which
/// resize its boxes, and the captures that the editor asks the game for. The state of each watched probe, which the
/// Properties panel shows, is the world's (<see cref="WorldModel.Probe"/>).
/// </summary>
public sealed partial class EditorShell
{
    /// <summary>The box handle under the mouse, or the one that a drag holds, or null.</summary>
    public ProbeHandle? HotHandle { get; private set; }

    /// <summary>The selected probe, when one entity is selected, outside mesh mode, and it has a Reflection_Probe and a pose.</summary>
    public (SceneEntity Entity, ProbeBoxes Boxes)? SelectedProbe()
    {
        if (Mesh.InMeshMode || Scene == null || SelectedSceneEntities.Count != 1 || SelectedSceneEntity is not { } entity
            || SceneEdits.WorldPose(Scene.Expanded.Flat, entity) is not { } pose || ProbeBoxes.Of(entity, pose) is not { } boxes)
        {
            return null;
        }
        return (entity, boxes);
    }

    ProbeHandle? HitProbeHandle(Vec2 pixel)
    {
        var (width, height) = FrameSize;
        return SelectedProbe() is var (_, boxes) ? boxes.HitTest(Camera, pixel, width, height) : null;
    }

    // Starts a drag of the hot handle in a new undo entry.
    bool PressProbeHandle(Vec2 pixel, ProbeHandle handle)
    {
        if (SelectedProbe() is not var (entity, boxes))
        {
            return false;
        }
        var (width, height) = FrameSize;
        var gap = ProbeBoxes.Gap(boxes.HandleSize(Camera, height));
        var center = Camera.RelativeTo(boxes.Position(handle, gap));
        var part = Gizmo.AxisPart(handle.Axis);
        var box = handle.Box switch
        {
            BoxHandleKind.Influence => "Influence Box",
            BoxHandleKind.Blend => "Blend",
            _ => "Projection Box",
        };
        return _gizmo.Start(new GizmoDrag(GizmoKind.Translate, part, Camera, center, boxes.Axes, pixel, width, height),
            new ProbeHandleTarget(this, entity.Id, boxes, handle), $"Resize {Label(entity)}'s {box}");
    }

    // A drag of a box handle: each step moves the handle's face, and the opposite one, by how far the mouse went along
    // the face's axis from the press.
    sealed class ProbeHandleTarget(EditorShell shell, ulong entity, ProbeBoxes boxes, ProbeHandle handle) : IGizmoTarget
    {
        public IReadOnlyList<Operation> Drag(GizmoDrag drag, Vec2 pixel, bool snap)
        {
            var moved = Vec3.Dot(drag.Update(pixel, null).Translation, boxes.Outward(handle));
            return [boxes.Resize(entity, handle, moved, snap ? shell.Snapping : null)];
        }
    }

    // The selected probe's handles in each open viewport when they change, with the hot one marked, or none. Their
    // size follows the viewport's camera and frame, as the gizmo's does.
    void SendBoxHandles()
    {
        var probe = SelectedProbe();
        foreach (var viewport in OpenViewports)
        {
            var message = new BoxHandles((uint)viewport.Index, 0, []);
            if (probe is var (_, boxes))
            {
                var size = boxes.HandleSize(viewport.Camera, viewport.FrameSize.Height);
                var gap = ProbeBoxes.Gap(size);
                message = message with { Size = (float)size, Handles = [.. boxes.Handles().Select(h => new BoxHandle(boxes.Position(h, gap), h.Box, h == HotHandle))] };
            }
            var key = $"{message.Size}|{string.Join(";", message.Handles.Select(h => $"{string.Join(",", h.Position)},{h.Kind},{h.Hot}"))}";
            if (key != viewport.SentHandles && Host.Linked)
            {
                viewport.SentHandles = key;
                Host.Send(message);
            }
        }
    }

    /// <summary>Whether the selection has a probe in the document, which Capture captures.</summary>
    public bool SelectionHasProbe =>
        SelectedSceneEntities.Any(e => e.Components.Any(c => c.Id == SceneEdits.ReflectionProbeId));

    /// <summary>Whether the scene has a probe, which Capture All Probes captures.</summary>
    public bool SceneHasProbe =>
        Scene?.Expanded.Flat.Entities.Any(e => e.Components.Any(c => c.Id == SceneEdits.ReflectionProbeId)) == true;

    /// <summary>Asks the game to capture the selected probes now, each in one frame, one a frame.</summary>
    public void CaptureSelectedProbes()
    {
        var probes = Selection.Entities.Where(h => World.Find(h)?.SceneId is { } id && Scene?.Expanded.Flat.Find(id)?.Components.Any(c => c.Id == SceneEdits.ReflectionProbeId) == true).ToArray();
        if (probes.Length > 0 && Host.Linked)
        {
            Host.Send(new CaptureReflectionProbes(probes));
        }
    }

    /// <summary>Asks the game to capture every probe that holds a slot, one a frame, whatever the level's budget.</summary>
    public void CaptureAllProbes()
    {
        if (Host.Linked)
        {
            Host.Send(new CaptureReflectionProbes([]));
        }
    }
}
