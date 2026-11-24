using Cinnabar.Editor.Commands;

namespace Cinnabar.Editor.Tests;

public class CommandTests
{
    [Fact]
    public void ExecuteRunsOnlyWhenEnabled()
    {
        var enabled = false;
        var runs = 0;
        var command = new Command("test.run", "Run", () => runs++) { CanExecuteWhen = () => enabled };

        Assert.False(command.Execute());
        enabled = true;
        Assert.True(command.Execute());
        Assert.Equal(1, runs);
    }

    [Fact]
    public void ExecuteRaisesChangedSoTogglesShowTheirNewState()
    {
        var on = false;
        var command = new Command("test.toggle", "Toggle", () => on = !on) { IsCheckedWhen = () => on };
        var changes = 0;
        command.Changed += () => changes++;

        command.Execute();

        Assert.True(command.IsToggle);
        Assert.True(command.IsChecked);
        Assert.Equal(1, changes);
    }

    [Fact]
    public void ChoiceRejectsAnUnknownOption()
    {
        var selected = "Fit";
        var choice = new ChoiceCommand("test.scale", "Scale", ["Fit", "100%"], () => selected, s => selected = s);

        choice.Select("100%");
        Assert.Equal("100%", choice.Selected);
        Assert.Throws<ArgumentException>(() => choice.Select("200%"));
    }

    [Fact]
    public void RegistryRefusesADuplicateId()
    {
        var commands = new CommandRegistry();
        commands.Register(new Command("test.run", "Run", () => { }));

        Assert.Throws<InvalidOperationException>(() => commands.Register(new Command("test.run", "Run again", () => { })));
    }

    [Fact]
    public void ContextRaisesChangedOnlyOnAChange()
    {
        var context = new EditorContext();
        var changes = 0;
        context.Changed += () => changes++;

        context.Set("host.running", true);
        context.Set("host.running", true);
        context.Set("host.running", false);

        Assert.Equal(2, changes);
        Assert.False(context.IsActive("host.running"));
    }

    // A scope that takes the commands of a table, each with its action and whether it can run.
    sealed class TableScope(Dictionary<string, ScopedCommand> table) : ICommandScope
    {
        public ScopedCommand? Handler(string commandId) => table.GetValueOrDefault(commandId);
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
    public void ACommandOutsideARegistryAndOneUnregisteredRunTheirOwnAction()
    {
        var commands = new CommandRegistry();
        var runs = 0;
        var command = commands.Register(new Command("game.spin", "Spin", () => runs++));
        commands.Focus(new TableScope(new() { ["game.spin"] = ScopedCommand.Never }));
        Assert.False(command.Execute());

        commands.Unregister("game.spin");

        Assert.True(command.Execute());
        Assert.Equal(1, runs);
    }
}
