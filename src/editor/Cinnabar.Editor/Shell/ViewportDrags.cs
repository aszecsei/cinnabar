using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Shell;

/// <summary>The modifier keys that a left drag in the viewport reads.</summary>
public readonly record struct DragKeys(bool Shift, bool Ctrl);

/// <summary>
/// A left drag in the viewport from press to release (see docs/editor/viewport.md#viewport), which the view forwards
/// to. A drag is a token for the work that it began: once its session has ended that work, for a change of the
/// selection, the tool or the mode, each of these does nothing.
/// </summary>
public interface IViewportDrag
{
    void Move(Vec2 pixel, DragKeys keys);

    /// <summary>The release: the drag's edit commits.</summary>
    void End(DragKeys keys);

    /// <summary>Esc: the drag puts back what it changed.</summary>
    void Cancel();

    /// <summary>The view lost the mouse's capture.</summary>
    void Lost() => Cancel();
}

/// <summary>A tool that a left press in the viewport may start a drag of. The shell's <see cref="EditorShell.LeftTools"/> tries each in order.</summary>
public interface IViewportTool
{
    /// <summary>A drag from a pixel of the frame, or null when the press is not this tool's.</summary>
    IViewportDrag? TryBegin(Vec2 pixel, DragKeys keys);

    /// <summary>The mouse over a pixel of the frame, with no button held. Every tool hovers.</summary>
    void Hover(Vec2 pixel) { }
}
