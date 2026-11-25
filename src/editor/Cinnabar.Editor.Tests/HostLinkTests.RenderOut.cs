using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tests;

// Render out on the real host (see docs/editor/cutscene-editor.md#render-out): the game plays the sample's intro out of
// real time, and the host writes its frames. These drive the link as the editor's run does: a Render_Out_Begin in
// Edit, and after Render_Out_Ended, Edit and the scene again.
public sealed partial class HostLinkTests
{
    // The first run streams and compiles from cold, and the second finds everything resident, so they wait for
    // different numbers of draws; the frames are the same to the bit.
    [Fact]
    public async Task TenFramesRenderTheSameTwice()
    {
        SkipWithoutTheFox();
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<Welcome>();
        var scene = AnimationSceneFile();
        var root = Path.Combine(Environment.GetEnvironmentVariable("CINNABAR_KEEP_RENDERS") ?? Path.GetTempPath(), $"cinnabar-render-{Guid.NewGuid():N}");
        try
        {
            var cold = await RenderOut(editor, scene, 1, Path.Combine(root, "cold"), frames: 10);
            var warm = await RenderOut(editor, scene, 2, Path.Combine(root, "warm"), frames: 10);
            Assert.Equal(10, cold.Written.Count);
            Assert.Equal(10, warm.Written.Count);
            for (var i = 0; i < 10; i++)
            {
                var a = File.ReadAllBytes(cold.Written[i].Path);
                var b = File.ReadAllBytes(warm.Written[i].Path);
                Assert.True(a.AsSpan().SequenceEqual(b), $"frame {i} differs between the runs");
            }
            // The frames are at the rate's exact ticks, and the first waited for what it shows.
            Assert.Equal(Enumerable.Range(0, 10).Select(n => n * 2000), cold.Frames.Select(f => f.Tick));
            Assert.True(cold.Frames[0].SettleDraws >= 3);
            Assert.DoesNotContain(editor.Skipped, m => m is Log { Level: LogLevel.Error });
        }
        finally
        {
            if (Directory.Exists(root) && Environment.GetEnvironmentVariable("CINNABAR_KEEP_RENDERS") == null)
            {
                Directory.Delete(root, true);
            }
        }
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
