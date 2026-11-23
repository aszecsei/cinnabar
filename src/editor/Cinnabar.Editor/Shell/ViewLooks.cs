using Cinnabar.Editor.Tools;
using ViewportLook = Cinnabar.Editor.Link.Protocol.ViewportLook;
using ViewportLookShown = Cinnabar.Editor.Link.Protocol.ViewportLookShown;
using ViewportLookSource = Cinnabar.Editor.Link.Protocol.ViewportLookSource;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// What a scene view draws from (see docs/editor/cutscene-editor.md#cameras): its editor camera, or a camera of the
/// cutscene that holds the preview. Only <see cref="ViewLooks"/> makes them.
/// </summary>
public abstract record ViewLook
{
    private protected ViewLook()
    {
    }

    /// <summary>The view's own editor camera.</summary>
    public sealed record Editor : ViewLook
    {
        public static readonly Editor Instance = new();
    }

    /// <summary>
    /// A camera of <paramref name="Owner"/>'s cutscene, which the game draws the view from while that tab holds the
    /// preview. <paramref name="Serial"/> names the look in the game's answers, and <paramref name="Ticket"/> is the
    /// preview session that the game was told it for, 0 before one. <paramref name="Shown"/> is the game's last answer to
    /// it, or null before one.
    /// </summary>
    public abstract record Through(CutsceneEditor Owner, ulong Serial, ulong Ticket, ViewportLookShown? Shown) : ViewLook
    {
        /// <summary>Whether the game drew the view from the camera at its last answer.</summary>
        public bool Drawn => Shown is { Camera: true };
    }

    /// <summary>The camera of the camera cut track's shot at the playhead, which changes as the playhead moves.</summary>
    public sealed record Cuts(CutsceneEditor Owner, ulong Serial, ulong Ticket, ViewportLookShown? Shown) : Through(Owner, Serial, Ticket, Shown);

    /// <summary>The camera of a binding, which the view pilots while <paramref name="Pilot"/> is ready.</summary>
    public sealed record Camera(CutsceneEditor Owner, int Binding, ulong Serial, ulong Ticket, ViewportLookShown? Shown, Pilot Pilot)
        : Through(Owner, Serial, Ticket, Shown);
}

/// <summary>
/// Whether a view that looks through a binding's camera moves it (see docs/editor/cutscene-editor.md#pilot). Only
/// <see cref="ViewLooks"/> makes them.
/// </summary>
public abstract record Pilot
{
    private protected Pilot()
    {
    }

    /// <summary>The game has not shown the camera yet, so the pilot has no pose to start from.</summary>
    public sealed record Waiting : Pilot
    {
        public static readonly Waiting Instance = new();
    }

    /// <summary>The camera cannot be piloted, for the reason.</summary>
    public sealed record Refused(string Reason) : Pilot;

    /// <summary>The view's fly, orbit and pan controls move <paramref name="Camera"/>, which the camera's binding follows.</summary>
    public sealed record Ready(EditorCamera Camera, PilotGesture Gesture) : Pilot;
}

/// <summary>A pilot's mouse gesture: none, or one under way, which a release keys and Esc takes back.</summary>
public abstract record PilotGesture
{
    private protected PilotGesture()
    {
    }

    public sealed record Idle : PilotGesture
    {
        public static readonly Idle Instance = new();
    }

    /// <summary>
    /// A gesture under way: the values over the preview and the pilot's pose before it, and with auto-key, the drag
    /// that keys it, from its first move.
    /// </summary>
    public sealed record Moving(PreviewValuesState Before, CameraPose Start, CutsceneDrag? Keys) : PilotGesture;
}

/// <summary>
/// What each scene view draws from (see docs/editor/cutscene-editor.md#cameras). <see cref="Become"/> is the one place
/// that a look changes, and it tells the game. A look follows the tab that holds the preview: the game is told it again
/// for each new session of that tab, and it goes back to the editor camera when another tab takes the preview or the tab
/// closes. The editor camera is never moved by a look, so it is as it was when the look ends.
/// </summary>
public sealed class ViewLooks
{
    readonly EditorShell _shell;
    readonly ViewLook[] _looks = [.. Enumerable.Repeat<ViewLook>(ViewLook.Editor.Instance, EditorViewport.SceneViews)];

    // The last serial given: it only goes up, so the game drops a late look.
    ulong _serial;

    public ViewLooks(EditorShell shell)
    {
        _shell = shell;
        shell.CutscenePreview.Changed += Follow;
    }

    /// <summary>A view's look changed.</summary>
    public event Action<int>? Changed;

    /// <summary>The look of a scene view, by its number.</summary>
    public ViewLook this[int viewport] => viewport is >= 0 and < EditorViewport.SceneViews ? _looks[viewport] : ViewLook.Editor.Instance;

    /// <summary>The look of a view: the Game view's is always the editor's, as it draws from the game's camera.</summary>
    public ViewLook Of(EditorViewport viewport) => this[viewport.Index];

    /// <summary>Whether any scene view looks through a camera.</summary>
    public bool Any => _looks.Any(l => l is ViewLook.Through);

    /// <summary>Makes a scene view draw from its editor camera.</summary>
    public void LookThroughEditor(int viewport) => Become(viewport, ViewLook.Editor.Instance);

    /// <summary>Makes a scene view follow the cutscene's camera cuts. False when the view is not a scene view.</summary>
    public bool LookThroughCuts(int viewport, CutsceneEditor owner)
    {
        if (viewport is < 0 or >= EditorViewport.SceneViews)
        {
            return false;
        }
        Become(viewport, new ViewLook.Cuts(owner, 0, 0, null));
        return true;
    }

    /// <summary>Makes a scene view look through a binding's camera. False when the view is not a scene view.</summary>
    public bool LookThrough(int viewport, CutsceneEditor owner, int binding)
    {
        if (viewport is < 0 or >= EditorViewport.SceneViews)
        {
            return false;
        }
        Become(viewport, new ViewLook.Camera(owner, binding, 0, 0, null, Pilot.Waiting.Instance));
        return true;
    }

    /// <summary>The first scene view that looks through a binding's camera, or null.</summary>
    public int? ViewThrough(CutsceneEditor owner, int binding)
    {
        for (var i = 0; i < _looks.Length; i++)
        {
            if (_looks[i] is ViewLook.Camera camera && camera.Owner == owner && camera.Binding == binding)
            {
                return i;
            }
        }
        return null;
    }

    // The one writer of the looks. A look with a new source gets a new serial, and the game hears it at once when the
    // preview is live for its owner, or at the next session that is.
    internal void Become(int viewport, ViewLook next)
    {
        var previous = _looks[viewport];
        if (previous == next)
        {
            return;
        }
        if (SourceOf(previous) != SourceOf(next) || OwnerOf(previous) != OwnerOf(next))
        {
            next = next switch
            {
                ViewLook.Cuts cuts => cuts with { Serial = ++_serial, Ticket = 0, Shown = null },
                ViewLook.Camera camera => camera with { Serial = ++_serial, Ticket = 0, Shown = null },
                _ => next,
            };
            if (next is ViewLook.Editor && previous is ViewLook.Through { Ticket: not 0 } && _shell.Host.Linked)
            {
                _shell.Host.Send(new ViewportLook((uint)viewport, ++_serial, 0, ViewportLookSource.EditorCamera, 0));
            }
        }
        _looks[viewport] = next;
        if (next is ViewLook.Through through)
        {
            Tell(viewport, through);
        }
        Changed?.Invoke(viewport);
        _shell.Commands.InvalidateAll();
    }

    // Tells the game a look when the preview is live for its owner and the game has not heard it for that session.
    void Tell(int viewport, ViewLook.Through look)
    {
        if (_shell.CutscenePreview.State is not CutscenePreviewState.Live live || live.Editor != look.Owner || live.Ticket == look.Ticket
            || !_shell.Host.Linked)
        {
            return;
        }
        var (source, binding) = SourceOf(look) ?? (ViewportLookSource.EditorCamera, 0);
        _shell.Host.Send(new ViewportLook((uint)viewport, look.Serial, live.Ticket, source, (uint)binding));
        _looks[viewport] = look switch
        {
            ViewLook.Cuts cuts => cuts with { Ticket = live.Ticket, Shown = null },
            ViewLook.Camera camera => camera with { Ticket = live.Ticket, Shown = null },
            _ => look,
        };
    }

    static (ViewportLookSource Source, int Binding)? SourceOf(ViewLook look) => look switch
    {
        ViewLook.Cuts => (ViewportLookSource.Cuts, 0),
        ViewLook.Camera camera => (ViewportLookSource.Binding, camera.Binding),
        _ => null,
    };

    static CutsceneEditor? OwnerOf(ViewLook look) => (look as ViewLook.Through)?.Owner;

    // A look ends when its tab no longer holds the preview, and is told again for each new session of the tab.
    void Follow()
    {
        for (var i = 0; i < _looks.Length; i++)
        {
            if (_looks[i] is not ViewLook.Through through)
            {
                continue;
            }
            if (_shell.CutscenePreview.Owner != through.Owner || !_shell.Cutscenes.Contains(through.Owner))
            {
                Become(i, ViewLook.Editor.Instance);
                continue;
            }
            var before = _looks[i];
            Tell(i, through);
            if (_looks[i] != before)
            {
                Changed?.Invoke(i);
            }
        }
    }

    /// <summary>The game drew a looking view: the answer to the view's look, when its serial is the look's.</summary>
    internal void OnShown(ViewportLookShown shown)
    {
        var i = (int)shown.Viewport;
        if (i >= _looks.Length || _looks[i] is not ViewLook.Through through || through.Serial != shown.Serial)
        {
            return;
        }
        Become(i, through switch
        {
            ViewLook.Cuts cuts => cuts with { Shown = shown },
            ViewLook.Camera camera => camera with { Shown = shown },
            _ => through,
        });
    }
}
