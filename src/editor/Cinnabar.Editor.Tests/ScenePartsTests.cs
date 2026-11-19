using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// A scene's sublevels as scenes of the game's world: the base and a part of each sublevel, each with its number, and
/// the operations that name their entity's part (see docs/editor/document-and-scenes.md#parts).
/// </summary>
public sealed class ScenePartsTests : IDisposable
{
    // A lamp in the night that refers to the crate in the base, its bulb, the crate, and a moth at dusk.
    const string Room = """
        scene 4

        entity 0000000000000001
        name = "Lamp"
        sublevel = "night"
        component 1001 Spin
        	target = @0000000000000003

        entity 0000000000000002
        name = "Bulb"
        parent = @0000000000000001

        entity 0000000000000003
        name = "Crate"

        entity 0000000000000006
        name = "Moth"
        sublevel = "dusk"

        """;

    const string BaseGuid = "a1b2c3d4e5f60718293a4b5c6d7e8f90";
    const string NightGuid = "0e93f03e879752587cdb44aedc183e15";
    const string DuskGuid = "5f0a1c2d3e4b4a6c8d7e9f0a1b2c3d4e";

    readonly TempDirectory _temp = new("scene-parts");
    readonly List<ILinkMessage> _sent = [];

    public void Dispose() => _temp.Dispose();

    // A shell on room.scene, whose .meta file has the scene's GUID and its sublevels', linked to a fake game.
    EditorShell Open()
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("room.scene.meta"), $"guid = {BaseGuid}\nsublevel.dusk = {DuskGuid}\nsublevel.night = {NightGuid}\n");
        var shell = TestShell.Open(_temp, "room.scene", Room.ReplaceLineEndings("\n"));
        shell.Host.LinkForTests(_sent.Add);
        Assert.NotNull(shell.Scene);
        return shell;
    }

    List<Link.Protocol.Operation> Sent() => [.. _sent.OfType<ApplyOperations>().SelectMany(a => a.Operations)];

    static string Hex(byte[] bytes) => bytes.All(b => b == 0) ? "" : Convert.ToHexStringLower(bytes);

    // The last Load_Scene's scene of a sublevel, "" for the base.
    LoadedScene PartOf(string sublevel) => _sent.OfType<LoadScene>().Last().Scenes.Single(s => s.Sublevel == sublevel);

    [Fact]
    public void AScenesBaseAndEachSublevelAreScenesOfTheGamesWorld()
    {
        using var shell = Open();
        var number = shell.Scene!.Number;

        var load = Assert.Single(_sent.OfType<LoadScene>());
        Assert.Equal(["", "dusk", "night"], load.Scenes.Select(s => s.Sublevel));
        var (base_, dusk, night) = (PartOf(""), PartOf("dusk"), PartOf("night"));
        Assert.Equal(number, base_.Scene);
        Assert.Equal(0u, base_.Base);
        Assert.Equal(BaseGuid, Hex(base_.Guid));
        Assert.Equal([number, number], new[] { dusk.Base, night.Base });
        Assert.Equal(DuskGuid, Hex(dusk.Guid));
        Assert.Equal(NightGuid, Hex(night.Guid));
        Assert.Equal(3, load.Scenes.Select(s => s.Scene).Distinct().Count());
        Assert.Equal(["Crate"], base_.Entities.Select(e => e.Name));
        Assert.Equal(["Lamp", "Bulb"], night.Entities.Select(e => e.Name));

        // The lamp's reference to the crate crosses parts, so it names the base's GUID, as the cooker writes it.
        var target = night.Entities[0].Components.Single(c => c.Id == 1001).Fields.Single().Value;
        Assert.Equal(3UL, target.Entity);
        Assert.Equal(BaseGuid, Hex(target.Scene));
    }

    [Fact]
    public void AnEditNamesThePartOfItsEntity()
    {
        using var shell = Open();
        var night = PartOf("night").Scene;
        _sent.Clear();

        Assert.True(shell.Edit("Rename", new Rename(2, "Night Bulb")));
        Assert.True(shell.Edit("Rename", new Rename(3, "Box")));

        Assert.Equal([night, shell.Scene!.Number], Sent().Select(o => o.Scene));
    }

    [Fact]
    public void SetSublevelMovesAnEntityAndUndoPutsItBack()
    {
        using var shell = Open();
        var document = shell.Scene!;
        var night = PartOf("night").Scene;
        _sent.Clear();

        Assert.True(shell.SetSublevel(1, ""));
        Assert.Null(document.Scene.Find(1)!.Sublevel);
        var sent = Sent();
        var move = sent[0];
        Assert.Equal(OperationKind.SetSublevel, move.Kind);
        Assert.Equal((night, 1UL, document.Number, ""), (move.Scene, move.Entity, move.Target, move.Sublevel));
        // The lamp's reference to the crate is in one part now, so it goes again as a local one.
        var field = Assert.Single(sent, o => o.Kind == OperationKind.SetField);
        Assert.Equal(document.Number, field.Scene);
        Assert.Equal("", Hex(field.Fields.Single().Value.Scene));
        Assert.Empty(_sent.OfType<AddScene>());

        // Undo puts the lamp, and its bulb, back in the night, whose part the game loads again with a new number.
        _sent.Clear();
        document.Undo();
        Assert.Equal("night", document.Scene.Find(1)!.Sublevel);
        var back = Sent()[0];
        Assert.Equal(OperationKind.SetSublevel, back.Kind);
        Assert.Equal(document.Number, back.Scene);
        Assert.Equal("night", back.Sublevel);
        Assert.Equal(NightGuid, Hex(back.Guid));
        Assert.NotEqual(night, back.Target);
        Assert.NotEqual(document.Number, back.Target);

        // An edit of the bulb names the new part.
        _sent.Clear();
        shell.Edit("Rename", new Rename(2, "Night Bulb"));
        Assert.Equal(back.Target, Assert.Single(Sent()).Scene);
    }

    [Fact]
    public void ANewParentInAnotherSublevelTakesTheEntityThere()
    {
        using var shell = Open();
        var document = shell.Scene!;
        var night = PartOf("night").Scene;
        _sent.Clear();

        Assert.True(shell.Reparent(3, 1));

        var sent = Sent();
        Assert.Equal(OperationKind.SetSublevel, sent[0].Kind);
        Assert.Equal((document.Number, 3UL, night), (sent[0].Scene, sent[0].Entity, sent[0].Target));
        var parent = Assert.Single(sent, o => o.Kind == OperationKind.SetParent);
        Assert.Equal(night, parent.Scene);
        Assert.Equal("night", document.Scene.SublevelOf(document.Scene.Find(3)!));
    }

    [Fact]
    public void WhatTheGameReportsOfAPartIsTheScenes()
    {
        using var shell = Open();
        var document = shell.Scene!;
        var night = PartOf("night").Scene;

        shell.OnGameMessage(new EntitySnapshot(
        [
            new EntityInfo(1UL << 32 | 1, "Lamp", 1, night, 0, true, []),
            new EntityInfo(1UL << 32 | 3, "Crate", 3, document.Number, 0, true, []),
        ]));
        shell.OnGameMessage(new EditProblems(false, [new EditProblem(night, 1, "no such field")]));

        Assert.Equal(document.Number, shell.World.FindScene(document.Number, 1)!.Scene);
        Assert.Same(document, shell.SceneOf(shell.World.FindScene(document.Number, 1)!));
        Assert.Equal(["no such field"], shell.ProblemsOf(1));
    }

    [Fact]
    public void LoadingASublevelSendsOnlyItsParts()
    {
        using var shell = Open();
        var document = shell.Scene!;
        var dusk = PartOf("dusk").Scene;
        _sent.Clear();

        shell.SetSublevelLoaded("dusk", false);
        Assert.Equal(dusk, Assert.Single(_sent.OfType<RemoveScene>()).Scene);
        Assert.False(shell.IsSublevelLoaded("dusk"));

        // The moth's edit stays in the document, and the game, which has no dusk, does not get it.
        _sent.Clear();
        shell.Edit("Rename", new Rename(6, "Owl"));
        Assert.Empty(Sent());

        shell.SetSublevelLoaded("dusk", true);
        var added = Assert.Single(_sent.OfType<AddScene>()).Scene;
        Assert.Equal(("dusk", document.Number), (added.Sublevel, added.Base));
        Assert.NotEqual(dusk, added.Scene);
        Assert.Equal(["Owl"], added.Entities.Select(e => e.Name));
        Assert.Empty(_sent.OfType<LoadScene>());
    }

    [Fact]
    public void AChildCannotBeInASublevelApartFromItsParent()
    {
        using var shell = Open();
        var document = shell.Scene!;
        Assert.False(shell.SetSublevel(2, "dusk"));
        Assert.Null(document.Scene.Find(2)!.Sublevel);
    }
}
