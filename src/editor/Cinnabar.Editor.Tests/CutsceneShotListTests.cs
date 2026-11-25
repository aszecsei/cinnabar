using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>The shot list and New Shot at Playhead in the cutscene editor (see docs/editor/cutscene-editor.md#shot-list).</summary>
public sealed class CutsceneShotListTests : IDisposable
{
    const string Parent = "11111111111111111111111111111111";
    const string Child = "22222222222222222222222222222222";
    const string Shot = "33333333333333333333333333333333";
    const string Scene = "44444444444444444444444444444444";

    // Two cameras with a cut each, the child as two shots with a gap between them, and a move of the hero.
    const string ParentText = $"""
        cutscene 1
        length = 900000
        rate = 30
        binding 1 "Hero"
        	possess = @{Scene}/0000000000000001
        binding 2 "Wide"
        	possess = @{Scene}/0000000000000002
        binding 3 "Close"
        	possess = @{Scene}/0000000000000003

        track 1 camera_cut "Cuts"
        	section 1 0 300000
        		camera = 2
        	section 2 300000 600000
        		camera = 3
        track 2 transform "Move"
        	binding = 1
        	section 3 600000 700000
        track 3 event "Events"
        	trigger 4 650000 hit
        track 4 sub_sequence "Shots"
        	section 5 0 120000
        		asset = ${Child}
        		name = "Opening"
        	section 6 300000 360000
        		asset = ${Child}

        """;

    // The child cuts to its own camera at its start.
    const string ChildText = $"""
        cutscene 1
        length = 300000
        rate = 30
        binding 1 "Crane"
        	possess = @{Scene}/0000000000000009

        track 1 camera_cut "Cameras"
        	section 1 0 300000
        		camera = 1

        """;

    readonly TempDirectory _temp = new("cutscene-shot-list");

    public void Dispose() => _temp.Dispose();

    string PathOf(string name) => _temp.Combine(name + ".cutscene");

    (EditorShell Shell, CutsceneEditor Editor) Open(string childText = ChildText)
    {
        var shell = TestShell.Open(_temp, null, null);
        File.WriteAllText(PathOf("parent"), ParentText.ReplaceLineEndings("\n"));
        File.WriteAllText(PathOf("child"), childText.ReplaceLineEndings("\n"));
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        Asset[] assets = [TestAssets.Make(Parent, AssetKind.Cutscene, "parent.cutscene"), TestAssets.Make(Child, AssetKind.Cutscene, "child.cutscene")];
        shell.Assets.Apply(new AssetSnapshot([.. assets], []));
        return (shell, shell.OpenCutscene(assets[0])!);
    }

    [Fact]
    public void TheShotListHasEachShotWithItsNameSpanAndCameraAndAClickGoesToIt()
    {
        var (shell, editor) = Open();
        using var _ = shell;

        Assert.Equal(
            [new CutsceneShotRow("section:5", "Opening", 0, 120000, "Crane"), new CutsceneShotRow("section:6", "child", 300000, 60000, "Crane")],
            editor.ShotRows);
        // The bar says the section's name, or the child's file name without one.
        Assert.Equal("Opening", editor.Layout().Rows.SelectMany(r => r.Bars).Single(b => b.Path == "section:5").Label);
        Assert.Equal("child", editor.Layout().Rows.SelectMany(r => r.Bars).Single(b => b.Path == "section:6").Label);

        editor.GoToShot("section:6");
        Assert.Equal("section:6", editor.Selection);
        Assert.Equal(300000, editor.Playhead);

        // In context, the crumb is the section's name.
        Assert.True(editor.OpenSubSequence("section:5"));
        Assert.Equal(["parent", "Opening"], editor.Breadcrumbs);
    }

    [Fact]
    public void AShotWithoutACutOfItsOwnOpensOnTheParentsCamera()
    {
        var (shell, editor) = Open("cutscene 1\nlength = 300000\nrate = 30\n");
        using var _ = shell;
        Assert.Equal(["Wide", "Close"], editor.ShotRows.Select(r => r.Camera));
    }

    [Fact]
    public void ARenameAndAReorderAreEachOneUndoEntryOfTheShownLevel()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        var text = editor.Document.Text;

        editor.RenameShot("section:6", "Close-up");
        Assert.Contains("\tsection 6 300000 360000\n\t\tasset = $" + Child + "\n\t\tname = \"Close-up\"\n", editor.Document.Text);
        Assert.Equal("Close-up", editor.ShotRows[1].Name);

        // The second shot takes the first's place; the gap of 180000 stays before the second place.
        Assert.True(editor.MoveShot("section:6", "section:5"));
        Assert.Equal([("section:6", 0, 60000), ("section:5", 240000, 360000)], editor.ShotRows.Select(r => (r.Path, r.Start, r.Start + r.Length)));
        Assert.Equal(["Rename Shot", "Reorder Shots"], editor.Document.History);

        shell.Commands.Get("edit.undo").Execute();
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(text, editor.Document.Text);

        // A shot moves only on its own track.
        Assert.False(editor.MoveShot("section:6", "section:1"));
        Assert.Contains(shell.Console.Lines, l => l.Text.Contains("A shot moves only among the shots of its own track."));
    }

    [Fact]
    public void ANewShotFromThreeSelectedBlocksMovesThemIntoASavedChildInOneEntryOfEach()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        var text = editor.Document.Text;

        editor.Select(["section:2", "section:3", "trigger:4"], SelectMode.Replace);
        editor.SetKeyboardPane(CutscenePane.Timeline);
        Assert.True(editor.Handler(EditorCommands.CutsceneNewShot)!.CanExecute);
        var pending = editor.RequestNewShot()!;
        Assert.Equal("parent_shot_03", pending.FileName);
        Assert.Equal("Shot 03", pending.Name);
        Assert.Equal(new Content.ContentFolder("game", ""), pending.Folder);

        // The daemon writes the template, and the index has the asset after it answers.
        File.WriteAllText(PathOf(pending.FileName), CutsceneFileTests.Template);
        shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(Shot, AssetKind.Cutscene, "parent_shot_03.cutscene")], []));
        Assert.True(editor.FinishNewShot(pending, Shot));

        // The parent: the cut, the move and the event go, and a section plays the child over their span.
        Assert.Equal(["New Shot"], editor.Document.History);
        Assert.True(editor.Document.IsDirty);
        Assert.Equal("section:7", editor.Selection);
        var section = editor.File.Find("section:7")!;
        Assert.Equal((300000, 700000), (section.Start, section.End));
        Assert.Equal("Shot 03", section.Name);
        Assert.Equal([("bind 1", "1"), ("bind 3", "3")], section.Fields.Where(f => f.Key.StartsWith("bind ", StringComparison.Ordinal)));
        Assert.Null(editor.File.Find("section:2"));
        Assert.Null(editor.File.Find("section:3"));
        Assert.Null(editor.File.Find("trigger:4"));

        // The child is saved with them, at its own time, and its document closed with its lease.
        Assert.Null(shell.CutsceneDocuments.Find(Shot));
        var child = CutsceneFile.Parse(File.ReadAllText(PathOf(pending.FileName))).File!;
        Assert.Equal(400000, child.Length);
        Assert.Equal([1, 3], child.Bindings.Select(b => b.Id!.Value));
        Assert.Equal((0, 300000), (child.Find("section:1")!.Start, child.Find("section:1")!.End));
        Assert.Equal("3", child.Find("section:1")!.Get("camera"));
        Assert.Equal(300000, child.Tracks.Single(t => t.TrackKind == "transform").Children.Single().Start);
        Assert.Equal(350000, child.Tracks.Single(t => t.TrackKind == "event").Children.Single().Start);
        Assert.Equal(3, editor.ShotRows.Count);

        // Save writes the parent; an undo brings its text back and leaves the child's asset.
        shell.Commands.Get("file.save").Execute();
        Assert.Contains("name = \"Shot 03\"", File.ReadAllText(PathOf("parent")));
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(text, editor.Document.Text);
        Assert.True(File.Exists(PathOf(pending.FileName)));
    }

    [Fact]
    public void ANewShotWhoseCutsceneChangedWhileItsAssetWasMadeMovesNothing()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        editor.Select(["section:3"], SelectMode.Replace);
        var pending = editor.RequestNewShot()!;
        editor.RenameShot("section:5", "Changed");
        var text = editor.Document.Text;

        File.WriteAllText(PathOf(pending.FileName), CutsceneFileTests.Template);
        shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(Shot, AssetKind.Cutscene, "parent_shot_03.cutscene")], []));
        Assert.False(editor.FinishNewShot(pending, Shot));
        Assert.Equal(text, editor.Document.Text);
        Assert.Contains(shell.Console.Lines, l => l.Text.Contains("the cutscene changed while the new shot was made"));
    }

    [Fact]
    public void NewShotIsRefusedForLockedBlocksAndDuringADrag()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        editor.SetKeyboardPane(CutscenePane.Timeline);
        var command = editor.Handler(EditorCommands.CutsceneNewShot)!;
        Assert.True(command.CanExecute);
        editor.Select(["section:3"], SelectMode.Replace);
        editor.SetLocked(2, true);
        Assert.False(command.CanExecute);
        Assert.Null(editor.RequestNewShot());
        Assert.Contains(shell.Console.Lines, l => l.Text.Contains("Each selected block is on a locked track."));

        Assert.Equal("Ctrl+Alt+N", shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneNewShot));
        Assert.Equal([Commands.ShortcutScopes.CutsceneTimeline], shell.KeyBindings.ScopesOf(EditorCommands.CutsceneNewShot));
        editor.Handler(EditorCommands.CutsceneShots)!.Run();
        Assert.True(editor.ShotsOpen);
    }
}
