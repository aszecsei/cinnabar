using System.Text.RegularExpressions;
using Cinnabar.Editor.Decisions;

namespace Cinnabar.Editor.Tests;

/// <summary>The decision details' table of fields, against docs/content/kinds/decisions.md.</summary>
public sealed partial class DecisionFieldsTests
{
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
}
