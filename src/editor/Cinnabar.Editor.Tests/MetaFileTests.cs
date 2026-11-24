using System.Text.RegularExpressions;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tests;

/// <summary><see cref="MetaFile"/> against the rules of the engine's <c>meta_text</c> and <c>meta_parse</c>, and their tests' cases.</summary>
public sealed class MetaFileTests : IDisposable
{
    const string Guid = "00112233445566778899aabbccddeeff";
    const string Other = "ffeeddccbbaa99887766554433221100";

    readonly TempDirectory _temp = new("meta-file");

    public void Dispose() => _temp.Dispose();

    [Fact]
    public void TheHeaderIsTheEngines()
    {
        var source = File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "lib", "engine", "asset", "format", "format.odin"));
        var header = Regex.Match(source, @"^META_HEADER :: ""(.*)""\r?$", RegexOptions.Multiline);
        Assert.True(header.Success, "format.odin has no META_HEADER line");
        Assert.Equal(MetaFile.Header, header.Groups[1].Value);
    }

    [Fact]
    public void TheBuilderWritesAsMetaTextDoes()
    {
        // The case of meta_files_group_settings_in_sections: each section after the top-level lines, in the order that
        // the settings first name it.
        var text = MetaFile.New(Guid.ToUpperInvariant())
            .Set("sampler.wrap", "clamp")
            .Set("usage", "mask")
            .Set("mip_map.kernel", "box")
            .Set("sampler.filter", "nearest")
            .Text();

        Assert.Equal(
            MetaFile.Header + "\n" +
            $"guid = {Guid}\nusage = mask\n\n[sampler]\nwrap = clamp\nfilter = nearest\n\n[mip_map]\nkernel = box\n",
            text);
        var again = MetaFile.Parse(text);
        Assert.NotNull(again);
        Assert.Equal(4, again.Settings.Count);
        Assert.Equal(text, again.Text());
    }

    [Fact]
    public void ANewFileWithNoSettingsIsItsHeaderAndGuid() =>
        Assert.Equal($"{MetaFile.Header}\nguid = {Guid}\n", MetaFile.New(Guid).Text());

    [Theory]
    [InlineData("guid")]
    [InlineData("mip map.kernel")]
    [InlineData("sampler.guid")]
    [InlineData("sampler.")]
    [InlineData("")]
    public void TheBuilderRefusesAKeyThatWouldNotParse(string key) =>
        Assert.Throws<ArgumentException>(() => MetaFile.New(Guid).Set(key, "x"));

    [Fact]
    public void TheBuilderRefusesAGuidThatIsNotOne() =>
        Assert.Throws<ArgumentException>(() => MetaFile.New("not-a-guid"));

    [Fact]
    public void SettingsAreGroupedInSections()
    {
        var meta = MetaFile.Parse(
            $"# a comment\r\nguid = {Guid.ToUpperInvariant()}\r\nusage = mask\nmesh.door = {Other}\n\n[mip_map]\nkernel = box\n[sampler]\n wrap = clamp \n");

        Assert.NotNull(meta);
        Assert.Equal(Guid, meta.Guid);
        Assert.Equal(3, meta.Settings.Count);
        Assert.Equal("mask", meta.Setting("usage"));
        Assert.Equal("box", meta.Setting("mip_map.kernel"));
        Assert.Equal("clamp", meta.Setting("sampler.wrap"));
        Assert.Null(meta.Setting("wrap"));
        Assert.Equal(new MetaSubasset("mesh", "door", Other), Assert.Single(meta.Subassets));
        Assert.Equal(Other, meta.SubassetGuid("mesh.door"));
        Assert.Null(meta.SubassetGuid("texture.door"));
    }

    [Theory]
    // The cases of meta_files_hold_a_guid_and_settings, meta_files_name_their_subassets and
    // meta_files_group_settings_in_sections: no guid, a line without '=', a sub-asset without a GUID, and a guid or a
    // sub-asset in a section, a section's name that is not an identifier, and a section without its bracket or a name.
    [InlineData("native = true\n")]
    [InlineData($"guid {Guid}\n")]
    [InlineData($"guid = {Guid}\nmesh.door = 12\n")]
    [InlineData($"guid = {Guid}\n[sampler]\nmesh.door = {Other}\n")]
    [InlineData($"guid = {Guid}\n[sampler]\nguid = {Other}\n")]
    [InlineData($"guid = {Guid}\n[mip map]\nkernel = box\n")]
    [InlineData($"guid = {Guid}\n[sampler\nwrap = clamp\n")]
    [InlineData($"guid = {Guid}\n[]\nwrap = clamp\n")]
    [InlineData("guid = 00112233-4455-6677-8899-aabbccddeeff\n")]
    public void AFileThatMetaParseRefusesDoesNotParse(string text) => Assert.Null(MetaFile.Parse(text));

    [Fact]
    public void AGuidInASectionIsNotTheAssets()
    {
        // The old reader, ProjectSettings.Get, knew no sections, so the last guid line won. meta_parse refuses the file,
        // so the daemon gives the asset no GUID from it, and the editor finds nothing by either GUID.
        var path = _temp.Combine("door.prefab");
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(path, "");
        File.WriteAllText(path + MetaFile.Extension, $"guid = {Guid}\n\n[sampler]\nguid = {Other}\n");

        Assert.Null(MetaFile.TryRead(path + MetaFile.Extension));
        Assert.Null(ProjectLayout.FindAsset(_temp.Path, Other));
        Assert.Null(ProjectLayout.FindAsset(_temp.Path, Guid));
    }

    [Fact]
    public void FindAssetReadsTheTopLevelGuid()
    {
        var path = _temp.Combine("textures", "stone.png");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "");
        File.WriteAllText(path + MetaFile.Extension, MetaFile.New(Guid).Set("sampler.wrap", "clamp").Text());

        Assert.Equal(path, ProjectLayout.FindAsset(_temp.Path, Guid.ToUpperInvariant()));
        Assert.Null(ProjectLayout.FindAsset(_temp.Path, Other));
    }

    [Fact]
    public void AMissingFileReadsAsNone() => Assert.Null(MetaFile.TryRead(_temp.Combine("none.png.meta")));
}
