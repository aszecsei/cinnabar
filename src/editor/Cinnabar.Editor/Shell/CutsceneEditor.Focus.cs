using System.Globalization;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using LogLevel = Cinnabar.Editor.Model.LogLevel;
using PickResult = Cinnabar.Editor.Link.Protocol.PickResult;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// A camera binding's focus (see docs/editor/cutscene-editor.md#focus): Focus On, which sets the focus constraint on the
/// binding, and Pick Focus, which sets the focus distance to the depth of what a looking view draws at a pixel.
/// </summary>
public sealed partial class CutsceneEditor
{
    // The armed pick of a focus: the view, and the look through a camera binding, by its serial, that the next click in
    // the view picks for. A pick armed for a look that has ended does nothing, and shows as none.
    (int Viewport, int Binding, ulong Serial)? _focusArmed;

    // Whether an armed pick's look is still the view's.
    bool ArmedLooks((int Viewport, int Binding, ulong Serial) armed) =>
        _shell.Looks[armed.Viewport] is ViewLook.Camera camera && camera.Owner == this && camera.Binding == armed.Binding && camera.Serial == armed.Serial;

    /// <summary>The camera binding whose focus the next click in the view that looks through it picks, or null.</summary>
    public int? FocusArmed => _focusArmed is { } armed && ArmedLooks(armed) ? armed.Binding : null;

    /// <summary>The binding that a camera binding's own focus constraint names, or null.</summary>
    public int? FocusOn(int binding) =>
        File.Bindings.FirstOrDefault(b => b.Id == binding)?.Get("focus") is { } text && CutsceneFile.TryParseTicks(text.Trim(), out var id) ? id : null;

    /// <summary>
    /// The binding that a camera focuses on at the playhead: its own focus constraint, or that of the camera cut section
    /// over the playhead that shows it. Null when no constraint sets its focus.
    /// </summary>
    public int? FocusedOn(int binding)
    {
        if (FocusOn(binding) is { } own)
        {
            return own;
        }
        var section = File.Tracks.Where(t => t.TrackKind == "camera_cut").SelectMany(t => t.Children)
            .FirstOrDefault(s => s.Kind == CutsceneBlockKind.Section && s.Start <= Playhead && Playhead < s.End
                && s.Get("camera") is { } camera && CutsceneFile.TryParseTicks(camera.Trim(), out var id) && id == binding);
        return section?.Get("focus") is { } text && CutsceneFile.TryParseTicks(text.Trim(), out var on) ? on : null;
    }

    /// <summary>
    /// Sets or clears a camera binding's focus constraint, as one undo entry, "Focus On". The constraint is the binding's,
    /// not a key: it holds over the whole cutscene.
    /// </summary>
    public void SetFocusOn(int binding, int? target)
    {
        if (Document.InTransaction || target == binding || FocusOn(binding) == target)
        {
            return;
        }
        Key("Focus On", f => f.Bindings.FirstOrDefault(b => b.Id == binding)?.Set("focus", target?.ToString(CultureInfo.InvariantCulture)));
    }

    /// <summary>Why a click in a viewport cannot pick the focus of the camera that it looks through, or null when it can.</summary>
    public string? PickFocusRefusal(int viewport)
    {
        if (_shell.Looks[viewport] is not ViewLook.Camera camera || camera.Owner != this)
        {
            return "Look through a camera of the cutscene in a scene view to pick its focus there.";
        }
        if (!camera.Drawn)
        {
            return "The view does not draw through the camera yet, so a pick would not hit what the camera sees.";
        }
        if (LensTargetOf(camera.Binding) is LensTarget.Refused refused)
        {
            return refused.Why;
        }
        if (FocusedOn(camera.Binding) is { } on)
        {
            return $"The camera focuses on {BindingName(on)}. Clear its Focus On to pick a distance.";
        }
        return _shell.Host.Linked ? null : "The game is not running, so nothing answers the pick.";
    }

    /// <summary>
    /// Arms a pick of a camera binding's focus in the scene view that looks through it: the next click there picks the
    /// focus, and Esc disarms it. Arming it again disarms it. Null when it armed, and otherwise why not, as when no view
    /// looks through the camera.
    /// </summary>
    public string? ArmFocusPick(int binding)
    {
        if (FocusArmed == binding)
        {
            DisarmFocusPick();
            return null;
        }
        if (_shell.Looks.ViewThrough(this, binding) is not { } view || _shell.Looks[view] is not ViewLook.Camera camera)
        {
            return "Look through the camera in a scene view to pick its focus there.";
        }
        if (PickFocusRefusal(view) is { } why)
        {
            return why;
        }
        _focusArmed = (view, binding, camera.Serial);
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
        return null;
    }

    /// <summary>Disarms the pick of a focus. False when none was armed for a look that is still there.</summary>
    public bool DisarmFocusPick()
    {
        if (_focusArmed is not { } armed)
        {
            return false;
        }
        _focusArmed = null;
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
        return ArmedLooks(armed);
    }

    /// <summary>Whether a click in a viewport picks focus, as a pick armed for the view's look makes it.</summary>
    public bool PicksFocusOnClick(int viewport) => _focusArmed is { } armed && armed.Viewport == viewport && ArmedLooks(armed);

    /// <summary>
    /// Picks the focus of the camera that a viewport looks through, at a pixel of its frame (see
    /// docs/editor/cutscene-editor.md#focus): the game's answer sets its focus distance to the depth there, keyed with
    /// auto-key and otherwise held over the preview. An answer that comes after the look or its session changed does
    /// nothing. False, with the reason in the console, when it cannot pick.
    /// </summary>
    public bool PickFocus(int viewport, Vec2 pixel)
    {
        DisarmFocusPick();
        if (PickFocusRefusal(viewport) is { } why)
        {
            _shell.Console.Add(LogLevel.Warning, $"pick focus: {why}");
            return false;
        }
        var look = (ViewLook.Camera)_shell.Looks[viewport];
        return _shell.PickPixelIn(viewport, pixel, result => OnFocusPicked(viewport, look, result));
    }

    void OnFocusPicked(int viewport, ViewLook.Camera look, PickResult result)
    {
        if (_shell.Looks[viewport] is not ViewLook.Camera { Drawn: true } now || now.Owner != this || now.Binding != look.Binding
            || now.Serial != look.Serial || now.Ticket != look.Ticket)
        {
            return;
        }
        if (result.Depth <= 0)
        {
            _shell.Console.Add(LogLevel.Warning, "pick focus: nothing is drawn under the pointer.");
            return;
        }
        var depth = Math.Round(result.Depth, 3);
        if (SetLens(look.Binding, [("focus_distance", depth)], "Pick Focus") is { } why)
        {
            _shell.Console.Add(LogLevel.Warning, $"pick focus: {why}");
        }
    }

    string BindingName(int binding) => File.Bindings.FirstOrDefault(b => b.Id == binding)?.Name ?? $"binding {binding}";
}
