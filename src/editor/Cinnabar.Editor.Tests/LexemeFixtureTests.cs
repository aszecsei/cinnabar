using System.Globalization;
using System.Text.Json;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The token rules that the editor shares with the cooker. Every row of lib/engine/asset/format/testdata/lexemes.json
/// runs here and in the engine's text_lex_test.odin, so the two sides read each token the same way.
/// </summary>
public sealed class LexemeFixtureTests
{
    static readonly string[] Rules =
        ["strip_comment", "strip_comment_word", "whole_ticks", "whole_id", "guid", "guid_ref", "settings_line", "sublevel_name"];

    static JsonElement Fixture()
    {
        var path = Path.Combine(EditorOptions.RepositoryRoot(), "lib", "engine", "asset", "format", "testdata", "lexemes.json");
        return JsonDocument.Parse(File.ReadAllText(path)).RootElement.GetProperty("rows");
    }

    // Each row as its rule, its input, whether it reads, and the value it reads as text, or null when the row gives none.
    public static TheoryData<int, string, string, bool, string?> Rows()
    {
        var rows = new TheoryData<int, string, string, bool, string?>();
        var i = 0;
        foreach (var row in Fixture().EnumerateArray())
        {
            string? value = row.TryGetProperty("value", out var v)
                ? v.ValueKind == JsonValueKind.Number ? v.GetInt64().ToString(CultureInfo.InvariantCulture) : v.GetString()
                : null;
            rows.Add(i++, row.GetProperty("rule").GetString()!, row.GetProperty("input").GetString()!, row.GetProperty("ok").GetBoolean(), value);
        }
        return rows;
    }

    [Theory]
    [MemberData(nameof(Rows))]
    public void EveryRowReadsAsTheFixtureSays(int row, string rule, string input, bool ok, string? value)
    {
        var (gotOk, got) = Read(rule, input);
        Assert.True(gotOk == ok, $"row {row}: {rule}(\"{input}\") ok = {gotOk}, not {ok}");
        if (ok && value != null)
        {
            Assert.Equal(value, got);
        }
    }

    [Fact]
    public void EveryRuleInTheFixtureIsOneThatTheEditorReads()
    {
        var rules = Fixture().EnumerateArray().Select(r => r.GetProperty("rule").GetString()).Distinct().ToList();
        Assert.All(rules, r => Assert.Contains(r, Rules));
        Assert.All(Rules, r => Assert.Contains(r, rules));
    }

    static (bool Ok, string? Value) Read(string rule, string input)
    {
        switch (rule)
        {
            case "strip_comment":
                return (true, TextLine.StripComment(input));
            case "strip_comment_word":
                return (true, TextLine.StripComment(input, hashInWord: true));
            case "whole_ticks":
            {
                var ok = CutsceneFile.TryParseTicks(input, out var ticks);
                return (ok, ticks.ToString(CultureInfo.InvariantCulture));
            }
            case "whole_id":
            {
                var ok = CutsceneFile.TryParseId(input, out var id);
                return (ok, id.ToString(CultureInfo.InvariantCulture));
            }
            case "guid":
            {
                var ok = AssetGuid.TryParse(input, out var guid);
                return (ok, guid.Text);
            }
            case "guid_ref":
            {
                var ok = AssetGuid.TryParseRef(input, out var guid);
                return (ok, guid.Text);
            }
            case "settings_line":
            {
                var ok = ProjectSettings.TryParseLine(input, out var key, out var value);
                return (ok, $"{key}={value}");
            }
            case "sublevel_name":
                return (SceneFile.IsSublevelName(input), null);
            default:
                Assert.Fail($"no rule \"{rule}\"");
                return default;
        }
    }
}
