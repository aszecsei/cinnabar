using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tests;

/// <summary>The text that the preview cooks with each script slot's stand-in (see docs/editor/cutscene-editor.md#script-slots).</summary>
public sealed class CutsceneStandInsTests
{
    const string Text = "cutscene 1\nlength = 60000\n\nbinding 1 \"Companion\"\n\tprovided = true # given by the quest\n\tpolicy = optional\n"
        + "binding 2 \"Gate\"\n\tprovided = true\n\ntrack 1 transform \"Move\"\n\tbinding = 1\n";

    [Fact]
    public void AStandInTakesItsSlotsLineAndEveryLineStaysWhereItWas()
    {
        var text = CutsceneStandIns.PreviewText(Text, new Dictionary<int, string>
        {
            [1] = "$cafecafecafecafecafecafecafecafe",
            [2] = "@5ce5ce5ce5ce5ce5ce5ce5ce5ce5ce51/0000000000000002",
            // Not a binding of the cutscene.
            [9] = "$00000000000000000000000000000001",
        });

        Assert.Equal(Text.Split('\n').Length, text.Split('\n').Length);
        Assert.Equal(Text
            .Replace("provided = true # given", "spawn = $cafecafecafecafecafecafecafecafe # given", StringComparison.Ordinal)
            .Replace("\tpolicy = optional", "\t# policy = optional", StringComparison.Ordinal)
            .Replace("\"Gate\"\n\tprovided = true", "\"Gate\"\n\tpossess = @5ce5ce5ce5ce5ce5ce5ce5ce5ce5ce51/0000000000000002", StringComparison.Ordinal), text);
    }

    [Fact]
    public void ATextWithNoStandInOrThatDoesNotParseComesBackAsItWas()
    {
        Assert.Same(Text, CutsceneStandIns.PreviewText(Text, new Dictionary<int, string>()));
        Assert.Same(Text, CutsceneStandIns.PreviewText(Text, new Dictionary<int, string> { [7] = "$cafecafecafecafecafecafecafecafe" }));
        Assert.Equal("not a cutscene", CutsceneStandIns.PreviewText("not a cutscene", new Dictionary<int, string> { [1] = "$x" }));
    }
}
