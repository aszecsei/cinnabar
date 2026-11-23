using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tests;

/// <summary>Keys from the inspector and the viewport: which track, section and channel they go in, and the button's states.</summary>
public sealed class CutsceneKeyingTests
{
    const string Guid = "0123456789abcdef0123456789abcdef";

    // 30 fps, so a frame is 2000 ticks. The fox's transform track keys position_x over 60000 to 240000.
    const string Text = """
        cutscene 1
        length = 600000
        rate = 30

        binding 1 "Fox"
        	possess = @0123456789ABCDEF0123456789abcdef/a1
        binding 2 "Guard"
        	spawn = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        binding 3 "Crate"
        	possess = @0123456789abcdef0123456789abcdef/00000000000000b2#00000000000000c3 # in the room's instance
        track 1 transform "Path"
        	binding = 1
        	section 3 60000 240000
        		channel position_x
        			key 0 0 linear
        			key 120000 4 linear
        	section 4 60000 240000
        		blend = additive
        		channel position_y
        			key 0 1 auto
        track 2 property "Glow"
        	binding = 1
        	component = 160
        	field = "light.color"
        	section 5 300000 360000
        		channel x
        			key 0 1 auto
        track 3 audio "Line"
        	section 6 30000 90000
        		asset = $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

        """;

    static CutsceneFile Parse(string text = Text) => CutsceneFile.Parse(text.ReplaceLineEndings("\n")).File!;

    static readonly KeyTarget Position = new KeyTarget.Pose(1, PosePart.Position);
    static readonly KeyTarget Rotation = new KeyTarget.Pose(1, PosePart.Rotation);
    static readonly KeyTarget Glow = new KeyTarget.Property(1, 160, "light.color", PropertyShape.Color);
    static readonly KeyTarget Mode = new KeyTarget.Property(1, 160, "mode", PropertyShape.Stepped);

    static IReadOnlyList<string> Lines(CutsceneFile file) => file.Text.ReplaceLineEndings("\n").Split('\n');

    [Fact]
    public void ABindingThatPossessesAnEntityGoesAfterTheLastBindingWithANameOfItsOwn()
    {
        var file = Parse();
        Assert.Equal(4, CutsceneKeying.AddBinding(file, new PossessRef(Guid, 0xd4), "Fox"));
        var lines = Lines(file).ToList();
        var at = lines.IndexOf("binding 4 \"Fox 2\"");
        Assert.True(at > lines.IndexOf("binding 3 \"Crate\"") && at < lines.IndexOf("track 1 transform \"Path\""));
        Assert.Equal($"\tpossess = @{Guid}/00000000000000d4", lines[at + 1]);
        Assert.Equal(4, CutsceneKeying.BindingOf(file, new PossessRef(Guid, 0xd4)));

        // With no binding, it goes before the first track, or last.
        var bare = Parse("cutscene 1\nlength = 600000\n");
        Assert.Equal(1, CutsceneKeying.AddBinding(bare, new PossessRef(Guid, 1), "Door"));
        Assert.Equal(["cutscene 1", "length = 600000", "binding 1 \"Door\"", $"\tpossess = @{Guid}/0000000000000001", ""], Lines(bare));
    }

    [Fact]
    public void APossessReadsAnIdOrAnInstancesPathAndIgnoresCase()
    {
        var file = Parse();

        Assert.Equal(new PossessRef(Guid, 0xa1), PossessRef.Parse("@0123456789ABCDEF0123456789abcdef/a1"));
        Assert.Equal(1, CutsceneKeying.BindingOf(file, new PossessRef(Guid, 0xa1)));
        Assert.Equal(new PossessRef(Guid, ScenePath.Id([0xb2, 0xc3])), PossessRef.Parse($"@{Guid}/00000000000000b2#00000000000000c3"));
        // A # inside a word is not a comment in a cutscene, so the binding names the instance's entity by its path.
        Assert.Equal(3, CutsceneKeying.BindingOf(file, new PossessRef(Guid, ScenePath.Id([0xb2, 0xc3]))));
        Assert.Null(CutsceneKeying.BindingOf(file, new PossessRef(Guid, 0xb2)));
        Assert.Null(PossessRef.Parse("$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
        Assert.Null(PossessRef.Parse("@a1"));
    }

    [Fact]
    public void TheButtonsStatesFollowTheTrackAndTheKeysAtTheTime()
    {
        var file = Parse();

        Assert.Equal(KeyState.None, CutsceneKeying.StateOf(file, Mode, 60000, null));
        Assert.Equal(KeyState.Track, CutsceneKeying.StateOf(file, Position, 100000, null));
        Assert.Equal(KeyState.Keyed, CutsceneKeying.StateOf(file, Position, 60000, null));
        Assert.Equal(KeyState.Keyed, CutsceneKeying.StateOf(file, Position, 180000, _ => false));
        Assert.Equal(KeyState.Differs, CutsceneKeying.StateOf(file, Position, 180000, keys => keys[0] != 3.5));
        // The additive section's key is not the transform's own: the button keys the section under it.
        Assert.Equal(KeyState.Keyed, CutsceneKeying.StateOf(file, Position, 60000, keys => keys[1] != null));
        Assert.Equal(KeyState.Track, CutsceneKeying.StateOf(file, Rotation, 60000, null));
    }

    [Fact]
    public void AKeyAtAKeysTimeChangesOnlyItsValue()
    {
        var file = Parse();

        CutsceneKeying.SetKeys(file, Position, 180000, [3.25, 0, -1], "Transform");

        var lines = Lines(file);
        Assert.Contains("\t\t\tkey 120000 3.25 linear", lines);
        Assert.Contains("\t\tchannel position_z", lines);
        Assert.Contains("\t\t\tkey 120000 -1 auto", lines);
        Assert.Equal(KeyState.Keyed, CutsceneKeying.StateOf(Parse(file.Text), Position, 180000, null));
        // A new channel goes after the section's channels, with no key before its own.
        Assert.Equal(["0", "120000"], file.Find("section:3/channel:position_x")!.Children.Select(k => k.Start!.Value.ToString()));
        Assert.Equal(["position_x", "position_y", "position_z"], file.Find("section:3")!.Children.Select(c => c.Name));
    }

    [Fact]
    public void KeysGoInOrderInTheirChannel()
    {
        var file = Parse();

        CutsceneKeying.SetKeys(file, Position, 90000, [1, 0, 0], "Transform");

        Assert.Equal(["0", "30000", "120000"], file.Find("section:3/channel:position_x")!.Children.Select(k => k.Start!.Value.ToString()));
    }

    [Fact]
    public void ANewTracksKeyGetsASectionOverTheLength()
    {
        var file = Parse();

        CutsceneKeying.SetKeys(file, Mode, 90000, [2], "Mode");

        var track = CutsceneKeying.TrackOf(file, Mode)!;
        Assert.Equal(["track 4 property \"Mode\"", "\tbinding = 1", "\tcomponent = 160", "\tfield = \"mode\"", "\tsection 7 0 600000",
            "\t\tchannel value", "\t\t\tkey 90000 2 constant"], track.Descendants().SelectMany(b => b.LineTexts));
        // It goes after the binding's last track, before the audio track.
        Assert.Equal(["track:1", "track:2", "track:4", "track:3"], file.Tracks.Select(CutsceneFile.PathOf));
    }

    [Fact]
    public void ATimeOutsideTheSectionsGrowsTheNearestKeepingItsKeysTimes()
    {
        var file = Parse();

        // 250000 is 10000 past section 3's end, and 50000 before section 5's start.
        CutsceneKeying.SetKeys(file, Position, 250000, [5, 0, 0], "Transform");
        Assert.Equal((60000, 250000), (file.Find("section:3")!.Start, file.Find("section:3")!.End));
        Assert.Contains("\t\t\tkey 190000 5 auto", Lines(file));

        // Before its start, the glow's section grows back, and its key stays at 300000 on the cutscene's time.
        CutsceneKeying.SetKeys(file, Glow, 290000, [0.5, 0.25, 1], "Glow");
        var glow = file.Find("section:5")!;
        Assert.Equal((290000, 360000), (glow.Start, glow.End));
        // The section names its channels x, y and z, so the color's keys go there.
        Assert.Equal(["x", "y", "z"], glow.Children.Select(c => c.Name));
        Assert.Equal([0, 10000], glow.Children.First(c => c.Name == "x").Children.Select(k => k.Start!.Value));
    }

    [Fact]
    public void AColorKeepsTheChannelNamesThatItsSectionHas()
    {
        var file = Parse();

        CutsceneKeying.SetKeys(file, Glow, 300000, [0.5, 0.25, 1], "Glow");

        var section = file.Find("section:5")!;
        Assert.Equal(["x", "y", "z"], section.Children.Select(c => c.Name));
        Assert.Contains("\t\t\tkey 0 0.5 auto", Lines(file));
        Assert.Equal(["x", "y", "z"], CutsceneKeying.ChannelsOf(Glow, section));
    }

    [Fact]
    public void RemovingAKeyDropsAChannelLeftWithout()
    {
        var file = Parse();
        CutsceneKeying.SetKeys(file, Position, 60000, [0, 0, 0], "Transform");

        CutsceneKeying.RemoveKeys(file, Position, 60000);

        var section = file.Find("section:3")!;
        Assert.Equal(["position_x"], section.Children.Select(c => c.Name));
        Assert.Equal(KeyState.Track, CutsceneKeying.StateOf(file, Position, 60000, null));
    }

    [Fact]
    public void ALockedOrRelativeToTrackAndABadValueTakeNoKey()
    {
        var file = Parse();
        var before = file.Text;

        Assert.NotNull(CutsceneKeying.Refusal(file, Position, new HashSet<int> { 1 }));
        CutsceneKeying.SetKeys(file, Position, 60000, [1, 0, 0], "Transform", new HashSet<int> { 1 });
        Assert.Equal(before, file.Text);

        Assert.NotNull(CutsceneKeying.Refusal(Mode, [2.5]));
        Assert.NotNull(CutsceneKeying.Refusal(Mode, [1 << 25]));
        Assert.NotNull(CutsceneKeying.Refusal(Position, [double.NaN]));
        Assert.Null(CutsceneKeying.Refusal(Mode, [-3]));

        // A track relative to another binding keys; a space that names none, or its own binding, does not.
        file.Find("track:1")!.Set("space", "relative 2");
        Assert.Null(CutsceneKeying.Refusal(file, Position, null));
        Assert.Equal(2, CutsceneKeying.RelativeToOf(file, Position));
        file.Find("track:1")!.Set("space", "relative 1");
        Assert.NotNull(CutsceneKeying.Refusal(file, Position, null));
        file.Find("track:1")!.Set("space", "sideways");
        Assert.NotNull(CutsceneKeying.Refusal(file, Position, null));
        Assert.Null(CutsceneKeying.Refusal(file, Glow, null));
    }

    [Fact]
    public void AnAbsoluteTracksFirstPositionKeySetsItsOrigin()
    {
        var file = Parse(Text.Replace("track 1 transform \"Path\"\n\tbinding = 1\n\tsection 3 60000 240000\n\t\tchannel position_x\n\t\t\tkey 0 0 linear\n\t\t\tkey 120000 4 linear\n",
            "track 1 transform \"Path\"\n\tbinding = 1\n\tspace = absolute\n", StringComparison.Ordinal));
        Assert.Null(file.Find("section:3"));

        Assert.True(CutsceneKeying.NeedsOrigin(file, Position));
        Assert.Equal([0.0, 0, 0], CutsceneKeying.OriginOf(file, Position)!);
        Assert.Null(CutsceneKeying.OriginOf(file, Glow));

        CutsceneKeying.SetOrigin(file, Position, [150000000002, 1, -3]);
        CutsceneKeying.SetKeys(file, Position, 0, [0.25, 0, 0.5], "Transform");

        Assert.Equal("[150000000002, 1, -3]", file.Find("track:1")!.Get("origin"));
        Assert.Equal([150000000002.0, 1, -3], CutsceneKeying.OriginOf(file, Position)!);
        Assert.False(CutsceneKeying.NeedsOrigin(file, Position));
        Assert.Contains("			key 0 0.25 auto", Lines(file));
    }

    [Theory]
    [InlineData(0.1, "0.1")]
    [InlineData(-4, "-4")]
    [InlineData(1e-7, "0.0000001")]
    [InlineData(123456789.0, "123456790")]
    public void ANumberIsTheShortestF32WithNoExponent(double value, string text) =>
        Assert.Equal(text, CutsceneKeying.Format(value));
}
