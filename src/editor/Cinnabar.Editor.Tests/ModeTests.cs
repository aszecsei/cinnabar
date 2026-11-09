using Avalonia.Input;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Ribbon;
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
    public void OnlyPlayGivesTheGameViewsInputToTheGame()
    {
        using var shell = NewShell();
        Assert.False(shell.InputGoesToGame);
        shell.Play();
        Assert.True(shell.InputGoesToGame);
        shell.TogglePause();
        Assert.False(shell.InputGoesToGame);
        shell.TogglePause();
        shell.Stop();
        Assert.False(shell.InputGoesToGame);
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

    [Fact]
    public void OnlyKeysThatMayTypeStayUnhandled()
    {
        Assert.True(GameInput.TypesCharacter("a", KeyModifiers.None));
        Assert.True(GameInput.TypesCharacter("A", KeyModifiers.Shift));
        // AltGr is Ctrl and Alt together.
        Assert.True(GameInput.TypesCharacter("€", KeyModifiers.Control | KeyModifiers.Alt));
        Assert.False(GameInput.TypesCharacter("s", KeyModifiers.Control));
        Assert.False(GameInput.TypesCharacter("f", KeyModifiers.Alt));
        Assert.False(GameInput.TypesCharacter("\t", KeyModifiers.None));
        Assert.False(GameInput.TypesCharacter(null, KeyModifiers.None));
    }

    [Fact]
    public void ShortcutsLeaveTheKeysToTheGameExceptTheFunctionKeys()
    {
        using var shell = NewShell();
        var runs = 0;
        var command = new Command("test.command", "Test", () => runs++);
        var letter = new ShortcutCommand(new CommandAdapter(command), new KeyGesture(Key.W), () => shell.GameHasKeys, () => false);
        var function = new ShortcutCommand(new CommandAdapter(command), new KeyGesture(Key.F5, KeyModifiers.Shift), () => shell.GameHasKeys, () => false);

        Assert.True(letter.CanExecute(null));
        shell.GameViewHasFocus = true;
        Assert.True(letter.CanExecute(null));
        shell.Play();
        Assert.False(letter.CanExecute(null));
        Assert.True(function.CanExecute(null));
        // Another panel's keys are the editor's, whatever the game does.
        shell.GameViewHasFocus = false;
        Assert.True(letter.CanExecute(null));
    }

    [Fact]
    public void CharactersInTwoHalvesAreJoined()
    {
        var characters = new GameInput.Characters();
        Assert.Equal("", characters.Join("\ud83d"));
        Assert.Equal("😀", characters.Join("\ude00"));
        Assert.Equal("日本語", characters.Join("日本語"));
    }

    [Fact]
    public void ACompositionsCursorIsInBytes()
    {
        var after = GameInput.Composition("に😀a", 3);
        Assert.Equal(InputEventKind.Composition, after.Kind);
        Assert.Equal("に😀a", after.Text);
        Assert.Equal(7, after.Cursor);
        Assert.Equal(0, GameInput.Composition("", 0).Cursor);
        Assert.Equal(1, GameInput.Composition("a", 9).Cursor);
    }

    [Fact]
    public void XInputCanBeAskedAboutEverySlot()
    {
        // Whether this machine has a pad does not matter: the import and the layout of its state must work.
        for (var slot = 0; slot < 4; slot++)
        {
            GamepadPoller.ReadXInput(slot);
        }
    }

    [Fact]
    public void APadPluggedInDuringPlayIsFoundAndToldOnce()
    {
        var pads = new GamepadReading?[4];
        var reads = new int[4];
        var poller = new GamepadPoller(slot =>
        {
            reads[slot]++;
            return pads[slot];
        });
        long now = 0;

        // No events for what has no pad, and one empty slot read until the interval has passed.
        Assert.Empty(poller.Poll(now));
        Assert.Empty(poller.Poll(now));
        Assert.Equal(1, reads.Sum());

        pads[2] = new GamepadReading(0x1000, 1, 0, 0, 0, 0, 0);
        InputEvent[] found = [];
        for (var i = 0; i < 4 && found.Length == 0; i++)
        {
            now += 250;
            found = poller.Poll(now);
        }
        var plugged = Assert.Single(found);
        Assert.Equal(InputEventKind.Gamepad, plugged.Kind);
        Assert.Equal(2, plugged.Pad);
        Assert.True(plugged.Connected);
        Assert.Equal(0x1000, plugged.Buttons);
        Assert.Equal(1, plugged.Axes[0]);

        // Only a change is told, and a connected slot is read on each call.
        var before = reads[2];
        Assert.Empty(poller.Poll(now));
        Assert.Equal(before + 1, reads[2]);
        pads[2] = new GamepadReading(0, 0, 0, 0, 0, 0, 0);
        Assert.Equal(0, Assert.Single(poller.Poll(now)).Buttons);

        // A game that lost the input hears about the pad again.
        poller.Forget();
        Assert.True(Assert.Single(poller.Poll(now)).Connected);

        pads[2] = null;
        var gone = Assert.Single(poller.Poll(now));
        Assert.Equal(2, gone.Pad);
        Assert.False(gone.Connected);
    }

    public void Dispose() => _temp.Dispose();
}
