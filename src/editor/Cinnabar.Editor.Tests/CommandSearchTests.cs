using Cinnabar.Editor.Commands;

namespace Cinnabar.Editor.Tests;

public class CommandSearchTests
{
    static CommandRegistry Commands()
    {
        var commands = new CommandRegistry();
        foreach (var (id, label) in new[]
        {
            ("view.outliner", "Outliner"),
            ("host.restart", "Restart Host"),
            ("view.resetLayout", "Reset Layout"),
            ("host.stop", "Stop Host"),
        })
        {
            commands.Register(new Command(id, label, () => { }));
        }
        return commands;
    }

    [Fact]
    public void EveryWordMustMatch() =>
        Assert.Equal(["host.restart"], CommandSearch.Find(Commands(), "host res").Select(c => c.Id));

    [Fact]
    public void LabelPrefixRanksFirstThenWordPrefix() =>
        Assert.Equal(["view.resetLayout", "host.restart"], CommandSearch.Find(Commands(), "re").Select(c => c.Id).Take(2));

    [Fact]
    public void IdsMatchToo() =>
        Assert.Equal(["host.restart", "host.stop"], CommandSearch.Find(Commands(), "host.").Select(c => c.Id));

    [Fact]
    public void AnEmptyQueryListsEverythingAlphabetically() =>
        Assert.Equal(["Outliner", "Reset Layout", "Restart Host", "Stop Host"], CommandSearch.Find(Commands(), " ").Select(c => c.Label));
}
