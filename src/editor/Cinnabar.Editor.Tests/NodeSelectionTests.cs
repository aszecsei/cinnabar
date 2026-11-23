using Cinnabar.Editor.Graphs;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>The selection that the material, animation graph and decision editors share.</summary>
public sealed class NodeSelectionTests
{
    [Fact]
    public void ReplaceAddAndToggleSetTheSelectionAndEachTellsChanged()
    {
        var selection = new NodeSelection();
        var changes = 0;
        selection.Changed += () => changes++;

        selection.Select([1, 2]);
        Assert.Equal([1, 2], selection.Order());
        selection.Select([3], SelectMode.Add);
        Assert.Equal([1, 2, 3], selection.Order());
        selection.Select([2, 4], SelectMode.Toggle);
        Assert.Equal([1, 3, 4], selection.Order());
        Assert.Null(selection.One);
        selection.Select([3]);
        Assert.Equal(3, selection.One);
        // A select that changes nothing still tells, as a click on what is selected does.
        selection.Select([3]);
        Assert.Equal(5, changes);
    }

    [Fact]
    public void APruneTellsChangedOnlyWhenItTakesSomething()
    {
        var selection = new NodeSelection();
        selection.Select([1, 2, 3]);
        var changes = 0;
        selection.Changed += () => changes++;

        Assert.False(selection.Prune(_ => true));
        Assert.Equal(0, changes);
        Assert.True(selection.Prune(id => id != 2));
        Assert.Equal([1, 3], selection.Order());
        Assert.Equal(1, changes);
    }
}
