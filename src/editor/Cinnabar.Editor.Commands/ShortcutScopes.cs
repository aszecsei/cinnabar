namespace Cinnabar.Editor.Commands;

/// <summary>
/// The parts of the editor whose controls have shortcuts of their own (see docs/editor/shell-and-panels.md#commands):
/// a command whose <see cref="Command.ShortcutScopes"/> names one of these has its key only while the keyboard is in
/// such a control.
/// </summary>
public static class ShortcutScopes
{
    /// <summary>A scene view: the tools, the mesh mode's keys and the texture tools' keys.</summary>
    public const string Viewport = "viewport";

    /// <summary>A graph editor's canvas, or the UI editor's canvas.</summary>
    public const string Canvas = "canvas";

    /// <summary>The content browser.</summary>
    public const string ContentBrowser = "contentBrowser";

    /// <summary>Every scope, in no order that matters.</summary>
    public static readonly IReadOnlyList<string> All = [Viewport, Canvas, ContentBrowser];

    /// <summary>Where a scope's keys work, for tooltips, as in "W in the viewport".</summary>
    public static string Label(string scope) => scope switch
    {
        Viewport => "in the viewport",
        Canvas => "in a graph or UI canvas",
        ContentBrowser => "in the content browser",
        _ => $"in {scope}",
    };
}
