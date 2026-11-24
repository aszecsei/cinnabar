using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>The cutscene editor's tab, driven without a window.</summary>
public sealed class CutsceneEditorTests : IDisposable
{
    const string Guid = "0123456789abcdef0123456789abcdef";

    readonly TempDirectory _temp = new("cutscene-editor");

    public void Dispose() => _temp.Dispose();

    string FilePath => _temp.Combine("intro.cutscene");

    // A shell whose index can have a cutscene with a text, in the test's directory.
    (EditorShell Shell, Asset Asset) Shell(string text)
    {
        var shell = TestShell.Open(_temp, null, null);
        File.WriteAllText(FilePath, text);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        return (shell, TestAssets.Make(Guid, AssetKind.Cutscene, "intro.cutscene"));
    }

    (EditorShell Shell, CutsceneEditor Editor, string Text) Intro()
    {
        var text = CutsceneFileTests.Sample("intro").ReplaceLineEndings("\n");
        var (shell, asset) = Shell(text);
        shell.Assets.Apply(new AssetSnapshot([asset], []));
        return (shell, shell.OpenCutscene(asset)!, text);
    }

    [Fact]
    public void ANewCutsceneOpensInItsTabAndUndoAndRedoGiveItsExactText()
    {
        // The daemon writes the template's text, and the index has the asset after it answers.
        var template = CutsceneFileTests.Template;
        var (shell, asset) = Shell(template);
        using var _ = shell;
        shell.Assets.Apply(new AssetSnapshot([], []));
        shell.OnAssetCreated(Guid, AssetTemplate.Cutscene);
        Assert.Empty(shell.Cutscenes);
        shell.Assets.Apply(new AssetSnapshot([asset], []));
        var editor = Assert.Single(shell.Cutscenes);
        Assert.Same(editor, shell.ActiveGraphEditor);
        Assert.Same(editor, shell.ActiveCutscene);
        Assert.Contains(editor, shell.GraphEditors);
        Assert.Equal("Open in Cutscene Editor", shell.OpenLabel(asset));
        Assert.Equal($"cutscene.{Guid}", Assert.IsType<GraphEditorDocument>(FindDocument(shell, editor)).Id);
        Assert.False(editor.Document.IsDirty);
        Assert.Equal(template, editor.Document.Text);
        // Opening it again shows the same editor.
        Assert.Same(editor, shell.OpenCutscene(asset));

        // Renaming the camera cut track changes its one line.
        editor.Select(editor.File.Tracks.Single());
        editor.EditSelected("Rename", b => b.SetName("Shots"));
        var renamed = template.Replace("track 1 camera_cut \"Cameras\"", "track 1 camera_cut \"Shots\"");
        Assert.Equal(renamed, editor.Document.Text);
        Assert.True(editor.Document.IsDirty);
        // A header setting goes with the header's, above the track.
        editor.Select(editor.File.Root);
        editor.EditSelected("Set rate", b => b.Set("rate", "24"));
        var rated = renamed.Replace("rate = 30\n", "rate = 24\n");
        Assert.Equal(rated, editor.Document.Text);
        Assert.Equal(["Rename", "Set rate"], editor.Document.History);

        // Undo, Redo and Save act on the active cutscene, and the selection stays across them.
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(renamed, editor.Document.Text);
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(template, editor.Document.Text);
        Assert.False(editor.Document.IsDirty);
        Assert.Same(editor.File.Root, editor.Selected);
        shell.Commands.Get("edit.redo").Execute();
        Assert.Equal(renamed, editor.Document.Text);
        shell.Commands.Get("edit.redo").Execute();
        Assert.Equal(rated, editor.Document.Text);
        shell.Commands.Get("file.save").Execute();
        Assert.False(editor.Document.IsDirty);
        Assert.Equal(rated, File.ReadAllText(FilePath));

        shell.CloseGraph(editor, discard: true);
        Assert.Empty(shell.Cutscenes);
        Assert.Null(shell.ActiveGraphEditor);
    }

    static EditorDocument? FindDocument(EditorShell shell, IGraphEditor editor) => shell.Layout.FindDocument(editor);

    [Fact]
    public void ACancelledDragLeavesTheTextAndTheUndoStackAsTheyWere()
    {
        var (shell, editor, text) = Intro();
        using var _ = shell;
        var save = shell.Commands.Get(EditorCommands.Save);
        editor.Select(editor.File.Find("section:6"));

        Assert.True(editor.BeginField("Move End"));
        Assert.False(editor.BeginField("Move End"), "one drag at a time");
        Assert.False(save.CanExecute);
        editor.StepField(b => b.SetSpan(200000, 410000));
        editor.StepField(b => b.SetSpan(200000, 420000));
        // The drag previews in the document as it goes.
        Assert.Contains("section 6 200000 420000", editor.Document.Text);
        editor.EndField(cancel: true);
        Assert.Equal(text, editor.Document.Text);
        Assert.Empty(editor.Document.History);
        Assert.Equal(0, editor.Document.Position);
        Assert.False(editor.Document.IsDirty);
        Assert.True(save.CanExecute);

        // A drag that ends is one entry, however many steps it took.
        editor.BeginField("Move End");
        editor.StepField(b => b.SetSpan(200000, 410000));
        editor.StepField(b => b.SetSpan(200000, 420000));
        editor.EndField(cancel: false);
        Assert.Equal(["Move End"], editor.Document.History);
        Assert.Equal(text.Replace("section 6 200000 400000", "section 6 200000 420000"), editor.Document.Text);
        editor.Document.Undo();
        Assert.Equal(text, editor.Document.Text);
    }

    [Fact]
    public void TheCheckersProblemsGoOnTheirBlocksAndAStaleAnswerWaits()
    {
        var (shell, editor, text) = Intro();
        using var _ = shell;
        var path = editor.Document.Path.Replace('\\', '/');
        var lines = text.Split('\n').ToList();
        var close = lines.IndexOf("\tsection 6 200000 400000") + 1;
        var key = lines.IndexOf("\t\t\tkey 120000 1.5 auto") + 1;
        static PreviewResult Answer(string file, params (uint Line, string Text)[] problems) =>
            new(problems.Length == 0 ? "" : problems[0].Text, [.. problems.Select(p => new Problem(file, p.Line, 0, true, p.Text))], []);

        editor.Checks.Show(editor.Document.Text, Answer(path, ((uint)close + 1, "the camera is not a binding"), ((uint)key, "keys are in order of time")));
        Assert.Equal(new CheckState.Failed("the camera is not a binding"), editor.Checks.State);
        var section = editor.File.Find("section:6")!;
        Assert.Equal("the camera is not a binding", Assert.Single(editor.ProblemsOf(section)).Text);
        // A key's problem is on the key, whose section's row shows it.
        var keyBlock = editor.File.Find("section:8/channel:value/key:1")!;
        Assert.Same(keyBlock, editor.BlockAt(key));
        Assert.Single(editor.ProblemsOf(keyBlock));

        // A problem in another file says where, and has no line here.
        editor.Checks.Show(editor.Document.Text, Answer("C:/elsewhere/shot.cutscene", (9, "broken")));
        Assert.Equal("shot.cutscene:9: broken", Assert.Single(editor.Problems).Text);
        Assert.Equal(0, editor.Problems[0].Line);

        // An answer about a text that has changed since names the wrong lines, so it waits for the next.
        var old = editor.Document.Text;
        editor.Select(section);
        editor.EditSelected("Set look_at_damping", b => b.Set("look_at_damping", "6000"));
        editor.Checks.Show(old, Answer(path, (3, "stale")));
        Assert.DoesNotContain(editor.Problems, p => p.Text.Contains("stale"));

        // The next answer clears them.
        editor.Checks.Show(editor.Document.Text, Answer(path));
        Assert.Empty(editor.Problems);
        Assert.IsType<CheckState.Clean>(editor.Checks.State);
    }

    [Fact]
    public async Task EachCommittedEditGoesToTheDaemonAndADragOnlyWhenItEnds()
    {
        var (shell, asset) = Shell(CutsceneFileTests.Template);
        using var _ = shell;
        var cooker = new PreviewCookTests.FakePreviewCooker();
        shell.PreviewCooker = cooker;
        shell.Assets.Apply(new AssetSnapshot([asset], []));
        var editor = shell.OpenCutscene(asset)!;
        var opened = Assert.Single(cooker.Requests);
        Assert.Equal((Guid, CutsceneFileTests.Template), (opened.Guid, opened.Text));
        opened.Answer(new PreviewResult("", [], []));

        // A drag's steps are not sent, however long it takes.
        editor.Select(editor.File.Root);
        editor.BeginField("Set Length");
        editor.StepField(b => b.Set("length", "300000"));
        await Task.Delay(PreviewCook.Delay * 3, TestContext.Current.CancellationToken);
        Assert.Single(cooker.Requests);
        // Its end is an edit, which goes once the edits stop.
        editor.EndField(cancel: false);
        await Until(() => cooker.Requests.Count == 2);
        Assert.Contains("length = 300000", cooker.Requests[1].Text);
    }

    static async Task Until(Func<bool> done)
    {
        for (var waited = 0; !done(); waited += 20)
        {
            Assert.True(waited < 5000, "timed out");
            await Task.Delay(20, TestContext.Current.CancellationToken);
        }
    }

    [Fact]
    public void AKeyIsSelectedByItsPathAndABlockThatSharesItsPathIsNot()
    {
        var (shell, editor, text) = Intro();
        using var _ = shell;
        var key = editor.File.Find("section:9/channel:gain/key:2")!;
        editor.Select(key);
        Assert.Equal("section:9/channel:gain/key:2", editor.Selection);
        editor.EditSelected("Set Key Value", b => b.SetKeyValue("0.9"));
        Assert.Equal(text.Replace("key 400000 0.8 auto", "key 400000 0.9 auto"), editor.Document.Text);

        shell.CloseGraph(editor, discard: true);

        // Two sections with one ID, which the cooker reports: neither can be selected, so no edit lands on the other.
        File.WriteAllText(FilePath, text.Replace("section 13 30000 174000", "section 12 30000 174000"));
        var clash = shell.OpenCutscene(shell.Assets.Find(Guid)!)!;
        var sections = clash.File.Blocks.Where(b => b.Kind == CutsceneBlockKind.Section && b.Id == 12).ToList();
        Assert.Equal(2, sections.Count);
        Assert.Null(clash.File.Find("section:12"));
        clash.Select(sections[1]);
        Assert.Null(clash.Selection);
        clash.EditSelected("Set kind", b => b.Set("kind", "fade"));
        Assert.False(clash.Document.IsDirty);
    }

    [Fact]
    public void ClosingADirtyTabAsksAndTheShellDropsTheEditorOnceItCloses()
    {
        var (shell, editor, text) = Intro();
        using var _ = shell;
        IGraphEditor? asked = null;
        shell.GraphCloseRequested += e => asked = e;
        editor.Select(editor.File.Find("binding:2"));
        editor.EditSelected("Rename", b => b.SetName("Gate Guard"));

        shell.Layout.CloseDocument(editor);
        Assert.Same(editor, asked);
        Assert.Contains(editor, shell.Cutscenes);
        Assert.NotNull(FindDocument(shell, editor));

        // Save closes it with its edit; the window's Save does this.
        shell.CloseGraph(editor, discard: false);
        Assert.Empty(shell.Cutscenes);
        Assert.DoesNotContain(editor, shell.GraphEditors);
        Assert.Null(FindDocument(shell, editor));
        Assert.Equal(text.Replace("binding 2 \"Extra Guard\"", "binding 2 \"Gate Guard\""), File.ReadAllText(FilePath));
    }

    [Fact]
    public void ASaveAsksBeforeReplacingAnotherProgramsChangesAndAnOpenCutsceneFollowsItsFile()
    {
        var (shell, editor, _) = Intro();
        using var __ = shell;
        IGraphEditor? asked = null;
        shell.GraphOverwriteRequested += e => asked = e;
        editor.Select(editor.File.Root);
        editor.EditSelected("Set rate", b => b.Set("rate", "24"));
        File.AppendAllText(FilePath, "# Someone's note.\n");
        Assert.False(shell.SaveGraph(editor));
        Assert.Same(editor, asked);
        Assert.Contains("Someone's note", File.ReadAllText(FilePath));
        Assert.True(shell.SaveGraph(editor, overwrite: true));
        Assert.DoesNotContain("Someone's note", File.ReadAllText(FilePath));

        var asset = shell.Assets.Find(Guid)!;
        File.Move(FilePath, _temp.Combine("opening.cutscene"));
        shell.Assets.Apply(new AssetDelta([asset with { Path = "opening.cutscene" }], [], [], []));
        Assert.Equal("opening.cutscene", editor.Document.Title);
    }

    [Fact]
    public void TheCinematicsWorkspaceOpensCutscenesUnderTheViewsAndKeepsThemAcrossASwitch()
    {
        var (shell, editor, _) = Intro();
        using var _ = shell;
        var cinematics = shell.Workspaces.Find("cinematics")!;
        // The scene view is in front when the switch comes, and after it the tab that the switch shows is the active editor.
        shell.Layout.ShowViewport(ViewportDocument.SceneId);
        Assert.Null(shell.ActiveGraphEditor);
        Assert.True(shell.Workspaces.Switch(cinematics));
        Assert.Same(editor, shell.ActiveGraphEditor);
        // The tab that was open moves to the editors' dock, apart from the viewports.
        var document = FindDocument(shell, editor)!;
        Assert.Equal(EditorLayout.EditorDocumentsDock, document.Owner?.Id);
        Assert.True(shell.Layout.IsOpen(ViewportDocument.SceneId));
        Assert.True(shell.Layout.IsOpen(ViewportDocument.GameId));

        shell.Workspaces.Switch(shell.Workspaces.Find("general")!);
        Assert.NotNull(FindDocument(shell, editor));
    }

    [Fact]
    public void AScrubOfThePlayheadRefreshesTheCommandsOncePerTurnAndAClosedTabNoMore()
    {
        var (shell, editor, _) = Intro();
        using var _ = shell;
        var save = shell.Commands.Get(EditorCommands.Save);
        shell.Commands.Flush();
        var changes = 0;
        save.Changed += () => changes++;

        for (var frame = 1; frame <= 30; frame++)
        {
            editor.SetPlayhead(frame * editor.FrameTicks);
        }
        Assert.Equal(30 * editor.FrameTicks, editor.Playhead);
        Assert.Equal(0, changes);
        shell.Commands.Flush();
        Assert.Equal(1, changes);

        // The tab that closed is no longer observed: its playhead asks for nothing.
        shell.CloseGraph(editor, discard: true);
        shell.Commands.Flush();
        changes = 0;
        editor.SetPlayheadFromGame(0);
        shell.Commands.Flush();
        Assert.Equal(0, changes);
    }
}
