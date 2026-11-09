using Cinnabar.Editor.Commands;

namespace Cinnabar.Editor.Shell;

static partial class EditorCommands
{
    // The reflection probes (see docs/editor/viewport.md#reflection-probes): a new probe, and captures that the game makes
    // now, whatever the level's budget, which need a linked game.
    static void RegisterReflections(EditorShell shell)
    {
        var commands = shell.Commands;
        commands.Register(new Command(CreateReflectionProbe, "New Reflection Probe", shell.CreateReflectionProbe)
        {
            Description = "Add a reflection probe, where the selected entity is, which the surfaces inside its box reflect. Drag its boxes' handles in the viewport to size it.",
            Icon = "add",
            CanExecuteWhen = () => shell.CanEditScene,
        });
        commands.Register(new Command(CaptureProbe, "Capture", shell.CaptureSelectedProbes)
        {
            Description = "Capture the selected reflection probes now: each takes its six faces in one frame, whatever the quality's budget, one probe a frame. A probe that holds no slot is not captured.",
            Icon = "restart",
            CanExecuteWhen = () => shell.Host.Linked && shell.SelectionHasProbe,
        });
        commands.Register(new Command(CaptureAllProbes, "Capture All Probes", shell.CaptureAllProbes)
        {
            Description = "Capture every reflection probe that holds a slot now, one a frame, each in one frame whatever the quality's budget.",
            Icon = "restart",
            CanExecuteWhen = () => shell.Host.Linked && shell.SceneHasProbe,
        });
    }
}
