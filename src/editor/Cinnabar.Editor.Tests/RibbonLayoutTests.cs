using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Commands.Ribbon;

namespace Cinnabar.Editor.Tests;

public class RibbonLayoutTests
{
    static CommandRegistry Commands()
    {
        var commands = new CommandRegistry();
        commands.Register(new Command("host.restart", "Restart Host", () => { }));
        commands.Register(new Command("host.stop", "Stop Host", () => { }));
        commands.Register(new ChoiceCommand("viewport.scale", "Scale", ["Fit", "100%"], () => "Fit", _ => { }));
        return commands;
    }

    static RibbonLayout Layout(params RibbonItem[] items) =>
        new([new RibbonCategory("art", "Art", "#3a7bd5")],
            [new RibbonTab("home", "Home", [new RibbonGroup("Host", items)])]);

    [Fact]
    public void AValidLayoutHasNoErrors() =>
        Assert.Empty(Layout(
            new SplitButton("host.restart", ["host.restart", "host.stop"]),
            new SmallStack(["host.stop"]),
            new ComboBox("viewport.scale")).Validate(Commands()));

    [Fact]
    public void AnUnknownCommandIsAnError() =>
        Assert.Contains(Layout(new LargeButton("no.such")).Validate(Commands()), e => e.Contains("no.such"));

    [Fact]
    public void ASmallStackHoldsAtMostThree() =>
        Assert.NotEmpty(Layout(new SmallStack(["host.stop", "host.stop", "host.stop", "host.stop"])).Validate(Commands()));

    [Fact]
    public void AComboBoxNeedsAChoiceCommand() =>
        Assert.Contains(Layout(new ComboBox("host.stop")).Validate(Commands()), e => e.Contains("choice"));

    [Fact]
    public void ATabMustNameAKnownCategory()
    {
        var layout = new RibbonLayout([], [new RibbonTab("home", "Home", []) { Category = "art" }]);

        Assert.Contains(layout.Validate(Commands()), e => e.Contains("art"));
    }

    [Fact]
    public void AContextualTabShowsOnlyWhileItsContextIsActive()
    {
        var layout = new RibbonLayout([],
        [
            new RibbonTab("home", "Home", []),
            new RibbonTab("terrain", "Terrain", []) { Context = "selection.terrain" },
        ]);
        var context = new EditorContext();

        Assert.Equal(["home"], layout.VisibleTabs(context).Select(t => t.Id));
        context.Set("selection.terrain", true);
        Assert.Equal(["home", "terrain"], layout.VisibleTabs(context).Select(t => t.Id));
    }
}
