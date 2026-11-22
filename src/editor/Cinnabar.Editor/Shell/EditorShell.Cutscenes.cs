using System.Text.Json;
using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>The cutscene editor's documents (see docs/editor/cutscene-editor.md).</summary>
public sealed partial class EditorShell
{
    readonly List<CutsceneEditor> _cutscenes = [];

    public IReadOnlyList<CutsceneEditor> Cutscenes => _cutscenes;

    /// <summary>The cutscene editor whose document is active, or null when the viewport or another document is.</summary>
    public CutsceneEditor? ActiveCutscene => ActiveGraphEditor as CutsceneEditor;

    /// <summary>
    /// Opens a cutscene in its editor, or shows its open editor. A file that does not start with <c>cutscene 1</c>
    /// opens in the script editor instead, with the reason in the console.
    /// </summary>
    public CutsceneEditor? OpenCutscene(Link.Cook.Asset asset)
    {
        if (_cutscenes.Find(c => c.Guid == asset.Guid) is { } open)
        {
            Layout.ShowDocument(open);
            return open;
        }
        if (Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        var (document, problem) = CutsceneDocument.Open(path, asset.Guid);
        if (document == null)
        {
            Report("cutscene", path, [(problem!.Line, problem.Message, true)]);
            OpenScript(path, (uint)problem.Line);
            return null;
        }
        var editor = new CutsceneEditor(this, document);
        _cutscenes.Add(editor);
        _ = editor.CookNow();
        Layout.OpenDocument(new CutsceneEditorDocument(editor, () => new Cutscenes.CutsceneEditorView(this, editor)));
        GraphEditorsChanged?.Invoke();
        return editor;
    }

    // How each user's timeline shows each cutscene, by GUID, read when the first cutscene opens.
    Dictionary<string, CutsceneTimelineView>? _cutsceneViews;

    internal CutsceneTimelineView CutsceneTimelineSettingsOf(string guid)
    {
        if (_cutsceneViews == null)
        {
            _cutsceneViews = [];
            try
            {
                if (Settings.Read(EditorSettings.CutsceneTimelineFileName) is { } text
                    && JsonSerializer.Deserialize<Dictionary<string, CutsceneTimelineView>>(text) is { } saved)
                {
                    _cutsceneViews = saved;
                }
            }
            catch (JsonException e)
            {
                Console.Add(LogLevel.Warning, $"cutscene: cannot read {EditorSettings.CutsceneTimelineFileName}: {e.Message}");
            }
        }
        return _cutsceneViews.GetValueOrDefault(guid) ?? CutsceneTimelineView.Default;
    }

    internal void SaveCutsceneTimelineSettings(string guid, CutsceneTimelineView view)
    {
        CutsceneTimelineSettingsOf(guid);
        if (view == CutsceneTimelineView.Default || (!view.ShowFrames && view.Locked.Length == 0))
        {
            _cutsceneViews!.Remove(guid);
        }
        else
        {
            _cutsceneViews![guid] = view;
        }
        WriteSetting("cutscene", EditorSettings.CutsceneTimelineFileName, JsonSerializer.Serialize(_cutsceneViews));
    }
}

/// <summary>How a user's timeline shows a cutscene: frames or timecode on the ruler, and the IDs of the locked tracks.</summary>
public sealed record CutsceneTimelineView(bool ShowFrames, int[] Locked)
{
    public static readonly CutsceneTimelineView Default = new(false, []);
}
