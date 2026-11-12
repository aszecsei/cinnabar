using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>A new game state, from a new link or a soft restart, gets everything that the game keeps for the editor (see docs/editor/link.md#a-new-game-state).</summary>
public sealed class GameStateTests : IDisposable
{
    readonly TempDirectory _temp = new("game-state");
    readonly List<ILinkMessage> _sent = [];

    const string SceneText = "scene 1\n\n" +
        "entity 0000000000000001\nname = \"Box\"\ncomponent 1 Transform\n\tposition = [0, 0, 83886080]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    const string MaterialGuid = "f7eadea8bd278c0ae71b61b681352a82";

    const ulong Box = 1UL << 32;

    // A shell with the scene's entity selected and a material editor's preview open, linked unless link is false.
    EditorShell NewShell(bool link = true)
    {
        var shell = TestShell.Open(_temp, "box.scene", SceneText);
        File.WriteAllText(_temp.Combine("plain.material"), "material 1\nshading = lit\n\nnode 1 output\n\tposition = [0, 0]\n");
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], MaterialTests.Nodes, []));
        shell.Assets.Apply(new ShadingModels(MaterialTests.Shading));
        shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(MaterialGuid, AssetKind.Material, "plain.material", permutations: 1)], []));
        if (link)
        {
            shell.Host.LinkForTests(_sent.Add);
        }
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(Box, "Box", 1, 0, true, [1])]));
        shell.Viewports[0].Session.Show(new Avalonia.PixelSize(1600, 900));
        shell.Selection.Select(Box);
        Assert.Equal(0, shell.OpenMaterial(shell.Assets.Find(MaterialGuid)!)!.PreviewId);
        return shell;
    }

    [Fact]
    public void ASoftRestartSendsWhatTheGameKeepsForTheEditor()
    {
        using var shell = NewShell();
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));

        // The gizmo did not change, so only a cleared cache sends it again.
        Assert.Single(_sent.OfType<GizmoState>());
        Assert.Single(_sent.OfType<LoadScene>());
        Assert.Single(_sent.OfType<EditorCamera>());
        Assert.Equal([Box], Assert.Single(_sent.OfType<SetSelection>()).Entities);
        Assert.Equal(0u, Assert.Single(_sent.OfType<SetViewportSettings>()).Viewport);
        Assert.Single(_sent.OfType<MeshOverlay>());
        Assert.Equal(0u, Assert.Single(_sent.OfType<OpenPreview>()).Id);
        Assert.Equal(0u, Assert.Single(_sent.OfType<PreviewSettings>()).Id);
    }

    [Fact]
    public void TheSceneIsSentWithItsFilesGuid()
    {
        const string guid = "0123456789abcdef0123456789abcdef";
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("box.scene.meta"), $"guid = {guid}\n");
        using var shell = TestShell.Open(_temp, "box.scene", SceneText);

        shell.Host.LinkForTests(_sent.Add);

        Assert.Equal(Convert.FromHexString(guid), Assert.Single(_sent.OfType<LoadScene>()).Guid);
    }

    [Fact]
    public void ASceneWithoutAFileGuidIsSentWithZeros()
    {
        using var shell = TestShell.Open(_temp, "box.scene", SceneText);

        shell.Host.LinkForTests(_sent.Add);

        Assert.Equal(new byte[16], Assert.Single(_sent.OfType<LoadScene>()).Guid);
    }

    [Fact]
    public void ANewLinkSendsWhatASoftRestartSends()
    {
        using var restarted = NewShell();
        _sent.Clear();
        restarted.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));
        var restart = _sent.Select(m => m.GetType().Name).ToList();
        _sent.Clear();

        using var linked = NewShell(link: false);
        Assert.Empty(_sent);
        linked.Host.LinkForTests(_sent.Add);

        Assert.Equal(restart, _sent.Select(m => m.GetType().Name));
    }

    [Fact]
    public void ACodeReloadKeepsTheGameState()
    {
        using var shell = NewShell();
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.Code));
        shell.Host.Receive(new GameReloaded(ReloadKind.Refused));

        Assert.Empty(_sent);
    }

    public void Dispose() => _temp.Dispose();
}
