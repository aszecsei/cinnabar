using System.Text;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tests;

/// <summary>What every <see cref="TextGraphDocument{TFile}"/> does the same: open, save and see another program's change.</summary>
public sealed class TextGraphDocumentTests : IDisposable
{
    readonly TempDirectory _temp = new("text-graph-document");

    public void Dispose() => _temp.Dispose();

    // A kind's file in the repository, how its document opens, and one edit to it.
    sealed record Kind(
        string[] File,
        Func<string, string, (ITextGraphDocument? Document, MaterialProblem? Problem)> Open,
        Action<ITextGraphDocument> Edit);

    static readonly Dictionary<string, Kind> Kinds = new()
    {
        ["animation_graph"] = new(["tools", "cook", "testdata", "animation_graphs", "plain.animation_graph"],
            (path, guid) => AnimationGraphDocument.Open(path, guid),
            d => ((AnimationGraphDocument)d).Edit("Entry", f => f.SetEntry("edited"))),
        ["decision"] = new(["tools", "cook", "testdata", "decisions", "plain.decision"],
            (path, guid) => DecisionDocument.Open(path, guid),
            d => ((DecisionDocument)d).Edit("Setting", f => f.SetSetting("edited", "1"))),
        ["blackboard"] = new(["tools", "cook", "testdata", "decisions", "guard.blackboard"],
            (path, guid) => BlackboardDocument.Open(path, guid),
            d => ((BlackboardDocument)d).Edit("Key", f => f.AddKey("bool", "edited", [], null))),
        ["world"] = new(["samples", "mygame", "content", "worlds", "streaming.world"],
            (path, guid) => WorldDocument.Open(path, guid),
            d => ((WorldDocument)d).Edit("Persistent", f => f.SetPersistent(f.Scenes.Last(), true))),
        ["cutscene"] = new(["tools", "cook", "testdata", "cutscenes", "template.cutscene"],
            (path, guid) => CutsceneDocument.Open(path, guid),
            d => ((CutsceneDocument)d).Edit("Rate", f => f.Root.Set("rate", "60"))),
        ["ui"] = new(["samples", "mygame", "content", "ui", "pause.ui"],
            (path, guid) => UiDocument.Open(path, guid),
            d => ((UiDocument)d).Edit("Fill", f => f.SetAttribute(f.AllElements().First(), "fill", "#123456"))),
    };

    public static TheoryData<string> KindNames => [.. Kinds.Keys];

    // The kind's file with CRLF endings, written to the temporary directory, and its document.
    (string Path, string Text, ITextGraphDocument Document) Open(string name)
    {
        var kind = Kinds[name];
        var text = File.ReadAllText(Path.Combine([EditorOptions.RepositoryRoot(), .. kind.File])).ReplaceLineEndings("\r\n");
        Directory.CreateDirectory(_temp.Path);
        var path = _temp.Combine(kind.File[^1]);
        File.WriteAllText(path, text);
        var (document, problem) = kind.Open(path, "a");
        Assert.Null(problem);
        return (path, text, document!);
    }

    [Theory]
    [MemberData(nameof(KindNames))]
    public void ADocumentSavesItsFileBackAsItWasAndThenOnlyItsEdit(string name)
    {
        var (path, text, document) = Open(name);
        Assert.False(document.IsDirty);
        Assert.False(document.ChangedOnDisk);
        document.Save();
        Assert.Equal(text, File.ReadAllText(path));

        Kinds[name].Edit(document);
        Assert.True(document.IsDirty);
        // The edit is not on disk until a save, and the file is still the one the document read.
        Assert.False(document.ChangedOnDisk);
        document.Undo();
        Assert.False(document.IsDirty);
        document.Redo();
        document.Save();
        Assert.False(document.IsDirty);
        Assert.False(document.ChangedOnDisk);
        var saved = File.ReadAllText(path);
        Assert.NotEqual(text, saved);
        Assert.DoesNotContain("\n", saved.Replace("\r\n", ""));
        // What it wrote opens again, as it was saved.
        var (again, problem) = Kinds[name].Open(path, "a");
        Assert.Null(problem);
        Assert.False(again!.ChangedOnDisk);
    }

    [Theory]
    [MemberData(nameof(KindNames))]
    public void ADocumentSeesAnotherProgramsChangeAndAFileThatIsGone(string name)
    {
        var (path, text, document) = Open(name);
        File.AppendAllText(path, "# Someone's note.\r\n");
        Assert.True(document.ChangedOnDisk);
        File.WriteAllText(path, text);
        Assert.False(document.ChangedOnDisk);
        // Bytes that are not UTF-8 are a change too, whatever they would read as.
        File.WriteAllBytes(path, [.. Encoding.UTF8.GetBytes(text), 0xFF]);
        Assert.True(document.ChangedOnDisk);
        File.Delete(path);
        Assert.True(document.ChangedOnDisk);
        // A save writes the file again, and takes it as the one on disk.
        document.Save();
        Assert.False(document.ChangedOnDisk);
        Assert.Equal(text, File.ReadAllText(path));
    }

    [Theory]
    [MemberData(nameof(KindNames))]
    public void ADocumentDoesNotOpenAFileThatIsNotUtf8OrIsNotThere(string name)
    {
        var (path, text, _) = Open(name);
        File.WriteAllBytes(path, [.. Encoding.UTF8.GetBytes(text), 0xFF]);
        var (document, problem) = Kinds[name].Open(path, "a");
        Assert.Null(document);
        Assert.Equal(new MaterialProblem(0, "its text is not UTF-8"), problem);
        File.Delete(path);
        (document, problem) = Kinds[name].Open(path, "a");
        Assert.Null(document);
        Assert.Equal(0, problem!.Line);
    }

    [Fact]
    public void Utf8TextKeepsAByteOrderMarkAndRefusesBytesThatAreNotUtf8()
    {
        Assert.Equal("﻿ui 1\n", Utf8Text.Decode([0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes("ui 1\n")]));
        Assert.Equal("é", Utf8Text.Decode([0xC3, 0xA9]));
        Assert.Null(Utf8Text.Decode([0xC3]));
        Assert.Null(Utf8Text.Decode([0xFF]));
        Assert.Equal("", Utf8Text.Decode([]));
    }
}
