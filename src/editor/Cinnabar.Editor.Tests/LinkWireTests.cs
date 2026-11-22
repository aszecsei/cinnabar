using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Generator;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tests;

public class LinkWireTests
{
    public static TheoryData<ILinkMessage> Messages() =>
    [
        new Hello(0x1234_5678_9abc_def0, "cinnabar editor"),
        new Welcome(1, "mygame", ulong.MaxValue),
        new Refused("versions differ", 2),
        new Log(LogLevel.Warning, -5, "host.odin:12:main()", "ünïcode"),
        new GameReloaded(ReloadKind.SoftRestart),
        new GameSize(1920, -1),
        new OpenViewport(2, ViewportKind.Game, 640, 360),
        new ViewportTarget(2, "cinnabar.viewport2.g3", 3, 640, 360),
        new ViewportAcknowledged(2, 3, 1UL << 40),
        new CaptureSource(-1),
        new CutscenePreviewTime(3, 1000),
        new CutscenePreviewPlay(3, 1000, -2, true, 500, 90000),
        new CutscenePreviewClose(3),
        new CutscenePreviewOpened(3, 12000, 0, 600000),
        new CutscenePreviewEnded(4, CutscenePreviewEndReason.CodeReloaded),
        new CutscenePreviewTick(3, 1001, true),
    ];

    [Theory]
    [MemberData(nameof(Messages))]
    public void EveryMessageRoundTrips(ILinkMessage message)
    {
        var frame = LinkFrame.Encode(message, request: 7);
        var header = LinkFrame.ReadHeader(frame);

        Assert.Equal((uint)(frame.Length - LinkFrame.HeaderSize), header.Length);
        Assert.Equal(message.MessageKind, header.Kind);
        Assert.Equal(7u, header.Request);
        Assert.Equal(message, LinkFrame.Decode(header.Kind, frame.AsSpan(LinkFrame.HeaderSize), LinkMessages.Read));
    }

    [Fact]
    public void ACutscenePreviewsSettingsRoundTripWithTheirSilentTracks()
    {
        var message = new CutscenePreviewSettings(3, false, true, [4, 1_000_001]);
        var frame = LinkFrame.Encode(message);
        var header = LinkFrame.ReadHeader(frame);
        var read = Assert.IsType<CutscenePreviewSettings>(LinkFrame.Decode(header.Kind, frame.AsSpan(LinkFrame.HeaderSize), LinkMessages.Read));
        Assert.Equal((3UL, false, true), (read.Ticket, read.ScrubSound, read.Events));
        Assert.Equal([4u, 1_000_001u], read.Silent);

        byte[] guid = [1, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9];
        frame = LinkFrame.Encode(new CutscenePreviewOpen(3, guid, true, 12000));
        header = LinkFrame.ReadHeader(frame);
        var open = Assert.IsType<CutscenePreviewOpen>(LinkFrame.Decode(header.Kind, frame.AsSpan(LinkFrame.HeaderSize), LinkMessages.Read));
        Assert.Equal((3UL, true, 12000), (open.Ticket, open.Unsaved, open.Tick));
        Assert.Equal(guid, open.Cutscene);
    }

    [Fact]
    public void AnEntitysValuesRoundTripWithWhatTheWorldShows()
    {
        var message = new EntityValues(9, [new ComponentValue(1, [1, 2, 3])], [], [new HeldField(1, 7)],
            [new ComponentValue(1, [4, 5, 6])], new ShownPreview(3, 1200, 1_700_000_000_000_000_000));
        var frame = LinkFrame.Encode(message);
        var header = LinkFrame.ReadHeader(frame);
        var read = Assert.IsType<EntityValues>(LinkFrame.Decode(header.Kind, frame.AsSpan(LinkFrame.HeaderSize), LinkMessages.Read));

        Assert.Equal([1, 2, 3], Assert.Single(read.Components).Data);
        Assert.Equal(new HeldField(1, 7), Assert.Single(read.Held));
        Assert.Equal([4, 5, 6], Assert.Single(read.Shown).Data);
        Assert.Equal(new ShownPreview(3, 1200, 1_700_000_000_000_000_000), read.ShownPreview);
    }

    [Fact]
    public void ANavProbeRoundTrips()
    {
        var message = new NavProbe([new NavProbePoint([1, -2, 1L << 40]), new NavProbePoint([0, 0, 3])]);
        var frame = LinkFrame.Encode(message);
        var header = LinkFrame.ReadHeader(frame);

        var back = Assert.IsType<NavProbe>(LinkFrame.Decode(header.Kind, frame.AsSpan(LinkFrame.HeaderSize), LinkMessages.Read));

        Assert.Equal(message.Points.Select(p => p.Position), back.Points.Select(p => p.Position));
    }

    [Fact]
    public void ALoadSceneRoundTripsItsGuid()
    {
        byte[] guid = [.. Enumerable.Range(1, 16).Select(i => (byte)i)];
        var frame = LinkFrame.Encode(new LoadScene([new LoadedScene(2, [], guid, 0, "")], 7));
        var header = LinkFrame.ReadHeader(frame);

        var back = Assert.IsType<LoadScene>(LinkFrame.Decode(header.Kind, frame.AsSpan(LinkFrame.HeaderSize), LinkMessages.Read));

        var scene = Assert.Single(back.Scenes);
        Assert.Equal(2u, scene.Scene);
        Assert.Equal(guid, scene.Guid);
        Assert.Empty(scene.Entities);
        Assert.Equal(7UL, back.Ticket);
    }

    [Fact]
    public void TheBytesMatchTheOdinEncoding()
    {
        // Game_Size{width = 3, height = 0x01020304} as lib/engine/editor/link writes it.
        var frame = LinkFrame.Encode(new GameSize(3, 0x01020304));

        Assert.Equal(
            [8, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 4, 3, 2, 1],
            frame);
    }

    [Fact]
    public void AShortOrLongPayloadIsRefused()
    {
        var payload = LinkFrame.Encode(new Hello(1, "editor")).AsSpan(LinkFrame.HeaderSize).ToArray();

        Assert.Throws<LinkProtocolException>(() => LinkFrame.Decode(Hello.KindId, payload[..^1], LinkMessages.Read));
        Assert.Throws<LinkProtocolException>(() => LinkFrame.Decode(Hello.KindId, [.. payload, 0], LinkMessages.Read));
    }

    [Fact]
    public void AnUnknownKindIsRefused() =>
        Assert.Throws<LinkProtocolException>(() => LinkFrame.Decode(200, [], LinkMessages.Read));

    [Fact]
    public void AStringLongerThanThePayloadIsRefused() =>
        Assert.Throws<LinkProtocolException>(() => LinkFrame.Decode(Refused.KindId, [0, 0, 0, 0x40], LinkMessages.Read));

    [Fact]
    public void AHeaderWithAHugePayloadIsRefused() =>
        Assert.Throws<LinkProtocolException>(() => LinkFrame.ReadHeader([0xff, 0xff, 0xff, 0xff, 1, 0, 0, 0, 0, 0, 0, 0]));

    [Fact]
    public void ABoolOtherThanZeroOrOneIsRefused()
    {
        var reader = new LinkReader([2]);
        try
        {
            reader.ReadBool();
            Assert.Fail("read 2 as a bool");
        }
        catch (LinkProtocolException)
        {
        }
    }

    [Fact]
    public void TheGeneratorHandlesStructsSlicesAndFixedArrays()
    {
        const string schema = """
            {
              "version": "00000000000000ff",
              "messages": [
                {"kind": 1, "name": "Entity_List", "fields": [{"name": "entities", "type": "[]Entity_Info"}, {"name": "bounds", "type": "[3]f32"}]}
              ],
              "structs": [
                {"name": "Entity_Info", "fields": [{"name": "id", "type": "u64"}, {"name": "kind", "type": "Entity_Kind"}]},
                {"name": "Blob", "fields": [{"name": "data", "type": "[]u8"}]}
              ],
              "enums": [
                {"name": "Entity_Kind", "type": "u16", "values": [{"name": "Plain", "value": 0}, {"name": "Prefab_Root", "value": 7}]}
              ]
            }
            """;

        var code = SchemaCode.Generate(schema);

        Assert.Contains("public enum EntityKind : ushort", code);
        Assert.Contains("PrefabRoot = 7,", code);
        Assert.Contains("public sealed partial record EntityList(EntityInfo[] Entities, float[] Bounds)", code);
        Assert.Contains("public sealed partial record EntityInfo(ulong Id, EntityKind Kind)", code);
        Assert.Contains("reader.ReadSlice(static (ref global::Cinnabar.Editor.Link.LinkReader r0) => EntityInfo.Read(ref r0))", code);
        Assert.Contains("reader.ReadFixed(3, static (ref global::Cinnabar.Editor.Link.LinkReader r0) => r0.ReadF32())", code);
        Assert.Contains("writer.WriteU16((ushort)Kind)", code);
        Assert.Contains("public sealed partial record Blob(byte[] Data)", code);
        Assert.Contains("reader.ReadBytes()", code);
        Assert.Contains("ProtocolVersion = 0x00000000000000ffUL", code);
    }

    [Fact]
    public void TheGeneratorRefusesAFieldNamedLikeItsType() =>
        Assert.Throws<FormatException>(() => SchemaCode.Generate("""
            {"version": "1", "messages": [{"kind": 1, "name": "Size", "fields": [{"name": "size", "type": "u32"}]}], "structs": [], "enums": []}
            """));

    [Theory]
    [InlineData("Viewport_Target", "ViewportTarget")]
    [InlineData("layout_hash", "LayoutHash")]
    [InlineData("Soft_Restart", "SoftRestart")]
    [InlineData("game", "Game")]
    public void NamesBecomePascalCase(string odin, string csharp) => Assert.Equal(csharp, SchemaCode.Pascal(odin));
}
