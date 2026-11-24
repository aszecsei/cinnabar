using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.LogicalTree;
using Cinnabar.Editor.AnimationGraphs;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>A details panel builds its rows once, however its rebuilds nest (see docs/editor/shell-and-panels.md#details-panels).</summary>
public sealed class DetailsPanelTests : IDisposable
{
    const string Guid = "0123456789abcdef0123456789abcdef";

    const string Graph = """
        animation_graph 1
        entry = idle

        param speed float 0

        node 1 state
        	position = [0, 0]
        	name = idle

        """;

    readonly TempDirectory _temp = new("details-panel");

    public void Dispose() => _temp.Dispose();

    static TextBox BoxOf(Panel rows, string name) =>
        rows.Children.OfType<Grid>().First(r => r.Children.OfType<TextBlock>().Any(t => t.Text == name)).GetLogicalDescendants().OfType<TextBox>().Single();

    [Fact]
    public void ABoxThatCommitsAsAProblemsRebuildClearsItLeavesTheRowsBuiltOnce() => Ui.Run(() =>
    {
        using var shell = TestShell.Open(_temp, null, null);
        var path = _temp.Combine("fox.animation_graph");
        File.WriteAllText(path, Graph.ReplaceLineEndings("\n"));
        var editor = new AnimationGraphEditor(shell, AnimationGraphDocument.Open(path, Guid).Document!);
        var panel = new AnimationNodeDetails(editor);
        panel.Subscriptions.Attach();
        editor.Select([1]);
        var rows = (Panel)panel.Content!;
        var speed = BoxOf(rows, "Speed");

        // The user types a speed, and has not left the box yet.
        speed.RaiseEvent(new FocusChangedEventArgs(InputElement.GotFocusEvent));
        speed.Text = "2";
        // A window's focus manager takes the focus from a box that leaves the tree, which commits its text.
        var row = speed.FindLogicalAncestorOfType<Grid>()!;
        var blurred = false;
        rows.Children.CollectionChanged += (_, _) =>
        {
            if (!blurred && !rows.Children.Contains(row))
            {
                blurred = true;
                speed.RaiseEvent(new FocusChangedEventArgs(InputElement.LostFocusEvent));
            }
        };
        // The daemon's check of the text names a problem on the node, which builds the rows again.
        var line = (uint)Graph.ReplaceLineEndings("\n").Split('\n').ToList().IndexOf("node 1 state") + 1;
        editor.Checks.Show(editor.Document.Text, new PreviewResult("no motion", [new Problem(path.Replace('\\', '/'), line, 0, true, "the state idle has no motion")], []));

        Assert.True(blurred);
        Assert.Equal("2", editor.Document.Graph.Find(1)!.Get("speed"));
        // One row of each, with the speed that the box committed.
        Assert.Single(rows.Children.OfType<Grid>(), r => r.Children.OfType<TextBlock>().Any(t => t.Text == "Speed"));
        Assert.Single(rows.Children.OfType<TextBlock>(), t => t.Text == "Problems");
        Assert.Equal("2", BoxOf(rows, "Speed").Text);
    });
}
