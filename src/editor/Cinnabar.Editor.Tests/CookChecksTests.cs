using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The cook checks that every asset editor shares: one state that starts as pending, answers about older text dropped,
/// problems placed by the editor's map, and the latch that says the daemon has cooked the unsaved text.
/// </summary>
public sealed class CookChecksTests : IDisposable
{
    const string Guid = "0123456789abcdef0123456789abcdef";

    readonly TempDirectory _temp = new("cook-checks");
    readonly EditorShell _shell;
    readonly string _path;
    readonly List<string> _events = [];
    string _text = "first";
    bool _linked = true;

    public CookChecksTests()
    {
        _shell = TestShell.Open(_temp, null, null);
        _path = _temp.Combine("probe.txt");
    }

    public void Dispose()
    {
        _shell.Dispose();
        _temp.Dispose();
    }

    CookChecks<CookLine> Checks(Func<string, Task<PreviewResult>>? cook = null)
    {
        var checks = new CookChecks<CookLine>(_shell, Guid, () => _text, () => _path, l => l,
            ready: () => _linked, cook: cook ?? (_ => Task.FromResult(Clean)));
        checks.Changed += () => _events.Add($"changed {checks.State}");
        checks.CookedCleanChanged += () => _events.Add($"cooked clean {checks.CookedClean}");
        return checks;
    }

    static readonly PreviewResult Clean = new("", [], []);

    static PreviewResult Failed(string file, uint line, uint column, string text) => new(text, [new Problem(file, line, column, true, text)], []);

    [Fact]
    public async Task NoAnswerIsPendingAndCookingNowShowsTheAnswer()
    {
        using var checks = Checks(text => Task.FromResult(text == "first" ? Clean : Failed(_path, 1, 0, "broken")));
        Assert.Same(CheckState.Pending, checks.State);
        Assert.False(checks.CookedClean);

        await checks.CookNow();

        Assert.Equal(new CheckState.Clean("first"), checks.State);
        Assert.True(checks.CookedClean);
    }

    [Fact]
    public void AProblemOfThisFileHasItsLineAndAnotherFilesSaysWhere()
    {
        using var checks = Checks();

        checks.Show(_text, new PreviewResult("bad",
        [
            new Problem(_path, 3, 0, true, "here"),
            new Problem(_temp.Combine("other.txt"), 9, 4, false, "there"),
            new Problem("", 0, 0, true, "nowhere"),
        ], []));

        Assert.Equal(
        [
            new CookLine("here", true, 3, 1),
            new CookLine("other.txt:9: there", false, 0, 0),
            new CookLine("nowhere", true, 0, 0),
        ], checks.Problems);
        Assert.Equal(new CheckState.Failed("bad"), checks.State);
    }

    [Fact]
    public void AnAnswerAboutAnOlderTextIsDroppedButACleanOneStillLatches()
    {
        using var checks = Checks();
        _text = "second";

        checks.Show("first", Failed(_path, 1, 0, "stale"));
        Assert.Same(CheckState.Pending, checks.State);
        Assert.Empty(checks.Problems);
        Assert.False(checks.CookedClean);

        // The daemon wrote the blob of the clean text, so the preview can show unsaved text from now on.
        checks.Show("first", Clean);
        Assert.Same(CheckState.Pending, checks.State);
        Assert.True(checks.CookedClean);
        Assert.Equal(["cooked clean True"], _events);
    }

    [Fact]
    public void TheLatchStaysAfterAFailureAndIsSetAfterItsChange()
    {
        using var checks = Checks();

        checks.Show(_text, Clean);
        _text = "second";
        checks.Show(_text, Failed(_path, 1, 0, "broken"));
        _text = "third";
        checks.Show(_text, Clean);

        Assert.True(checks.CookedClean);
        Assert.Equal(new CheckState.Clean("third"), checks.State);
        Assert.Equal(
        [
            $"changed {new CheckState.Clean("first")}",
            "cooked clean True",
            $"changed {new CheckState.Failed("broken")}",
            $"changed {new CheckState.Clean("third")}",
        ], _events);
    }

    [Fact]
    public async Task ANewLinkStartsTheChecksAgainWithNoCleanCook()
    {
        var answers = new Queue<PreviewResult>([Clean, Failed(_path, 1, 0, "broken")]);
        using var checks = Checks(_ => Task.FromResult(answers.Dequeue()));
        await checks.CookNow();
        _events.Clear();

        // The new daemon's preview area is empty, so the text has not cooked into it until it answers.
        await checks.Restart();

        Assert.Equal([$"changed {CheckState.Pending}", "cooked clean False", $"changed {new CheckState.Failed("broken")}"], _events);

        Assert.Equal(new CheckState.Failed("broken"), checks.State);
        Assert.False(checks.CookedClean);
    }

    [Fact]
    public async Task AnAnswerThatComesOnceTheLinkIsGoneIsNotTheTexts()
    {
        var answer = new TaskCompletionSource<PreviewResult>();
        using var checks = Checks(_ => answer.Task);
        var cooking = checks.CookNow();

        _linked = false;
        answer.SetResult(new PreviewResult("The cook link closed before the cook daemon answered.", [], []));
        await cooking;

        Assert.Same(CheckState.Pending, checks.State);
        Assert.Empty(_events);
    }
}
