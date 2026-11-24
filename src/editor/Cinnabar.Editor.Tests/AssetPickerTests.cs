using Cinnabar.Editor.AnimationGraphs;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Materials;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.UiDocuments;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The asset pickers of the graph and UI editors, which are the properties panel's <see cref="AssetView"/> over each
/// document's own encoding (see docs/editor/shell-and-panels.md#properties).
/// </summary>
public sealed class AssetPickerTests
{
    const string Function = "0123456789abcdef0123456789abcdef";
    const string Caller = "fedcba9876543210fedcba9876543210";
    const string Texture = "aaaabbbbccccddddeeeeffff00001111";
    const string Walk = "22223333444455556666777788889999";
    const string Gone = "99998888777766665555444433332222";

    static AssetIndex Index()
    {
        var index = new AssetIndex();
        index.Apply(new AssetSnapshot(
        [
            TestAssets.Make(Function, AssetKind.MaterialFunction, "blend.material_function"),
            TestAssets.Make(Caller, AssetKind.MaterialFunction, "mix.material_function"),
            TestAssets.Make(Texture, AssetKind.Texture, "rock.png"),
            TestAssets.Make(Walk, AssetKind.Animation, "walk.anim"),
        ], []));
        return index;
    }

    static string Shown(AssetContext assets, string value) => assets.Describe(value).Text;

    [Fact]
    public void AFunctionNodeTakesAnyFunctionButItsOwn()
    {
        // The drop goes through Takes, so a function cannot be dropped onto its own call either.
        var index = Index();
        var functions = new AssetContext(index, "material_function", _ => { }) { Exclude = a => a.Guid == Caller };
        Assert.Equal([Function], functions.Choices.Select(a => a.Guid));
        Assert.False(functions.Takes(index.Find(Caller)!));
        Assert.False(functions.Takes(index.Find(Texture)!));
    }

    [Fact]
    public void AMissingAssetShowsTheSameWayInEveryPicker()
    {
        var index = Index();
        Assert.Equal("Missing asset", Shown(new AssetContext(index, "material_function", _ => { }), NodeDetails.FunctionShown(new GraphAsset(Gone))));
        Assert.Equal("Missing asset", Shown(new AssetContext(index, "texture", _ => { }) { Builtins = ["white"] }, ParametersPanel.TextureShown("$" + Gone)));
        Assert.Equal("Missing asset", Shown(new AssetContext(index, "animation", _ => { }), AnimationGraphPanel.ClipShown(Gone)));
        Assert.Equal("Missing asset", Shown(new AssetContext(index, "font", _ => { }), UiDetails.AssetShown("$" + Gone)));
    }

    [Fact]
    public void EachPickerShowsItsAssetAndItsNone()
    {
        var index = Index();
        Assert.Equal("rock.png", Shown(new AssetContext(index, "texture", _ => { }), UiDetails.AssetShown("$" + Texture)));
        Assert.Equal("None", Shown(new AssetContext(index, "texture", _ => { }), UiDetails.AssetShown("")));
        Assert.Equal("walk.anim", Shown(new AssetContext(index, "animation", _ => { }), AnimationGraphPanel.ClipShown(Walk)));
        // A new clip names the all-zero GUID, which is none rather than a missing animation.
        Assert.Equal("None", Shown(new AssetContext(index, "animation", _ => { }), AnimationGraphPanel.ClipShown(new string('0', 32))));
        Assert.Equal("None", Shown(new AssetContext(index, "material_function", _ => { }), NodeDetails.FunctionShown(null)));
    }

    [Fact]
    public void AMaterialTextureKeepsItsBuiltInsThroughARoundTrip()
    {
        var textures = new AssetContext(Index(), "texture", _ => { }) { Builtins = ["white", "black", "normal"], Clearable = false };
        foreach (var builtin in new[] { "white", "black", "normal" })
        {
            Assert.Equal(builtin, Shown(textures, ParametersPanel.TextureShown(builtin)));
            Assert.Equal(builtin, ParametersPanel.TextureStored(ParametersPanel.TextureShown(builtin)));
        }
        Assert.Equal("rock.png", Shown(textures, ParametersPanel.TextureShown("$" + Texture)));
        Assert.Equal("$" + Texture, ParametersPanel.TextureStored(ParametersPanel.TextureShown("$" + Texture)));
    }

    [Fact]
    public void EachPickerWritesItsDocumentsEncoding()
    {
        Assert.Equal(new GraphAsset(Function), NodeDetails.FunctionStored(NodeDetails.FunctionShown(new GraphAsset(Function))));
        Assert.Null(NodeDetails.FunctionStored(""));
        Assert.Equal(Walk, AnimationGraphPanel.ClipStored(AnimationGraphPanel.ClipShown(Walk)));
        Assert.Equal(new string('0', 32), AnimationGraphPanel.ClipStored(""));
        Assert.Equal("$" + Texture, UiDetails.AssetStored(UiDetails.AssetShown("$" + Texture)));
        Assert.Null(UiDetails.AssetStored(""));
    }
}
