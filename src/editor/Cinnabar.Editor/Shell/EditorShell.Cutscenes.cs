using System.Text.Json;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>The cutscene editor's documents (see docs/editor/cutscene-editor.md).</summary>
public sealed partial class EditorShell
{
    public IReadOnlyList<CutsceneEditor> Cutscenes => [.. _graphEditors.OfType<CutsceneEditor>()];

    // A view's look changed, or the active view: each cutscene's camera rows read it again.
    void LooksChanged()
    {
        foreach (var cutscene in Cutscenes)
        {
            cutscene.OnLooksChanged();
        }
    }

    /// <summary>The cutscene editor whose document is active, or null when the viewport or another document is.</summary>
    public CutsceneEditor? ActiveCutscene => ActiveGraphEditor as CutsceneEditor;

    /// <summary>
    /// Asks whether to delete a cutscene's binding with tracks, by its name, its cutscene's and how many tracks go with
    /// it (see docs/editor/cutscene-editor.md#bindings). The window sets it, and tests answer it. Without it, the delete
    /// goes ahead.
    /// </summary>
    public Func<string, string, int, Task<bool>>? AskDeleteBinding { get; set; }

    // The one armed pick of a binding's entity, with its cutscene: the selection is the shell's, so only one cutscene
    // takes the next entity selected (see docs/editor/cutscene-editor.md#rebind-and-delete).
    (CutsceneEditor Owner, BindingPick Pick)? _bindingPick;

    /// <summary>A cutscene's armed pick, or null when none is armed or another cutscene's is.</summary>
    internal BindingPick? BindingPickOf(CutsceneEditor editor) => _bindingPick is { } armed && armed.Owner == editor ? armed.Pick : null;

    /// <summary>
    /// Arms a cutscene's pick, in place of any other cutscene's, or with null, cancels the cutscene's own. The one writer
    /// of the pick.
    /// </summary>
    internal void SetBindingPick(CutsceneEditor owner, BindingPick? pick)
    {
        var old = _bindingPick?.Owner;
        if (pick == null && old != owner)
        {
            return;
        }
        if (pick != null && _bindingPick is { } armed && armed.Owner == owner && armed.Pick == pick)
        {
            return;
        }
        _bindingPick = pick == null ? null : (owner, pick);
        if (old != null && old != owner)
        {
            old.OnPickChanged();
        }
        owner.OnPickChanged();
        Commands.InvalidateAll();
    }

    /// <summary>
    /// A click in a view that looks through a camera (see docs/editor/cutscene-editor.md#focus): with Ctrl, or with a pick
    /// of the camera's focus armed, it picks the focus at the pixel. Otherwise it selects what is drawn there.
    /// </summary>
    public void ClickInLook(int viewport, Maths.Vec2 pixel, SelectMode mode, bool control)
    {
        if (Looks[viewport] is ViewLook.Camera camera && (control || camera.Owner.PicksFocusOnClick(viewport)))
        {
            camera.Owner.PickFocus(viewport, pixel);
            return;
        }
        PickAt(pixel, mode);
    }

    /// <summary>Whether a click in a view picks the focus of the camera that it looks through, which Esc disarms.</summary>
    public bool FocusPickArmed(int viewport) =>
        Looks[viewport] is ViewLook.Camera camera && camera.Owner.PicksFocusOnClick(viewport);

    /// <summary>Disarms the pick of the focus of the camera that a view looks through, as Esc does. False when none was armed.</summary>
    public bool CancelFocusPick(int viewport) =>
        FocusPickArmed(viewport) && Looks[viewport] is ViewLook.Camera camera && camera.Owner.DisarmFocusPick();

    /// <summary>Whether a cutscene's pick of a binding's entity is armed, which Esc in a scene view cancels.</summary>
    public bool BindingPicking => _bindingPick != null;

    /// <summary>Cancels the armed pick of a binding's entity, as Esc does. False when none was armed.</summary>
    public bool CancelBindingPicks()
    {
        if (_bindingPick is not { } armed)
        {
            return false;
        }
        SetBindingPick(armed.Owner, null);
        return true;
    }

    // Another cutscene's tab, or the close of the pick's own, ends the pick. The viewport and other documents do not:
    // the designer picks there.
    void EndBindingPickFor(CutsceneEditor? active, CutsceneEditor? closed)
    {
        if (_bindingPick is { } armed && (armed.Owner == closed || (active != null && active != armed.Owner)))
        {
            SetBindingPick(armed.Owner, null);
        }
    }

    /// <summary>
    /// What the timeline's last copy or cut holds, which a paste in the tab of the cutscene that it came from puts at its
    /// playhead (see docs/editor/cutscene-editor.md#copy-and-paste). The editor keeps it, not the system's clipboard.
    /// </summary>
    public CutsceneClip? CutsceneClipboard { get; internal set; }

    /// <summary>
    /// Whether a channel is of a property track whose field steps, as an integer, a bool or an enum does
    /// (<see cref="KeyValues.Shape"/>), as the game's component types tell. A field that the game has not described is
    /// taken as smooth.
    /// </summary>
    internal bool SteppedChannel(CutsceneBlock channel)
    {
        if (CutsceneEdits.TrackOf(channel) is not { TrackKind: "property" } track
            || !ulong.TryParse(track.Get("component")?.Trim(), System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var component)
            || track.Get("field")?.Trim() is not { } quoted)
        {
            return false;
        }
        var name = TextQuote.Unquote(quoted) ?? quoted;
        return World.Type(component)?.Fields.FirstOrDefault(f => f.Name == name) is { } field && KeyValues.Shape(field) == PropertyShape.Stepped;
    }

    /// <summary>
    /// Opens a cutscene in its editor, or shows its open editor. A file that does not start with <c>cutscene 1</c>
    /// opens in the script editor instead, with the reason in the console.
    /// </summary>
    public CutsceneEditor? OpenCutscene(Link.Cook.Asset asset) => OpenEditor(asset) as CutsceneEditor;

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
        // A file from before mute and solo has neither.
        return _cutsceneViews.GetValueOrDefault(guid) is { } view
            ? view with { Locked = view.Locked ?? [], Muted = view.Muted ?? [], Soloed = view.Soloed ?? [] }
            : CutsceneTimelineView.Default;
    }

    internal void SaveCutsceneTimelineSettings(string guid, CutsceneTimelineView view)
    {
        CutsceneTimelineSettingsOf(guid);
        if (view.IsDefault)
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

/// <summary>
/// How a user's timeline shows a cutscene: frames or timecode on the ruler, the IDs of the locked, the muted and the
/// soloed tracks, whether the preview plays grains while scrubbed and sends events while it plays, and the stand-in of
/// each script slot by its binding's ID (see <see cref="CutsceneStandIns"/>). A file from before a field has its default.
/// </summary>
public sealed record CutsceneTimelineView(bool ShowFrames, int[] Locked, int[]? Muted = null, int[]? Soloed = null, bool ScrubSound = true, bool Events = false,
    Dictionary<int, string>? StandIns = null)
{
    public static readonly CutsceneTimelineView Default = new(false, [], [], []);

    /// <summary>Whether the view is the default, which the file leaves out.</summary>
    public bool IsDefault => !ShowFrames && (Locked?.Length ?? 0) == 0 && (Muted?.Length ?? 0) == 0 && (Soloed?.Length ?? 0) == 0
        && ScrubSound && !Events && (StandIns?.Count ?? 0) == 0;
}
