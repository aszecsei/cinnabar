using Avalonia.Input;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Viewport;

namespace Cinnabar.Editor.Tests;

/// <summary>Play, pause, step and stop in the shell, without a host, and the game's input keys.</summary>
public sealed class ModeTests : IDisposable
{
    readonly TempDirectory _temp = new("mode");

    EditorShell NewShell()
    {
        var shell = TestShell.Open(_temp, "door.scene", "scene 1\n\nentity 0000000000000001\nname = \"Door\"\n");
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(1, "Door", 1, 0, true, [])]));
        return shell;
    }

    [Fact]
    public void PlayingLeavesTheDocumentAlone()
    {
        using var shell = NewShell();
        shell.Selection.Select(1);
        Assert.NotNull(shell.SelectedSceneEntity);

        shell.Play();
        Assert.Equal(EditorMode.Play, shell.Mode);
        Assert.False(shell.Edit("Rename", new Rename(1, "Played")));
        Assert.Null(shell.SelectedSceneEntity);
        Assert.False(shell.Commands.Get(EditorCommands.DeleteEntity).CanExecute);
        Assert.False(shell.Commands.Get(EditorCommands.CreateEntity).CanExecute);
        Assert.Equal("Door", shell.Scene!.Scene.Find(1)!.Name);

        shell.TogglePause();
        Assert.Equal(EditorMode.Paused, shell.Mode);
        Assert.True(shell.Commands.Get(EditorCommands.StepFrame).CanExecute);
        shell.TogglePause();
        Assert.Equal(EditorMode.Play, shell.Mode);

        shell.Stop();
        Assert.True(shell.IsEditing);
        Assert.True(shell.Edit("Rename", new Rename(1, "Edited")));
    }

    [Fact]
    public void TheFreeCameraKeepsTheViewportsInputForTheEditor()
    {
        using var shell = NewShell();
        Assert.False(shell.InputGoesToGame);
        shell.Play();
        Assert.True(shell.InputGoesToGame);
        shell.ToggleFreeCamera();
        Assert.False(shell.InputGoesToGame);
        shell.Stop();
        Assert.False(shell.FreeCamera);
    }

    [Fact]
    public void KeysBecomeTheGamesKeys()
    {
        Assert.Equal(InputKey.Q, GameInput.Key(Key.Q));
        Assert.Equal(InputKey.Num7, GameInput.Key(Key.D7));
        Assert.Equal(InputKey.F12, GameInput.Key(Key.F12));
        Assert.Equal(InputKey.LeftControl, GameInput.Key(Key.LeftCtrl));
        Assert.Null(GameInput.Key(Key.NumLock));
        Assert.Equal(InputKey.Mouse5, GameInput.Button(PointerUpdateKind.XButton2Released));
    }

    public void Dispose() => _temp.Dispose();
}
