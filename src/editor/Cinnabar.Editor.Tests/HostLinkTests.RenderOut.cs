using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tests;

// Render out on the real host (see docs/editor/cutscene-editor.md#render-out): the game plays the sample's intro out of
// real time, and the host writes its frames. These drive the link as the editor's run does: a Render_Out_Begin in
// Edit, and after Render_Out_Ended, Edit and the scene again.
public sealed partial class HostLinkTests
{
    // The first run streams and compiles from cold, and the second finds everything resident, so they wait for
    // different numbers of draws, past the intro's fade from black, so the frames show the scene. The frames are the
    // same but for the GPU's own order: the split cascades' probes take their slots in the order that the GPU's
    // threads reach them, so a few pixels of their light differ from run to run by a few levels (see
    // docs/editor/cutscene-editor.md#render-out).
    [Fact]
    public async Task TenFramesRenderTheSameTwice()
    {
        SkipWithoutTheFox();
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<Welcome>();
        var scene = AnimationSceneFile();
        var root = Path.Combine(Path.GetTempPath(), $"cinnabar-render-{Guid.NewGuid():N}");
        try
        {
            var cold = await RenderOut(editor, scene, 1, Path.Combine(root, "cold"), frames: 10, rangeStart: 120000);
            var warm = await RenderOut(editor, scene, 2, Path.Combine(root, "warm"), frames: 10, rangeStart: 120000);
            Assert.Equal(10, cold.Written.Count);
            Assert.Equal(10, warm.Written.Count);
            for (var i = 0; i < 10; i++)
            {
                var (count, most) = Difference(cold.Written[i].Path, warm.Written[i].Path);
                Assert.True(count <= 320 * 180 / 50 && most <= 16, $"frame {i}: {count} pixels differ, by up to {most}");
            }
            // The frames are at the rate's exact ticks, and each waited for what it shows.
            Assert.Equal(Enumerable.Range(0, 10).Select(n => 120000 + n * 2000), cold.Frames.Select(f => f.Tick));
            Assert.All(cold.Frames, f => Assert.True(f.SettleDraws >= 3));
            Assert.DoesNotContain(editor.Skipped, m => m is Log { Level: LogLevel.Error });
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, true);
            }
        }
    }

    // A cancel stops the run after the frame that it is on: the folder holds the frames up to it, each whole, and no
    // file that the host was still writing.
    [Fact]
    public async Task ACancelStopsAfterItsFrameAndLeavesWholeFrames()
    {
        SkipWithoutTheFox();
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<Welcome>();
        var scene = AnimationSceneFile();
        var folder = Path.Combine(Path.GetTempPath(), $"cinnabar-render-{Guid.NewGuid():N}");
        try
        {
            editor.Link.Send(new SetMode(EditorMode.Edit));
            await Load(editor, scene, guid: AnimationScene);
            editor.Link.Send(new RenderOutBegin(1, Convert.FromHexString(IntroCutscene), "intro", 120000, 300, 30, 320, 180,
                RenderOutFormat.Png, 0, 0, folder, "{name}.{frame}.png", false));
            var drawn = await editor.Next<RenderOutFrame>(f => f.Ticket == 1 && f.Frame == 3);
            editor.Link.Send(new RenderOutCancel(1));
            var ended = await editor.Next<RenderOutEnded>(e => e.Ticket == 1);
            Assert.Equal(RenderOutOutcome.Cancelled, ended.Outcome);
            Assert.InRange(ended.Frames, drawn.Frame, drawn.Frame + 1);

            var files = Directory.GetFiles(folder).Select(Path.GetFileName).Order().ToList();
            Assert.Equal(Enumerable.Range(0, ended.Frames).Select(n => $"intro.{60 + n:D6}.png"), files);
            var end = new byte[] { 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
            Assert.All(files, f => Assert.Equal(end, File.ReadAllBytes(Path.Combine(folder, f!)).TakeLast(8)));
            // The game ran no further frame after the cancel.
            await Task.Delay(300, TestContext.Current.CancellationToken);
            Assert.DoesNotContain(Drained(editor), m => m is RenderOutFrame);
            editor.Link.Send(new SetMode(EditorMode.Edit));
            await Load(editor, scene, guid: AnimationScene);
            Assert.DoesNotContain(editor.Skipped, m => m is Log { Level: LogLevel.Error });
        }
        finally
        {
            if (Directory.Exists(folder))
            {
                Directory.Delete(folder, true);
            }
        }
    }

    // The sample's intro, its whole range, through the editor's model: 300 frames at 30 a second with a sidecar each, its
    // sound, and with ffmpeg, an MP4 of both that is as long as the range.
    [Fact]
    public async Task TheSampleIntroRendersToPngAndMp4WithSound()
    {
        SkipWithoutTheFox();
        var ffmpeg = Ffmpeg();
        if (ffmpeg == null)
        {
            Assert.Skip("ffmpeg is not installed");
        }
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<Welcome>();
        var scene = AnimationSceneFile();
        var folder = Path.Combine(Path.GetTempPath(), $"cinnabar-render-{Guid.NewGuid():N}");
        try
        {
            editor.Link.Send(new SetMode(EditorMode.Edit));
            await Load(editor, scene, guid: AnimationScene);
            var model = new Model.RenderOutModel(m => editor.Link.Send(m));
            var settings = new Model.RenderOutSettings(Convert.FromHexString(IntroCutscene), "intro", 0, 600000, 30, 640, 360,
                RenderOutFormat.Png, 0, 4, folder, Model.RenderOutSettings.DefaultPattern, true, true);
            var run = model.RunAsync(settings, this, ffmpeg, tick => new Model.RenderOutFrameTime($"{tick}", tick / 2000, "shot"));
            while (model.State is Model.RenderOutState.Starting or Model.RenderOutState.Running or Model.RenderOutState.Cancelling)
            {
                model.Apply(await editor.Next<ILinkMessage>(m => m is RenderOutProgress or RenderOutFrame or RenderOutWritten or RenderOutEnded));
            }
            var result = await run.WaitAsync(TimeSpan.FromMinutes(2), TestContext.Current.CancellationToken);
            Assert.True(result.Outcome == RenderOutOutcome.Done, $"{result.Outcome}: {result.Reason}");
            Assert.Equal(300, result.Frames);
            Assert.Equal(300, Directory.GetFiles(folder, "intro.*.png").Length);
            Assert.Equal(300, Directory.GetFiles(folder, "intro.*.json").Length);
            Assert.Equal(Path.Combine(folder, "intro.wav"), result.Audio);
            // 10 s of 16-bit stereo at 48 kHz, and its header.
            Assert.Equal(44 + 10 * 48000 * 4, new FileInfo(result.Audio!).Length);
            Assert.Equal(Path.Combine(folder, "intro.mp4"), result.Video);
            var probe = Probe(ffmpeg!, result.Video!);
            Assert.Contains("codec_name=h264", probe);
            Assert.Contains("codec_name=aac", probe);
            var duration = double.Parse(probe.Split('\n').First(l => l.StartsWith("duration=")).Split('=')[1], System.Globalization.CultureInfo.InvariantCulture);
            Assert.InRange(duration, 9.9, 10.1);
            Assert.DoesNotContain(editor.Skipped, m => m is Log { Level: LogLevel.Error });
            editor.Link.Send(new SetMode(EditorMode.Edit));
            await Load(editor, scene, guid: AnimationScene);
        }
        finally
        {
            if (Directory.Exists(folder))
            {
                Directory.Delete(folder, true);
            }
        }
    }

    // ffmpeg on the PATH, or where the Windows builds install it, or null.
    static string? Ffmpeg()
    {
        var names = new[] { "ffmpeg.exe", "ffmpeg" };
        var paths = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator).Append(@"C:fmpegin");
        return paths.SelectMany(p => names.Select(n => Path.Combine(p, n))).FirstOrDefault(File.Exists);
    }

    // What ffprobe, beside ffmpeg, says of a file's format and streams, a key=value a line.
    static string Probe(string ffmpeg, string file)
    {
        var ffprobe = Path.Combine(Path.GetDirectoryName(ffmpeg)!, Path.GetFileName(ffmpeg).Replace("ffmpeg", "ffprobe"));
        var info = new System.Diagnostics.ProcessStartInfo(ffprobe, ["-v", "error", "-show_format", "-show_streams", file])
        {
            RedirectStandardOutput = true,
            UseShellExecute = false,
        };
        using var process = System.Diagnostics.Process.Start(info)!;
        var text = process.StandardOutput.ReadToEnd();
        process.WaitForExit();
        return text.ReplaceLineEndings("\n");
    }

    // A host whose streamed transfers report done only 60 frames after they are, so every texture of the intro streams
    // in late. The frames wait for each one: none shows a lower mip than a run that found them resident, and the first,
    // with no warm-up to wait in, waited at least the delay.
    [Fact]
    public async Task ALateTextureNeverShowsALowerMip()
    {
        SkipWithoutTheFox();
        var scene = AnimationSceneFile();
        var root = Path.Combine(Path.GetTempPath(), $"cinnabar-render-{Guid.NewGuid():N}");
        try
        {
            RenderRun resident;
            await using (var editor = await Connect())
            {
                editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
                await editor.Next<Welcome>();
                await RenderOut(editor, scene, 1, Path.Combine(root, "warm-up"), frames: 1, rangeStart: 300000, size: (640, 360), warmup: 0);
                resident = await RenderOut(editor, scene, 2, Path.Combine(root, "resident"), frames: 3, rangeStart: 300000, size: (640, 360), warmup: 0);
            }
            await using var delayed = new DelayedHost();
            await using var late = await delayed.Open();
            late.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
            await late.Next<Welcome>();
            var streamed = await RenderOut(late, scene, 1, Path.Combine(root, "late"), frames: 3, rangeStart: 300000, size: (640, 360),
                fresh: true, warmup: 0);
            Assert.True(streamed.Frames[0].SettleDraws >= DelayedHost.Frames,
                $"the first frame waited {streamed.Frames[0].SettleDraws} draws, under the delay of {DelayedHost.Frames}");
            for (var i = 0; i < 3; i++)
            {
                var (count, most) = Difference(resident.Written[i].Path, streamed.Written[i].Path);
                Assert.True(count <= 640 * 360 / 50 && most <= 16, $"frame {i}: {count} pixels differ, by up to {most}");
            }
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, true);
            }
        }
    }

    // A host.exe whose streaming is held back (see core.STREAM_DELAY_VARIABLE). It is private, so xUnit does not run
    // the host tests on it.
    sealed class DelayedHost() : HostTests("host.exe", "just build", () => ["--adapter", Adapter.Value.ToString("x16")],
        new Dictionary<string, string> { ["CINNABAR_STREAM_DELAY_FRAMES"] = Frames.ToString() })
    {
        public const int Frames = 60;

        public Task<Editor> Open() => Connect();

    }

    // How many pixels of two frames differ, and by how much at most, in any channel.
    static (int Count, int Most) Difference(string a, string b)
    {
        var x = Pixels(a);
        var y = Pixels(b);
        Assert.Equal(x.Length, y.Length);
        var count = 0;
        var most = 0;
        for (var k = 0; k < x.Length; k += 4)
        {
            var d = 0;
            for (var c = 0; c < 3; c++)
            {
                d = Math.Max(d, Math.Abs(x[k + c] - y[k + c]));
            }
            if (d > 0)
            {
                count++;
                most = Math.Max(most, d);
            }
        }
        return (count, most);
    }

    static byte[] Pixels(string path)
    {
        using var bitmap = SkiaSharp.SKBitmap.Decode(path);
        return bitmap.Bytes;
    }

    // A render out's run: its frames as the game drew them, the files as the host wrote them, and its end.
    sealed record RenderRun(List<RenderOutFrame> Frames, List<RenderOutWritten> Written, RenderOutEnded Ended);

    static Document.Scene AnimationSceneFile()
    {
        var text = File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "scenes", "animation.scene")).ReplaceLineEndings("\n");
        var (scene, problems) = Document.SceneFile.Parse(text);
        Assert.Empty(problems);
        return scene!;
    }

    static async Task<RenderRun> RenderOut(Editor editor, Document.Scene scene, ulong ticket, string folder, int frames, uint rate = 30,
        int rangeStart = 0, (uint Width, uint Height)? size = null, bool fresh = false, uint warmup = 4)
    {
        var (width, height) = size ?? (320, 180);
        editor.Link.Send(new SetMode(EditorMode.Edit));
        // A fresh run begins in the poll that loads the scene, before any frame has streamed what it shows.
        if (fresh)
        {
            editor.Link.Send(Document.SceneSnapshot.ToMessage(scene, AnimationScene));
        }
        else
        {
            await Load(editor, scene, guid: AnimationScene);
        }
        editor.Skipped.Clear();
        editor.Link.Send(new RenderOutBegin(ticket, Convert.FromHexString(IntroCutscene), "intro", rangeStart, frames, rate, width, height,
            RenderOutFormat.Png, 0, warmup, folder, "{name}.{frame}.png", false));
        var ended = await editor.Next<RenderOutEnded>(e => e.Ticket == ticket);
        Assert.True(ended.Outcome == RenderOutOutcome.Done, $"{ended.Outcome}: {ended.Reason}");

        var drawn = editor.Skipped.OfType<RenderOutFrame>().Where(f => f.Ticket == ticket).ToList();
        var written = editor.Skipped.OfType<RenderOutWritten>().Where(w => w.Ticket == ticket).OrderBy(w => w.Frame).ToList();
        Assert.All(written, w => Assert.True(w.Ok, w.Reason));
        // The editor gives the world back as Stop does.
        editor.Link.Send(new SetMode(EditorMode.Edit));
        await Load(editor, scene, guid: AnimationScene);
        return new RenderRun(drawn, written, ended);
    }
}
