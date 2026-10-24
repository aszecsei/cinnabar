using Cinnabar.Editor.Document;
using Cinnabar.Editor.Tools;
using GizmoKind = Cinnabar.Editor.Link.Protocol.GizmoKind;
using GizmoPart = Cinnabar.Editor.Link.Protocol.GizmoPart;

namespace Cinnabar.Editor.Tests;

/// <summary>The viewport's tools without a viewport: the camera, the gizmo's hit test and drags, and pose edits.</summary>
public sealed class ToolsTests
{
    const double Width = 1600;
    const double Height = 900;

    static void Near(double expected, double actual, double tolerance = 1e-6) =>
        Assert.True(Math.Abs(expected - actual) <= tolerance, $"expected {expected}, got {actual}");

    [Fact]
    public void TheCameraLooksDownItsZAndProjectsWhatItSees()
    {
        var camera = new EditorCamera();
        var center = camera.Ray(new Vec2(Width / 2, Height / 2), Width, Height);
        Assert.Equal(Vec3.UnitZ, center);

        // A point ahead and up shows above the middle, and its ray comes back to it.
        var point = new Vec3(1, 2, 10);
        var pixel = camera.Project(point, Width, Height)!.Value;
        Assert.True(pixel.Y < Height / 2 && pixel.X > Width / 2);
        var ray = camera.Ray(pixel, Width, Height);
        Near(0, (ray - point.Normalized()).Length);
        Assert.Null(camera.Project(new Vec3(0, 0, -1), Width, Height));
    }

    [Fact]
    public void LookingDownTurnsTheCameraDownAndOrbitingKeepsThePivot()
    {
        var camera = new EditorCamera();
        camera.Look(0, 100);
        Assert.True(camera.Forward.Y < 0);

        camera.Place([0, 0, 0], 0, 0);
        var pivot = camera.Pivot;
        camera.Orbit(150, -40);
        Assert.Equal(pivot, camera.Pivot, (a, b) => a.Zip(b).All(p => Math.Abs(p.First - p.Second) <= 2));
        Assert.True(camera.Forward.X > 0);

        // A notch of dolly takes the camera part of the way to the pivot, and leaves the pivot where it is.
        var distance = camera.PivotDistance;
        camera.Dolly(1);
        Assert.True(camera.PivotDistance < distance);
        Assert.Equal(pivot, camera.Pivot, (a, b) => a.Zip(b).All(p => Math.Abs(p.First - p.Second) <= 2));
    }

    [Fact]
    public void OrbitingAroundAPointKeepsItWhereItIsOnScreen()
    {
        var camera = new EditorCamera();
        camera.Place([0, 0, 0], 0, 0);
        // A point off to the side, not on the view's axis.
        long[] point = [2L << 24, 1L << 24, 6L << 24];
        var before = camera.Project(camera.RelativeTo(point), Width, Height)!.Value;

        camera.OrbitAround(point, 120, 35);

        var after = camera.Project(camera.RelativeTo(point), Width, Height)!.Value;
        Near(before.X, after.X, 1e-3);
        Near(before.Y, after.Y, 1e-3);
        Assert.NotEqual([0L, 0L, 0L], camera.Position);
        // The camera keeps its distance from the point.
        Near(Vec3.Between(point, [0, 0, 0]).Length, Vec3.Between(point, camera.Position).Length, 1e-4);
    }

    [Fact]
    public void FramingPutsThePointAheadAtThePivot()
    {
        var camera = new EditorCamera();
        long[] center = [2516582400000000000, 0, 0];
        camera.Frame(center, 2);
        var relative = camera.RelativeTo(center);
        Near(camera.PivotDistance, relative.Z, 1e-6);
        Assert.True(camera.PivotDistance > 2);
        Assert.Equal((-camera.Forward * camera.PivotDistance).Offset(center), camera.Position);
    }

    [Fact]
    public void TheGizmoFindsItsPartsOnScreen()
    {
        var camera = new EditorCamera();
        var center = new Vec3(0, 0, 5);
        var size = Gizmo.Size(camera, center, Height);
        var middle = camera.Project(center, Width, Height)!.Value;
        GizmoPart At(GizmoKind kind, Vec3 p) => Gizmo.HitTest(kind, camera, center, Quat.Identity, camera.Project(p, Width, Height)!.Value, Width, Height);

        Assert.Equal(GizmoPart.View, Gizmo.HitTest(GizmoKind.Translate, camera, center, Quat.Identity, middle, Width, Height));
        Assert.Equal(GizmoPart.X, At(GizmoKind.Translate, center + Vec3.UnitX * (0.9 * size)));
        Assert.Equal(GizmoPart.Y, At(GizmoKind.Translate, center + Vec3.UnitY * (0.9 * size)));
        Assert.Equal(GizmoPart.XY, At(GizmoKind.Translate, center + new Vec3(0.4, 0.4, 0) * size));
        Assert.Equal(GizmoPart.None, At(GizmoKind.Translate, center + new Vec3(-0.7, -0.7, 0) * size));
        // Seen straight down its axis, the Z ring is a circle around the middle.
        Assert.Equal(GizmoPart.Z, At(GizmoKind.Rotate, center + new Vec3(0.7071, 0.7071, 0) * size));
        Assert.Equal(GizmoPart.View, Gizmo.HitTest(GizmoKind.Rotate, camera, center, Quat.Identity,
            middle + new Vec2(Gizmo.ViewRing * Gizmo.ScreenLength, 0), Width, Height));
        Assert.Equal(GizmoPart.None, At(GizmoKind.None, center));
    }

    [Fact]
    public void DraggingAnAxisMovesAlongItAndSnaps()
    {
        var camera = new EditorCamera();
        var center = new Vec3(0, 0, 5);
        var size = Gizmo.Size(camera, center, Height);
        var grab = camera.Project(center + Vec3.UnitX * (0.5 * size), Width, Height)!.Value;
        var drag = new GizmoDrag(GizmoKind.Translate, GizmoPart.X, camera, center, Quat.Identity, grab, Width, Height);

        var target = camera.Project(center + Vec3.UnitX * (0.5 * size + 0.6), Width, Height)!.Value;
        Near(0.6, drag.Update(target, null).Translation.X, 1e-6);
        Assert.Equal(0.5, drag.Update(target, Snapping.Default).Translation.X, 9);
        // Off the axis, the move is still along it.
        var off = drag.Update(target + new Vec2(0, -40), null);
        Assert.True(off.Translation.X > 0.5);
        Assert.Equal(0, off.Translation.Y);
        Assert.Equal(0, off.Translation.Z);
    }

    [Fact]
    public void DraggingAPlaneMovesInIt()
    {
        var camera = new EditorCamera();
        var center = new Vec3(0, 0, 5);
        var size = Gizmo.Size(camera, center, Height);
        var start = center + new Vec3(0.4, 0.4, 0) * size;
        var drag = new GizmoDrag(GizmoKind.Translate, GizmoPart.XY, camera, center, Quat.Identity, camera.Project(start, Width, Height)!.Value, Width, Height);
        var change = drag.Update(camera.Project(start + new Vec3(0.3, -0.2, 0), Width, Height)!.Value, null);
        Near(0.3, change.Translation.X, 1e-6);
        Near(-0.2, change.Translation.Y, 1e-6);
        Near(0, change.Translation.Z, 1e-9);
    }

    [Fact]
    public void DraggingARingTurnsAboutItsAxis()
    {
        var camera = new EditorCamera();
        var center = new Vec3(0, 0, 5);
        var size = Gizmo.Size(camera, center, Height);
        Vec2 OnRing(double degrees) =>
            camera.Project(center + new Vec3(Math.Cos(degrees * Math.PI / 180), Math.Sin(degrees * Math.PI / 180), 0) * size, Width, Height)!.Value;
        var drag = new GizmoDrag(GizmoKind.Rotate, GizmoPart.Z, camera, center, Quat.Identity, OnRing(0), Width, Height);

        // A quarter of the way around the ring, counterclockwise as +z points away: x turns toward y.
        var change = drag.Update(OnRing(80), null);
        var turned = change.Rotation.Rotate(Vec3.UnitX);
        Near(80, Math.Atan2(turned.Y, turned.X) * 180 / Math.PI, 1e-3);
        var snapped = drag.Update(OnRing(80), Snapping.Default).Rotation.Rotate(Vec3.UnitX);
        Near(75, Math.Atan2(snapped.Y, snapped.X) * 180 / Math.PI, 1e-6);
    }

    [Fact]
    public void DraggingAScaleHandleScalesByTheDistance()
    {
        var camera = new EditorCamera();
        var center = new Vec3(0, 0, 5);
        var size = Gizmo.Size(camera, center, Height);
        var grab = center + Vec3.UnitX * size;
        var drag = new GizmoDrag(GizmoKind.Scale, GizmoPart.X, camera, center, Quat.Identity, camera.Project(grab, Width, Height)!.Value, Width, Height);
        var change = drag.Update(camera.Project(center + Vec3.UnitX * (2 * size), Width, Height)!.Value, null);
        Near(2, change.Scale.X, 1e-6);
        Assert.Equal(1, change.Scale.Y);
        Assert.Equal(1, change.Scale.Z);
    }

    static Scene TwoWithAChild()
    {
        var scene = new Scene();
        foreach (var (id, x) in new[] { (1UL, 0L), (2UL, 1L << 24) })
        {
            var e = new SceneEntity(id);
            e.Components.Add(new SceneComponent(SceneEdits.TransformId, "Transform", SceneEdits.TransformFields(new Pose([x, 0, 0], Quat.Identity, [1, 1, 1]))));
            scene.Entities.Add(e);
        }
        var child = new SceneEntity(3) { Parent = 1 };
        child.Components.Add(new SceneComponent(SceneEdits.LocalTransformId, "Local_Transform",
            [new("offset", SceneEdits.Floats(0, 1, 0)), new("rotation", SceneEdits.Floats(0, 0, 0, 1)), new("scale", SceneEdits.Floats(1, 1, 1))]));
        scene.Entities.Add(child);
        return scene;
    }

    static SceneValue? Field(Scene scene, ulong id, ulong component, string name) =>
        scene.Find(id)!.Components.Find(c => c.Id == component)!.Fields.Find(f => f.Name == name)?.Value;

    [Fact]
    public void APoseEditMovesTheTopmostEntitiesAndTheirChildrenFollow()
    {
        var scene = TwoWithAChild();
        var edit = new PoseEdit(scene, [1, 3]);
        Assert.Equal([1UL], edit.Moved);

        var ops = edit.Apply(GizmoChange.None with { Translation = new Vec3(0, 0, 2) }, [0, 0, 0], Quat.Identity);
        var set = Assert.IsType<SetField>(Assert.Single(ops));
        Assert.Equal(("position", 2L << 24), (set.Field, (long)set.Value!.Numbers[2].Integer!.Value));
    }

    [Fact]
    public void TurningSeveralEntitiesTurnsThemAboutThePivot()
    {
        var scene = TwoWithAChild();
        var edit = new PoseEdit(scene, [1, 2]);
        var quarter = Rotations.AxisAngle(Vec3.UnitY, Math.PI / 2);
        foreach (var op in edit.Apply(GizmoChange.None with { Rotation = quarter }, [0, 0, 0], Quat.Identity))
        {
            op.Apply(scene);
        }
        // Entity 2 was 1 m along x, and a quarter turn about y takes x to -z.
        var moved = SceneEdits.WorldPose(scene, scene.Find(2)!)!;
        Assert.Equal(-(1L << 24), moved.Position[2]);
        Assert.InRange(Math.Abs(moved.Position[0]), 0, 2);
        // The pivot's own entity only turns.
        Assert.Null(edit.Apply(GizmoChange.None with { Rotation = quarter }, [0, 0, 0], Quat.Identity)
            .OfType<SetField>().FirstOrDefault(s => s.Entity == 1 && s.Field == "position"));
    }

    [Fact]
    public void AChildMovesByItsLocalTransform()
    {
        var scene = TwoWithAChild();
        var ops = new PoseEdit(scene, [3]).Apply(GizmoChange.None with { Translation = new Vec3(0.5, 0, 0) }, [0, 1 << 24, 0], Quat.Identity);
        var set = Assert.IsType<SetField>(Assert.Single(ops));
        Assert.Equal((SceneEdits.LocalTransformId, "offset"), (set.Component, set.Field));
        Assert.Equal([0.5, 1, 0], set.Value!.Numbers.Select(n => n.Float));
    }

    [Fact]
    public void ADragStepReplacesTheStepBeforeForEachEntity()
    {
        var scene = TwoWithAChild();
        var document = new SceneDocument("two.scene", scene);
        var edit = new PoseEdit(scene, [1, 2]);
        document.Begin("Move 2 Entities");
        for (var step = 1; step <= 3; step++)
        {
            document.Preview(edit.Apply(GizmoChange.None with { Translation = new Vec3(step, 0, 0) }, [0, 0, 0], Quat.Identity));
        }
        document.Commit();

        var entry = Assert.Single(document.History);
        Assert.Equal(2, entry.Operations.Count);
        Assert.Equal(3L << 24, (long)Field(scene, 1, SceneEdits.TransformId, "position")!.Numbers[0].Integer!.Value);
        document.Undo();
        Assert.Equal(0L, (long)Field(scene, 1, SceneEdits.TransformId, "position")!.Numbers[0].Integer!.Value);
        Assert.Equal(1L << 24, (long)Field(scene, 2, SceneEdits.TransformId, "position")!.Numbers[0].Integer!.Value);
    }
}
