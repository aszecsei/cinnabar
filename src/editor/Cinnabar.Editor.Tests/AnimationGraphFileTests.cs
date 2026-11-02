using System.Text;
using System.Text.RegularExpressions;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Tests;

/// <summary>The animation graph's reader and writer, over the files that the cooker's tests read too.</summary>
public sealed partial class AnimationGraphFileTests : IDisposable
{
    readonly TempDirectory _temp = new("animation-graph-file");

    const string Graph = """
        animation_graph 1
        # The file's comment.
        entry = idle

        param speed float 0 # meters a second
        param look trigger

        clip stand = $00112233445566778899aabbccddeeff

        # Stands about.
        node 1 state
        	position = [0, 0]   # the corner
        	name = idle
        	motion = stand
        node 2 state
        	name = walk
        	motion = stand

        node 20 transition
        	from = idle
        	to = walk
        	when = speed > 0.1
        node 21 transition
        	from = walk
        	to = idle
        	when = speed < 0.1

        """;

    static string Text => Graph.ReplaceLineEndings("\n");

    public void Dispose() => _temp.Dispose();

    static AnimationGraphFile Read(string text)
    {
        var (file, problem) = AnimationGraphFile.Parse(text);
        Assert.Null(problem);
        return file!;
    }

    static string Corpus(string name) =>
        File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "tools", "cook", "testdata", "animation_graphs", name + ".animation_graph")).ReplaceLineEndings("\n");

    static string Sample() =>
        File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "models", "fox", "fox.animation_graph")).ReplaceLineEndings("\n");

    [GeneratedRegex(@"# problem(?: node (\d+))?")]
    private static partial Regex ProblemMarker();

    [Theory]
    [InlineData("plain")]
    [InlineData("quirks")]
    [InlineData("mistakes")]
    public void TheCooksFilesWriteBackAsTheyWereWithEveryLineEnding(string name)
    {
        var text = Corpus(name);
        Assert.Equal(text, Read(text).Text);
        Assert.Equal(text.ReplaceLineEndings("\r\n"), Read(text.ReplaceLineEndings("\r\n")).Text);
        // Without a final line ending, and with one kind of ending on a line among the other.
        Assert.Equal(text.TrimEnd('\n'), Read(text.TrimEnd('\n')).Text);
        var mixed = text.Replace("\nnode", "\r\nnode");
        Assert.Equal(mixed, Read(mixed).Text);
    }

    [Fact]
    public void TheSamplesGraphWritesBackAsItWas() => Assert.Equal(Sample(), Read(Sample()).Text);

    [Theory]
    [InlineData("plain")]
    [InlineData("quirks")]
    [InlineData("mistakes")]
    public void NodesAreTheOnesTheCookerReadsAndProblemsLinesFindThem(string name)
    {
        var text = Corpus(name);
        var file = Read(text);
        // The file names its nodes in its comment, which the cooker's test checks too.
        var nodes = text.Split('\n').Single(l => l.StartsWith("# nodes: ", StringComparison.Ordinal))["# nodes: ".Length..].Split(' ').Select(int.Parse);
        Assert.Equal(nodes, file.Nodes.Select(n => n.Id));
        var number = 0;
        foreach (var line in text.Split('\n'))
        {
            number++;
            var marker = ProblemMarker().Match(line);
            if (marker.Success)
            {
                int? node = marker.Groups[1].Success ? int.Parse(marker.Groups[1].Value) : null;
                Assert.Equal(node, file.NodeAt(number));
            }
        }
    }

    [Fact]
    public void TheReaderReadsWhatTheCookerReadsInTheQuirksOfItsLines()
    {
        var file = Read(Corpus("quirks"));
        // The last of each counts, and a # in quotes is no comment.
        Assert.Equal("idle", file.Entry);
        Assert.Equal("b_#Root", file.RootMotion);
        // An ID has a base, and a field needs no spaces.
        Assert.NotNull(file.Find(16));
        Assert.Equal("idle", file.Find(1)!.Get("name"));
        // A comment and a blank line under a block stay in it, when a line indented after them shows that they are.
        Assert.Equal("a", file.Find(1)!.Get("motion"));
        Assert.Equal(["event 0.5 step \"a \\\" # b\" 1"], file.Clips.First().Events);
        Assert.Equal("00112233445566778899aabbccddeeff", file.Clips.First().Guid);
    }

    [Fact]
    public void AFileWithoutItsHeaderIsRefusedAtTheLineTheCookerGives()
    {
        var (file, problem) = AnimationGraphFile.Parse(Corpus("refused"));
        Assert.Null(file);
        Assert.Equal(3, problem!.Line);
        Assert.Equal(1, AnimationGraphFile.Parse("# only a comment\n").Problem!.Line);
        Assert.Equal(1, AnimationGraphFile.Parse("").Problem!.Line);
        Assert.Equal(1, AnimationGraphFile.Parse("animation_graph 2\n").Problem!.Line);
    }

    [Fact]
    public void TheDocumentOpensBytesAsTheCookerReadsThem()
    {
        Directory.CreateDirectory(_temp.Path);
        var path = _temp.Combine("a.animation_graph");
        // A byte order mark is on the header's line, where the cooker refuses it.
        File.WriteAllBytes(path, [0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes(Text)]);
        Assert.Null(AnimationGraphDocument.Open(path, "a").Document);
        File.WriteAllBytes(path, [.. Encoding.UTF8.GetBytes(Text), 0xFF]);
        Assert.Contains("UTF-8", AnimationGraphDocument.Open(path, "a").Problem!.Message);
        File.WriteAllBytes(path, Encoding.UTF8.GetBytes(Text));
        Assert.Equal(Text, AnimationGraphDocument.Open(path, "a").Document!.Text);
        Assert.NotNull(AnimationGraphDocument.Open(_temp.Combine("gone"), "a").Problem);
    }

    // The lines of the first text that the second has not, and the second's that the first has not.
    static (string[] Removed, string[] Added) Diff(string before, string after)
    {
        var (a, b) = (before.Split('\n'), after.Split('\n'));
        return ([.. a.Except(b)], [.. b.Except(a)]);
    }

    [Fact]
    public void AFieldsEditChangesOnlyItsValue()
    {
        var file = Read(Text);
        file.Find(1)!.Set("name", "stand");
        var renamed = Diff(Text, file.Text);
        Assert.Equal(["\tname = idle"], renamed.Removed);
        Assert.Equal(["\tname = stand"], renamed.Added);

        // A comment stays where it is, and so do the spaces before it.
        file = Read(Text);
        file.Find(1)!.SetPosition(10.4, -20.6);
        var moved = Diff(Text, file.Text);
        Assert.Equal(["\tposition = [10, -21]   # the corner"], moved.Added);
        Assert.Equal((10, -21), file.Find(1)!.Position);

        // A value with no spaces around its = keeps none.
        file = Read("animation_graph 1\nentry=idle\n");
        file.SetEntry("walk");
        Assert.Equal("animation_graph 1\nentry=walk\n", file.Text);
    }

    [Fact]
    public void ANewFieldIsALineOfTheNodeAndAPositionComesFirst()
    {
        var file = Read(Text);
        var walk = file.Find(2)!;
        walk.Set("speed", "2");
        Assert.Equal((double?)null, walk.Position?.X);
        walk.SetPosition(320, 0);
        Assert.Contains("node 2 state\n\tposition = [320, 0]\n\tname = walk\n\tmotion = stand\n\tspeed = 2\n", file.Text);

        walk.Set("speed", null);
        walk.Set("position", null);
        Assert.Equal(Text, file.Text);
        // A value is on one line.
        walk.Set("name", "a\nb");
        Assert.Equal("a b", walk.Get("name"));
    }

    [Theory]
    [InlineData("\n")]
    [InlineData("\r\n")]
    public void NewLinesEndAsTheFilesDo(string ending)
    {
        var text = Text.ReplaceLineEndings(ending);
        var file = Read(text);
        file.Find(21)!.Set("duration", "0.5");
        Assert.Contains($"when = speed < 0.1{ending}\tduration = 0.5{ending}", file.Text);
        Assert.EndsWith(ending, file.Text);
    }

    [Fact]
    public void AFileWithoutAFinalLineEndingStaysSo()
    {
        var file = Read("animation_graph 1\nnode 1 state");
        file.Find(1)!.Set("name", "idle");
        Assert.Equal("animation_graph 1\nnode 1 state\n\tname = idle", file.Text);
        var added = file.AddNode(AnimationGraphNodeKind.State);
        Assert.Equal(2, added.Id);
        Assert.Equal("animation_graph 1\nnode 1 state\n\tname = idle\nnode 2 state", file.Text);
        file.Remove(added);
        Assert.Equal("animation_graph 1\nnode 1 state\n\tname = idle", file.Text);
    }

    [Fact]
    public void NewBlocksGoWithTheirKind()
    {
        var file = Read(Text);
        file.AddParam("grounded", "bool", "true");
        Assert.Contains("param look trigger\nparam grounded bool true\n\nclip", file.Text);
        file.AddClip("run", "ffeeddccbbaa99887766554433221100");
        Assert.Contains("= $00112233445566778899aabbccddeeff\nclip run = $ffeeddccbbaa99887766554433221100\n\n# Stands", file.Text);
        var state = file.AddNode(AnimationGraphNodeKind.State);
        Assert.Equal(22, state.Id);
        Assert.Contains("\tmotion = stand\nnode 22 state\n\nnode 20", file.Text);
        var blend = file.AddNode(AnimationGraphNodeKind.Blend1D);
        Assert.Equal(23, blend.Id);
        Assert.EndsWith("when = speed < 0.1\n\nnode 23 blend_1d\n", file.Text);

        // Nothing is in its group yet: a blank line parts it from what follows, or from what is before it.
        file = Read("animation_graph 1\nentry = a\nnode 1 state\n");
        file.AddParam("speed", "float", null);
        Assert.Equal("animation_graph 1\nentry = a\nparam speed float\n\nnode 1 state\n", file.Text);
        file = Read("animation_graph 1\n# Why.\n");
        file.SetEntry("a");
        Assert.Equal("animation_graph 1\n# Why.\nentry = a\n", file.Text);
        file.SetRootMotion("hips \"0\"");
        Assert.Equal("hips \"0\"", file.RootMotion);
        file.SetRootMotion(null);
        Assert.Equal("animation_graph 1\n# Why.\nentry = a\n", file.Text);
    }

    [Fact]
    public void AParameterAndAClipKeepTheirComments()
    {
        var file = Read(Text);
        AnimationGraphFile.SetParam(file.Params.First(), "pace", "float", "1");
        Assert.Contains("param pace float 1 # meters a second\n", file.Text);
        Assert.Equal(("pace", "float", "1"), (file.Params.First().Name, file.Params.First().Type, file.Params.First().Default));
        Assert.Null(file.Params.Last().Default);
        AnimationGraphFile.SetClip(file.Clips.First(), "wait", "ffeeddccbbaa99887766554433221100");
        Assert.Equal(("wait", "ffeeddccbbaa99887766554433221100"), (file.Clips.First().Name, file.Clips.First().Guid));
    }

    [Fact]
    public void ANodesRemovalTakesItsCommentAndOneBlankLine()
    {
        var file = Read(Text);
        file.Remove(file.Find(1)!);
        Assert.Contains("clip stand = $00112233445566778899aabbccddeeff\n\nnode 2 state", file.Text);

        // The blank lines on each side of it become one.
        file = Read("animation_graph 1\n\nnode 1 state\n\nnode 2 state\n");
        file.Remove(file.Find(1)!);
        Assert.Equal("animation_graph 1\n\nnode 2 state\n", file.Text);
    }

    [Fact]
    public void SwappingTwoTransitionsSwapsTheirLines()
    {
        var file = Read(Text);
        file.Swap(file.Find(20)!, file.Find(21)!);
        Assert.Contains("node 21 transition\n\tfrom = walk\n\tto = idle\n\twhen = speed < 0.1\nnode 20 transition\n\tfrom = idle", file.Text);
        Assert.Equal([1, 2, 21, 20], file.Nodes.Select(n => n.Id));
        file.Swap(file.Find(20)!, file.Find(21)!);
        Assert.Equal(Text, file.Text);
    }

    [Fact]
    public void TheDocumentKeepsTheFilesTextAndUndoesEachEdit()
    {
        Directory.CreateDirectory(_temp.Path);
        var path = _temp.Combine("a.animation_graph");
        var crlf = Text.ReplaceLineEndings("\r\n");
        File.WriteAllText(path, crlf);
        var document = AnimationGraphDocument.Open(path, "a").Document!;
        Assert.False(document.IsDirty);
        Assert.Equal(crlf, document.Text);

        document.Edit("Rename", g => g.Find(1)!.Set("name", "stand"));
        Assert.True(document.IsDirty);
        Assert.Equal(["Rename"], document.History);
        // An edit that changes nothing leaves no entry.
        document.Edit("Rename again", g => g.Find(1)!.Set("name", "stand"));
        Assert.Single(document.History);

        // A drag is one entry, and undo puts every line back.
        document.Begin("Move");
        for (var x = 1; x <= 3; x++)
        {
            document.Step(g => g.Find(2)!.SetPosition(x * 10, 0));
        }
        Assert.Contains("[30, 0]", document.Text);
        document.Commit();
        Assert.Equal(["Rename", "Move"], document.History);
        document.Undo();
        Assert.Null(document.Graph.Find(2)!.Position);
        document.Undo();
        Assert.Equal(crlf, document.Text);
        Assert.Equal("idle", document.Graph.Find(1)!.Get("name"));
        Assert.False(document.IsDirty);
        document.Redo();
        Assert.Equal("stand", document.Graph.Find(1)!.Get("name"));

        // A cancelled drag changes nothing.
        document.Begin("Move");
        document.Step(g => g.Find(1)!.SetPosition(99, 99));
        document.Cancel();
        Assert.Equal((0, 0), document.Graph.Find(1)!.Position);

        document.Save();
        Assert.False(document.IsDirty);
        Assert.Equal(crlf.Replace("name = idle", "name = stand"), File.ReadAllText(path));
        // A problem's line finds its node in the text as it is now.
        Assert.Equal(1, document.NodeAt(document.Text.ReplaceLineEndings("\n").Split('\n').ToList().IndexOf("\tname = stand") + 1));
    }
}
