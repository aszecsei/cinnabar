using Cinnabar.Editor.Commands;

namespace Cinnabar.Editor.Tests;

public class KeyBindingsTests
{
    static CommandRegistry Commands()
    {
        var commands = new CommandRegistry();
        commands.Register(new Command("app.palette", "Command Palette", () => { }) { Shortcut = "Ctrl+Shift+P" });
        commands.Register(new Command("host.restart", "Restart Host", () => { }) { Shortcut = "Ctrl+Shift+F5" });
        commands.Register(new Command("view.stats", "Stats", () => { }));
        return commands;
    }

    [Fact]
    public void DefaultsApplyWithoutOverrides()
    {
        var bindings = new KeyBindings(Commands(), new Dictionary<string, string>());

        Assert.Equal("Ctrl+Shift+P", bindings.ShortcutOf("app.palette"));
        Assert.Null(bindings.ShortcutOf("view.stats"));
        Assert.Empty(bindings.Warnings);
    }

    [Fact]
    public void AnOverrideReplacesOrRemovesTheDefault()
    {
        var bindings = new KeyBindings(Commands(), new Dictionary<string, string>
        {
            ["view.stats"] = "F3",
            ["host.restart"] = "",
        });

        Assert.Equal("F3", bindings.ShortcutOf("view.stats"));
        Assert.Null(bindings.ShortcutOf("host.restart"));
    }

    [Fact]
    public void AConflictKeepsTheFirstCommandByIdAndWarns()
    {
        var bindings = new KeyBindings(Commands(), new Dictionary<string, string> { ["view.stats"] = "shift+ctrl+p" });

        Assert.Equal("Ctrl+Shift+P", bindings.ShortcutOf("app.palette"));
        Assert.Null(bindings.ShortcutOf("view.stats"));
        Assert.Contains(bindings.Warnings, w => w.Contains("app.palette") && w.Contains("view.stats"));
    }

    [Fact]
    public void AnOverrideForAnUnknownCommandWarns()
    {
        var bindings = new KeyBindings(Commands(), new Dictionary<string, string> { ["no.such"] = "F9" });

        Assert.Contains(bindings.Warnings, w => w.Contains("no.such"));
    }

    [Theory]
    [InlineData("Ctrl+Shift+P", "shift+control+p")]
    [InlineData("Alt+F4", "alt + f4")]
    public void NormalizeIgnoresModifierOrderCaseAndSpaces(string a, string b) =>
        Assert.Equal(KeyBindings.Normalize(a), KeyBindings.Normalize(b));
}
