using Cinnabar.Editor.Maths;
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

    /// <summary>
    /// What a view's frame guides say of its camera (see docs/editor/cutscene-editor.md#frame-guides): the drawn camera's
    /// sensor aspect, and its name, focal length and the shot at the playhead. A scene view that the game drew through a
    /// camera has all three. The Game view, while a session is open, has the shot's camera's name. Others have none.
    /// </summary>
    public (double? Aspect, string? Info) CameraInfoOf(EditorViewport viewport)
    {
        if (viewport.IsGame)
        {
            return _shell.CutscenePreview.State is CutscenePreviewState.Open open
                ? (null, CutsceneTimelineLayout.ShotAt(open.Editor.File, open.Editor.Playhead, open.Editor.SilentTracks()) ?? "gameplay")
                : (null, null);
        }
        if (this[viewport.Index] is not ViewLook.Through { Shown: { Camera: true } shown } through)
        {
            return (null, null);
        }
        var file = through.Owner.File;
        var camera = file.Bindings.FirstOrDefault(b => b.Id == (int)shown.Binding)?.Name;
        var shot = CutsceneTimelineLayout.ShotAt(file, through.Owner.Playhead, through.Owner.SilentTracks());
        double? aspect = shown.Sensor is [> 0 and var w, > 0 and var h] ? w / h : null;
        return (aspect, FrameGuides.CameraInfo(camera, shown.FocalLength > 0 ? shown.FocalLength : null, shot));
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
            ViewLook.Camera camera => camera with { Shown = shown, Pilot = PilotOf(camera, shown) },
            _ => through,
        });
    }

    // A camera's pilot after the game shows it: a gesture under way, or a pose over the preview that the pilot set, keeps
    // its camera; otherwise the pilot starts again from what the world shows, as after a move of the playhead, or is
    // refused when the binding cannot take its keys.
    Pilot PilotOf(ViewLook.Camera camera, ViewportLookShown shown)
    {
        if (camera.Pilot is Pilot.Ready { Gesture: PilotGesture.Moving } moving)
        {
            return moving;
        }
        if (!shown.Camera)
        {
            return Pilot.Waiting.Instance;
        }
        if (camera.Pilot is Pilot.Ready ready && _shell.PreviewValues.PoseOf(camera.Binding) != null)
        {
            return ready;
        }
        if (PilotKeys.Refusal(camera.Owner.File, camera.Binding, camera.Owner.Locked) is { } why)
        {
            return new Pilot.Refused(why);
        }
        var r = shown.Rotation;
        var speed = camera.Pilot is Pilot.Ready old ? old.Camera.Speed : 4;
        return new Pilot.Ready(EditorCamera.FromPose(shown.Position, new Quat(r[0], r[1], r[2], r[3]), shown.VerticalFov, speed), PilotGesture.Idle.Instance);
    }

    /// <summary>Why a scene view's fly, orbit and pan cannot move what it looks through, or null when they move it or the view's own camera.</summary>
    public string? PilotRefusal(int viewport) => this[viewport] switch
    {
        ViewLook.Cuts => "The view follows the cuts, so it moves no camera. Look through one camera to pilot it.",
        ViewLook.Camera { Pilot: Pilot.Refused refused } => refused.Reason,
        ViewLook.Camera { Pilot: Pilot.Waiting } => "Waiting for the game to show the camera.",
        _ => null,
    };

    /// <summary>
    /// A mouse gesture that moves the camera starts in a view that pilots one: the preview pauses, as values show only
    /// at a standing playhead, and the pose and the values before it are kept for Esc.
    /// </summary>
    public void BeginGesture(int viewport)
    {
        if (this[viewport] is not ViewLook.Camera { Pilot: Pilot.Ready { Gesture: PilotGesture.Idle } ready } camera)
        {
            return;
        }
        if (_shell.CutscenePreview.State is CutscenePreviewState.Open { Playing: true })
        {
            _shell.CutscenePreview.Pause();
        }
        Become(viewport, camera with { Pilot = ready with { Gesture = new PilotGesture.Moving(_shell.PreviewValues.State, ready.Camera.Pose, null) } });
    }

    /// <summary>
    /// Moves the camera that a view pilots during a gesture: the pose shows over the preview at once, and with auto-key,
    /// the gesture's one undo entry keys it, from its first move. Nothing in a view that pilots nothing.
    /// </summary>
    public void Move(int viewport, Action<EditorCamera> move)
    {
        if (this[viewport] is not ViewLook.Camera { Pilot: Pilot.Ready { Gesture: PilotGesture.Moving moving } ready } camera)
        {
            return;
        }
        var before = ready.Camera.Pose;
        move(ready.Camera);
        if (ready.Camera.Pose == before)
        {
            return;
        }
        var position = ready.Camera.Position;
        var rotation = ready.Camera.Rotation;
        if (!_shell.PreviewValues.SetBindingPose(camera.Owner, camera.Binding, position, rotation) || !_shell.Keying.AutoKey)
        {
            return;
        }
        var keys = moving.Keys;
        if (keys == null)
        {
            var name = camera.Owner.File.Bindings.FirstOrDefault(b => b.Id == camera.Binding)?.Name ?? "Camera";
            keys = camera.Owner.BeginHeldDrag($"Pilot {name}");
            if (keys == null)
            {
                return;
            }
            Become(viewport, camera with { Pilot = ready with { Gesture = moving with { Keys = keys } } });
        }
        var tick = camera.Owner.Playhead;
        keys.Step(file =>
        {
            PilotKeys.Set(file, camera.Binding, position, rotation, tick, camera.Owner.Locked);
            return [];
        });
    }

    /// <summary>
    /// Ends a view's pilot gesture. A release keeps the pose: with auto-key its keys are the gesture's one undo entry,
    /// and the values settle until the preview shows them; without, they hold until they are keyed or the playhead moves.
    /// A cancel, as Esc, puts the keys, the values and the pilot's pose back as they were.
    /// </summary>
    public void EndGesture(int viewport, bool cancel)
    {
        if (this[viewport] is not ViewLook.Camera { Pilot: Pilot.Ready { Gesture: PilotGesture.Moving moving } ready } camera)
        {
            return;
        }
        Become(viewport, camera with { Pilot = ready with { Gesture = PilotGesture.Idle.Instance } });
        if (cancel)
        {
            moving.Keys?.End(cancel: true);
            _shell.PreviewValues.Restore(moving.Before);
            var start = moving.Start;
            ready.Camera.Place([start.X, start.Y, start.Z], start.Yaw, start.Pitch);
            return;
        }
        if (moving.Keys is { IsOpen: true } keys)
        {
            var before = camera.Owner.Document.Position;
            keys.End(cancel: false);
            if (camera.Owner.Document.Position != before)
            {
                _shell.Edited(new UndoTarget.Cutscene(camera.Owner));
            }
            _shell.PreviewValues.Keyed();
        }
    }

    /// <summary>
    /// Esc in a looking view: it takes back a pilot's gesture under way, or else gives the view its own camera back.
    /// False when the view looks through nothing.
    /// </summary>
    public bool Escape(int viewport)
    {
        switch (this[viewport])
        {
            case ViewLook.Camera { Pilot: Pilot.Ready { Gesture: PilotGesture.Moving } }:
                EndGesture(viewport, cancel: true);
                return true;
            case ViewLook.Through:
                LookThroughEditor(viewport);
                return true;
            default:
                return false;
        }
    }
}
