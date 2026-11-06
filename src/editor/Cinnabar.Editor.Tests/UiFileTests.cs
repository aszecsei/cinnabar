using System.Text;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tests;

/// <summary>The UI document's reader and writer, over the files that the cooker's tests read too.</summary>
public sealed class UiFileTests : IDisposable
{
    readonly TempDirectory _temp = new("ui-file");

    public void Dispose() => _temp.Dispose();

    static string CorpusDirectory => Path.Combine(EditorOptions.RepositoryRoot(), "lib", "engine", "asset", "format", "testdata", "ui");

    public static TheoryData<string> CorpusFiles() => [.. Directory.GetFiles(CorpusDirectory, "*.ui").Select(f => Path.GetFileNameWithoutExtension(f)!).Order()];

    static string Corpus(string name) => File.ReadAllText(Path.Combine(CorpusDirectory, name + ".ui")).ReplaceLineEndings("\n");

    static string Pause() =>
        File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "ui", "pause.ui")).ReplaceLineEndings("\n");

    static UiFile Read(string text)
    {
        var (file, problem) = UiFile.Parse(text);
        Assert.Null(problem);
        return file!;
    }

    static UiElement ById(UiFile file, string id) => file.AllElements().First(e => e.Get("id") == id);

    // The lines of the first text that the second has not, and the second's that the first has not.
    static (string[] Removed, string[] Added) Diff(string before, string after)
    {
        var (a, b) = (before.Split('\n'), after.Split('\n'));
        return ([.. a.Except(b)], [.. b.Except(a)]);
    }

    [Theory]
    [MemberData(nameof(CorpusFiles))]
    public void TheCooksFilesWriteBackAsTheyWereWithEveryLineEnding(string name)
    {
        var text = Corpus(name);
        Assert.Equal(text, Read(text).Text);
        Assert.Equal(text.ReplaceLineEndings("\r\n"), Read(text.ReplaceLineEndings("\r\n")).Text);
        Assert.Equal(text.TrimEnd('\n'), Read(text.TrimEnd('\n')).Text);
        var mixed = text.Replace("\n\t<", "\r\n\t<");
        Assert.Equal(mixed, Read(mixed).Text);
    }

    [Theory]
    [MemberData(nameof(CorpusFiles))]
    public void NodesAreTheOnesThatTheCookerMakes(string name)
    {
        var text = Corpus(name);
        var marker = text.IndexOf("<!-- nodes:", StringComparison.Ordinal);
        if (marker < 0)
        {
            return;
        }
        var end = text.IndexOf("-->", marker, StringComparison.Ordinal);
        var listed = text[(marker + "<!-- nodes:".Length)..end].Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var file = Read(text);
        Assert.Equal(listed, file.Nodes.Select(n => n.Kind));
        // Each node's parent comes before it, and its index is its place in the walk.
        for (var i = 0; i < file.Nodes.Count; i++)
        {
            Assert.Equal(i, file.Nodes[i].Index);
            Assert.True(file.Nodes[i].Parent < i);
        }
    }

    [Theory]
    [MemberData(nameof(CorpusFiles))]
    public void AProblemOnAnElementsLineFindsTheElement(string name)
    {
        var text = Corpus(name);
        var file = Read(text);
        var lines = text.Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            if (!lines[i].Contains("<!-- problem -->") && !lines[i].Contains("<!-- warning -->"))
            {
                continue;
            }
            var trimmed = lines[i].TrimStart();
            if (!trimmed.StartsWith('<') || trimmed.StartsWith("</", StringComparison.Ordinal) || trimmed.StartsWith("<!--", StringComparison.Ordinal))
            {
                continue;
            }
            var column = lines[i].Length - trimmed.Length + 1;
            var found = file.ElementAt(i + 1, column);
            Assert.NotNull(found);
            Assert.Equal(i + 1, file.Position(found.Start).Line);
            // A column inside the element is still the element, or one of its children.
            var attribute = lines[i].IndexOf('=');
            if (attribute > 0)
            {
                var inner = file.ElementAt(i + 1, attribute + 1)!;
                Assert.True(inner == found || inner.Parent == found);
            }
        }
    }

    [Fact]
    public void AFileWithoutItsHeaderIsRefusedAtTheHeadersLine()
    {
        var (file, problem) = UiFile.Parse("\n\n<ui></ui>\n");
        Assert.Null(file);
        Assert.Equal(3, problem!.Line);
        Assert.Contains("ui 1", problem.Message);
        Assert.Contains("version 2", UiFile.Parse("ui 2\n<ui/>").Problem!.Message);
        // A document with problems opens, with what nodes it has.
        var broken = Read(Corpus("unclosed"));
        Assert.Equal("ui", broken.Nodes[0].Kind);
    }

    [Fact]
    public void TheSamplesMenuWritesBackAsItWasAndHasItsNodes()
    {
        var file = Read(Pause());
        Assert.Equal(Pause(), file.Text);
        Assert.Equal(["ui", "box", "column", "text", "text", "button", "text", "button", "text", "row", "text", "field", "text"], file.Nodes.Select(n => n.Kind));
        var resume = file.NodeById("resume")!;
        Assert.True(file.Nodes[resume.Index + 1].ButtonText);
        Assert.Equal("Resume", file.Nodes[resume.Index + 1].Element.Text);
        Assert.Equal(["button", "button:hover", "button:focus", "button:press", "field", "field:focus", "caption"], file.Styles.Select(s => s.Name));
        Assert.Equal(["button"], file.StylesOf(resume).Select(s => s.Name));
    }

    [Fact]
    public void AnAttributesEditChangesOnlyItsValue()
    {
        var text = Pause();
        var file = Read(text);
        file.SetAttribute(ById(file, "resume"), "fill", "#ff0000");
        var (removed, added) = Diff(text, file.Text);
        Assert.Equal(["\t\t<button id=\"resume\" click=\"resume\">Resume</button>"], removed);
        Assert.Equal(["\t\t<button id=\"resume\" click=\"resume\" fill=\"#ff0000\">Resume</button>"], added);
        var after = file.Text;
        file.SetAttribute(ById(file, "resume"), "fill", "linear(90, #fff, #000)");
        Assert.Equal(["\t\t<button id=\"resume\" click=\"resume\" fill=\"linear(90, #fff, #000)\">Resume</button>"], Diff(after, file.Text).Added);
        file.SetAttribute(ById(file, "resume"), "fill", null);
        Assert.Equal(text, file.Text);

        // An attribute without quotes keeps them off while it can, and a value that needs them gets them.
        var font = file.Root!.Attribute("font")!;
        Assert.Equal('\0', font.Quote);
        file.SetAttribute(file.Root, "font", "$00112233445566778899aabbccddeeff");
        Assert.Contains("font=$00112233445566778899aabbccddeeff size", file.Text);
        file.SetAttribute(file.Root!, "font", "a b");
        Assert.Contains("font=\"a b\" size", file.Text);
        // Entities go in for what a value cannot hold.
        file.SetAttribute(ById(file, "name"), "placeholder", "Fish & \"chips\"");
        Assert.Contains("placeholder=\"Fish &amp; &quot;chips&quot;\"", file.Text);
        Assert.Equal("Fish & \"chips\"", ById(file, "name").Get("placeholder"));
    }

    [Fact]
    public void AnAttributeOnASecondLineOfItsTagChangesOnlyThatLine()
    {
        var text = Pause();
        var file = Read(text);
        file.SetAttribute(ById(file, "menu"), "border", null);
        var (removed, added) = Diff(text, file.Text);
        Assert.Equal(["\t        fill=\"linear(90, #1a1e2bf4, #0d0f16f4)\" border=\"1 #ffffff20\">"], removed);
        Assert.Equal(["\t        fill=\"linear(90, #1a1e2bf4, #0d0f16f4)\">"], added);
        // An attribute alone on its line takes the line with it.
        file.SetAttribute(ById(file, "menu"), "fill", null);
        Assert.Equal(["\t        >"], Diff(text, file.Text).Added.Where(l => l.Trim() == ">").ToArray());
    }

    [Fact]
    public void MovingAnElementMovesItsLinesAndKeepsTheRest()
    {
        var text = Pause();
        var file = Read(text);
        var menu = ById(file, "menu");
        var row = menu.Children.First(c => c.Name == "row");
        var resumeIndex = menu.Children.IndexOf(ById(file, "resume"));
        file.Move(row, menu, resumeIndex);
        var lines = text.Split('\n').ToList();
        var rowAt = lines.FindIndex(l => l.Contains("<row"));
        var block = lines.GetRange(rowAt, 4);
        lines.RemoveRange(rowAt, 4);
        lines.InsertRange(lines.FindIndex(l => l.Contains("id=\"resume\"")), block);
        Assert.Equal(string.Join('\n', lines), file.Text);

        // Into another parent, at its depth.
        file = Read(text);
        file.Move(ById(file, "quality"), ById(file, "dim"), 0);
        Assert.Contains("\t<box id=\"dim\" anchor=\"fill\" fill=\"#00000080\">\n\t\t<button id=\"quality\" click=\"quality\">Quality: {quality}</button>\n\t</box>\n", file.Text);
        Assert.DoesNotContain("\t\t<button id=\"quality\"", file.Text.Split("<column")[1]);
    }

    [Fact]
    public void AddingAndRemovingElementsTakesLinesOfTheirOwn()
    {
        var text = Pause();
        var file = Read(text);
        // A box that closes itself opens for its child.
        file.Insert(ById(file, "dim"), 0, "<text>Hi</text>");
        Assert.Equal(["\t<box id=\"dim\" anchor=\"fill\" fill=\"#00000080\"/>"], Diff(text, file.Text).Removed);
        Assert.Equal(["\t<box id=\"dim\" anchor=\"fill\" fill=\"#00000080\">", "\t\t<text>Hi</text>", "\t</box>"], Diff(text, file.Text).Added);

        file = Read(text);
        var menu = ById(file, "menu");
        file.Insert(menu, menu.Children.Count, "<box height=\"4\"/>");
        Assert.Equal(["\t\t<box height=\"4\"/>"], Diff(text, file.Text).Added);
        Assert.Contains("wrap=\"true\">Quality takes the next preset. Office, fifty, waffle: the text is kerned and has its ligatures.</text>\n\t\t<box height=\"4\"/>\n\t</column>", file.Text);
        file.Remove(file.AllElements().First(e => e.Get("height") == "4"));
        Assert.Equal(text, file.Text);

        file.Remove(ById(file, "dim"));
        Assert.Equal(["\t<box id=\"dim\" anchor=\"fill\" fill=\"#00000080\"/>"], Diff(text, file.Text).Removed);
        Assert.Empty(Diff(text, file.Text).Added);
    }

    [Fact]
    public void ACopyGetsIdsOfItsOwn()
    {
        var text = Pause();
        var file = Read(text);
        var path = file.Duplicate(ById(file, "resume"));
        Assert.Equal(["\t\t<button id=\"resume_2\" click=\"resume\">Resume</button>"], Diff(text, file.Text).Added);
        Assert.Equal("resume_2", file.At(path)!.Get("id"));
        file.Duplicate(ById(file, "resume"));
        Assert.Contains("id=\"resume_3\"", file.Text);
    }

    [Fact]
    public void StylesAndVariantsGoAfterTheLastStyle()
    {
        var text = Pause();
        var file = Read(text);
        var path = file.AddStyle("button:disabled");
        file.SetAttribute(file.At(path)!, "opacity", "0.5");
        Assert.Equal(["\t<style name=\"button:disabled\" opacity=\"0.5\"/>"], Diff(text, file.Text).Added);
        Assert.Contains("<style name=\"caption\" size=\"15\" color=\"#ffffffa0\"/>\n\t<style name=\"button:disabled\"", file.Text);

        file = Read(text);
        file.RenameStyle("caption", "small");
        Assert.DoesNotContain("caption", file.Text.Replace("Quality takes", ""));
        Assert.Equal(4, Diff(text, file.Text).Added.Length);
        file.RenameStyle("button", "action");
        Assert.Contains("<style name=\"action:hover\"", file.Text);
    }

    [Fact]
    public void TextChangesBetweenItsTags()
    {
        var text = Pause();
        var file = Read(text);
        file.SetText(ById(file, "resume"), "Go <on> & on");
        Assert.Equal(["\t\t<button id=\"resume\" click=\"resume\">Go &lt;on&gt; &amp; on</button>"], Diff(text, file.Text).Added);
        Assert.Equal("Go <on> & on", ById(file, "resume").Text);
        // A field's text without content is its attribute.
        file.SetText(ById(file, "name"), "Ada");
        Assert.Contains("<field id=\"name\" width=\"fill\" placeholder=\"Type a name\" max_length=\"20\" changed=\"name_changed\" submit=\"name_submitted\">Ada</field>", file.Text);
    }

    [Fact]
    public void EditsKeepTheFilesLineEndings()
    {
        var text = Pause().ReplaceLineEndings("\r\n");
        var file = Read(text);
        var menu = ById(file, "menu");
        file.Insert(menu, 0, "<box/>");
        file.Duplicate(ById(file, "quality"));
        file.Remove(ById(file, "dim"));
        Assert.DoesNotContain("\n", file.Text.Replace("\r\n", ""));
    }

    [Fact]
    public void ACascadeSaysWhereEachValueComesFrom()
    {
        var file = Read(Pause());
        var inherited = new HashSet<string> { "font", "size", "color", "text_align", "line_height", "wrap" };
        var resume = file.NodeById("resume")!;
        var none = UiCascade.Resolve(file, resume.Index, inherited, _ => []);
        Assert.Equal(new UiValue("#1c2030e0", UiSource.Style, "button"), none["fill"]);
        Assert.Equal(new UiValue("resume", UiSource.Own, ""), none["click"]);
        Assert.Equal(UiSource.Inherited, none["size"].Source);
        Assert.Equal("<ui>", none["size"].From);
        var hovered = UiCascade.Resolve(file, resume.Index, inherited, n => n == resume.Index ? ["hover"] : []);
        Assert.Equal(new UiValue("#2a3048f0", UiSource.Style, "button:hover"), hovered["fill"]);
        // Disabled is a state alone; the menu has no variant for it.
        var disabled = UiCascade.Resolve(file, resume.Index, inherited, n => n == resume.Index ? ["hover", "disabled"] : []);
        Assert.Equal("button", disabled["fill"].From);
        // A button's text inherits from the button and its own ancestors.
        var text = UiCascade.Resolve(file, resume.Index + 1, inherited, _ => []);
        Assert.Equal(new UiValue("Resume", UiSource.Own, ""), text["text"]);
        Assert.Equal("20", text["size"].Value);
        Assert.False(text.ContainsKey("fill"));
        var caption = file.Nodes.First(n => n.Element.Get("style") == "caption");
        Assert.Equal(new UiValue("15", UiSource.Style, "caption"), UiCascade.Resolve(file, caption.Index, inherited, _ => [])["size"]);
    }

    [Fact]
    public void ADocumentUndoesAndSavesItsText()
    {
        Directory.CreateDirectory(_temp.Path);
        var path = _temp.Combine("pause.ui");
        File.WriteAllText(path, Pause().ReplaceLineEndings("\r\n"));
        var (document, problem) = UiDocument.Open(path, "a");
        Assert.Null(problem);
        Assert.False(document!.IsDirty);
        document.Edit("Fill", f => f.SetAttribute(f.AllElements().First(e => e.Get("id") == "resume"), "fill", "#123456"));
        Assert.True(document.IsDirty);
        document.Undo();
        Assert.False(document.IsDirty);
        document.Redo();
        document.Save();
        Assert.False(document.ChangedOnDisk);
        Assert.Contains("fill=\"#123456\">Resume</button>\r\n", File.ReadAllText(path));
        File.WriteAllBytes(path, [.. Encoding.UTF8.GetBytes("ui 1\n"), 0xFF]);
        Assert.True(document.ChangedOnDisk);
        Assert.Contains("UTF-8", UiDocument.Open(path, "a").Problem!.Message);
    }

    [Fact]
    public void BindingsAreTheNamesInBraces()
    {
        Assert.Equal(["name", "fps"], UiFile.Bindings("Hi {name}, {{not}} {fps} {name}"));
        Assert.True(UiFile.ValidBindings("{a} {{ }}"));
        Assert.False(UiFile.ValidBindings("{Bad Name}"));
        Assert.False(UiFile.ValidBindings("{open"));
    }
}
