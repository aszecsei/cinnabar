using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Shell;

static partial class EditorCommands
{
    public const string CutsceneLookThrough = "cutscene.lookThrough";
    public const string CutsceneLookThroughCuts = "cutscene.lookThroughCuts";
    public const string CutsceneEditorCamera = "cutscene.editorCamera";
    public const string CutsceneNewCameraFromView = "cutscene.newCameraFromView";
    public const string CutscenePickFocus = "cutscene.pickFocus";

    /// <summary>
    /// The camera commands, which act between the active scene view and the active cutscene, or the one that holds the
    /// preview, wherever the keyboard is (see docs/editor/cutscene-editor.md#cameras).
    /// </summary>
    public static readonly string[] CutsceneCameraCommands = [CutsceneLookThrough, CutsceneLookThroughCuts, CutsceneEditorCamera, CutsceneNewCameraFromView,
        CutscenePickFocus];

    static void RegisterCutsceneCameras(EditorShell shell)
    {
        var commands = shell.Commands;
        CutsceneEditor? Cameras() => shell.ActiveCutscene ?? shell.CutscenePreview.Owner;
        int? SelectedCamera() =>
            Cameras() is { Selected: { Kind: CutsceneBlockKind.Binding, Id: { } id } binding } editor && editor.IsCamera(binding) ? id : null;
        commands.Register(new Command(CutsceneLookThrough, "Look Through Camera", () =>
        {
            if (Cameras() is { } editor && SelectedCamera() is { } id)
            {
                editor.ToggleLookThrough(id);
            }
        })
        {
            Description = "Draw the active scene view from the selected camera binding, and move the camera with the view's fly, orbit and pan. Esc gives the view back its own camera.",
            Icon = "cutscene",
            CanExecuteWhen = () => shell.IsEditing && SelectedCamera() != null,
            IsCheckedWhen = () => Cameras() is { } editor && SelectedCamera() is { } id && editor.LooksThrough(id),
        });
        commands.Register(new Command(CutsceneLookThroughCuts, "Look Through Cuts", () => Cameras()?.LookThroughCuts())
        {
            Description = "Draw the active scene view from the camera of the camera cut at the playhead, which changes as the playhead moves.",
            Icon = "cutscene",
            CanExecuteWhen = () => shell.IsEditing && Cameras() != null,
            IsCheckedWhen = () => shell.Looks[shell.ActiveViewport.Index] is ViewLook.Cuts,
        });
        commands.Register(new Command(CutsceneNewCameraFromView, "New Camera from View", () => Cameras()?.NewCameraFromView(shell.ActiveViewport))
        {
            Description = "Add a camera to the cutscene where the active scene view looks from, with its lens, keyed at the playhead, and cut to it there when no cut is.",
            Icon = "cutscene",
            Shortcut = "Ctrl+Shift+C",
            CanExecuteWhen = () => Cameras() is { } editor && editor.NewCameraRefusal(shell.ActiveViewport) == null,
        });
        ViewLook.Camera? Looked() => shell.Looks[shell.ActiveViewport.Index] as ViewLook.Camera;
        commands.Register(new Command(CutscenePickFocus, "Pick Focus", () =>
        {
            if (Looked() is { } look)
            {
                look.Owner.ArmFocusPick(look.Binding);
            }
        })
        {
            Description = "Set the focus distance of the camera that the active scene view looks through to the depth of what the next click there hits. Ctrl+click in the view does it at once.",
            Icon = "cutscene",
            CanExecuteWhen = () => Looked() is { } look && look.Owner.PickFocusRefusal(shell.ActiveViewport.Index) == null,
            IsCheckedWhen = () => Looked() is { } look && look.Owner.FocusArmed == look.Binding,
        });
        commands.Register(new Command(CutsceneEditorCamera, "Editor Camera", () => shell.Looks.LookThroughEditor(shell.ActiveViewport.Index))
        {
            Description = "Draw the active scene view from its own camera again.",
            Icon = "cutscene",
            CanExecuteWhen = () => shell.Looks[shell.ActiveViewport.Index] is ViewLook.Through,
        });
    }
}
