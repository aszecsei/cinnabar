using Cinnabar.Editor.Tools;
using Cinnabar.Editor.Viewport;
using ViewportSettings = Cinnabar.Editor.Link.Protocol.ViewportSettings;

namespace Cinnabar.Editor.Shell;

/// <summary>How many viewports the editor shows, and where (see docs/editor/viewport.md#several-viewports).</summary>
public enum ViewportArrangement
{
    /// <summary>The first viewport alone.</summary>
    Single,
    /// <summary>Two viewports, left and right.</summary>
    SideBySide,
    /// <summary>Two viewports, one above the other.</summary>
    Stacked,
    /// <summary>Four viewports, two by two.</summary>
    Quad,
}

/// <summary>
/// One of the editor's viewports of the scene (see docs/editor/viewport.md#several-viewports): its frames from the game,
/// its camera and how it draws. The first is the host's frame target and is always open. The others are open while the
/// arrangement shows them, and the game draws each into a shared target of its own. The shell makes them all once, so
/// a viewport that closes and opens again keeps its camera and its settings.
/// </summary>
public sealed class SceneViewport(int index, ViewportSettings settings)
{
    /// <summary>The viewports that the game can draw: the frame target's, and its extra views.</summary>
    public const int Max = 4;

    /// <summary>The viewport's number in the link's messages. 0 is the first.</summary>
    public int Index { get; } = index;

    /// <summary>The first viewport: the host's frame target, which takes the game's input in play mode and which captures show.</summary>
    public bool IsMain => Index == 0;

    public ViewportSession Session { get; } = new();

    public EditorCamera Camera { get; } = new();

    /// <summary>How the viewport draws. The shell changes it (<see cref="EditorShell.ApplyViewportSettings"/>).</summary>
    public ViewportSettings Settings { get; internal set; } = settings;

    /// <summary>Whether the arrangement shows the viewport.</summary>
    public bool IsOpen { get; internal set; } = index == 0;

    /// <summary>Whether the camera has a place: the first viewport's always, and another one's once it has opened, which puts it where the first one's is.</summary>
    internal bool Placed { get; set; } = index == 0;

    // What the game was last sent of the viewport's gizmo and box handles, which a new game state forgets.
    internal string SentGizmo { get; set; } = "";
    internal string SentHandles { get; set; } = "";

    /// <summary>The frame's size in pixels: the host's, or before its first frame, the size that the viewport asked for.</summary>
    public (double Width, double Height) FrameSize
    {
        get
        {
            var size = Session.FrameSize is { Width: > 0, Height: > 0 } frame ? frame : Session.RequestedSize;
            return (Math.Max(size.Width, 1), Math.Max(size.Height, 1));
        }
    }

    /// <summary>The number of viewports that an arrangement shows.</summary>
    public static int Count(ViewportArrangement arrangement) => arrangement switch
    {
        ViewportArrangement.Single => 1,
        ViewportArrangement.Quad => 4,
        _ => 2,
    };
}
