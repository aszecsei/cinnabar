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
}
