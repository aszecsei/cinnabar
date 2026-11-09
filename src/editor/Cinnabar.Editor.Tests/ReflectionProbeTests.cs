using Avalonia;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using EditorCamera = Cinnabar.Editor.Tools.EditorCamera;
using SceneComponent = Cinnabar.Editor.Document.SceneComponent;
using SceneEntity = Cinnabar.Editor.Document.SceneEntity;
using SceneField = Cinnabar.Editor.Document.SceneField;
using SceneValue = Cinnabar.Editor.Document.SceneValue;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The reflection probes in the editor (see docs/editor/viewport.md#reflection-probes): their boxes and handles, the drags
/// that resize them, the captures that the editor asks for, and the probe's state in words.
/// </summary>
public sealed class ReflectionProbeTests : IDisposable
{
    const double Width = 1600;
    const double Height = 900;

    readonly TempDirectory _temp = new("probes");
    readonly List<ILinkMessage> _sent = [];

    public void Dispose() => _temp.Dispose();

    static SceneEntity Probe(params SceneField[] fields)
    {
        var entity = new SceneEntity(1);
        entity.Components.Add(new SceneComponent(SceneEdits.ReflectionProbeId, "Reflection_Probe", [.. fields]));
        return entity;
    }

    static SceneField Field(string name, params double[] values) => new(name, SceneEdits.Floats(values));

    // A probe 10 m ahead of a camera at the origin, scaled 2 along x.
    static readonly Pose Ahead = new([0, 0, 10L << 24], Quat.Identity, [2, 1, 1]);

    static double[] Numbers(SetField op) => [.. op.Value!.Numbers.Select(n => n.Float)];

    [Fact]
    public void TheBoxesTakeTheirDefaultsAndTheScaleAsTheRendererDoes()
    {
        var boxes = ProbeBoxes.Of(Probe(Field("extent", 2, 0, 1), Field("blend_distance", 10), Field("projection_extent", 0, 1, 0),
            new SceneField("box_projection", SceneValue.Of(true))), new Pose([0, 0, 0], Quat.Identity, [2, -1, 3]))!;

        Assert.Equal([4, ProbeBoxes.DefaultExtent, 3], boxes.Extent);
        // The fade is no more than the smallest half size, and a projection of 0 is the influence box's.
        Assert.Equal(3, boxes.Blend);
        Assert.Equal([4, 1, 3], boxes.Projection);
        Assert.Equal(18, boxes.Handles().Count());
        Assert.Equal(12, ProbeBoxes.Of(Probe(), Pose.Identity)!.Handles().Count());
        Assert.Null(ProbeBoxes.Of(new SceneEntity(2), Pose.Identity));
    }

    [Fact]
    public void AHandleThatWouldSitOnTheInfluenceBoxsStaysAGapFromIt()
    {
        var boxes = ProbeBoxes.Of(Probe(Field("extent", 2, 2, 2), new SceneField("box_projection", SceneValue.Of(true))), Pose.Identity)!;
        var x = 0;
        Assert.Equal(2, boxes.Distance(new ProbeHandle(BoxHandleKind.Influence, x, 1), 0.5));
        // No fade, and a projection box that is the influence box: each handle stays half a meter off.
        Assert.Equal(1.5, boxes.Distance(new ProbeHandle(BoxHandleKind.Blend, x, 1), 0.5));
        Assert.Equal(2.5, boxes.Distance(new ProbeHandle(BoxHandleKind.Projection, x, -1), 0.5));
        var apart = ProbeBoxes.Of(Probe(Field("extent", 2, 2, 2), Field("blend_distance", 1), Field("projection_extent", 3, 3, 3),
            new SceneField("box_projection", SceneValue.Of(true))), Pose.Identity)!;
        Assert.Equal(1, apart.Distance(new ProbeHandle(BoxHandleKind.Blend, x, 1), 0.5));
        Assert.Equal(3, apart.Distance(new ProbeHandle(BoxHandleKind.Projection, x, 1), 0.5));
        Assert.Equal([0L, 0, -(3L << 24)], apart.Position(new ProbeHandle(BoxHandleKind.Projection, 2, -1), 0.5));
    }

    [Fact]
    public void TheHitTestFindsTheNearestHandleOnScreen()
    {
        var camera = new EditorCamera();
        var boxes = ProbeBoxes.Of(Probe(Field("extent", 2, 1, 3)), Ahead)!;
        var gap = ProbeBoxes.Gap(boxes.HandleSize(camera, Height));
        var right = new ProbeHandle(BoxHandleKind.Influence, 0, 1);
        var at = camera.Project(camera.RelativeTo(boxes.Position(right, gap)), Width, Height)!.Value;

        Assert.Equal(right, boxes.HitTest(camera, at + new Vec2(3, -2), Width, Height));
        Assert.Equal(new ProbeHandle(BoxHandleKind.Blend, 0, 1), boxes.HitTest(camera,
            camera.Project(camera.RelativeTo(boxes.Position(new ProbeHandle(BoxHandleKind.Blend, 0, 1), gap)), Width, Height)!.Value, Width, Height));
        Assert.Null(boxes.HitTest(camera, at + new Vec2(Gizmo.HitPixels + 1, 0), Width, Height));
    }

    [Fact]
    public void AResizeMovesBothFacesAndWritesTheFieldBeforeTheScale()
    {
        var boxes = ProbeBoxes.Of(Probe(Field("extent", 2, 0, 3), Field("blend_distance", 0.5)), Ahead)!;

        // The influence box is 4 m along x after the scale: a face out by 1 m is 5 m, 2.5 in the field, and the
        // defaults that the other axes stood for are written.
        var grown = boxes.Resize(1, new ProbeHandle(BoxHandleKind.Influence, 0, -1), 1, null);
        Assert.Equal(("extent", SceneEdits.ReflectionProbeId), (grown.Field, grown.Component));
        Assert.Equal([2.5, ProbeBoxes.DefaultExtent, 3], Numbers(grown));
        // Snapping rounds the half size in meters, and the box goes no smaller than its least.
        Assert.Equal([2.25, ProbeBoxes.DefaultExtent, 3], Numbers(boxes.Resize(1, new ProbeHandle(BoxHandleKind.Influence, 0, 1), 0.6, Snapping.Default)));
        Assert.Equal(ProbeBoxes.MinHalfSize, Numbers(boxes.Resize(1, new ProbeHandle(BoxHandleKind.Influence, 2, 1), -10, null))[2], 6);

        // The fade grows as its face moves in, in meters, from 0 to the smallest half size.
        var blend = new ProbeHandle(BoxHandleKind.Blend, 1, 1);
        Assert.Equal("blend_distance", boxes.Resize(1, blend, 0, null).Field);
        Assert.Equal([1.25], Numbers(boxes.Resize(1, blend, -0.75, null)));
        Assert.Equal([0.0], Numbers(boxes.Resize(1, blend, 2, null)));
        Assert.Equal([3.0], Numbers(boxes.Resize(1, blend, -10, null)));

        // The projection box, which is the influence box until it is set, takes its own field.
        var projection = boxes.Resize(1, new ProbeHandle(BoxHandleKind.Projection, 1, 1), 0.5, null);
        Assert.Equal("projection_extent", projection.Field);
        Assert.Equal([2, ProbeBoxes.DefaultExtent + 0.5, 3], Numbers(projection));
    }

    // Probes 10 m ahead of a camera at the origin: one with a box of 2 x 1 x 3 half sizes scaled 2 along x, one with a
    // tiny box that the gizmo covers, and a plain entity.
    const string Text = "scene 1\n\n" +
        "entity 0000000000000001\nname = \"Probe\"\ncomponent 1 Transform\n\tposition = [0, 0, 167772160]\n\trotation = [0, 0, 0, 1]\n\tscale = [2, 1, 1]\n" +
        "component 54 Reflection_Probe\n\textent = [2, 1, 3]\n\n" +
        "entity 0000000000000002\nname = \"Tiny\"\ncomponent 1 Transform\n\tposition = [0, 0, 167772160]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        "component 54 Reflection_Probe\n\textent = [0.2, 0.2, 0.2]\n\n" +
        "entity 0000000000000003\nname = \"Plain\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    const ulong ProbeHandleId = 1UL << 32;
    const ulong TinyHandle = 1UL << 32 | 1;
    const ulong PlainHandle = 1UL << 32 | 2;

    EditorShell NewShell(bool link = false)
    {
        var shell = TestShell.Open(_temp, "probes.scene", Text);
        if (link)
        {
            shell.Host.LinkForTests(_sent.Add);
        }
        shell.OnGameMessage(new EntitySnapshot(
        [
            new EntityInfo(ProbeHandleId, "Probe", 1, 0, true, [1, SceneEdits.ReflectionProbeId]),
            new EntityInfo(TinyHandle, "Tiny", 2, 0, true, [1, SceneEdits.ReflectionProbeId]),
            new EntityInfo(PlainHandle, "Plain", 3, 0, true, [1]),
        ]));
        shell.Viewport.RequestSize(new PixelSize(1600, 900));
        shell.Camera.Place([0, 0, 0], 0, 0);
        shell.SetTool(Tool.Select);
        return shell;
    }

    static double[] Extent(EditorShell shell, ulong id) =>
        [.. shell.Scene!.Scene.Find(id)!.Components.Single(c => c.Id == SceneEdits.ReflectionProbeId).Fields.Single(f => f.Name == "extent").Value.Numbers.Select(n => n.Float)];

    // Where a handle of the selected probe is on screen, moved along its face's axis by meters.
    static Vec2 OnScreen(EditorShell shell, ProbeHandle handle, double meters = 0)
    {
        var (width, height) = shell.FrameSize;
        var (_, boxes) = shell.SelectedProbe()!.Value;
        var gap = ProbeBoxes.Gap(boxes.HandleSize(shell.Camera, height));
        var at = shell.Camera.RelativeTo(boxes.Position(handle, gap)) + boxes.Outward(handle) * meters;
        return shell.Camera.Project(at, width, height)!.Value;
    }

    [Fact]
    public void DraggingAHandleResizesTheBoxInOneUndoEntry()
    {
        using var shell = NewShell();
        shell.Selection.Select(ProbeHandleId);
        var right = new ProbeHandle(BoxHandleKind.Influence, 0, 1);
        // The points are where the handle was at the press: each step moves it.
        Vec2[] points = [OnScreen(shell, right), OnScreen(shell, right, 0.5), OnScreen(shell, right, 1)];

        Assert.True(shell.PressGizmo(points[0]));
        Assert.Equal(right, shell.HotHandle);
        shell.DragGizmo(points[1], invertSnap: false);
        shell.DragGizmo(points[2], invertSnap: false);
        shell.ReleaseGizmo();

        var entry = Assert.Single(shell.Scene!.History);
        Assert.Equal("Resize Probe's Influence Box", entry.Label);
        // The face went out by 1 m, and the opposite one with it: 5 m, 2.5 before the scale.
        var extent = Extent(shell, 1);
        Assert.InRange(extent[0], 2.49, 2.51);
        Assert.Equal([1, 3], extent[1..]);
        // The probe stays where it is.
        Assert.Equal([0L, 0, 10L << 24], SceneEdits.WorldPose(shell.Scene.Scene, shell.Scene.Scene.Find(1)!)!.Position);
    }

    [Fact]
    public void AHandleDragCanBeCancelled()
    {
        using var shell = NewShell();
        shell.Selection.Select(ProbeHandleId);
        // A face across the view, since one that faces the camera moves along the ray.
        var blend = new ProbeHandle(BoxHandleKind.Blend, 0, -1);

        Assert.True(shell.PressGizmo(OnScreen(shell, blend)));
        shell.DragGizmo(OnScreen(shell, blend, -0.5), invertSnap: false);
        Assert.Contains(shell.Scene!.Scene.Find(1)!.Components.Single(c => c.Id == SceneEdits.ReflectionProbeId).Fields, f => f.Name == "blend_distance");
        shell.CancelGizmo();

        Assert.Empty(shell.Scene.History);
        Assert.DoesNotContain(shell.Scene.Scene.Find(1)!.Components.Single(c => c.Id == SceneEdits.ReflectionProbeId).Fields, f => f.Name == "blend_distance");
    }

    [Fact]
    public void TheGizmoWinsOverAHandleUnderIt()
    {
        using var shell = NewShell();
        shell.Selection.Select(TinyHandle);
        shell.SetTool(Tool.Move);
        var right = new ProbeHandle(BoxHandleKind.Influence, 0, 1);

        shell.HoverGizmo(OnScreen(shell, right));
        Assert.Equal(GizmoPart.X, shell.HotPart);
        Assert.Null(shell.HotHandle);
        // With the select tool, there is no gizmo, so the handle takes the mouse.
        shell.SetTool(Tool.Select);
        shell.HoverGizmo(OnScreen(shell, right));
        Assert.Equal(right, shell.HotHandle);
    }

    [Fact]
    public void OnlyOneSelectedProbeHasHandlesAndTheGameDrawsThem()
    {
        using var shell = NewShell(link: true);
        shell.Selection.Select(PlainHandle);
        Assert.Null(shell.SelectedProbe());
        Assert.Empty(_sent.OfType<BoxHandles>().Last().Handles);

        shell.Selection.Select(ProbeHandleId);
        var handles = _sent.OfType<BoxHandles>().Last();
        Assert.Equal(12, handles.Handles.Length);
        Assert.True(handles.Size > 0);
        Assert.Equal(6, handles.Handles.Count(h => h.Kind == BoxHandleKind.Influence));

        // A handle under the mouse is drawn hot.
        shell.HoverGizmo(OnScreen(shell, new ProbeHandle(BoxHandleKind.Influence, 1, -1)));
        Assert.Single(_sent.OfType<BoxHandles>().Last().Handles, h => h.Hot);

        shell.Selection.Set([ProbeHandleId, TinyHandle]);
        Assert.Null(shell.SelectedProbe());
        Assert.Empty(_sent.OfType<BoxHandles>().Last().Handles);
    }

    [Fact]
    public void TheCaptureCommandsSendTheProbesOnceLinked()
    {
        using var shell = NewShell();
        var capture = shell.Commands.Get(EditorCommands.CaptureProbe);
        var all = shell.Commands.Get(EditorCommands.CaptureAllProbes);
        shell.Selection.Select(ProbeHandleId);
        Assert.False(capture.CanExecute);
        Assert.False(all.CanExecute);

        shell.Host.LinkForTests(_sent.Add);
        Assert.True(capture.Execute());
        Assert.Equal([ProbeHandleId], _sent.OfType<CaptureReflectionProbes>().Last().Entities);
        shell.Selection.Set([PlainHandle, TinyHandle, ProbeHandleId]);
        Assert.True(capture.Execute());
        Assert.Equal([TinyHandle, ProbeHandleId], _sent.OfType<CaptureReflectionProbes>().Last().Entities);
        Assert.True(all.Execute());
        Assert.Empty(_sent.OfType<CaptureReflectionProbes>().Last().Entities);

        // A plain entity has no probe to capture.
        shell.Selection.Select(PlainHandle);
        Assert.False(capture.CanExecute);
        Assert.True(all.CanExecute);
    }

    [Fact]
    public void ANewReflectionProbeIsOneUndoEntry()
    {
        using var shell = NewShell();
        shell.Selection.Select(PlainHandle);

        Assert.True(shell.Commands.Get(EditorCommands.CreateReflectionProbe).Execute());

        var created = shell.Scene!.Scene.Entities.Single(e => e.Id > 3);
        Assert.Equal("Reflection Probe", created.Name);
        Assert.Contains(created.Components, c => c.Id == SceneEdits.ReflectionProbeId);
        Assert.Equal("Create Reflection Probe", Assert.Single(shell.Scene.History).Label);
    }

    [Fact]
    public void TheGamesViewOfAProbeLastsAsLongAsItsEntityInTheWorld()
    {
        using var shell = NewShell(link: true);
        var changes = new List<ulong>();
        shell.World.ProbeChanged += changes.Add;
        ReflectionProbeView Captured(ulong entity) => new(entity, ReflectionProbeStatus.Captured, false, true, 2);

        shell.OnGameMessage(Captured(ProbeHandleId));
        Assert.Equal(ReflectionProbeStatus.Captured, shell.World.Probe(ProbeHandleId)!.Value.View.Status);
        // None says that it has gone.
        shell.OnGameMessage(new ReflectionProbeView(ProbeHandleId, ReflectionProbeStatus.None, false, false, 0));
        Assert.Null(shell.World.Probe(ProbeHandleId));
        Assert.Equal([ProbeHandleId, ProbeHandleId], changes);

        // A destroyed entity's view goes, and a new snapshot or a closed link drops every view.
        shell.OnGameMessage(Captured(ProbeHandleId));
        shell.OnGameMessage(Captured(TinyHandle));
        shell.OnGameMessage(new EntityDelta([], [TinyHandle]));
        Assert.Null(shell.World.Probe(TinyHandle));
        Assert.Equal(TinyHandle, changes[^1]);
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(ProbeHandleId, "Probe", 1, 0, true, [1, SceneEdits.ReflectionProbeId])]));
        Assert.Null(shell.World.Probe(ProbeHandleId));
        shell.OnGameMessage(Captured(ProbeHandleId));
        shell.World.Clear();
        Assert.Null(shell.World.Probe(ProbeHandleId));
        // An entity that the world does not know has none.
        shell.OnGameMessage(Captured(PlainHandle + 100));
        Assert.Null(shell.World.Probe(PlainHandle + 100));
    }

    [Fact]
    public void AProbesStateReadsAsWords()
    {
        var received = new DateTime(2026, 11, 8, 12, 0, 10, DateTimeKind.Utc);
        (ReflectionProbeView, DateTime) View(ReflectionProbeStatus status, bool capturing = false, bool complete = true) =>
            (new ReflectionProbeView(1, status, capturing, complete, 10), received);
        var at = new DateTime(2026, 11, 8, 12, 0, 0, DateTimeKind.Utc).ToLocalTime().ToString("HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture);

        Assert.StartsWith("Run the game", ReflectionProbeStatusText.Describe(null, linked: false));
        Assert.StartsWith("No capture", ReflectionProbeStatusText.Describe(null, linked: true));
        Assert.StartsWith("No slot", ReflectionProbeStatusText.Describe(View(ReflectionProbeStatus.NoSlot), true));
        Assert.Equal("A slot, waiting for its first capture. Capturing now.", ReflectionProbeStatusText.Describe(View(ReflectionProbeStatus.Waiting, capturing: true), true));
        Assert.Equal($"A slot, captured at {at}.", ReflectionProbeStatusText.Describe(View(ReflectionProbeStatus.Captured), true));
        Assert.StartsWith($"A slot, captured at {at}, provisional", ReflectionProbeStatusText.Describe(View(ReflectionProbeStatus.Captured, complete: false), true));
    }

    [Fact]
    public void TheResourceMonitorShowsTheReflectionsMemory()
    {
        var reader = new LinkReader(new byte[1024]);
        var none = GameStats.Read(ref reader);
        Assert.Empty(ResourceMonitorView.ReflectionProbeRows(none));

        var stats = none with { ReflectionProbes = 3, ReflectionProbeSlots = 2, ReflectionProbeCapacity = 16, ReflectionProbeFaces = 6, ReflectionMemory = 3 << 20 };
        var rows = ResourceMonitorView.ReflectionProbeRows(stats).ToDictionary(r => r.Name, r => r.Value);
        Assert.Equal("2 / 16", rows["Reflection probe slots"]);
        Assert.Equal("6", rows["Reflection probe faces"]);
        Assert.Equal(ResourceStats.Bytes(3 << 20), rows["Reflection memory"]);
        // The screen-space reflections without the probes have memory and no probe rows.
        Assert.Equal(["Reflection memory"], ResourceMonitorView.ReflectionProbeRows(none with { ReflectionMemory = 1 }).Select(r => r.Name));
    }
}
