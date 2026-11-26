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
    public void AnOverrideReplacesOrRemovesTheDefaultAndOneForAnUnknownCommandWarns()
    {
        var bindings = new KeyBindings(Commands(), new Dictionary<string, string>
        {
            ["view.stats"] = "F3",
            ["host.restart"] = "",
            ["no.such"] = "F9",
        });

        Assert.Equal("F3", bindings.ShortcutOf("view.stats"));
        Assert.Null(bindings.ShortcutOf("host.restart"));
        Assert.Equal("Ctrl+Shift+P", bindings.ShortcutOf("app.palette"));
        Assert.Contains(bindings.Warnings, w => w.Contains("no.such"));
    }

    [Fact]
    public void AConflictKeepsTheFirstCommandByIdAndWarns()
    {
        var bindings = new KeyBindings(Commands(), new Dictionary<string, string> { ["view.stats"] = "shift+ctrl+p" });

        Assert.Equal("Ctrl+Shift+P", bindings.ShortcutOf("app.palette"));
        Assert.Null(bindings.ShortcutOf("view.stats"));
        Assert.Contains(bindings.Warnings, w => w.Contains("app.palette") && w.Contains("view.stats"));
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
        var warning = Assert.Single(bindings.Warnings);
        Assert.Contains("graph.frame", warning);
        Assert.Contains("view.frame", warning);
        Assert.Contains(ShortcutScopes.Label(ShortcutScopes.Canvas), warning);
    }
}
