using System.Text.Json;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>Captures without a host: the messages a capture sends, the files and the sidecar it writes.</summary>
public sealed class CaptureModelTests : IDisposable
{
    readonly TempDirectory _temp = new("capture");
    readonly List<ILinkMessage> _sent = [];
    int _framesAwaited;

    CaptureModel NewModel() => new(_sent.Add, (frames, _) =>
    {
        _framesAwaited += frames;
        return Task.CompletedTask;
    });

    static CaptureContext Context() => new("Edit", false, "E:/scenes/door.scene", new CameraInfo([0, 1 << 24, 0], [0, 1, 0], 0.5, -0.1, 1.05, 0.05),
        EditorShell.DefaultViewportSettings, null, null, "mygame", 1234, ["mygame.dll"], Environment.ProcessId);

    /// <summary>Answers every request that waits, as the host would, until the capture ends.</summary>
    async Task<CaptureOutcome> Drive(CaptureModel model, Task<CaptureOutcome> capture, Func<CaptureRequest, CaptureResult> answer)
    {
        var answered = 0;
        while (!capture.IsCompleted)
        {
            var requests = _sent.OfType<CaptureRequest>().ToList();
            if (requests.Count > answered)
            {
                var request = requests[answered++];
                Assert.True(model.Apply(answer(request)));
            }
            else
            {
                await Task.Delay(5, TestContext.Current.CancellationToken);
            }
        }
        return await capture;
    }

    static CaptureResult Written(CaptureRequest r) => new(r.Id, r.Kind, true, "", r.Path, 900, 640, 360, r.Kind == CaptureKind.Gif ? 50u : 0u, r.Kind == CaptureKind.Gif ? 4900 : 0, OutputMode.Sdr);

    [Fact]
    public async Task AScreenshotWithViewsSwitchesTheViewportAndPutsItBack()
    {
        var model = NewModel();
        var settings = EditorShell.DefaultViewportSettings with { NoBloom = true };
        var outcome = await Drive(model, model.CaptureAsync(CaptureKind.Screenshot, [DebugView.Depth, DebugView.Normals], _temp.Path, null, settings, Context, CancellationToken.None), Written);

        Assert.True(outcome.Ok, outcome.Error);
        Assert.False(model.Busy);
        // The lit frame, then each view: the settings with the view, a wait for frames, the request; then the user's settings again.
        Assert.Collection(_sent,
            m => Assert.Equal(CaptureKind.Screenshot, Assert.IsType<CaptureRequest>(m).Kind),
            m => Assert.Equal(DebugView.Depth, Assert.IsType<ViewportSettings>(m).DebugView),
            m => Assert.EndsWith(".depth.png", Assert.IsType<CaptureRequest>(m).Path),
            m => Assert.Equal(DebugView.Normals, Assert.IsType<ViewportSettings>(m).DebugView),
            m => Assert.EndsWith(".normals.png", Assert.IsType<CaptureRequest>(m).Path),
            m => Assert.Equal(settings, Assert.IsType<ViewportSettings>(m)));
        Assert.Equal(2 * CaptureModel.SettleFrames, _framesAwaited);
        // The view's settings keep the user's other choices.
        Assert.True(((ViewportSettings)_sent[1]).NoBloom);

        Assert.Equal(4, outcome.Files.Count);
        Assert.All(outcome.Files, f => Assert.StartsWith(_temp.Path, f));
        Assert.EndsWith(".json", outcome.Sidecar);
        Assert.True(File.Exists(outcome.Sidecar));
        using var json = JsonDocument.Parse(File.ReadAllText(outcome.Sidecar));
        var root = json.RootElement;
        Assert.Equal("Screenshot", root.GetProperty("kind").GetString());
        Assert.Equal(["depth", "normals"], root.GetProperty("views").EnumerateArray().Select(v => v.GetString()));
        Assert.Equal(3, root.GetProperty("images").GetArrayLength());
        Assert.Equal(900ul, root.GetProperty("images")[0].GetProperty("frame").GetUInt64());
        Assert.Equal("depth", root.GetProperty("images")[1].GetProperty("view").GetString());
        var context = root.GetProperty("context");
        Assert.Equal("Edit", context.GetProperty("mode").GetString());
        Assert.Equal("E:/scenes/door.scene", context.GetProperty("scene").GetString());
        Assert.Equal(1, context.GetProperty("camera").GetProperty("positionMeters")[1].GetDouble());
        Assert.Equal("Lit", context.GetProperty("settings").GetProperty("debugView").GetString());
        Assert.Equal(1234, context.GetProperty("hostPid").GetInt32());
    }

    [Fact]
    public async Task AGifIsOneRequestAndAGivenPathNamesTheFiles()
    {
        var model = NewModel();
        var path = _temp.Combine("clips", "jump");
        var outcome = await Drive(model, model.CaptureAsync(CaptureKind.Gif, [], _temp.Path, path, EditorShell.DefaultViewportSettings, Context, CancellationToken.None), Written);

        Assert.True(outcome.Ok, outcome.Error);
        var request = Assert.IsType<CaptureRequest>(Assert.Single(_sent));
        Assert.Equal(CaptureKind.Gif, request.Kind);
        Assert.Equal(path + ".gif", request.Path);
        Assert.Equal([path + ".gif", path + ".json"], outcome.Files);
        using var json = JsonDocument.Parse(File.ReadAllText(outcome.Sidecar!));
        Assert.Equal(50u, json.RootElement.GetProperty("images")[0].GetProperty("frames").GetUInt32());
    }

    [Fact]
    public async Task AFailedCaptureStillWritesTheSidecarAndPutsTheSettingsBack()
    {
        var model = NewModel();
        var outcome = await Drive(model, model.CaptureAsync(CaptureKind.Screenshot, [DebugView.Albedo], _temp.Path, null, EditorShell.DefaultViewportSettings, Context, CancellationToken.None),
            r => new CaptureResult(r.Id, r.Kind, false, "the window is minimized", r.Path, 0, 0, 0, 0, 0, OutputMode.Sdr));

        Assert.False(outcome.Ok);
        Assert.Contains("minimized", outcome.Error);
        Assert.Equal(EditorShell.DefaultViewportSettings, Assert.IsType<ViewportSettings>(_sent[^1]));
        var sidecar = Assert.Single(outcome.Files);
        Assert.EndsWith(".json", sidecar);
        Assert.Contains("minimized", File.ReadAllText(sidecar));
    }

    [Fact]
    public async Task OnlyOneCaptureRunsAndStrayResultsAreIgnored()
    {
        var model = NewModel();
        var first = model.CaptureAsync(CaptureKind.Screenshot, [], _temp.Path, null, EditorShell.DefaultViewportSettings, Context, CancellationToken.None);
        Assert.True(model.Busy);
        var second = await model.CaptureAsync(CaptureKind.Gif, [], _temp.Path, null, EditorShell.DefaultViewportSettings, Context, CancellationToken.None);
        Assert.False(second.Ok);
        Assert.Contains("under way", second.Error);
        Assert.False(model.Apply(new CaptureResult(99, CaptureKind.Screenshot, true, "", "x.png", 0, 0, 0, 0, 0, OutputMode.Sdr)));
        var outcome = await Drive(model, first, Written);
        Assert.True(outcome.Ok);
        Assert.False(model.Busy);
    }

    [Fact]
    public void ViewNamesReadInAnySpelling()
    {
        Assert.Equal("entity_ids", CaptureModel.ViewName(DebugView.EntityIds));
        Assert.Contains("gi_diffuse", CaptureModel.ViewNames);
        foreach (var text in new[] { "depth", "Depth", " depth " })
        {
            Assert.True(CaptureModel.TryParseView(text, out var depth));
            Assert.Equal(DebugView.Depth, depth);
        }
        foreach (var text in new[] { "entity_ids", "Entity_Ids", "entityIds", "EntityIds", "entity ids", "entity-ids" })
        {
            Assert.True(CaptureModel.TryParseView(text, out var ids), text);
            Assert.Equal(DebugView.EntityIds, ids);
        }
        Assert.False(CaptureModel.TryParseView("wireframe", out _));
    }

    public void Dispose() => _temp.Dispose();
}
