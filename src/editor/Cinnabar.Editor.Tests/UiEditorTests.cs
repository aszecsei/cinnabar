using System.Text;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>The UI editor without a window: opening, edits through the shell, problems on elements, and the canvas's layout.</summary>
public sealed class UiEditorTests : IDisposable
{
    const string Guid = "5b845a4341f6a3b772ec017211470fac";

    readonly TempDirectory _temp = new("ui-editor");

    public void Dispose() => _temp.Dispose();

    static string Pause() => File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "ui", "pause.ui"));

    // A shell whose index has the sample's pause menu, in the test's directory.
    (EditorShell Shell, Asset Asset, string Text) Menu()
    {
        Directory.CreateDirectory(_temp.Path);
        var text = Pause();
        var shell = TestShell.Open(_temp, null, null);
        File.WriteAllText(_temp.Combine("pause.ui"), text);
        var asset = TestAssets.Make(Guid, AssetKind.Ui, "pause.ui");
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [],
        [
            new UiAttributeInfo("fill", "paint", ["box", "row", "column", "stack", "text", "image", "button", "field"], false, 0, 0),
            new UiAttributeInfo("size", "number", ["ui", "box", "row", "column", "stack", "text", "image", "button", "field"], true, 1, 1000),
            new UiAttributeInfo("color", "color", ["ui", "box", "row", "column", "stack", "text", "image", "button", "field"], true, 0, 0),
        ]));
        shell.Assets.Apply(new AssetSnapshot([asset], []));
        return (shell, asset, text);
    }

    static PreviewResult Answer(string file, params (uint Line, uint Column, string Text)[] problems) =>
        new(problems.Length == 0 ? "" : problems[0].Text, [.. problems.Select(p => new Problem(file, p.Line, p.Column, true, p.Text))]);

    static UiPreviewLayout Layout(UiEditor editor, params (int Node, float X0, float Y0, float X1, float Y1)[] nodes) =>
        new(0, Fnv.Hash64(Encoding.UTF8.GetBytes(editor.Document.Text)), 1, 1920, 1080,
            [.. nodes.Select(n => new UiLayoutNode((uint)n.Node, true, [n.X0, n.Y0, n.X1, n.Y1], [n.X0 + 1, n.Y0 + 1, n.X1 - 1, n.Y1 - 1], [0, 0, 1920, 1080]))]);

    [Fact]
    public void TheSamplesMenuOpensInItsEditorAndAnEditChangesOnlyItsLine()
    {
        var (shell, asset, text) = Menu();
        using var _ = shell;
        Assert.True(EditorShell.CanOpen(asset));
        Assert.Equal("Open in UI Editor", shell.OpenLabel(asset));
        shell.OpenAsset(asset);
        var editor = Assert.Single(shell.UiDocuments);
        Assert.Same(editor, shell.ActiveGraphEditor);
        Assert.Same(editor, shell.ActiveUiDocument);
        Assert.Contains(editor, shell.GraphEditors);
        Assert.False(editor.Document.IsDirty);
        Assert.Same(editor, shell.OpenUiDocument(asset));

        var resume = editor.File.NodeById("resume")!.Index;
        editor.Select(resume);
        editor.SetAttribute(resume, "fill", "#ff0000");
        var expected = text.Replace("<button id=\"resume\" click=\"resume\">", "<button id=\"resume\" click=\"resume\" fill=\"#ff0000\">");
        Assert.Equal(expected, editor.Document.Text);
        Assert.Equal(new UiValue("#ff0000", UiSource.Own, ""), editor.Values(resume)["fill"]);

        // Undo, Redo and Save act on the active document.
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(text, editor.Document.Text);
        shell.Commands.Get("edit.redo").Execute();
        shell.Commands.Get("file.save").Execute();
        Assert.False(editor.Document.IsDirty);
        Assert.Equal(expected, File.ReadAllText(_temp.Combine("pause.ui")));

        shell.CloseGraph(editor, discard: true);
        Assert.Empty(shell.UiDocuments);
        Assert.Null(shell.ActiveGraphEditor);
    }

    [Fact]
    public void TheTreesEditsKeepTheirElementSelected()
    {
        var (shell, asset, text) = Menu();
        using var _ = shell;
        var editor = shell.OpenUiDocument(asset)!;
        var file = () => editor.File;
        var menu = file().NodeById("menu")!.Index;
        var row = file().Nodes.First(n => n.Kind == "row").Index;
        // The name row goes before Resume, as one entry, and stays selected.
        editor.Move(row, menu, editor.IndexOf(file().NodeById("resume")!.Index));
        Assert.Equal("row", editor.Selected!.Kind);
        Assert.True(editor.Selected.Index < file().NodeById("resume")!.Index);
        Assert.Equal(1, editor.Document.Position);
        // A node cannot go into itself, nor into a text.
        Assert.False(editor.CanMove(menu, editor.Selected.Index));
        Assert.False(editor.CanMove(row, file().NodeById("resume")!.Index + 1));

        editor.Add("<box/>", menu);
        Assert.Equal("box", editor.Selected!.Kind);
        Assert.Equal(menu, editor.Selected.Parent);
        editor.Duplicate(file().NodeById("quality")!.Index);
        Assert.Equal("quality_2", editor.Selected!.Id);
        editor.Delete(editor.Selected.Index);
        Assert.Equal(menu, editor.SelectedNode);
        Assert.False(editor.SetId(menu, "resume"));
        Assert.False(editor.SetId(menu, "Bad Id"));
        Assert.True(editor.SetId(menu, "pause"));

        // A style and a variant, which the properties then show.
        Assert.True(editor.AddStyle("button:disabled"));
        Assert.Equal("button:disabled", editor.SelectedStyle);
        Assert.False(editor.AddStyle("button:disabled"));
        Assert.False(editor.AddStyle("button:active"));
        editor.SetStyleAttribute("button:disabled", "opacity", "0.5");
        Assert.Contains("<style name=\"button:disabled\" opacity=\"0.5\"/>", editor.Document.Text);
        Assert.Equal(["resume", "quality"], editor.TakersOf("button:disabled").Select(n => n.Id));
        while (editor.Document.CanUndo)
        {
            editor.Document.Undo();
        }
        Assert.Equal(text, editor.Document.Text);
    }

    [Fact]
    public void AStateThatTheCanvasShowsPicksItsVariant()
    {
        var (shell, asset, _) = Menu();
        using var __ = shell;
        var editor = shell.OpenUiDocument(asset)!;
        var resume = editor.File.NodeById("resume")!.Index;
        editor.Select(resume);
        editor.SetState("hover", true);
        Assert.Equal("button:hover", editor.Values(resume)["fill"].From);
        Assert.Equal("button", editor.Values(editor.File.NodeById("quality")!.Index)["fill"].From);
        editor.SetState("hover", false);
        Assert.Equal("button", editor.Values(resume)["fill"].From);
        // The bindings are the text's, and their values are the preview's only.
        Assert.Equal(["name", "quality"], editor.BindingNames);
        editor.SetBinding("name", "Ada");
        Assert.Equal("Ada", editor.BindingValues["name"]);
        Assert.False(editor.Document.IsDirty);
    }

    [Fact]
    public void AProblemGoesOnTheElementAtItsLineAndColumn()
    {
        var (shell, asset, _) = Menu();
        using var __ = shell;
        var editor = shell.OpenUiDocument(asset)!;
        var path = _temp.Combine("pause.ui");
        var lines = editor.Document.Text.ReplaceLineEndings("\n").Split('\n');
        var fieldLine = Array.FindIndex(lines, l => l.Contains("<field")) + 1;
        var fieldColumn = lines[fieldLine - 1].IndexOf("width", StringComparison.Ordinal) + 1;
        var styleLine = Array.FindIndex(lines, l => l.Contains("name=\"caption\"")) + 1;
        editor.ShowProblems(editor.Document.Text, Answer(path, ((uint)fieldLine, (uint)fieldColumn, "width is wrong"), ((uint)styleLine, 2, "a style's problem"), (1, 1, "the header")));
        Assert.Equal(editor.File.NodeById("name")!.Index, editor.Problems[0].Node);
        Assert.Equal((fieldLine, fieldColumn), (editor.Problems[0].Line, editor.Problems[0].Column));
        Assert.Equal("caption", editor.Problems[1].Style);
        Assert.Null(editor.Problems[1].Node);
        Assert.Null(editor.Problems[2].Node);
        Assert.Equal("width is wrong", editor.CookError);

        // An answer about a text that has changed since is dropped.
        var old = editor.Document.Text;
        editor.SetAttribute(0, "size", "21");
        editor.ShowProblems(old, Answer(path));
        Assert.Equal("width is wrong", editor.CookError);
        editor.ShowProblems(editor.Document.Text, Answer(path));
        Assert.Null(editor.CookError);
        Assert.Empty(editor.Problems);
    }

    [Fact]
    public void TheCanvasPicksAndOutlinesByALayoutOfTheTextAsItIs()
    {
        var (shell, asset, _) = Menu();
        using var __ = shell;
        var editor = shell.OpenUiDocument(asset)!;
        var menu = editor.File.NodeById("menu")!.Index;
        var resume = editor.File.NodeById("resume")!.Index;
        shell.OnGameMessage(Layout(editor, (0, 0, 0, 1920, 1080), (menu, 770, 300, 1150, 780), (resume, 794, 400, 1126, 440), (resume + 1, 810, 410, 870, 430)));
        Assert.True(editor.LayoutCurrent);
        // The topmost that holds the point: a button's text over the button, the button over the menu.
        Assert.Equal(resume + 1, editor.Pick(820, 420));
        Assert.Equal(resume, editor.Pick(1000, 420));
        Assert.Equal(menu, editor.Pick(800, 600));
        Assert.Null(editor.Pick(10, 10));
        Assert.Equal(new UiRect(794, 400, 1126, 440), editor.BoxOf(resume)!.Value.Rect);

        // An edit makes the layout one of another text, until the game draws the new one.
        editor.SetAttribute(menu, "gap", "12");
        Assert.False(editor.LayoutCurrent);
        Assert.Null(editor.Pick(1000, 420));
        Assert.Null(editor.BoxOf(resume));
    }

    [Fact]
    public void TheViewFitsTheScreenUntilItIsZoomedOrPanned()
    {
        var (shell, asset, _) = Menu();
        using var __ = shell;
        var editor = shell.OpenUiDocument(asset)!;
        editor.SetScreen(3840, 2160);
        Assert.Equal(2, editor.Scale);
        editor.SetScaleFactor(10);
        Assert.Equal(8, editor.Scale);
        editor.SetScaleFactor(1);
        editor.Fit();
        // The default preview is 256 pixels square: the screen's width fits it.
        Assert.Equal(256.0 / 3840, editor.ViewScale, 6);
        var (x, y) = editor.ToScreen(128, 128);
        Assert.Equal((1920, 1080), (Math.Round(x), Math.Round(y)));
        editor.ZoomView(1, 128, 128);
        Assert.False(editor.Fitted);
        Assert.Equal((1920, 1080), (Math.Round(editor.ToScreen(128, 128).X), Math.Round(editor.ToScreen(128, 128).Y)));
        editor.Pan(10, 0);
        Assert.Equal(1910, Math.Round(editor.ToScreen(128, 128).X));
        Assert.Equal(1, UiEditor.ProjectScale(_temp.Combine("none.settings")));
        File.WriteAllText(_temp.Combine("project.settings"), "ui.scale = 1.5\n");
        Assert.Equal(1.5, UiEditor.ProjectScale(_temp.Combine("project.settings")));
        File.WriteAllText(_temp.Combine("project.settings"), "ui.scale = 9\n");
        Assert.Equal(1, UiEditor.ProjectScale(_temp.Combine("project.settings")));
    }

    [Fact]
    public void ANewUiDocumentOpensInItsEditorOnceTheIndexHasIt()
    {
        var (shell, asset, _) = Menu();
        using var __ = shell;
        shell.Assets.Apply(new AssetSnapshot([], []));
        shell.OnAssetCreated(Guid, AssetTemplate.Ui);
        Assert.Empty(shell.UiDocuments);
        shell.Assets.Apply(new AssetSnapshot([asset], []));
        Assert.Single(shell.UiDocuments);
    }

    [Fact]
    public void PickingTakesTheLastShownBoxThatHoldsThePointInItsClip()
    {
        UiBox Box(int node, UiRect rect, UiRect? clip = null, bool shown = true) => new(node, shown, rect, rect, clip ?? new UiRect(0, 0, 100, 100));
        var boxes = new[]
        {
            Box(0, new UiRect(0, 0, 100, 100)),
            Box(1, new UiRect(10, 10, 60, 60)),
            Box(2, new UiRect(20, 20, 90, 90), clip: new UiRect(10, 10, 60, 60)),
            Box(3, new UiRect(30, 30, 40, 40), shown: false),
        };
        Assert.Equal(2, UiCanvasGeometry.Pick(boxes, 35, 35));
        Assert.Equal(1, UiCanvasGeometry.Pick(boxes, 70 - 15, 15));
        // Outside its clip, the node under it is picked; the root never is.
        Assert.Null(UiCanvasGeometry.Pick(boxes, 80, 80));
        Assert.Null(UiCanvasGeometry.Pick(boxes, 5, 5));
    }
}
