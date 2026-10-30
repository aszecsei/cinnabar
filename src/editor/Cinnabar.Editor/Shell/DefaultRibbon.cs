using Cinnabar.Editor.Commands.Ribbon;
using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Shell;

/// <summary>The editor's ribbon. It holds only commands that work today. Later phases add tabs as they add commands.</summary>
static class DefaultRibbon
{
    public static RibbonLayout Create(IEnumerable<PanelTool> panels)
    {
        var panelCommands = panels.Select(p => EditorCommands.Panel(p.Id)).ToList();
        return new RibbonLayout(
            Categories: [],
            Tabs:
            [
                new RibbonTab("home", "Home",
                [
                    new RibbonGroup("Scene",
                    [
                        new LargeButton(EditorCommands.OpenScene),
                        new LargeButton(EditorCommands.Save),
                        new SmallStack([EditorCommands.SaveAs]),
                    ]),
                    new RibbonGroup("Edit", [new SmallStack([EditorCommands.Undo, EditorCommands.Redo])]),
                    new RibbonGroup("Entity",
                    [
                        new LargeButton(EditorCommands.CreateEntity),
                        new SmallStack([EditorCommands.CreateVolume, EditorCommands.DuplicateEntity, EditorCommands.DeleteEntity]),
                        new SmallStack([EditorCommands.HideSelected, EditorCommands.ShowAll, EditorCommands.LockSelected]),
                        new SmallStack([EditorCommands.EditMesh, EditorCommands.MeshBlock]),
                    ]),
                    new RibbonGroup("Tools",
                    [
                        new SmallStack([EditorCommands.SelectTool, EditorCommands.MoveTool]),
                        new SmallStack([EditorCommands.RotateTool, EditorCommands.ScaleTool]),
                        new SmallStack([EditorCommands.LocalSpace, EditorCommands.Snap]),
                    ]),
                    new RibbonGroup("Play",
                    [
                        new LargeButton(EditorCommands.PlayMode),
                        new SmallStack([EditorCommands.PauseMode, EditorCommands.StepFrame, EditorCommands.StopMode]),
                        new SmallStack([EditorCommands.FreeCamera]),
                    ]),
                    new RibbonGroup("Game Window",
                    [
                        new SplitButton(EditorCommands.RunGame, [EditorCommands.RunGame, EditorCommands.StopGame]),
                        new ComboBox(EditorCommands.ProjectOutput),
                        new ComboBox(EditorCommands.UserOutput),
                        new ComboBox(EditorCommands.ProjectQuality),
                        new ComboBox(EditorCommands.UserQuality),
                    ]),
                    new RibbonGroup("Host",
                    [
                        new SplitButton(EditorCommands.RestartHost, [EditorCommands.RestartHost, EditorCommands.StopHost]),
                        new SmallStack([EditorCommands.RestartCook]),
                    ]),
                    new RibbonGroup("Window",
                    [
                        new LargeButton(EditorCommands.Palette),
                        new Dropdown("Panels", "panels", panelCommands),
                    ]),
                ]),
                new RibbonTab("view", "View",
                [
                    new RibbonGroup("Panels", panelCommands.Chunk(SmallStack.MaxCommands).Select(c => (RibbonItem)new SmallStack(c)).ToList()),
                    new RibbonGroup("Viewport",
                    [
                        new LargeButton(EditorCommands.Stats),
                        new SmallStack([EditorCommands.FrameSelected, EditorCommands.FrameScene, EditorCommands.OrbitSelection]),
                        new ComboBox(EditorCommands.ViewportScale),
                    ]),
                    new RibbonGroup("Rendering",
                    [
                        new ComboBox(EditorCommands.DebugView),
                        new SmallStack([EditorCommands.TemporalAa, EditorCommands.Bloom, EditorCommands.ToneMapping]),
                        new SmallStack([EditorCommands.Fog, EditorCommands.AmbientOcclusion, EditorCommands.GlobalIllumination]),
                        new SmallStack([EditorCommands.Shadows, EditorCommands.PostEffects, EditorCommands.OcclusionCulling]),
                        new SmallStack([EditorCommands.ExposureUp, EditorCommands.ExposureDown, EditorCommands.ExposureReset]),
                    ]),
                    new RibbonGroup("Quality",
                    [
                        new ComboBox(EditorCommands.ViewportQuality),
                        new ComboBox(EditorCommands.ViewportAntiAliasing),
                        new ComboBox(EditorCommands.ViewportRenderScale),
                    ]),
                    new RibbonGroup("Helpers", [new SmallStack([EditorCommands.Icons]), new ComboBox(EditorCommands.Helpers)]),
                    new RibbonGroup("Profiler",
                    [
                        new LargeButton(EditorCommands.CaptureFrame),
                        new SmallStack([EditorCommands.CaptureWorstFrame, EditorCommands.RecordZones]),
                    ]),
                    new RibbonGroup("Capture", [new LargeButton(EditorCommands.Screenshot), new SmallStack([EditorCommands.CaptureGif])]),
                    new RibbonGroup("Layout", [new LargeButton(EditorCommands.ResetLayout), new LargeButton(EditorCommands.CollapseRibbon)]),
                ]),
                // The scene's atmosphere (see docs/editor/shell-and-panels.md#atmosphere). Its panel has every setting.
                new RibbonTab("atmosphere", "Atmosphere",
                [
                    new RibbonGroup("Atmosphere", [new LargeButton(EditorCommands.AtmosphereSelect), new ComboBox(EditorCommands.AtmosphereMode)]),
                    new RibbonGroup("Sun",
                    [
                        new LargeButton(EditorCommands.LinkSun),
                        new LargeButton(EditorCommands.AimSun),
                        new Dropdown("Time of Day", "sun", [.. Atmosphere.TimesOfDay.Select(t => EditorCommands.TimeOfDay(t.Name))]),
                    ]),
                    new RibbonGroup("Sky",
                    [
                        new Dropdown("Air", "sky", [.. Atmosphere.Skies.Select(s => EditorCommands.SkyPreset(s.Name))]),
                        new SmallStack([EditorCommands.Stars, EditorCommands.Moon]),
                    ]),
                    new RibbonGroup("Fog",
                    [
                        new LargeButton(EditorCommands.AtmosphereFog),
                        new Dropdown("Density", "fog", [.. Atmosphere.Fogs.Select(f => EditorCommands.FogPreset(f.Name))]),
                    ]),
                    new RibbonGroup("Details", [new LargeButton(EditorCommands.Panel("atmosphere"))]),
                ]),
                // The contextual Mesh tab, while mesh mode is on (see docs/editor/mesh-editing.md#mesh-mode).
                new RibbonTab("mesh", "Mesh",
                [
                    new RibbonGroup("Selection",
                    [
                        new SmallStack([EditorCommands.MeshVertices, EditorCommands.MeshEdges, EditorCommands.MeshFaces]),
                        new SmallStack([EditorCommands.SelectAll, EditorCommands.MeshSelectThrough, EditorCommands.MeshSelectLinked]),
                        new SmallStack([EditorCommands.MeshGrow, EditorCommands.MeshShrink]),
                    ]),
                    new RibbonGroup("Edit",
                    [
                        new SmallStack([EditorCommands.MeshExtrude, EditorCommands.MeshPushPull, EditorCommands.MeshOffset]),
                        new SmallStack([EditorCommands.MeshInset, EditorCommands.MeshOutset, EditorCommands.MeshDuplicate]),
                        new SmallStack([EditorCommands.MeshCollapse, EditorCommands.MeshMergeFaces, EditorCommands.MeshInvert]),
                        new SmallStack([EditorCommands.DeleteEntity, EditorCommands.MeshDetach, EditorCommands.MeshExtract]),
                        new SmallStack([EditorCommands.MeshBevel, EditorCommands.MeshClean, EditorCommands.MeshRecalculateNormals]),
                        new SmallStack([EditorCommands.MeshEditPivot, EditorCommands.MeshCenterPivot, EditorCommands.MeshPivotToGrid]),
                        new ComboBox(EditorCommands.MeshBevelSegments),
                        new ComboBox(EditorCommands.MeshNormalAngle),
                    ]),
                    new RibbonGroup("Create",
                    [
                        new LargeButton(EditorCommands.MeshCreate),
                        new ComboBox(EditorCommands.MeshPrimitive),
                        new SmallStack([EditorCommands.MeshCut, EditorCommands.MeshDraw, EditorCommands.MeshApplyPoints]),
                        new ComboBox(EditorCommands.MeshSides),
                        new ComboBox(EditorCommands.MeshSegments),
                        new ComboBox(EditorCommands.MeshRings),
                        new ComboBox(EditorCommands.MeshSteps),
                        new ComboBox(EditorCommands.MeshArc),
                        new ComboBox(EditorCommands.MeshThickness),
                        new ComboBox(EditorCommands.MeshTubeRadius),
                    ]),
                    new RibbonGroup("Texture",
                    [
                        new SmallStack([EditorCommands.TextureShiftLeft, EditorCommands.TextureShiftRight, EditorCommands.TextureShiftUp]),
                        new SmallStack([EditorCommands.TextureShiftDown, EditorCommands.TextureRotateLeft, EditorCommands.TextureRotateRight]),
                        new SmallStack([EditorCommands.TextureScaleUp, EditorCommands.TextureScaleDown, EditorCommands.TextureResetScale]),
                        new SmallStack([EditorCommands.TextureAlignWorld, EditorCommands.TextureAlignFace, EditorCommands.TextureAlignEdge]),
                        new SmallStack([EditorCommands.TextureAlignToFace, EditorCommands.TextureFit, EditorCommands.TextureFlipU]),
                        new SmallStack([EditorCommands.TextureJustifyLeft, EditorCommands.TextureJustifyRight, EditorCommands.TextureJustifyCenter]),
                        new SmallStack([EditorCommands.TextureHotspot, EditorCommands.TextureHotspotNext, EditorCommands.TextureHotspotRandom]),
                        new SmallStack([EditorCommands.MeshTransformTexture]),
                        new ComboBox(EditorCommands.MeshDevMaterial),
                        new ComboBox(EditorCommands.MeshTexelDensity),
                    ]),
                    new RibbonGroup("Options",
                    [
                        new SmallStack([EditorCommands.MeshGridToggle, EditorCommands.MeshGridFiner, EditorCommands.MeshGridCoarser]),
                        new SmallStack([EditorCommands.Snap, EditorCommands.LocalSpace, EditorCommands.MeshKeepPlanar]),
                    ]),
                    new RibbonGroup("Mode", [new LargeButton(EditorCommands.ObjectMode)]),
                ]) { Context = MeshSession.MeshContext },
            ]);
    }
}
