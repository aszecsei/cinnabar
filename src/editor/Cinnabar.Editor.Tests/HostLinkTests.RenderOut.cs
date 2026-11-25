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
