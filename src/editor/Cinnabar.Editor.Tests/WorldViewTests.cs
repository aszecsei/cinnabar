using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;
using Asset = Cinnabar.Editor.Link.Cook.Asset;

namespace Cinnabar.Editor.Tests;

/// <summary>What the editor sends the game to draw of the shown world, and how the preview and Play change it (see docs/editor/world-view.md).</summary>
public sealed class WorldViewTests : IDisposable
{
    const long Anchor = 150000000000;

    readonly TempDirectory _temp = new("world-view");
    readonly List<ILinkMessage> _sent = [];

    public void Dispose() => _temp.Dispose();

    // A linked shell whose main scene has the streamer.
    (EditorShell Shell, Asset World) Open(bool streamer = true)
    {
        var (shell, world) = WorldFixture.Open(_temp, streamer);
        shell.Host.LinkForTests(_sent.Add);
        return (shell, world);
    }

    WorldView Latest() => _sent.OfType<WorldView>().Last();

    static byte[] Bytes(string guid) => Convert.FromHexString(guid);

    // A position of x meters along the world's x axis.
    static long[] At(double x) => [(long)(x * (1 << 24)), 0, 0];

    [Fact]
    public void AStreamerSendsTheWorldsScenesWithTheActiveSceneMarked()
    {
        var (shell, _) = Open();
        using var _ = shell;
        var view = Assert.Single(_sent.OfType<WorldView>());
        Assert.Equal(5, view.Scenes.Length);
        Assert.True(view.Scenes[0].Persistent);
        Assert.Equal([(Anchor + 20) << 24, -5L << 24, -25L << 24], view.Scenes[1].Min);
        Assert.Equal([(Anchor + 60) << 24, 30L << 24, 25L << 24], view.Scenes[1].Max);
        Assert.Equal(25, view.Scenes[1].LoadDistance);
        Assert.Equal(40, view.Scenes[1].UnloadDistance);
        Assert.All(view.Scenes, s => Assert.False(s.Active || s.Previewed || s.Loaded));
        Assert.Empty(view.Preview);

        // The scene that edits is marked, and nothing else is sent while nothing else changes.
        Assert.True(shell.AddScene(_temp.Combine("tile1.scene")));
        Assert.Equal([2], Latest().Scenes.Select((s, i) => (s, i)).Where(x => x.s.Active).Select(x => x.i));
        var count = _sent.OfType<WorldView>().Count();
        shell.ActivateScene(shell.Scenes[0]);
        Assert.Equal(count + 1, _sent.OfType<WorldView>().Count());
        Assert.DoesNotContain(Latest().Scenes, s => s.Active);
        shell.ActivateScene(shell.Scenes[0]);
        Assert.Equal(count + 1, _sent.OfType<WorldView>().Count());
    }

    [Fact]
    public void ASceneWithoutAStreamerSendsNothingAndAnEditorWorldIsShownInItsPlace()
    {
        var (shell, world) = Open(streamer: false);
        using var _ = shell;
        Assert.Empty(_sent.OfType<WorldView>());
        shell.OpenWorld(world);
        Assert.Equal(5, Latest().Scenes.Length);
        // Closing the editor leaves no world.
        shell.CloseGraph(shell.Worlds[0], discard: true);
        Assert.Empty(Latest().Scenes);
    }

    [Fact]
    public void TheWorldEditorsUnsavedEditsAreWhatTheViewShows()
    {
        var (shell, world) = Open();
        using var _ = shell;
        var editor = shell.OpenWorld(world)!;
        // The world is the same as the file's, so nothing changes yet.
        Assert.Single(_sent.OfType<WorldView>());

        editor.SetBounds(WorldFixture.Tiles[0], [Anchor + 20, -5, -25], [Anchor + 70, 30, 25]);
        Assert.Equal(2, _sent.OfType<WorldView>().Count());
        Assert.Equal((Anchor + 70) << 24, Latest().Scenes[1].Max[0]);
        editor.Document.Undo();
        Assert.Equal((Anchor + 60) << 24, Latest().Scenes[1].Max[0]);

        // A World editor is shown over the streamer's world, and the streamer's world comes back when it closes.
        editor.RemoveScene(WorldFixture.Tiles[3]);
        Assert.Equal(4, Latest().Scenes.Length);
        shell.CloseGraph(editor, discard: true);
        Assert.Equal(5, Latest().Scenes.Length);
    }

    [Fact]
    public void ACameraMoveThatKeepsThePreviewedScenesSendsNothing()
    {
        var (shell, _) = Open();
        using var _ = shell;
        shell.Camera.Place(At(Anchor + 62), 0, 0);
        shell.SetPreview(new WorldPreview.FollowCamera());
        Assert.Equal([true, true, true, false, false], Latest().Scenes.Select(s => s.Previewed));
        // The camera is its own mark.
        Assert.Empty(Latest().Preview);

        var count = _sent.OfType<WorldView>().Count();
        shell.Camera.Place(At(Anchor + 64), 0, 0);
        shell.Camera.Place(At(Anchor + 61), 0, 0);
        Assert.Equal(count, _sent.OfType<WorldView>().Count());

        // Past the load distance of the first tile, which ends 60 m out, the previewed set changes.
        shell.Camera.Place(At(Anchor + 90), 0, 0);
        Assert.Equal([true, false, true, true, false], Latest().Scenes.Select(s => s.Previewed));
        shell.SetPreview(new WorldPreview.Off());
        Assert.DoesNotContain(Latest().Scenes, s => s.Previewed);
    }

    [Fact]
    public void APinMarksTheSceneAndTheTilesWithinTheLoadDistance()
    {
        var (shell, _) = Open();
        using var _ = shell;
        shell.Camera.Place(At(Anchor + 62), 0, 0);
        Assert.True(shell.PinPreview());
        shell.Camera.Place(At(0), 0, 0);

        // The persistent scene, the tile that holds the pin and the tile 2 m from it. The tile 38 m away is out.
        Assert.Equal([true, true, true, false, false], Latest().Scenes.Take(5).Select(s => s.Previewed));
        Assert.Equal([[(Anchor + 62) << 24, 0, 0]], Latest().Preview.Select(p => p.Position));
        Assert.Equal(["aae627e32417d3edb166d3ee07c5176c", WorldFixture.Tiles[0], WorldFixture.Tiles[1]],
            shell.PreviewedScenes);
    }

    [Fact]
    public void OpenPreviewedScenesOpensTheMissingAndClosesTheOutOfRange()
    {
        var (shell, _) = Open();
        using var _ = shell;
        shell.CloseSceneRequested += scene => shell.CloseScene(scene);
        Assert.True(shell.AddScene(_temp.Combine("tile3.scene")));
        Assert.True(shell.AddScene(_temp.Combine("tile0.scene")));
        var far = shell.SceneOfPath(_temp.Combine("tile3.scene"))!;
        shell.Camera.Place(At(Anchor + 62), 0, 0);
        shell.PinPreview();
        _sent.Clear();

        shell.OpenPreviewedScenes();

        // The base and the other tile open. The tile that is far from the pin closes, and the main scene stays.
        var added = _sent.OfType<AddScene>().Select(a => Convert.ToHexStringLower(a.Scene.Guid)).ToList();
        Assert.Equal(["aae627e32417d3edb166d3ee07c5176c", WorldFixture.Tiles[1]], added);
        Assert.Equal([far.Number], _sent.OfType<RemoveScene>().Select(r => r.Scene));
        Assert.Equal(["main.scene", "tile0.scene", "base.scene", "tile1.scene"], shell.Scenes.Select(s => Path.GetFileName(s.Path)));

        // The same preview has nothing more to open or close.
        _sent.Clear();
        shell.OpenPreviewedScenes();
        Assert.Empty(_sent.OfType<AddScene>());
        Assert.Empty(_sent.OfType<RemoveScene>());
    }

    [Fact]
    public void TheGamesStreamedScenesFillThePlayColumnAndTheLoadedFlagsUntilStop()
    {
        var (shell, world) = Open();
        using var _ = shell;
        var editor = shell.OpenWorld(world)!;
        shell.Camera.Place(At(Anchor + 62), 0, 0);
        shell.SetPreview(new WorldPreview.FollowCamera());
        Assert.Equal("", editor.PlayState(editor.Scenes[1]));

        shell.Play();
        // In Play the game's own scenes show, and the preview does not.
        Assert.DoesNotContain(Latest().Scenes, s => s.Previewed);
        shell.OnGameMessage(new StreamedScenes(Bytes(WorldFixture.World),
        [
            new StreamedScene(Bytes(WorldFixture.Base), 7, true),
            new StreamedScene(Bytes(WorldFixture.Tiles[0]), 8, false),
        ]));
        Assert.Equal([true, true, false, false, false], Latest().Scenes.Select(s => s.Loaded));
        Assert.Equal(["Ready", "", "Loading", ""], [editor.PlayState(editor.Scenes[0]), editor.PlayState(editor.Scenes[2]), editor.PlayState(editor.Scenes[1]), editor.PlayState(editor.Scenes[3])]);

        // Another world's scenes are not this one's.
        shell.OnGameMessage(new StreamedScenes(Bytes("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"), [new StreamedScene(Bytes(WorldFixture.Base), 7, true)]));
        Assert.DoesNotContain(Latest().Scenes, s => s.Loaded);
        Assert.Equal("", editor.PlayState(editor.Scenes[0]));
        shell.OnGameMessage(new StreamedScenes(Bytes(WorldFixture.World), [new StreamedScene(Bytes(WorldFixture.Base), 7, true)]));
        Assert.True(Latest().Scenes[0].Loaded);

        shell.Stop();
        Assert.DoesNotContain(Latest().Scenes, s => s.Loaded);
        Assert.Equal("", editor.PlayState(editor.Scenes[0]));
        // The preview shows again in Edit.
        Assert.Equal([true, true, true, false, false], Latest().Scenes.Select(s => s.Previewed));
    }

    [Fact]
    public void ANewGameStateGetsTheViewAgain()
    {
        var (shell, _) = Open();
        using var _ = shell;
        shell.Camera.Place(At(Anchor + 62), 0, 0);
        shell.PinPreview();
        var before = Latest();
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));

        var view = Assert.Single(_sent.OfType<WorldView>());
        Assert.Equal(before.Scenes.Select(s => s.Previewed), view.Scenes.Select(s => s.Previewed));
        Assert.Single(view.Preview);
    }
}
