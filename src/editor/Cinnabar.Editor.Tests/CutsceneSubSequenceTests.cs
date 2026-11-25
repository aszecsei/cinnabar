using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>Sub-sequences in the cutscene editor: a child shown in context, its documents, its time and its drops (see docs/editor/cutscene-editor.md#sub-sequences).</summary>
public sealed class CutsceneSubSequenceTests : IDisposable
{
    const string Parent = "11111111111111111111111111111111";
    const string Child = "22222222222222222222222222222222";
    const string Third = "33333333333333333333333333333333";

    // The parent plays the child from 1 s to 6 s, from half a second into it, at half speed.
    const string ParentText = $"""
        cutscene 1
        length = 600000
        rate = 30

        track 1 sub_sequence "Shots"
        	section 1 60000 360000
        		asset = ${Child}
        		trim = 30000
        		scale = 0.5

        """;

    const string ChildText = """
        cutscene 1
        length = 300000
        rate = 30

        track 1 event "Events"
        	trigger 1 60000 hit

        """;

    const string ThirdText = """
        cutscene 1
        length = 120000
        rate = 30

        track 1 event "Events"
        	trigger 1 0 start

        """;

    readonly TempDirectory _temp = new("cutscene-sub-sequences");

    public void Dispose() => _temp.Dispose();

    string PathOf(string name) => _temp.Combine(name + ".cutscene");

    // A shell whose index has the three cutscenes, with the parent open in its tab.
    (EditorShell Shell, CutsceneEditor Editor, Dictionary<string, Asset> Assets) Open()
    {
        var shell = TestShell.Open(_temp, null, null);
        File.WriteAllText(PathOf("parent"), ParentText.ReplaceLineEndings("\n"));
        File.WriteAllText(PathOf("child"), ChildText.ReplaceLineEndings("\n"));
        File.WriteAllText(PathOf("third"), ThirdText.ReplaceLineEndings("\n"));
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        var assets = new Dictionary<string, Asset>
        {
            [Parent] = TestAssets.Make(Parent, AssetKind.Cutscene, "parent.cutscene"),
            [Child] = TestAssets.Make(Child, AssetKind.Cutscene, "child.cutscene"),
            [Third] = TestAssets.Make(Third, AssetKind.Cutscene, "third.cutscene"),
        };
        shell.Assets.Apply(new AssetSnapshot([.. assets.Values], []));
        return (shell, shell.OpenCutscene(assets[Parent])!, assets);
    }

    [Fact]
    public void AParentsTimeMapsThroughTheTrimAndTheScaleToTheChildAndBack()
    {
        var child = CutsceneFile.Parse(ChildText.ReplaceLineEndings("\n")).File!;
        SubSequenceMap Map(string settings)
        {
            var parent = CutsceneFile.Parse($"cutscene 1\nlength = 600000\nrate = 30\n\ntrack 1 sub_sequence \"Shots\"\n\tsection 1 60000 360000\n\t\tasset = ${Child}\n{settings}").File!;
            return SubSequenceMap.Of(parent.Find("section:1")!, child)!;
        }

        // Half speed from half a second in: 1 s of the parent is half a second of the child.
        var half = Map("\t\ttrim = 30000\n\t\tscale = 0.5\n");
        Assert.Equal((30000, 0), half.ToChild(60000));
        Assert.Equal((80000, 0), half.ToChild(160000));
        Assert.Equal(160000, half.ToParent(80000));
        // Before the section, its start; after it, its end, which holds at where the scale reached.
        Assert.Equal((30000, 0), half.ToChild(0));
        Assert.Equal((180000, 0), half.ToChild(600000));
        Assert.Equal((30000, 180000), half.Span);

        // The same speed, from the start of the child's range.
        var same = Map("");
        foreach (var t in new[] { 60000, 61000, 200000, 359999 })
        {
            var (c, loops) = same.ToChild(t);
            Assert.Equal(t - 60000, c);
            Assert.Equal(t, same.ToParent(c, loops));
        }

        // Double speed holds at the trim's end, the child's length, once it reaches it.
        var fast = Map("\t\tscale = 2\n");
        Assert.Equal((200000, 0), fast.ToChild(160000));
        Assert.Equal((300000, 0), fast.ToChild(250000));
        Assert.Equal(160000, fast.ToParent(200000));
        // The child skips odd ticks, so a tick between maps to the first parent's time past it.
        Assert.Equal(160001, fast.ToParent(200001));

        // A loop of a second wraps, and the way back keeps its pass.
        var loop = Map("\t\ttrim = 60000 120000\n\t\tloop = true\n");
        Assert.Equal((90000, 0), loop.ToChild(90000));
        Assert.Equal((90000, 2), loop.ToChild(210000));
        Assert.Equal(210000, loop.ToParent(90000, 2));
        Assert.Equal(90000, loop.ToParent(90000, 0));
        // At the section's end, a loop that ends there shows the trim's end.
        Assert.Equal((120000, 4), loop.ToChild(360000));
        Assert.Equal((60000, 120000), loop.Span);
    }

    [Fact]
    public void AnEditInContextChangesOnlyTheChildsTextWithItsUndoOnTheChildsStack()
    {
        var (shell, editor, _) = Open();
        using var _s = shell;
        var parentText = editor.Document.Text;

        editor.Select(editor.File.Find("section:1"));
        Assert.Equal("section:1", editor.SelectedSubSequence);
        Assert.True(editor.OpenSubSequence("section:1"));
        Assert.True(editor.InContext);
        Assert.Equal(Child, editor.ShownGuid);
        Assert.Equal(Parent, editor.Guid);
        Assert.Equal(["parent", "child"], editor.Breadcrumbs);
        Assert.Same(editor.Document, editor.UndoDocument);

        editor.Select(editor.File.Tracks.Single());
        editor.EditSelected("Rename", b => b.SetName("Hits"));
        var childText = ChildText.ReplaceLineEndings("\n").Replace("track 1 event \"Events\"", "track 1 event \"Hits\"");
        Assert.Equal(childText, editor.Document.Text);
        Assert.Equal(parentText, editor.RootDocument.Text);
        Assert.Empty(editor.RootDocument.History);
        Assert.Equal(["Rename"], editor.Document.History);
        // The tab is dirty while only the child is, and closing it would lose the child's edit.
        Assert.False(editor.RootDocument.IsDirty);
        Assert.True(editor.IsDirty);
        Assert.True(editor.LosesChangesOnClose);

        // Undo moves the child's stack, the one of the level shown.
        shell.Commands.Get(EditorCommands.Undo).Execute();
        Assert.Equal(ChildText.ReplaceLineEndings("\n"), editor.Document.Text);
        Assert.Equal(parentText, editor.RootDocument.Text);
        shell.Commands.Get(EditorCommands.Redo).Execute();
        Assert.Equal(childText, editor.Document.Text);

        // Save writes every level with changes, and the child's file only has its edit.
        shell.Commands.Get(EditorCommands.Save).Execute();
        Assert.Equal(childText, File.ReadAllText(PathOf("child")));
        Assert.Equal(ParentText.ReplaceLineEndings("\n"), File.ReadAllText(PathOf("parent")));
        Assert.False(editor.IsDirty);
    }

    [Fact]
    public void ThePlayheadKeepsTheParentsTimeAndTheRulerShowsIt()
    {
        var (shell, editor, _) = Open();
        using var _s = shell;
        editor.SetRootPlayhead(160000);
        editor.OpenSubSequence("section:1");

        Assert.Equal(160000, editor.RootPlayhead);
        Assert.Equal(80000, editor.Playhead);
        // A move of the playhead on the child's time maps up to the parent's.
        editor.SetPlayhead(100000);
        Assert.Equal(200000, editor.RootPlayhead);
        Assert.Equal(100000, editor.Playhead);
        // The ruler shows the parent's time, also past the section's edges, or the child's own with Local time.
        Assert.Equal(60000, editor.RulerTicks(30000));
        Assert.Equal(0, editor.RulerTicks(0));
        Assert.Equal((30000, 180000), editor.ContextSpan);
        editor.LocalTime = true;
        Assert.Equal(30000, editor.RulerTicks(30000));

        editor.LocalTime = false;
        editor.GoToLevel(0);
        Assert.Equal(200000, editor.Playhead);
        Assert.Null(editor.ContextSpan);
    }

    [Fact]
    public void BackspaceAndTheCrumbsGoUpAndDeletingTheSectionLeavesTheChild()
    {
        var (shell, editor, _) = Open();
        using var _s = shell;
        editor.Select(editor.File.Find("section:1"));
        editor.SetKeyboardPane(CutscenePane.Timeline);
        var open = editor.Handler(EditorCommands.CutsceneOpenSubSequence)!;
        Assert.True(open.CanExecute);
        open.Run();
        Assert.True(editor.InContext);
        // The child's tracks, and nothing that was selected in the parent.
        Assert.Null(editor.Selection);
        Assert.Equal("Events", editor.File.Tracks.Single().Name);

        var up = editor.Handler(EditorCommands.CutsceneUpOneLevel)!;
        Assert.True(up.CanExecute);
        up.Run();
        Assert.False(editor.InContext);
        Assert.False(editor.Handler(EditorCommands.CutsceneUpOneLevel)!.CanExecute);
        // The parent's selection is as it was.
        Assert.Equal("section:1", editor.Selection);

        // Another tab's edit, or an undo, that takes the section away shows the parent again.
        editor.OpenSubSequence("section:1");
        editor.RootDocument.Edit("Delete", f => CutsceneEdits.Delete(f, ["section:1"], ripple: false));
        Assert.False(editor.InContext);
        Assert.Same(editor.RootDocument, editor.Document);
    }

    [Fact]
    public void TheChildInItsOwnTabAndInContextIsOneDocument()
    {
        var (shell, editor, _) = Open();
        using var _s = shell;
        editor.OpenSubSequence("section:1");
        var inContext = editor.Document;

        editor.OpenInOwnTab();
        var own = Assert.Single(shell.Cutscenes, c => c != editor);
        Assert.Equal(Child, own.Guid);
        Assert.Same(inContext, own.Document);

        // An edit in one shows in the other, and its undo is on the one stack.
        own.Select(own.File.Tracks.Single());
        own.EditSelected("Rename", b => b.SetName("Hits"));
        Assert.Equal("Hits", editor.File.Tracks.Single().Name);
        Assert.True(editor.IsDirty);
        // Both tabs hold the child, so neither loses it on close.
        Assert.False(editor.LosesChangesOnClose);
        Assert.False(own.LosesChangesOnClose);

        // A lock is the cutscene's, in the settings' one copy, so a lock in one tab shows in the other and a lock in the
        // other keeps it.
        own.SetLocked(1, true);
        Assert.Contains(1, editor.Locked);
        editor.SetLocked(1, false);
        Assert.DoesNotContain(1, own.Locked);

        // Closing the child's tab keeps the document that the parent's tab shows.
        shell.CloseGraph(own, discard: true);
        Assert.DoesNotContain(own, shell.Cutscenes);
        Assert.Same(inContext, shell.CutsceneDocuments.Find(Child));
        Assert.True(editor.LosesChangesOnClose);
        // Going up keeps the child while it has changes, and Save writes it.
        editor.UpOneLevel();
        Assert.Same(inContext, shell.CutsceneDocuments.Find(Child));
        Assert.Contains(inContext, editor.Documents);
        Assert.True(shell.SaveGraph(editor));
        Assert.Contains("\"Hits\"", File.ReadAllText(PathOf("child")));
        // A saved child that no level shows is let go at the next change of level.
        editor.OpenSubSequence("section:1");
        editor.UpOneLevel();
        Assert.Null(shell.CutsceneDocuments.Find(Child));
    }

    // A child that a level change lets go is no longer observed: once the parent's tab closes, the child's own tab edits
    // without the closed editor hearing it.
    [Fact]
    public void AChildThatTheTabLetGoIsNoLongerObserved()
    {
        var (shell, editor, _) = Open();
        using var _s = shell;
        editor.OpenSubSequence("section:1");
        editor.OpenInOwnTab();
        var own = Assert.Single(shell.Cutscenes, c => c != editor);
        var heard = 0;
        editor.Changed += () => heard++;

        editor.UpOneLevel();
        Assert.DoesNotContain(own.Document, editor.Documents);
        heard = 0;
        own.Select(own.File.Tracks.Single());
        own.EditSelected("Rename", b => b.SetName("Hits"));
        Assert.Equal(0, heard);

        shell.CloseGraph(editor, discard: true);
        own.EditSelected("Rename", b => b.SetName("Beats"));
        Assert.Equal(0, heard);
        Assert.Equal("Beats", own.File.Tracks.Single().Name);
    }

    [Fact]
    public void ADroppedCutsceneIsASubSequenceAndOneThatPlaysItsParentIsRefused()
    {
        var (shell, editor, _) = Open();
        using var _s = shell;

        // A cutscene dropped on the parent plays as a sub-sequence of its range, on the Shots track past its section,
        // as one undo entry, with the child's name on its bar.
        var added = editor.DropClips([Third], null, 400000);
        var path = Assert.Single(added);
        var section = editor.File.Find(path)!;
        Assert.Equal((400000, 520000), (section.Start, section.End));
        Assert.Equal($"${Third}", section.Get("asset"));
        Assert.Equal("Shots", CutsceneEdits.TrackOf(section)!.Name);
        Assert.Single(editor.Document.History);
        var bar = editor.Layout().Rows.SelectMany(r => r.Bars).Single(b => b.Path == path);
        Assert.Equal("third", bar.Label);
        // One over the first section's span goes on a new track, since a sub-sequence track's sections do not overlap.
        var over = Assert.Single(editor.DropClips([Third], null, 100000));
        Assert.NotEqual(CutsceneEdits.TrackOf(editor.File.Find(path)!)!.Id, CutsceneEdits.TrackOf(editor.File.Find(over)!)!.Id);
        Assert.Equal(2, editor.Document.History.Count);
    }

    [Fact]
    public void ADropThatWouldPlayItsOwnParentIsRefusedWithThePath()
    {
        var (shell, editor, _) = Open();
        using var _s = shell;

        // The parent dropped into its child would play itself.
        editor.OpenSubSequence("section:1");
        Assert.Equal("sub-sequence cycle: child -> parent -> child", editor.SubSequenceRefusal(Parent));
        var before = editor.Document.Text;
        Assert.Empty(editor.DropClips([Parent], null, 0));
        Assert.Equal(before, editor.Document.Text);
        Assert.Contains(shell.Console.Lines, l => l.Text.Contains("sub-sequence cycle: child -> parent -> child"));

        // The child's unsaved text counts: once it plays the third cutscene, the third cannot play the parent, and the
        // path goes the shortest way.
        Assert.Single(editor.DropClips([Third], null, 0));
        Assert.True(editor.Document.IsDirty);
        Assert.Equal([Third, Parent, Child, Third], CutsceneSubSequences.Cycle(Third, Parent, shell.CutsceneDocuments.Read));
        var third = shell.OpenCutscene(shell.Assets.Find(Third)!)!;
        Assert.Equal("sub-sequence cycle: third -> parent -> child -> third", third.SubSequenceRefusal(Parent));
        Assert.Empty(third.DropClips([Parent], null, 0));
        // Nothing plays the parent, so it can play the third cutscene again.
        editor.GoToLevel(0);
        Assert.Null(editor.SubSequenceRefusal(Third));
    }

    [Fact]
    public void MuteAndSoloAreTheTabsOwnCutscenesInContext()
    {
        var (shell, editor, _) = Open();
        using var _s = shell;
        editor.SetMuted(1, true);
        editor.OpenSubSequence("section:1");

        Assert.Empty(editor.Muted);
        Assert.NotNull(editor.MixRefusal);
        editor.SetSoloed(1, true);
        Assert.Empty(editor.Soloed);
        // The preview still silences the parent's muted track.
        Assert.Equal([1], editor.SilentTracks());
        editor.UpOneLevel();
        Assert.Contains(1, editor.Muted);
        Assert.Empty(editor.Soloed);
    }
}
