using Cinnabar.Editor.Document;
using BoxHandleKind = Cinnabar.Editor.Link.Protocol.BoxHandleKind;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Tools;

/// <summary>A handle on a face of a reflection probe's box: the box, the probe's axis, and the side, 1 or -1.</summary>
public readonly record struct ProbeHandle(BoxHandleKind Box, int Axis, int Side)
{
    /// <summary>The probe's field that a drag of the handle sets.</summary>
    public string Field => Box switch
    {
        BoxHandleKind.Influence => "extent",
        BoxHandleKind.Blend => "blend_distance",
        _ => "projection_extent",
    };
}

/// <summary>
/// A reflection probe's boxes, as the renderer takes them from the component and its entity's scale (see
/// docs/editor/viewport.md#reflection-probes and reflection_probe_extents in lib/engine/render/reflection_probes.odin), and the handles
/// that resize them. The boxes are about the entity's position along its axes, and a handle's drag moves its face and
/// the opposite one alike, so the entity stays where it is.
/// </summary>
public sealed class ProbeBoxes
{
    /// <summary>An extent of 0 is this many meters, as DEFAULT_PROBE_EXTENT in lib/engine/render/components.odin.</summary>
    public const double DefaultExtent = 5;
    /// <summary>A box's half size that a drag goes no smaller than, in meters.</summary>
    public const double MinHalfSize = 0.05;
    /// <summary>A handle's size on screen, in pixels of the frame.</summary>
    public const double HandlePixels = 10;

    ProbeBoxes(long[] center, Quat axes, double[] scale, double[] extentField, double blendField, bool boxProjection, double[] projectionField)
    {
        (Center, Axes, Scale, BoxProjection) = (center, axes, scale, boxProjection);
        Extent = [.. extentField.Select((e, a) => (e > 0 ? e : DefaultExtent) * scale[a])];
        Projection = [.. projectionField.Select((p, a) => p > 0 ? p * scale[a] : Extent[a])];
        Blend = Math.Min(Math.Max(blendField, 0), Extent.Min());
    }

    /// <summary>The probe's position, a raw World_Position.</summary>
    public long[] Center { get; }

    /// <summary>The entity's rotation, whose axes the boxes are along.</summary>
    public Quat Axes { get; }

    /// <summary>The entity's scale, without its signs.</summary>
    public double[] Scale { get; }

    /// <summary>The influence box's half sizes, in meters.</summary>
    public double[] Extent { get; }

    /// <summary>The fade inside the influence box, in meters, which no half size is less than.</summary>
    public double Blend { get; }

    /// <summary>The projection box's half sizes, in meters, which the renderer uses only with <see cref="BoxProjection"/>.</summary>
    public double[] Projection { get; }

    public bool BoxProjection { get; }

    /// <summary>The boxes of an entity's Reflection_Probe at its world pose, or null without one.</summary>
    public static ProbeBoxes? Of(SceneEntity entity, Pose pose)
    {
        if (entity.Components.Find(c => c.Id == SceneEdits.ReflectionProbeId) is not { } probe)
        {
            return null;
        }
        double[] Vector(string name)
        {
            var v = probe.Fields.Find(f => f.Name == name)?.Value;
            return v is { Kind: SceneValueKind.Number, Numbers.Count: 3 } ? [.. v.Numbers.Select(n => n.Float)] : [0, 0, 0];
        }
        var blend = probe.Fields.Find(f => f.Name == "blend_distance")?.Value is { Kind: SceneValueKind.Number, Numbers.Count: 1 } b ? b.Numbers[0].Float : 0;
        var boxProjection = probe.Fields.Find(f => f.Name == "box_projection")?.Value is { Kind: SceneValueKind.Bool, Bool: true };
        return new ProbeBoxes(pose.Position, pose.Rotation, [.. pose.Scale.Select(Math.Abs)], Vector("extent"), blend, boxProjection, Vector("projection_extent"));
    }

    /// <summary>A handle's size in meters, so it is <see cref="HandlePixels"/> wide at the probe's distance.</summary>
    public double HandleSize(EditorCamera camera, double height) =>
        camera.PixelSize(Math.Max(Vec3.Dot(camera.RelativeTo(Center), camera.Forward), camera.Near), height) * HandlePixels;

    /// <summary>The handles: the influence box's six, the fade's, and the projection box's with box projection.</summary>
    public IEnumerable<ProbeHandle> Handles()
    {
        var boxes = BoxProjection ? new[] { BoxHandleKind.Influence, BoxHandleKind.Blend, BoxHandleKind.Projection } : [BoxHandleKind.Influence, BoxHandleKind.Blend];
        foreach (var box in boxes)
        {
            for (var axis = 0; axis < 3; axis++)
            {
                yield return new ProbeHandle(box, axis, 1);
                yield return new ProbeHandle(box, axis, -1);
            }
        }
    }

    /// <summary>
    /// How far from the center a handle sits along its axis, in meters. A handle that its value would put on the
    /// influence box's, a fade shorter than <paramref name="gap"/> or a projection box within it of the influence box,
    /// stays that far from it, so each can be grabbed; its drag starts from its value all the same.
    /// </summary>
    public double Distance(ProbeHandle h, double gap)
    {
        var extent = Extent[h.Axis];
        return h.Box switch
        {
            BoxHandleKind.Influence => extent,
            BoxHandleKind.Blend => Math.Max(extent - Math.Max(Blend, gap), 0),
            _ => Math.Abs(Projection[h.Axis] - extent) < gap ? extent + gap : Projection[h.Axis],
        };
    }

    /// <summary>The handle's world direction out of the box.</summary>
    public Vec3 Outward(ProbeHandle h) => Gizmo.Axis(Axes, h.Axis) * h.Side;

    /// <summary>Where a handle is, a raw World_Position.</summary>
    public long[] Position(ProbeHandle h, double gap) => (Outward(h) * Distance(h, gap)).Offset(Center);

    /// <summary>The gap that keeps handles apart: two handles' sizes.</summary>
    public static double Gap(double handleSize) => 2 * handleSize;

    /// <summary>The handle under a point of the frame, the nearest within <see cref="Gizmo.HitPixels"/> of its middle, or null.</summary>
    public ProbeHandle? HitTest(EditorCamera camera, Vec2 mouse, double width, double height)
    {
        var gap = Gap(HandleSize(camera, height));
        ProbeHandle? best = null;
        var bestDistance = Gizmo.HitPixels;
        foreach (var h in Handles())
        {
            if (camera.Project(camera.RelativeTo(Position(h, gap)), width, height) is { } p && (p - mouse).Length is var d && d < bestDistance)
            {
                (best, bestDistance) = (h, d);
            }
        }
        return best;
    }

    /// <summary>
    /// The edit that moves a handle's face out by <paramref name="moved"/> meters from where the drag started, and the
    /// opposite face with it: a half size or a fade in meters, rounded to the snapping's meters, and the field in the
    /// component's units, before the scale. The whole vector is written, with the defaults that it stood for.
    /// </summary>
    public SetField Resize(ulong entity, ProbeHandle h, double moved, Snapping? snap)
    {
        double Round(double v) => snap is { } s ? Snapping.Round(v, s.Meters) : v;
        double Unscaled(double meters, int axis) => Scale[axis] > 1e-9 ? meters / Scale[axis] : meters;
        double[] Field(double[] meters) => [.. meters.Select(Unscaled)];
        switch (h.Box)
        {
            case BoxHandleKind.Blend:
                var blend = Math.Clamp(Round(Blend - moved), 0, Extent.Min());
                return new SetField(entity, SceneEdits.ReflectionProbeId, h.Field, SceneEdits.Floats(blend));
            case BoxHandleKind.Influence:
                var extent = Extent.ToArray();
                extent[h.Axis] = Math.Max(Round(extent[h.Axis] + moved), MinHalfSize);
                return new SetField(entity, SceneEdits.ReflectionProbeId, h.Field, SceneEdits.Floats(Field(extent)));
            default:
                var projection = Projection.ToArray();
                projection[h.Axis] = Math.Max(Round(projection[h.Axis] + moved), MinHalfSize);
                return new SetField(entity, SceneEdits.ReflectionProbeId, h.Field, SceneEdits.Floats(Field(projection)));
        }
    }
}
