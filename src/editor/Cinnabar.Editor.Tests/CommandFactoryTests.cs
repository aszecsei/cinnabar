using Cinnabar.Editor.Commands;

namespace Cinnabar.Editor.Tests;

public class CommandFactoryTests
{
    enum Shape
    {
        Box,
        Ball,
        Cone,
    }

    [Fact]
    public void ForEnumOffersEachValueByNameInOrder()
    {
        var choice = ChoiceCommand.ForEnum("shape", "Shape", () => Shape.Ball, _ => { });
        Assert.Equal(["Box", "Ball", "Cone"], choice.Options);
        Assert.Equal("Ball", choice.Selected);
    }

    [Fact]
    public void ForEnumSelectSetsTheValue()
    {
        var shape = Shape.Box;
        var choice = ChoiceCommand.ForEnum("shape", "Shape", () => shape, value => shape = value);
        choice.Select("Cone");
        Assert.Equal(Shape.Cone, shape);
        Assert.Equal("Cone", choice.Selected);
    }

    [Fact]
    public void ForEnumShowsValuesWithDisplay()
    {
        var shape = Shape.Box;
        var choice = ChoiceCommand.ForEnum("shape", "Shape", () => shape, value => shape = value, value => $"<{value}>");
        Assert.Equal(["<Box>", "<Ball>", "<Cone>"], choice.Options);
        choice.Select("<Ball>");
        Assert.Equal(Shape.Ball, shape);
        Assert.Throws<ArgumentException>(() => choice.Select("Ball"));
    }

    [Fact]
    public void ForEnumKeepsItsDescriptionIconAndGate()
    {
        var open = false;
        var choice = ChoiceCommand.ForEnum("shape", "Shape", () => Shape.Box, _ => { }, description: "d", icon: "i", canExecuteWhen: () => open);
        Assert.Equal("d", choice.Description);
        Assert.Equal("i", choice.Icon);
        Assert.False(choice.CanExecute);
        open = true;
        Assert.True(choice.CanExecute);
    }

    [Fact]
    public void ToggleSetsTheOppositeAndIsCheckedWhileOn()
    {
        var on = false;
        var toggle = Command.Toggle("t", "T", () => on, value => on = value, "d");
        Assert.True(toggle.IsToggle);
        Assert.False(toggle.IsChecked);
        Assert.True(toggle.Execute());
        Assert.True(on);
        Assert.True(toggle.IsChecked);
        toggle.Execute();
        Assert.False(on);
        Assert.Equal("d", toggle.Description);
    }
}
