using Avalonia;
using Cinnabar.Editor.Tools;
using Cinnabar.Editor.Viewport;
using ViewportKind = Cinnabar.Editor.Link.Protocol.ViewportKind;
using ViewportSettings = Cinnabar.Editor.Link.Protocol.ViewportSettings;

namespace Cinnabar.Editor.Shell;

/// <summary>What the game was last told of a viewport that it has open, which a new game state forgets (see <see cref="EditorViewport.Opened"/>).</summary>
/// <param name="Size">The size in the last <c>Open_Viewport</c>.</param>
/// <param name="Gizmo">The last <c>Gizmo_State</c>, as a key.</param>
/// <param name="Handles">The last <c>Box_Handles</c>, as a key.</param>
public sealed record OpenedViewport(PixelSize Size, string Gizmo = "", string Handles = "");

/// <summary>
/// One of the editor's views of the game (see docs/editor/viewport.md#views): a scene view, which draws the world from
/// the editor's camera with the editor's tools, or the Game view, which draws it from the game's camera. The shell makes
/// all of them once, so a view that closes and opens again keeps its camera and its settings. Each has a document in the
/// dock layout, a number in the link's messages, and a shared target of its own while it is shown.
/// </summary>
public sealed class EditorViewport
{
    /// <summary>The viewports that the game can draw, which <c>link.MAX_VIEWPORTS</c> names.</summary>
    public const int Max = 4;

    /// <summary>How many of the viewports are scene views: the numbers below this.</summary>
    public const int SceneViews = 3;

    /// <summary>The Game view's number, which is the last.</summary>
    public const int GameIndex = SceneViews;

    readonly EditorCamera? _camera;

    public EditorViewport(int index, ViewportSettings settings)
    {
        Index = index;
        Kind = index == GameIndex ? ViewportKind.Game : ViewportKind.Scene;
        _camera = IsGame ? null : new EditorCamera();
        Settings = settings;
        // The first scene view starts at the origin. A scene view that is shown for the first time starts from another one's.
        Placed = index == 0 || IsGame;
        // A camera that has moved has a place, whoever moved it.
        if (_camera != null)
        {
            _camera.Changed += () => Placed = true;
        }
    }

    /// <summary>The viewport's number in the link's messages.</summary>
    public int Index { get; }

    public ViewportKind Kind { get; }

    public bool IsGame => Kind == ViewportKind.Game;

    /// <summary>The document's title: Scene, Scene 2, Scene 3 or Game.</summary>
    public string Title => IsGame ? "Game" : Index == 0 ? "Scene" : $"Scene {Index + 1}";

    public ViewportSession Session { get; } = new();

    /// <summary>The editor's camera. The Game view has none: it draws from the game's.</summary>
    public EditorCamera Camera => _camera ?? throw new InvalidOperationException("the Game view has no editor camera");

    /// <summary>Whether the viewport has an editor camera: a scene view.</summary>
    public bool HasCamera => _camera != null;

    /// <summary>How the viewport draws. The shell changes it (<see cref="EditorShell.ApplyViewportSettings"/>).</summary>
    public ViewportSettings Settings { get; internal set; }

    /// <summary>Whether the camera has a place. A scene view that is shown for the first time gets another one's.</summary>
    internal bool Placed { get; set; }

    /// <summary>
    /// What the game was last told of the viewport, or null when it has it closed: never opened, closed, or the game has
    /// a new state. The shell changes it in one place (<c>SyncViewport</c>), from <see cref="ViewportSession.Presence"/>.
    /// </summary>
    internal OpenedViewport? Opened { get; set; }

    /// <summary>Whether the viewport's control is on screen with a size.</summary>
    public bool IsShown => Session.Presence is ViewportPresence.Shown;

    /// <summary>The frame's size in pixels: the host's, or before its first frame, the size that the control has.</summary>
    public (double Width, double Height) FrameSize
    {
        get
        {
            var size = Session.FrameSize is { Width: > 0, Height: > 0 } frame ? frame
                : Session.Presence is ViewportPresence.Shown { Size: var shown } ? shown : default;
            return (Math.Max(size.Width, 1), Math.Max(size.Height, 1));
        }
    }
}
