using System.Text.RegularExpressions;
using Avalonia.Controls;
using Cinnabar.Editor.Decisions;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>The decision details' table of fields, against docs/content/kinds/decisions.md, and the rows that it builds.</summary>
public sealed partial class DecisionFieldsTests : IDisposable
{
    const string Guid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa9";

    readonly TempDirectory _temp = new("decision-fields");

    public void Dispose() => _temp.Dispose();

    // The doc's tables of fields: the section and the table's heading, and the technique and kind that it is of. A null
    // kind is a table of kinds, with each kind's fields in its second column. GOAP's consideration takes utility's
    // fields, which the doc says in prose.
    static readonly (string Section, string Table, string Technique, string? Kind)[] Tables =
    [
        ("Behavior trees", "Nodes", "behavior_tree", null),
        ("Utility", "Options", "utility", "option"),
        ("Utility", "Considerations", "utility", "consideration"),
        ("Utility", "Considerations", "goap", "consideration"),
        ("GOAP", "Goals", "goap", "goal"),
        ("GOAP", "Actions", "goap", "action"),
        ("HTN", "Tasks, methods and actions", "htn", null),
    ];

    [GeneratedRegex("`([a-z_]+)[^`]*`")]
    private static partial Regex Names();

    // The first table under a "## section" and its "### table", as its rows' cells.
    static List<string[]> TableOf(string[] doc, string section, string table)
    {
        var at = Array.IndexOf(doc, "## " + section);
        at = Array.IndexOf(doc, "### " + table, at);
        Assert.True(at > 0, $"decisions.md has no {section}: {table}");
        return [.. doc.Skip(at + 1).SkipWhile(l => !l.StartsWith('|')).TakeWhile(l => l.StartsWith('|')).Skip(2)
            .Select(l => l.Trim('|').Split('|').Select(c => c.Trim()).ToArray())];
    }

    // The fields that a cell names: each name in backquotes, as `set <key> = <value>` names set.
    static IEnumerable<string> NamesIn(string cell) => Names().Matches(cell).Select(m => m.Groups[1].Value);

    static string[] Doc() =>
        File.ReadAllLines(Path.Combine(EditorOptions.RepositoryRoot(), "docs", "content", "kinds", "decisions.md"));

    [Fact]
    public void TheTableHasTheFieldsOfEachKindThatTheDocLists()
    {
        var doc = Doc();
        var listed = new Dictionary<(string, string), HashSet<string>>();
        foreach (var (section, table, technique, kind) in Tables)
        {
            foreach (var cells in TableOf(doc, section, table))
            {
                if (kind == null)
                {
                    listed[(technique, NamesIn(cells[0]).Single())] = [.. NamesIn(cells[1])];
                }
                else
                {
                    listed.TryAdd((technique, kind), []);
                    listed[(technique, kind)].UnionWith(NamesIn(cells[0]));
                }
            }
        }
        Assert.Equal(listed.Keys.Order(), DecisionFields.Known.Order());
        foreach (var ((technique, kind), fields) in listed)
        {
            Assert.True(fields.SetEquals(DecisionFields.Of(technique, kind)!.Select(f => f.Key)), $"{technique} {kind}");
        }
        var decorators = TableOf(doc, "Behavior trees", "Decorators").SelectMany(c => NamesIn(c[0]));
        Assert.Equal(decorators.Order(), DecisionFields.DecoratorsOf("behavior_tree").Select(f => f.Key).Order());
        Assert.Empty(DecisionFields.DecoratorsOf("utility"));
    }

    static IEnumerable<string> Labels(Panel rows) =>
        rows.Children.Select(r => r switch
        {
            Grid g => g.Children.OfType<TextBlock>().First().Text!,
            TextBlock t => t.Text!,
            _ => "",
        });

    [Fact]
    public void ATreeNodeShowsItsKindsFieldsThenWhatItsKindDoesNotTakeThenItsDecorators() => Ui.Run(() =>
    {
        using var shell = TestShell.Open(_temp, null, null);
        var path = _temp.Combine("guard.decision");
        File.WriteAllText(path, """
            decision 1
            technique = behavior_tree

            node 1 wait
            	seconds = 2
            	speed = 3
            	= 4
            	when = tired
            	abort = self

            """.ReplaceLineEndings("\n"));
        var editor = new DecisionEditor(shell, DecisionDocument.Open(path, Guid).Document!);
        var panel = new DecisionNodeDetails(shell, editor);
        panel.Subscriptions.Attach();
        editor.Select([1]);
        var rows = (Panel)panel.Content!;
        Assert.Equal(["Wait", "node 1 · wait", "Seconds", "Speed", "", "Decorators", "When", "Abort", "Cooldown", "Time limit", "Repeat", "Invert", "Force"], Labels(rows));

        // A choice shows its fallback when the file does not write it, and picking the fallback removes the field.
        var abort = rows.Children.OfType<Grid>().Single(g => g.Children.OfType<TextBlock>().First().Text == "Abort").Children.OfType<ComboBox>().Single();
        Assert.Equal("self", abort.SelectedItem);
        abort.SelectedItem = "none";
        Assert.Null(editor.Document.Graph.Find(1)!.Get("abort"));
    });
}
