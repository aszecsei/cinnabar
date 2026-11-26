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
    public void ForEnumOffersEachValueInOrderAndSelectsByWhatItShows()
    {
        var shape = Shape.Box;
        var plain = ChoiceCommand.ForEnum("shape", "Shape", () => shape, value => shape = value);
        Assert.Equal(["Box", "Ball", "Cone"], plain.Options);
        plain.Select("Cone");
        Assert.Equal(Shape.Cone, shape);
        Assert.Equal("Cone", plain.Selected);

        // With a display, the options are what it shows, and a value's own name is not one of them.
        var choice = ChoiceCommand.ForEnum("shape", "Shape", () => shape, value => shape = value, value => $"<{value}>");
        Assert.Equal(["<Box>", "<Ball>", "<Cone>"], choice.Options);
        choice.Select("<Ball>");
        Assert.Equal(Shape.Ball, shape);
        Assert.Throws<ArgumentException>(() => choice.Select("Ball"));
    }
}
