using System.Text.RegularExpressions;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Tests;

/// <summary>The decision's and the blackboard's readers and writers, over the files that the cooker's tests read too.</summary>
public sealed partial class DecisionFileTests
{
    static string Corpus(string file) =>
        File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "tools", "cook", "testdata", "decisions", file)).ReplaceLineEndings("\n");

    static DecisionFile Read(string text)
    {
        var (file, problem) = DecisionFile.Parse(text);
        Assert.Null(problem);
        return file!;
    }

    static BlackboardFile ReadBoard(string text)
    {
        var (file, problem) = BlackboardFile.Parse(text);
        Assert.Null(problem);
        return file!;
    }

    [GeneratedRegex(@"# problem(?: node (\d+))?")]
    private static partial Regex ProblemMarker();

    // Every way that a file's lines can end: as it is, with CRLF, without a final ending, and both kinds in one file.
    static IEnumerable<string> Endings(string text, string blockStart)
    {
        yield return text;
        yield return text.ReplaceLineEndings("\r\n");
        yield return text.TrimEnd('\n');
        yield return text.Replace("\n" + blockStart, "\r\n" + blockStart);
    }

    [Theory]
    [InlineData("plain")]
    [InlineData("quirks")]
    [InlineData("mistakes")]
    [InlineData("utility")]
    [InlineData("goap")]
    [InlineData("htn")]
    public void TheCooksDecisionsWriteBackAsTheyWereWithEveryLineEnding(string name)
    {
        foreach (var text in Endings(Corpus(name + ".decision"), "node"))
        {
            Assert.Equal(text, Read(text).Text);
        }
    }

    [Theory]
    [InlineData("guard")]
    [InlineData("quirks")]
    [InlineData("mistakes")]
    public void TheCooksBlackboardsWriteBackAsTheyWereWithEveryLineEnding(string name)
    {
        foreach (var text in Endings(Corpus(name + ".blackboard"), "float"))
        {
            Assert.Equal(text, ReadBoard(text).Text);
        }
    }

    [Theory]
    [InlineData("plain")]
    [InlineData("quirks")]
    [InlineData("mistakes")]
    [InlineData("utility")]
    [InlineData("goap")]
    [InlineData("htn")]
    public void NodesAreTheOnesTheCookerReadsAndProblemsLinesFindThem(string name)
    {
        var text = Corpus(name + ".decision");
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

    [Theory]
    [InlineData("guard")]
    [InlineData("quirks")]
    public void KeysAreTheOnesTheCookerReads(string name)
    {
        var text = Corpus(name + ".blackboard");
        var keys = text.Split('\n').Single(l => l.StartsWith("# keys: ", StringComparison.Ordinal))["# keys: ".Length..].Split(' ');
        Assert.Equal(keys, ReadBoard(text).Keys.Select(k => k.Name));
    }

    [Fact]
    public void TheReaderReadsWhatTheCookerReadsInTheQuirksOfItsLines()
    {
        var file = Read(Corpus("quirks.decision"));
        // An ID has a base, a comment in the first column does not end a block, and the header's lines can come last.
        Assert.Equal([1, 3, 5], file.Find(16)!.Ids("children"));
        Assert.Equal((0.0, 0.0), file.Find(16)!.Position);
        Assert.Equal((1.0, 2.0), file.Find(1)!.Position);
        Assert.Equal("behavior_tree", file.Technique);
        Assert.Equal("0123456789abcdef0123456789abcdef", file.Blackboard);
        // A # in quotes is no comment, and a write can have a tab after its set.
        Assert.Equal("bark(line = \"Halt! # not a comment\", at = target)", file.Find(3)!.Get("action"));
        Assert.Equal([("mood", "alert"), ("searching", "true"), ("ammo", "0")], file.Find(5)!.Writes);

        // The first of a field that is set twice counts, as in the cooker.
        Assert.Equal("1", Read(Corpus("mistakes.decision")).Find(2)!.Get("seconds"));

        var board = ReadBoard(Corpus("quirks.blackboard"));
        Assert.Equal(["calm", "alert", "angry"], board.Find("mood")!.Values);
        Assert.Equal("alert", board.Find("mood")!.Default);
        Assert.Equal("position", board.Find("last_seen")!.Type);
        Assert.Null(board.Find("searching")!.Default);
    }

    [Fact]
    public void AFileWithoutItsHeaderIsRefusedAtTheLineTheCookerGives()
    {
        Assert.Equal(3, DecisionFile.Parse(Corpus("refused.decision")).Problem!.Line);
        Assert.Equal(2, DecisionFile.Parse(Corpus("refused_version.decision")).Problem!.Line);
        Assert.Equal(1, DecisionFile.Parse("# only a comment\n").Problem!.Line);
        Assert.Equal(1, BlackboardFile.Parse("").Problem!.Line);
        Assert.Equal(2, BlackboardFile.Parse("# a guard\nblackboard 2\n").Problem!.Line);
    }

    [Fact]
    public void AnEditChangesOnlyItsOwnLines()
    {
        var text = Corpus("plain.decision");
        var file = Read(text);
        file.Find(4)!.Set("seconds", "2");
        file.Find(3)!.SetPosition(10.4, -20.6);
        file.Find(1)!.SetIds("children", [5, 2, 6, 9, 10]);
        var expected = text.Replace("\tseconds = 0.5", "\tseconds = 2")
            .Replace("node 3 action\n", "node 3 action\n\tposition = [10, -21]\n")
            .Replace("children = 2, 5, 6, 9, 10", "children = 5, 2, 6, 9, 10");
        Assert.Equal(expected, file.Text);
    }

    [Fact]
    public void ListsKeepTheirIdsAsTheyAreWritten()
    {
        var file = Read(Corpus("quirks.decision"));
        file.Find(16)!.SetIds("children", [5, 1, 3]);
        Assert.Equal("5, 1, 3", file.Find(16)!.Get("children"));
        // An empty list takes its field away.
        file.Find(1)!.SetIds("children", []);
        Assert.Null(file.Find(1)!.Get("children"));
        Assert.Contains("  when = has_target", file.Text);
    }

    [Fact]
    public void NodesAreAddedAfterTheLastAndRemovedWithTheirComment()
    {
        var file = Read("decision 1\ntechnique = behavior_tree\n\n# The root.\nnode 1 selector\n\tchildren = 2\nnode 2 wait\n\tseconds = 1\n");
        var node = file.AddNode("action");
        Assert.Equal(3, node.Id);
        node.Set("action", "patrol");
        node.SetPosition(0, 100);
        Assert.Equal("decision 1\ntechnique = behavior_tree\n\n# The root.\nnode 1 selector\n\tchildren = 2\nnode 2 wait\n\tseconds = 1\nnode 3 action\n\tposition = [0, 100]\n\taction = patrol\n", file.Text);
        file.Remove(file.Find(1)!);
        Assert.Equal("decision 1\ntechnique = behavior_tree\n\nnode 2 wait\n\tseconds = 1\nnode 3 action\n\tposition = [0, 100]\n\taction = patrol\n", file.Text);
    }

    [Fact]
    public void WritesAreReplacedInTheirPlace()
    {
        var file = Read("decision 1\nnode 1 set\n\tset a = 1 # first\n\tset b = 2\n\twhen = c\n");
        file.Find(1)!.SetWrites([("a", "3"), ("d", "4"), ("e", "5")]);
        Assert.Equal("decision 1\nnode 1 set\n\tset a = 3 # first\n\tset d = 4\n\tset e = 5\n\twhen = c\n", file.Text);
        file.Find(1)!.SetWrites([("a", "3")]);
        Assert.Equal("decision 1\nnode 1 set\n\tset a = 3 # first\n\twhen = c\n", file.Text);
    }

    [Fact]
    public void ABlackboardIsSetAfterTheTechnique()
    {
        var file = Read("decision 1\n# A tree.\ntechnique = behavior_tree\n\nnode 1 wait\n\tseconds = 1\n");
        file.SetBlackboard("0123456789ABCDEF0123456789ABCDEF");
        Assert.Equal("decision 1\n# A tree.\ntechnique = behavior_tree\nblackboard = $0123456789abcdef0123456789abcdef\n\nnode 1 wait\n\tseconds = 1\n", file.Text);
        Assert.Equal("0123456789abcdef0123456789abcdef", file.Blackboard);
    }

    [Fact]
    public void RenamingAKeyChangesTheWordsThatNameItAndNoOthers()
    {
        var file = Read(Corpus("plain.decision"));
        Assert.True(file.ReadsKey("target"));
        Assert.False(file.ReadsKey("ammo"));
        Assert.True(file.RenameKey("target", "enemy"));
        Assert.Equal("enemy != none and distance(self, enemy) < 2", file.Find(2)!.Get("when"));
        // An argument's name and a quoted string stay: move_to's key is the text "target", not the key.
        Assert.Equal("attack(at = enemy)", file.Find(3)!.Get("action"));
        Assert.Equal("move_to(key = \"target\")", file.Find(5)!.Get("action"));

        Assert.True(file.RenameKey("rest_time", "rest"));
        Assert.Equal("rest", file.Find(11)!.Get("seconds"));
        Assert.Equal("rest", file.Find(11)!.Get("cooldown"));
        Assert.Contains(("rest", "3"), file.Find(8)!.Writes);
        // A key that is part of another word is not that word.
        Assert.False(file.RenameKey("has", "had"));

        // A planner's keys, tests and effects name keys too, and a comment stays as it is.
        var goap = Read(Corpus("goap.decision"));
        Assert.True(goap.RenameKey("ammo", "rounds"));
        Assert.Equal("armed, rounds, near, down", goap.Setting("keys"));
        Assert.Equal("rounds >= 5", goap.Find(2)!.Get("desired"));
        Assert.Equal("armed = true, rounds += 6", goap.Find(10)!.Get("effects"));
        Assert.Equal("armed and rounds > 0 and near", goap.Find(11)!.Get("preconditions"));
        Assert.Contains("otherwise keep ammo.", goap.Text);
    }

    [Fact]
    public void ActionReferencesSplitAsTheCookerSplitsThem()
    {
        var reference = ActionReference.Parse("bark(line = \"a, b\", at = [1, 2, 3], to = target)")!;
        Assert.Equal("bark", reference.Name);
        Assert.Equal([("line", "\"a, b\""), ("at", "[1, 2, 3]"), ("to", "target")], reference.Arguments);
        Assert.Equal("bark(line = \"a, b\", to = enemy)", reference.With("at", null).With("to", "enemy").Write());
        Assert.Equal("patrol", ActionReference.Parse(" patrol ")!.Write());
        Assert.Null(ActionReference.Parse("bark(line)"));
        Assert.Null(ActionReference.Parse("bark(line = \"open)"));
    }

    [Fact]
    public void ABlackboardsKeysAreEditedInTheirLines()
    {
        var board = ReadBoard(Corpus("guard.blackboard"));
        var mood = board.Find("mood")!;
        BlackboardFile.SetKey(mood, "enum", "temper", ["calm", "alert"], "alert");
        board.Move(board.Find("ammo")!, -1);
        board.Remove(board.Find("heading")!);
        board.AddKey("int", "kills", [], null);
        var expected = Corpus("guard.blackboard")
            .Replace("float health = 100\nint ammo = 30\n", "int ammo = 30\nfloat health = 100\n")
            .Replace("enum mood (calm, alert, angry) = calm", "enum temper (calm, alert) = alert")
            .Replace("vector heading = [0, 0, 1]\n", "")
            .Replace("float travel_cost = 1", "float travel_cost = 1\nint kills");
        Assert.Equal(expected, board.Text);
    }
}
