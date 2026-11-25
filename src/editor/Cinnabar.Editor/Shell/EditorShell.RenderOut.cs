using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using LogLevel = Cinnabar.Editor.Model.LogLevel;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Render out (see docs/editor/cutscene-editor.md#render-out): a cutscene tab asks the game to play its saved cutscene
/// out of real time, and the host writes its frames and its sound. The world runs as in Play while it does, so the
/// editor leaves Edit as Play does, and when the game ends the run, gives the world back as Stop does. Stop cancels a run,
/// as does closing its tab, and a lost link ends it.
/// </summary>
public sealed partial class EditorShell
{
    RenderOutModel? _renderOuts;

    public RenderOutModel RenderOuts
    {
        get
        {
            if (_renderOuts == null)
            {
                _renderOuts = new RenderOutModel(Host.Send);
                _renderOuts.GameEnded += OnRenderOutGameEnded;
            }
            return _renderOuts;
        }
    }

    /// <summary>Why the tab cannot render out now, or null.</summary>
    public string? RenderOutRefusal(CutsceneEditor editor) =>
        !Host.Linked ? "no game is linked"
        : RenderOuts.Busy ? "a render out is under way"
        : Mode != EditorMode.Edit ? "a render out starts in Edit"
        : editor.RootDocument.IsDirty ? "save the cutscene first: a render out renders the saved cutscene"
        : Scene == null ? "no scene is open"
        : null;

    /// <summary>
    /// Renders the tab's cutscene out with the settings, and gives how it ended. The editor is out of Edit from the start
    /// to the game's end of the run, and the video, if any, is made after the world is back.
    /// </summary>
    public async Task<RenderOutResult> RenderOutAsync(CutsceneEditor editor, RenderOutSettings settings)
    {
        if (RenderOutRefusal(editor) is { } refusal)
        {
            Console.Add(LogLevel.Warning, $"render out: {refusal}");
            return new RenderOutResult(RenderOutOutcome.Failed, refusal, 0, settings.Folder, [], null, null);
        }
        var ffmpeg = Settings.Ffmpeg();
        var run = RenderOuts.RunAsync(settings, editor, ffmpeg, editor.RenderOutTime);
        if (RenderOuts.Busy)
        {
            LeaveEditForRenderOut();
            Console.Add(LogLevel.Info, $"render out: {settings.Name}, {settings.FrameCount} frames at {settings.Rate} a second to {settings.Folder}");
        }
        var result = await run;
        var level = result.Outcome == RenderOutOutcome.Done ? LogLevel.Info : LogLevel.Warning;
        Console.Add(level, $"render out: {result.Outcome}, {result.Frames} frames{(result.Video != null ? $" and {result.Video}" : "")}{(result.Reason != null ? $": {result.Reason}" : "")}");
        return result;
    }

    // The game plays the document's world from the editor's scene, as Play does: an open edit ends, the overrides end and
    // the preview closes. The game changes its own mode when the run begins, so none is sent.
    void LeaveEditForRenderOut()
    {
        Mesh.LeaveMeshMode();
        InterruptEdit();
        Overrides.EndAll(OverrideEnd.Mode);
        CutscenePreview.OnPlay();
        SetModeTo(EditorMode.Play, send: false);
    }

    // The game ended the run: its world goes back to the editor's scene, as at Stop.
    void OnRenderOutGameEnded()
    {
        if (Mode == EditorMode.Edit)
        {
            return;
        }
        SetStreamed(null);
        SetModeTo(EditorMode.Edit);
        SendScene();
    }
}
