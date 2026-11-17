using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>The Add Component picker's folders and search (see docs/editor/shell-and-panels.md#properties).</summary>
public sealed class CatalogTests
{
    static readonly CatalogItem[] Items =
    [
        new("point", "Point Light", "Lighting"),
        new("spot", "Spot Light", "Lighting"),
        new("hinge", "Hinge Joint", "Physics/Joints"),
        new("body", "Rigid Body", "Physics"),
        new("spin", "Spin", "mygame"),
        new("odd", "Odd One", ""),
    ];

    [Fact]
    public void ACategoryReadsAsATitleAndNoneIsOther()
    {
        Assert.Equal("Mygame", Catalog.Normalize("mygame"));
        Assert.Equal("Physics/Joints", Catalog.Normalize(" Physics / Joints "));
        Assert.Equal("AI", Catalog.Normalize("AI"));
        Assert.Equal(Catalog.Uncategorized, Catalog.Normalize(""));
        Assert.Equal(Catalog.Uncategorized, Catalog.Normalize("//"));
    }

    [Fact]
    public void WithoutAQueryTheFoldersShowClosedInOrderWithOtherLast()
    {
        var rows = Catalog.Rows(Items, "", _ => false);

        Assert.All(rows, r => Assert.True(r.IsFolder));
        Assert.Equal(["Lighting", "Mygame", "Physics", "Other"], rows.Select(r => r.Label));
    }

    [Fact]
    public void AnOpenFolderHasItsItemsAndThenTheFoldersUnderIt()
    {
        var rows = Catalog.Rows(Items, "", folder => folder is "Physics" or "Physics/Joints");

        var physics = rows.SkipWhile(r => r.Label != "Physics").TakeWhile(r => r.Label != "Other").ToList();
        Assert.Equal(["Physics", "Rigid Body", "Joints", "Hinge Joint"], physics.Select(r => r.Label));
        Assert.Equal([0, 1, 1, 2], physics.Select(r => r.Depth));
        Assert.Equal("Physics/Joints", physics[2].Folder);
        Assert.Equal("hinge", physics[3].Item!.Id);
    }

    [Fact]
    public void AQueryFindsItemsByLabelOrFolderBestFirst()
    {
        var rows = Catalog.Rows(Items, "light", _ => false);
        Assert.Equal(["Point Light", "Spot Light"], rows.Select(r => r.Label));
        Assert.All(rows, r => Assert.False(r.IsFolder));

        // A label that starts with the query comes before one that only has it, and a folder's name finds its items.
        Assert.Equal("Spin", Catalog.Rows(Items, "sp", _ => false)[0].Label);
        Assert.Equal(["Hinge Joint"], Catalog.Rows(Items, "joints", _ => false).Select(r => r.Label));
        Assert.Equal(["Hinge Joint"], Catalog.Rows(Items, "physics hinge", _ => false).Select(r => r.Label));
        Assert.Empty(Catalog.Rows(Items, "nothing", _ => false));
    }

    [Fact]
    public void TheEnginesOwnComponentsAreNotOffered()
    {
        ComponentType[] types =
        [
            new(35, "Point_Light", "Lighting", 32, []),
            new(66, "Physics_Body", ComponentCatalog.NoCategory, 64, []),
            new(1001, "Spin", "mygame", 4, []),
        ];

        var items = ComponentCatalog.Components(types).ToList();

        Assert.Equal(["Point Light", "Spin"], items.Select(i => i.Label));
        Assert.Equal(35UL, ComponentCatalog.ComponentOf(items[0]));
        Assert.Null(ComponentCatalog.ScriptOf(items[0]));
        Assert.Equal("mygame", items[1].Category);
    }

    [Fact]
    public void ABehaviourIsInItsScriptsFolderUnderBehaviours()
    {
        Assert.Equal("Behaviours", ComponentCatalog.BehaviourFolder("scripts/door.luau"));
        Assert.Equal("Behaviours/ai", ComponentCatalog.BehaviourFolder("scripts/ai/guard.luau"));
        Assert.Equal("Behaviours/gameplay/doors", ComponentCatalog.BehaviourFolder("gameplay/doors/door.luau"));
        Assert.Equal("Behaviours", ComponentCatalog.BehaviourFolder("door.luau"));

        var script = TestAssets.Make("0123456789abcdef0123456789abcdef", AssetKind.Script, "scripts/ai/guard.luau", behaviour: "Guard_Bark");
        var item = Assert.Single(ComponentCatalog.Behaviours([script]));
        Assert.Equal("Guard Bark", item.Label);
        Assert.Equal("0123456789abcdef0123456789abcdef", ComponentCatalog.ScriptOf(item));
        Assert.Null(ComponentCatalog.ComponentOf(item));
        // The picker shows the folder as a title, under the engine's folders' icons or the script's.
        Assert.Equal(["Behaviours", "Ai", "Guard Bark"], Catalog.Rows([item], "").Select(r => r.Label));
        Assert.Equal("script", ComponentCatalog.FolderIcon("Behaviours/Ai"));
        Assert.Equal("folder", ComponentCatalog.FolderIcon("Mygame"));
    }

    [Fact]
    public void ABehaviourWithACategoryIsInThatFolder()
    {
        var ring = TestAssets.Make("0123456789abcdef0123456789abcdef", AssetKind.Script, "scripts/ring.luau", behaviour: "Ring", category: "Tools/Layout", editMode: true);
        var hidden = TestAssets.Make("fedcba9876543210fedcba9876543210", AssetKind.Script, "scripts/helper.luau", behaviour: "Helper", category: ComponentCatalog.NoCategory);
        var item = Assert.Single(ComponentCatalog.Behaviours([ring, hidden]));
        Assert.Equal("Tools/Layout", item.Category);
        Assert.Equal("scripts/ring.luau", item.Detail?[(item.Detail.IndexOf('/') + 1)..]);
        Assert.Equal(["Tools", "Layout", "Ring"], Catalog.Rows([item], "").Select(r => r.Label));
    }

    [Fact]
    public void AnEntitysIconIsItsMostTellingComponents()
    {
        Assert.Equal("camera", EntityIcons.For(["Transform", "Camera", "Audio_Listener", "Behaviours"]));
        Assert.Equal("decision", EntityIcons.For(["Transform", "Character", "Nav_Agent", "Agent", "Mesh_Renderer"]));
        Assert.Equal("nav-path", EntityIcons.For(["Transform", "Volume", "Nav_Mesh_Volume"]));
        Assert.Equal("light-point", EntityIcons.For(["Transform", "Point_Light"]));
        Assert.Equal("script", EntityIcons.For(["Transform", "Behaviours"]));
        Assert.Null(EntityIcons.For(["Transform", "Spin"]));
    }

    [Fact]
    public void TheOutlinerKeepsASceneEntityCollapsedAcrossANewHandle()
    {
        var state = new OutlinerState();
        var world = new Model.WorldModel();
        world.Apply(new EntitySnapshot([new EntityInfo(1UL << 32, "Room", 7, 1, 0, true, []), new EntityInfo(2UL << 32, "Spawned", 0, 0, 0, true, [])]));
        state.Toggle(world.Find(1UL << 32)!);
        state.Toggle(world.Find(2UL << 32)!);
        Assert.True(state.IsCollapsed(world.Find(1UL << 32)!));
        Assert.True(state.IsCollapsed(world.Find(2UL << 32)!));

        // A resync, as Stop makes, gives every entity a new handle.
        world.Apply(new EntitySnapshot([new EntityInfo(5UL << 32, "Room", 7, 1, 0, true, []), new EntityInfo(6UL << 32, "Spawned", 0, 0, 0, true, [])]));

        Assert.True(state.IsCollapsed(world.Find(5UL << 32)!));
        Assert.False(state.IsCollapsed(world.Find(6UL << 32)!));
        state.Toggle(world.Find(5UL << 32)!);
        Assert.False(state.IsCollapsed(world.Find(5UL << 32)!));
    }
}
