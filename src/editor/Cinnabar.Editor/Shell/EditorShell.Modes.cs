using System.Diagnostics.CodeAnalysis;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using EditorInput = Cinnabar.Editor.Link.Protocol.EditorInput;
using EditorMode = Cinnabar.Editor.Link.Protocol.EditorMode;
using InputEvent = Cinnabar.Editor.Link.Protocol.InputEvent;
using SetMode = Cinnabar.Editor.Link.Protocol.SetMode;
using StepFrame = Cinnabar.Editor.Link.Protocol.StepFrame;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Play, pause, step and stop (see docs/editor/document-and-scenes.md#modes). In Edit, the game's world stands still and mirrors the
/// document. Play runs the world that the game has; nothing of it reaches the document, which no edit changes until
/// Stop, which sends the document again. A new link starts in Edit, as the game does.
/// </summary>
public sealed partial class EditorShell
{
    public EditorMode Mode { get; private set; } = EditorMode.Edit;

    /// <summary>Edits change the document only in Edit.</summary>
    public bool IsEditing => Mode == EditorMode.Edit;

    /// <summary>Whether a scene is open and edits to it are allowed: not while the game plays.</summary>
    [MemberNotNullWhen(true, nameof(Scene))]
    public bool CanEditScene => IsEditing && Scene != null;

    /// <summary>Whether the open scene's meshes are in edit mode and edits are allowed.</summary>
    public bool CanEditInMeshMode => InMeshMode && IsEditing;

    /// <summary>While playing, the viewport flies the editor's camera and the game draws from it, instead of the game's input and camera.</summary>
    public bool FreeCamera { get; private set; }

    /// <summary>The mode or the free camera changed.</summary>
    public event Action? ModeChanged;

    /// <summary>Starts playing the world that the game has, or goes on after a pause.</summary>
    public void Play()
    {
        // The Play command needs a linked host. Without one, the mode only changes here.
        if (Mode == EditorMode.Play)
        {
            return;
        }
        if (Mode == EditorMode.Edit)
        {
            // A drag or a scrub that is under way ends as it is, and mesh mode with it.
            LeaveMeshMode();
            CancelGizmo();
            // A material that a drag only shows was never dropped.
            CancelMaterial();
            if (Scene is { InTransaction: true })
            {
                Scene.Commit();
            }
            Console.Add(LogLevel.Info, "editor: playing. Edits wait until Stop.");
        }
        SetModeTo(EditorMode.Play);
    }

    /// <summary>Pauses play, or goes on after a pause.</summary>
    public void TogglePause()
    {
        if (Mode != EditorMode.Edit)
        {
            SetModeTo(Mode == EditorMode.Play ? EditorMode.Paused : EditorMode.Play);
        }
    }

    /// <summary>While paused, runs one frame of one fixed tick.</summary>
    public void Step()
    {
        if (Mode == EditorMode.Paused)
        {
            Host.Send(new StepFrame());
        }
    }

    /// <summary>Ends play: the game goes back to Edit, and its world becomes the document again.</summary>
    public void Stop()
    {
        if (Mode == EditorMode.Edit)
        {
            return;
        }
        FreeCamera = false;
        SetModeTo(EditorMode.Edit);
        SendScene();
        Console.Add(LogLevel.Info, "editor: stopped, so the game has the scene again.");
    }

    public void ToggleFreeCamera()
    {
        FreeCamera = !FreeCamera;
        SendMode();
        OnModeChanged();
    }

    void SetModeTo(EditorMode mode)
    {
        Mode = mode;
        SendMode();
        OnModeChanged();
    }

    void SendMode() => Host.Send(new SetMode(Mode, FreeCamera));

    void OnModeChanged()
    {
        Context.Set("mode.play", Mode != EditorMode.Edit);
        SendGizmo();
        Commands.InvalidateAll();
        ModeChanged?.Invoke();
    }

    // A new link, a restart or a soft restart has a game in Edit.
    void ResetMode()
    {
        if (Mode != EditorMode.Edit || FreeCamera)
        {
            Mode = EditorMode.Edit;
            FreeCamera = false;
            OnModeChanged();
        }
    }

    /// <summary>Sends keyboard and mouse input to the game, while it plays without the free camera.</summary>
    public void SendInput(params InputEvent[] events)
    {
        if (Mode == EditorMode.Play && !FreeCamera && events.Length > 0)
        {
            Host.Send(new EditorInput(events));
        }
    }

    /// <summary>Whether the viewport's input goes to the game.</summary>
    public bool InputGoesToGame => Mode == EditorMode.Play && !FreeCamera;
}
