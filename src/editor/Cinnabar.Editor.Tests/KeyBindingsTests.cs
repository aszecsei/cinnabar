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

    static CommandRegistry ScopedCommands()
    {
        var commands = Commands();
        commands.Register(new Command("cutscene.snap", "Snap", () => { }) { Shortcut = "N" });
        commands.Register(new Command("tool.nav", "Navigation Path", () => { }) { Shortcut = "N", ShortcutScopes = [ShortcutScopes.Viewport] });
        commands.Register(new Command("view.frame", "Frame", () => { }) { Shortcut = "F", ShortcutScopes = [ShortcutScopes.Viewport, ShortcutScopes.Canvas] });
        commands.Register(new Command("graph.frame", "Frame Graph", () => { }) { Shortcut = "F", ShortcutScopes = [ShortcutScopes.Canvas] });
        return commands;
    }

    [Fact]
    public void AScopedShortcutIsTheScopesAndNotTheWindows()
    {
        var bindings = new KeyBindings(ScopedCommands(), new Dictionary<string, string>());

        Assert.DoesNotContain(bindings.All, b => b.CommandId == "tool.nav");
        Assert.Contains(("cutscene.snap", "N"), bindings.All);
        Assert.Equal([("tool.nav", "N"), ("view.frame", "F")], bindings.InScope(ShortcutScopes.Viewport).OrderBy(b => b.CommandId));
        Assert.Equal("N", bindings.ShortcutOf("tool.nav"));
        Assert.Equal("N in the viewport", bindings.Describe("tool.nav"));
        Assert.Equal("N", bindings.Describe("cutscene.snap"));
        Assert.Empty(bindings.ScopesOf("cutscene.snap"));
    }

    [Fact]
    public void TheSameKeyConflictsOnlyInTheSameScope()
    {
        var bindings = new KeyBindings(ScopedCommands(), new Dictionary<string, string>());

        // N in the viewport and N in the window are not the same key. F in the canvas is graph.frame's, the first by ID,
        // and view.frame keeps F in the viewport.
        Assert.Equal(["graph.frame"], bindings.InScope(ShortcutScopes.Canvas).Select(b => b.CommandId));
        Assert.Equal([ShortcutScopes.Viewport], bindings.ScopesOf("view.frame"));
        Assert.Equal("F in the viewport", bindings.Describe("view.frame"));
        var warning = Assert.Single(bindings.Warnings);
        Assert.Contains("graph.frame", warning);
        Assert.Contains("view.frame", warning);
        Assert.Contains(ShortcutScopes.Label(ShortcutScopes.Canvas), warning);
    }

    [Fact]
    public void AnOverrideOfAScopedCommandChangesItsKeyInItsScopes()
    {
        var bindings = new KeyBindings(ScopedCommands(), new Dictionary<string, string> { ["tool.nav"] = "J", ["view.frame"] = "" });

        Assert.Equal([("tool.nav", "J")], bindings.InScope(ShortcutScopes.Viewport));
        Assert.DoesNotContain(bindings.All, b => b.CommandId == "tool.nav");
        Assert.Null(bindings.ShortcutOf("view.frame"));
    }

    [Theory]
    [InlineData("Ctrl+Shift+P", "shift+control+p")]
    [InlineData("Alt+F4", "alt + f4")]
    public void NormalizeIgnoresModifierOrderCaseAndSpaces(string a, string b) =>
        Assert.Equal(KeyBindings.Normalize(a), KeyBindings.Normalize(b));
}
