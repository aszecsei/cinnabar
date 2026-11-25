using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tests;

/// <summary>The shots of a cutscene: their order, a reorder, and a new shot that moves blocks into a child.</summary>
public sealed class CutsceneShotsTests
{
    const string Scene = "11111111111111111111111111111111";
    const string Prefab = "22222222222222222222222222222222";
    const string Sound = "33333333333333333333333333333333";
    const string ChildGuid = "44444444444444444444444444444444";
    const string Other = "55555555555555555555555555555555";

    static CutsceneFile Parse(string text) => CutsceneFile.Parse(text).File!;

    // A parent with a possessed hero, a spawned camera with a target, an unused binding, two cuts, a move of the hero,
    // a line of dialogue with its subtitle, and a sound that stays.
    const string Parent =
        "cutscene 1\n"
        + "length = 600000\n"
        + "rate = 24\n"
        + $"binding 1 \"Hero\"\n\tpossess = @{Scene}/0000000000000001\n"
        + $"binding 2 \"Cam\"\n\tspawn = ${Prefab}\n\tlook_at = 1\n"
        + $"binding 3 \"Unused\"\n\tpossess = @{Scene}/0000000000000002\n"
        + "track 1 camera_cut \"Cuts\"\n"
        + "\tsection 1 0 120000\n\t\tcamera = 2\n"
        + "\tsection 2 300000 360000\n\t\tcamera = 2\n"
        + "track 2 transform \"Move\"\n\tbinding = 1\n"
        + "\tsection 3 60000 180000\n\t\tchannel location.x\n\t\t\tkey 0 0 linear\n\t\t\tkey 60000 1 linear\n"
        + "track 3 audio \"Line\"\n"
        + $"\tsection 4 90000 150000\n\t\tasset = ${Sound}\n"
        + $"\tsection 6 400000 420000\n\t\tasset = ${Sound}\n"
        + "track 4 presentation \"Subs\"\n"
        + "\tsection 5 90000 150000\n\t\tkind = subtitle\n\t\ttext = \"Hi\"\n\t\taudio = 4\n";

    [Fact]
    public void ANewShotFromThreeSectionsMovesThemWithTheirBindingsAndSubtitleIntoTheChild()
    {
        var parent = Parse(Parent);
        var child = Parse(CutsceneFileTests.Template);
        var path = CutsceneShots.NewShot(parent, child, ["section:1", "section:3/channel:location.x/key:1", "section:4"], 0, ChildGuid, "Shot 01");

        Assert.Equal("section:7", path);
        Assert.Equal(
            "cutscene 1\n"
            + "length = 600000\n"
            + "rate = 24\n"
            + $"binding 1 \"Hero\"\n\tpossess = @{Scene}/0000000000000001\n"
            + $"binding 2 \"Cam\"\n\tspawn = ${Prefab}\n\tlook_at = 1\n"
            + $"binding 3 \"Unused\"\n\tpossess = @{Scene}/0000000000000002\n"
            + "track 1 camera_cut \"Cuts\"\n"
            + "\tsection 2 300000 360000\n\t\tcamera = 2\n"
            + "track 2 transform \"Move\"\n\tbinding = 1\n"
            + "track 3 audio \"Line\"\n"
            + $"\tsection 6 400000 420000\n\t\tasset = ${Sound}\n"
            + "track 4 presentation \"Subs\"\n"
            + "track 5 sub_sequence \"Shots\"\n"
            + $"\tsection 7 0 180000\n\t\tasset = ${ChildGuid}\n\t\tname = \"Shot 01\"\n\t\tbind 1 = 1\n\t\tbind 2 = 2\n",
            parent.Text);
        Assert.Equal(
            "cutscene 1\n"
            + "# Bindings, tracks, sections and keys (see docs/content/kinds/cutscenes.md). Times are ticks, 60000 a second.\n"
            + "length = 180000\n"
            + "rate = 24\n"
            + $"binding 1 \"Hero\"\n\tpossess = @{Scene}/0000000000000001\n"
            + $"binding 2 \"Cam\"\n\tspawn = ${Prefab}\n\tlook_at = 1\n"
            + "\n"
            + "track 1 camera_cut \"Cameras\"\n"
            + "\tsection 1 0 120000\n\t\tcamera = 2\n"
            + "track 3 audio \"Line\"\n"
            + $"\tsection 3 90000 150000\n\t\tasset = ${Sound}\n"
            + "track 4 presentation \"Subs\"\n"
            + "\tsection 4 90000 150000\n\t\tkind = subtitle\n\t\ttext = \"Hi\"\n\t\taudio = 3\n"
            // A binding's track goes after the binding's tracks, or else after the last track, as a paste puts it.
            + "track 2 transform \"Move\"\n\tbinding = 1\n"
            + "\tsection 2 60000 180000\n\t\tchannel location.x\n\t\t\tkey 0 0 linear\n\t\t\tkey 60000 1 linear\n",
            child.Text);
        Assert.Equal("Shot 01", parent.Find(path!)!.Name);
    }

    [Fact]
    public void ANewShotWithNothingSelectedIsEmptyAndRunsFromThePlayheadToTheNextShot()
    {
        var parent = Parse("cutscene 1\nlength = 600000\nrate = 30\ntrack 1 sub_sequence \"Shots\"\n"
            + $"\tsection 1 300000 360000\n\t\tasset = ${Other}\n");
        var child = Parse(CutsceneFileTests.Template);
        var path = CutsceneShots.NewShot(parent, child, [], 60000, ChildGuid, "Shot 02");

        Assert.Equal("section:2", path);
        Assert.Equal((60000, 300000), (parent.Find(path!)!.Start, parent.Find(path!)!.End));
        Assert.Equal(1, parent.Find(path!)!.Parent!.Id);
        Assert.Equal(240000, child.Length);
        Assert.Equal(CutsceneFileTests.Template.Replace("length = 600000", "length = 240000"), child.Text);
        // Past the last shot, the child is the template's length.
        var after = CutsceneShots.NewShot(parent, Parse(CutsceneFileTests.Template), [], 420000, Other, "Shot 03");
        Assert.Equal((420000, 1020000), (parent.Find(after!)!.Start, parent.Find(after!)!.End));
    }

    [Fact]
    public void ANewShotOfOnlyLockedBlocksChangesNothing()
    {
        var parent = Parse(Parent);
        var child = Parse(CutsceneFileTests.Template);
        Assert.Null(CutsceneShots.NewShot(parent, child, ["section:3"], 0, ChildGuid, "Shot", new HashSet<int> { 2 }));
        Assert.Equal(Parent, parent.Text);
        Assert.Equal(CutsceneFileTests.Template, child.Text);
    }

    const string Three =
        "cutscene 1\nlength = 600000\ntrack 1 sub_sequence \"Shots\"\n"
        + $"\tsection 1 0 60000\n\t\tasset = ${Other}\n\t\tname = \"A\"\n"
        + $"\tsection 2 70000 100000\n\t\tasset = ${Other}\n\t\tname = \"B\"\n"
        + $"\tsection 3 120000 220000\n\t\tasset = ${Other}\n\t\tname = \"C\"\n"
        + $"\tsection 4 300000 360000\n\t\tasset = ${Other}\n\t\tname = \"D\"\n"
        + "track 2 sub_sequence \"Inserts\"\n"
        + $"\tsection 5 10000 20000\n\t\tasset = ${Other}\n";

    [Fact]
    public void TheShotsAreEverySubSequenceSectionInTimeOrder()
    {
        var shots = CutsceneShots.Shots(Parse(Three));
        Assert.Equal(["section:1", "section:5", "section:2", "section:3", "section:4"], shots.Select(s => s.Path));
        Assert.Equal((70000, 100000, Other), (shots[2].Start, shots[2].End, shots[2].Guid));
    }

    [Fact]
    public void AReorderLaysTheShotsBetweenOutAgainWithTheirLengthsAndTheGapsOfTheirPlaces()
    {
        var file = Parse(Three);
        // C to the place of A: C, A, B, with the gaps of 10000 and 20000 before the second and third places.
        Assert.Equal(["section:3", "section:1", "section:2"], CutsceneShots.Reorder(file, "section:3", "section:1"));
        Assert.Equal(
            [("C", 0, 100000), ("A", 110000, 170000), ("B", 190000, 220000), ("D", 300000, 360000)],
            file.Tracks.First().Children.Select(s => (s.Name, s.Start!.Value, s.End!.Value)));
        // Back again, and the text is as it was, but for the order of the sections, which follows their starts.
        CutsceneShots.Reorder(file, "section:3", "section:2");
        Assert.Equal(Three, file.Text);
    }

    [Fact]
    public void AReorderStaysOnItsTrackAndOffLockedOnes()
    {
        var file = Parse(Three);
        Assert.NotNull(CutsceneShots.ReorderRefusal(file, "section:5", "section:1", null));
        Assert.Empty(CutsceneShots.Reorder(file, "section:5", "section:1"));
        Assert.Empty(CutsceneShots.Reorder(file, "section:2", "section:1", new HashSet<int> { 1 }));
        Assert.Equal(Three, file.Text);
    }

    [Fact]
    public void ASectionsNameIsItsQuotedSettingAndAnEmptyOneRemovesIt()
    {
        var file = Parse(Three);
        var a = file.Find("section:1")!;
        a.SetName("Big \"open\"");
        Assert.Equal("Big \"open\"", a.Name);
        a.SetName("");
        Assert.Null(a.Name);
        Assert.Null(a.Get("name"));
    }
}
