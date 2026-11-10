using Avalonia;
using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Tools;
using Cinnabar.Editor.Viewport;
using CameraProjection = Cinnabar.Editor.Link.Protocol.CameraProjection;
using ViewportKind = Cinnabar.Editor.Link.Protocol.ViewportKind;
using ViewportSettings = Cinnabar.Editor.Link.Protocol.ViewportSettings;

namespace Cinnabar.Editor.Shell;

/// <summary>What the game was last told of a viewport that it has open, which a new game state forgets (see <see cref="EditorViewport.Opened"/>).</summary>
/// <param name="Size">The size in the last <c>Open_Viewport</c>.</param>
/// <param name="Gizmo">The last <c>Gizmo_State</c>, as a key.</param>
/// <param name="Handles">The last <c>Box_Handles</c>, as a key.</param>
public sealed record OpenedViewport(PixelSize Size, string Gizmo = "", string Handles = "");

/// <summary>Where a scene view's camera starts when the view is first shown (see <see cref="EditorViewport.StartCamera"/>).</summary>
public enum SceneViewStart
{
    /// <summary>Where the first scene view is: it starts at the origin, looking along +z.</summary>
    Perspective,
    /// <summary>Looking straight down, with +z up the view.</summary>
    Top,
    /// <summary>Looking along -z from +z, with +x to the left.</summary>
    Front,
    /// <summary>Looking along -x from +x, with +z to the right.</summary>
    Side,
}

/// <summary>
/// One of the editor's views of the game (see docs/editor/viewport.md#views): a scene view, which draws the world from
/// the editor's camera with the editor's tools, or the Game view, which draws it from the game's camera. The shell makes
/// all of them once, so a view that closes and opens again keeps its camera and its settings. A scene view is in the Scene
/// document and the Game view in the Game document, and each has a number in the link's messages and a shared target of
/// its own while it is shown.
/// </summary>
public sealed class EditorViewport
{
    /// <summary>The viewports that the game can draw, which <c>link.MAX_VIEWPORTS</c> names.</summary>
    public const int Max = 5;

    /// <summary>How many of the viewports are scene views: the numbers below this.</summary>
    public const int SceneViews = 4;

    /// <summary>The Game view's number, which is the last.</summary>
    public const int GameIndex = SceneViews;

    static readonly string[] Titles = ["Perspective", "Top", "Front", "Side"];

    readonly EditorCamera? _camera;

    public EditorViewport(int index, ViewportSettings settings)
    {
        Index = index;
        Kind = index == GameIndex ? ViewportKind.Game : ViewportKind.Scene;
        _camera = IsGame ? null : new EditorCamera();
        Settings = settings;
        Start = IsGame ? SceneViewStart.Perspective : (SceneViewStart)index;
        Projection = Start == SceneViewStart.Perspective ? CameraProjection.Perspective : CameraProjection.Orthographic;
        // The first scene view starts at the origin. The others start from its pivot when they are first shown.
        Placed = index == 0 || IsGame;
        // A camera that has moved has a place, whoever moved it.
        if (_camera != null)
        {
            _camera.Changed += () => Placed = true;
        }
    }

    /// <summary>How the camera starts when the view is first shown.</summary>
    public SceneViewStart Start { get; }

    /// <summary>The viewport's number in the link's messages.</summary>
    public int Index { get; }

    public ViewportKind Kind { get; }

    public bool IsGame => Kind == ViewportKind.Game;

    /// <summary>The view's title: Perspective, Top, Front, Side or Game.</summary>
    public string Title => IsGame ? "Game" : Titles[Index];

    /// <summary>The ID of the dock document that holds the view: <c>scene</c> for a scene view, <c>game</c> for the Game view.</summary>
    public string DocumentId => IsGame ? ViewportDocument.GameId : ViewportDocument.SceneId;

    public ViewportSession Session { get; } = new();

    /// <summary>The editor's camera. The Game view has none: it draws from the game's.</summary>
    public EditorCamera Camera => _camera ?? throw new InvalidOperationException("the Game view has no editor camera");

    /// <summary>Whether the viewport has an editor camera: a scene view.</summary>
    public bool HasCamera => _camera != null;

    /// <summary>How the viewport draws. The shell changes it (<see cref="EditorShell.ApplyViewportSettings"/>).</summary>
    public ViewportSettings Settings { get; internal set; }

    /// <summary>Whether the camera has a place. A scene view that is shown for the first time gets its start from the first one's.</summary>
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

    /// <summary>
    /// The projection that the user chose for this view, which viewport.json keeps: orthographic for Top, Front and
    /// Side until they choose, and perspective for the first. The camera has it from <see cref="StartCamera"/> on,
    /// until it orbits or looks around, which makes it a perspective camera without changing the choice.
    /// </summary>
    public CameraProjection Projection { get; internal set; }

    /// <summary>
    /// Puts the camera where this view starts, from the first scene view's camera: the same pivot at the same distance,
    /// looking along the view's axis, with the view's projection, so every view frames the same spot.
    /// </summary>
    internal void StartCamera(EditorCamera first)
    {
        var (yaw, pitch) = Start switch
        {
            SceneViewStart.Top => ViewGizmo.Angles(ViewAxis.Top),
            SceneViewStart.Front => ViewGizmo.Angles(ViewAxis.Front),
            SceneViewStart.Side => ViewGizmo.Angles(ViewAxis.Right),
            _ => (first.Yaw, first.Pitch),
        };
        // What the first view shows at its pivot, whatever its own projection is.
        Camera.LookAt(first.Pivot, first.ViewDistance, yaw, pitch, Projection);
    }

    /// <summary>
    /// The camera's turn to look along an axis while the view gizmo animates it, or null when none runs. Only the shell
    /// changes it (<see cref="EditorShell.LookAlong"/>, <see cref="EditorShell.StepTurn"/>).
    /// </summary>
    public CameraTurn? Turn { get; internal set; }

    /// <summary>A turn started, which the view's control steps until it ends.</summary>
    public event Action? TurnStarted;

    internal void RaiseTurnStarted() => TurnStarted?.Invoke();

    // Whether the view should take the keyboard focus once its control is on screen. Play asks it of the Game view, whose
    // control docking may make only after the tab changes.
    bool _focusWanted;

    /// <summary>The shell wants the view to take the keyboard focus (see <see cref="RequestFocus"/>).</summary>
    public event Action? FocusRequested;

    /// <summary>Asks the view's control to take the keyboard focus, now if it is attached, or else when it attaches.</summary>
    internal void RequestFocus()
    {
        _focusWanted = true;
        FocusRequested?.Invoke();
    }

    /// <summary>Whether the focus is wanted, which the control that takes it clears.</summary>
    public bool TakeFocusRequest()
    {
        var wanted = _focusWanted;
        _focusWanted = false;
        return wanted;
    }

    /// <summary>Whether the focus is wanted, without taking the request.</summary>
    public bool WantsFocus => _focusWanted;
}
