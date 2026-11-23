using System.Globalization;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// A piloted camera's keys (see docs/editor/cutscene-editor.md#pilot): the world pose that the pilot gives a spawned
/// camera, as its transform track keys it. A relative track, the default, keys the offset from the pose that the binding
/// spawns with, in its axes, and the turn after its rotation. An absolute track keys the pose from its origin.
/// </summary>
public static class PilotKeys
{
    /// <summary>
    /// Why a binding's camera cannot be piloted, or null when it can: only a spawned camera with no parent binding, whose
    /// transform track is relative to its own pose or absolute, and is not locked.
    /// </summary>
    public static string? Refusal(CutsceneFile file, int binding, IReadOnlySet<int>? locked)
    {
        if (file.Bindings.FirstOrDefault(b => b.Id == binding) is not { } block)
        {
            return "The binding is not in the cutscene.";
        }
        if (CutsceneBindings.SpawnOf(block) == null)
        {
            return "Only a spawned camera can be piloted. Move a possessed one with the gizmo.";
        }
        if (block.Get("parent") != null)
        {
            return "The camera has a parent binding, so the view's pose is not its own.";
        }
        var position = new KeyTarget.Pose(binding, PosePart.Position);
        if (CutsceneKeying.RelativeToOf(file, position) is { } other)
        {
            return $"Its transform track is relative to binding {other}.";
        }
        return CutsceneKeying.Refusal(file, position, locked);
    }

    /// <summary>
    /// Keys a spawned camera's world pose at a time, in its transform track's space: its position and its rotation, with
    /// the rotation's angles unwrapped to the keys next to them.
    /// </summary>
    public static void Set(CutsceneFile file, int binding, IReadOnlyList<long> position, Quat rotation, int tick, IReadOnlySet<int>? locked)
    {
        if (Refusal(file, binding, locked) != null || file.Bindings.FirstOrDefault(b => b.Id == binding) is not { } block)
        {
            return;
        }
        var positionTarget = new KeyTarget.Pose(binding, PosePart.Position);
        var rotationTarget = new KeyTarget.Pose(binding, PosePart.Rotation);
        double[] place;
        double[] turn;
        if (CutsceneKeying.OriginOf(file, positionTarget) is { } originMeters)
        {
            if (CutsceneKeying.NeedsOrigin(file, positionTarget))
            {
                CutsceneKeying.SetOrigin(file, positionTarget, PoseKeys.OriginNear(position).Meters);
                originMeters = CutsceneKeying.OriginOf(file, positionTarget)!;
            }
            place = PoseKeys.AbsolutePosition(position, PoseKeys.Units(originMeters));
            turn = PoseKeys.Euler(rotation.Normalized());
        }
        else
        {
            var (ownUnits, own) = SpawnPose(block);
            var offset = new Vec3((position[0] - ownUnits[0]) / PoseKeys.UnitsPerMeter, (position[1] - ownUnits[1]) / PoseKeys.UnitsPerMeter,
                (position[2] - ownUnits[2]) / PoseKeys.UnitsPerMeter);
            place = PoseKeys.RelativePosition(offset, own);
            turn = PoseKeys.RelativeRotation(own, rotation);
        }
        turn = PoseKeys.Unwrap(turn, CutsceneKeying.NearKeys(file, rotationTarget, tick));
        CutsceneKeying.SetKeys(file, positionTarget, tick, place, "Transform", locked);
        CutsceneKeying.SetKeys(file, rotationTarget, tick, turn, "Transform", locked);
    }

    /// <summary>The pose that a spawned binding spawns with: its <c>position</c> in World_Position units and its <c>rotation</c>.</summary>
    public static (long[] Units, Quat Rotation) SpawnPose(CutsceneBlock binding)
    {
        var position = Numbers(binding.Get("position"));
        var rotation = Numbers(binding.Get("rotation"));
        long[] units = position is [var x, var y, var z] ? PoseKeys.Units([x, y, z]) : [0, 0, 0];
        var q = rotation is [var qx, var qy, var qz, var qw] ? new Quat(qx, qy, qz, qw).Normalized() : Quat.Identity;
        return (units, q);
    }

    static double[] Numbers(string? text) =>
        text?.Trim().TrimStart('[').TrimEnd(']').Split(',') is { } parts
        && parts.All(p => double.TryParse(p.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out _))
            ? [.. parts.Select(p => double.Parse(p.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture))]
            : [];
}
