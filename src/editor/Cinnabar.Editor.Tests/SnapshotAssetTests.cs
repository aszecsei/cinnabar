using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The one save path of the assets on the scene's undo stack (see docs/editor/document-and-scenes.md#document-model):
/// what the file has as one value, a new asset's <c>.meta</c>, and dirtiness that an undo to the saved snapshot clears.
/// </summary>
public sealed class SnapshotAssetTests : IDisposable
{
    const string Guid = "0123456789abcdef0123456789abcdef";

    readonly TempDirectory _temp = new("snapshot-asset");

    public void Dispose() => _temp.Dispose();

    static readonly FoliageInstance One = new(new Vec3(1, 2, 3), new Quat(0, 0, 0, 1), new Vec3(1, 1, 1));

    [Fact]
    public void ANewAssetsFirstSaveWritesItsMetaAndAnUndoToTheSavedSnapshotIsClean()
    {
        var set = new FoliageSet(Guid, _temp.Combine("grass.instances"));
        Assert.IsType<SavedSnapshot<IReadOnlyList<FoliageInstance>>.NoFile>(set.Saved);
        Assert.True(set.IsDirty);

        set.Save();
        Assert.False(set.IsDirty);
        Assert.Equal(MetaFile.New(Guid).Text(), File.ReadAllText(set.Path + MetaFile.Extension));
        Assert.Equal(InstancesFile.Write([]), File.ReadAllText(set.Path));

        var saved = set.Instances;
        set.Set([One]);
        Assert.True(set.IsDirty);
        set.Set(saved);
        Assert.False(set.IsDirty);
    }

    [Fact]
    public void AnAssetWithAFileNeverWritesAMetaAndANewOneKeepsTheMetaThatIsThere()
    {
        var path = _temp.Combine("trees.instances");
        AtomicFile.Write(path, InstancesFile.Write([One]));
        var (opened, problem) = FoliageSet.Open(Guid, path);
        Assert.Null(problem);
        opened!.Set([]);
        opened.Save();
        Assert.False(File.Exists(path + MetaFile.Extension));

        var fresh = new FoliageSet(Guid, _temp.Combine("rocks.instances"));
        File.WriteAllText(fresh.Path + MetaFile.Extension, "guid = " + Guid + "\n");
        fresh.Save();
        Assert.Equal("guid = " + Guid + "\n", File.ReadAllText(fresh.Path + MetaFile.Extension));
    }

    [Fact]
    public void ANewLandscapeMapsMetaHasItsKindsImportSettings()
    {
        var mask = new LandscapeMap(Guid, _temp.Combine("holes.png"), LandscapeMapKind.Mask, new HeightGrid(2, 2, 65535));
        mask.Save();
        var meta = MetaFile.Parse(File.ReadAllText(mask.Path + MetaFile.Extension));
        Assert.Equal("mask", meta?.Setting("usage"));
        Assert.Equal("box", meta?.Setting("mip_map.kernel"));
        Assert.False(mask.IsDirty);

        var layers = new LandscapeMap(Guid, _temp.Combine("layers.png"), LandscapeMapKind.Layers, HeightGrid.Of(2, 2, 65535, 0, 0, 0));
        layers.Save();
        Assert.Equal("data", MetaFile.Parse(File.ReadAllText(layers.Path + MetaFile.Extension))?.Setting("usage"));
    }

    [Fact]
    public void AFailedSaveLeavesTheAssetDirtyAndWithoutAFile()
    {
        var blocked = _temp.Combine("blocked.instances");
        Directory.CreateDirectory(blocked);
        var set = new FoliageSet(Guid, blocked);
        Assert.True(Record.Exception(set.Save) is IOException or UnauthorizedAccessException);
        Assert.True(set.IsDirty);
        Assert.IsType<SavedSnapshot<IReadOnlyList<FoliageInstance>>.NoFile>(set.Saved);
    }

    [Fact]
    public void ALiveAssetIsReleasedOnce()
    {
        var set = new FoliageSet(Guid, _temp.Combine("live.instances"));
        Assert.False(set.Release());
        set.Sent();
        Assert.True(set.IsLive);
        Assert.True(set.Release());
        Assert.False(set.Release());
        Assert.False(set.IsLive);
    }
}
