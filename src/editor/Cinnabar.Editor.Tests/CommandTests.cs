using Cinnabar.Editor.Commands;

namespace Cinnabar.Editor.Tests;

public class CommandTests
{
    [Fact]
    public void ExecuteRunsOnlyWhenEnabledAndRaisesChangedSoTogglesShowTheirNewState()
    {
        var enabled = false;
        var on = false;
        var command = new Command("test.toggle", "Toggle", () => on = !on) { CanExecuteWhen = () => enabled, IsCheckedWhen = () => on };
        var changes = 0;
        command.Changed += () => changes++;

        Assert.False(command.Execute());
        Assert.False(on);
        enabled = true;
        Assert.True(command.Execute());
        Assert.True(command.IsChecked);
        Assert.Equal(1, changes);
    }

    // A scope that takes the commands of a table, each with its action and whether it can run.
    sealed class TableScope(Dictionary<string, ScopedCommand> table) : ICommandScope
    {
        public ScopedCommand? Handler(string commandId) => table.GetValueOrDefault(commandId);
    }

    [Fact]
    public void ALadderRunsItsFirstRungThatHoldsAndAskingWhetherItCanRunRunsNone()
    {
        var ran = new List<string>();
        var drag = false;
        var pick = true;
        var cancel = ScopedCommand.FirstOf(
            (() => drag, () => ran.Add("drag")),
            (() => pick, () => ran.Add("pick")));

        Assert.True(cancel.CanExecute);
        Assert.Empty(ran);
        cancel.Run();
        drag = true;
        cancel.Run();
        Assert.Equal(["pick", "drag"], ran);

        drag = pick = false;
        Assert.False(cancel.CanExecute);
    }

    [Fact]
    public void TheFocusedScopeTakesACommandBeforeTheOtherScopesAndTheCommandsOwnAction()
    {
        var commands = new CommandRegistry();
        var ran = new List<string>();
        var delete = commands.Register(new Command("entity.delete", "Delete", () => ran.Add("scene")));
        var editor = new TableScope(new() { ["entity.delete"] = new(() => ran.Add("editor")) });
        var canvas = new TableScope(new() { ["entity.delete"] = new(() => ran.Add("canvas")) });
        commands.AddScope(editor);

        Assert.True(delete.Execute());
        commands.Focus(canvas);
        Assert.True(delete.Execute());
        commands.Leave(canvas);
        Assert.True(delete.Execute());

        Assert.Equal(["editor", "canvas", "editor"], ran);
    }

    [Fact]
    public void AScopeThatTakesACommandItCannotRunStopsItAndAScopeThatDoesNotTakeItPassesItOn()
    {
        var commands = new CommandRegistry();
        var ran = new List<string>();
        var delete = commands.Register(new Command("entity.delete", "Delete", () => ran.Add("scene")));
        var undo = commands.Register(new Command("edit.undo", "Undo", () => ran.Add("undo")));
        var empty = new TableScope(new() { ["entity.delete"] = new(() => ran.Add("graph"), () => false) });

        commands.Focus(empty);

        Assert.False(delete.CanExecute);
        Assert.False(delete.Execute());
        Assert.True(undo.Execute());
        Assert.Equal(["undo"], ran);
    }

    [Fact]
    public void OnlyTheScopeThatHasTheKeyboardLetsItGoAndAChangeOfScopeInvalidatesTheCommands()
    {
        var commands = new CommandRegistry();
        var delete = commands.Register(new Command("entity.delete", "Delete", () => { }));
        var changes = 0;
        delete.Changed += () => changes++;
        var first = new TableScope([]);
        var second = new TableScope([]);

        commands.Focus(first);
        commands.Focus(first);
        // The keyboard moved into the second scope before the first said that it lost it.
        commands.Focus(second);
        commands.Leave(first);

        Assert.Same(second, commands.Focused);
        Assert.Equal(2, changes);
        commands.Leave(second);
        Assert.Null(commands.Focused);
        Assert.Equal(3, changes);
    }

    [Fact]
    public void RequestsBeforeTheDispatchersTurnRefreshTheCommandsOnce()
    {
        var posted = new List<Action>();
        var commands = new CommandRegistry(posted.Add);
        var save = commands.Register(new Command("scene.save", "Save", () => { }));
        var changes = 0;
        save.Changed += () => changes++;
        var owner = (Action?)null;
        commands.InvalidateOn(h => owner += h);

        for (var i = 0; i < 5; i++)
        {
            owner!();
        }
        commands.RequestInvalidate();
        // One turn is posted for all of them, and nothing is refreshed before it runs.
        Assert.Single(posted);
        Assert.Equal(0, changes);
        posted[0]();
        Assert.Equal(1, changes);
        // A run of the turn again, as Flush after it, refreshes nothing more.
        commands.Flush();
        Assert.Equal(1, changes);

        // A request after the turn posts another.
        owner!();
        Assert.Equal(2, posted.Count);
        posted[1]();
        Assert.Equal(2, changes);
    }

    [Fact]
    public void AClosedRegistryRunsNoRefreshThatWaitsAndPostsNoOther()
    {
        var posted = new List<Action>();
        var commands = new CommandRegistry(posted.Add);
        var save = commands.Register(new Command("scene.save", "Save", () => { }));
        var changes = 0;
        save.Changed += () => changes++;

        commands.RequestInvalidate();
        commands.Close();
        posted[0]();
        commands.RequestInvalidate();
        // A scope that the keyboard leaves after the close refreshes nothing either.
        var canvas = new TableScope([]);
        commands.Focus(canvas);
        commands.Leave(canvas);

        Assert.Single(posted);
        Assert.Equal(0, changes);
    }
}
