using Cinnabar.Editor.Cutscenes;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

/// <summary>Which part of a cutscene a render out renders: its range, the loop's in and out points, or the selected shot.</summary>
public enum RenderOutRange
{
    Whole,
    InOut,
    Shot,
}

/// <summary>A tab's render out (see docs/editor/cutscene-editor.md#render-out): its dialog's choices and its sidecars' times.</summary>
public sealed partial class CutsceneEditor
{
    /// <summary>The view shows the render out dialog for the tab.</summary>
    public event Action? RenderOutRequested;

    public void RequestRenderOut() => RenderOutRequested?.Invoke();

    /// <summary>The cutscene's name: its file's, without the extension.</summary>
    public string CutsceneName => Path.GetFileNameWithoutExtension(RootDocument.Path);

    /// <summary>The ticks that a part of the cutscene covers, or null when the tab has none: no in or out point, or no shot selected.</summary>
    public (int Start, int End)? RenderOutSpan(RenderOutRange range)
    {
        switch (range)
        {
            case RenderOutRange.Whole:
                return CutsceneEdits.RangeOf(RootFile);
            case RenderOutRange.InOut:
                return (InPoint != null || OutPoint != null) && LoopRange is { } loop ? (loop.Start, loop.End) : null;
            case RenderOutRange.Shot:
                if (InContext || SelectedSubSequence is not { } path || ShotRows.FirstOrDefault(r => r.Path == path) is not { } shot)
                {
                    return null;
                }
                return (shot.Start, shot.Start + shot.Length);
        }
        return null;
    }

    /// <summary>The cameras that a render out can see through instead of the cut track: the bindings that spawn or possess one, by ID.</summary>
    public IReadOnlyList<(uint Binding, string Name)> RenderOutCameras() =>
    [
        .. RootFile.Bindings
            .Where(b => b.Id is not null && RootFile.Tracks.Any(t => t.TrackKind == "camera_cut"
                && t.Children.Any(c => c.Get("camera") == b.Id.ToString())))
            .Select(b => ((uint)b.Id!.Value, b.Name ?? $"binding {b.Id}")),
    ];

    /// <summary>The settings that the dialog starts from: the whole range at the cutscene's rate, at 1080p, to the project's renders folder.</summary>
    public RenderOutSettings DefaultRenderOut(string projectDirectory, bool video)
    {
        var (start, end) = CutsceneEdits.RangeOf(RootFile);
        return new RenderOutSettings(System.Convert.FromHexString(Guid), CutsceneName, start, end, (uint)RootFile.Rate, 1920, 1080,
            RenderOutFormat.Png, 0, 8, Path.Combine(projectDirectory, "renders", CutsceneName), RenderOutSettings.DefaultPattern,
            true, video);
    }

    /// <summary>A frame's time for its sidecar: its timecode and frame at the cutscene's rate, and its shot, or "gameplay".</summary>
    public RenderOutFrameTime RenderOutTime(int tick)
    {
        var rate = RootFile.Rate;
        var shot = CutsceneTimelineLayout.ShotAt(RootFile, tick, SilentTracks()) ?? "gameplay";
        return new RenderOutFrameTime(CutsceneTime.Timecode(tick, rate), (int)CutsceneTime.Frames(tick, rate), shot);
    }
}
