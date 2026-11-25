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

    async Task<RenderRun> RenderOut(Editor editor, Document.Scene scene, ulong ticket, string folder, int frames, uint rate = 30,
        int rangeStart = 0)
    {
        editor.Link.Send(new SetMode(EditorMode.Edit));
        await Load(editor, scene, guid: AnimationScene);
        editor.Skipped.Clear();
        editor.Link.Send(new RenderOutBegin(ticket, Convert.FromHexString(IntroCutscene), "intro", rangeStart, frames, rate, 320, 180,
            RenderOutFormat.Png, 0, 4, folder, "{name}.{frame}.png", false));
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
