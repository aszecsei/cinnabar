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
        new ViewportSize(1920, -1),
        new FrameTarget("cinnabar.g3", 3, 640, 360),
        new FrameAcknowledged(3, 1UL << 40),
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
    public void TheBytesMatchTheOdinEncoding()
    {
        // FrameAcknowledged{generation = 3, frame = 0x0102030405060708} as lib/engine/editor/link writes it.
        var frame = LinkFrame.Encode(new FrameAcknowledged(3, 0x0102030405060708));

        Assert.Equal(
            [12, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 8, 7, 6, 5, 4, 3, 2, 1],
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
    [InlineData("Frame_Target", "FrameTarget")]
    [InlineData("layout_hash", "LayoutHash")]
    [InlineData("Soft_Restart", "SoftRestart")]
    [InlineData("game", "Game")]
    public void NamesBecomePascalCase(string odin, string csharp) => Assert.Equal(csharp, SchemaCode.Pascal(odin));
}
