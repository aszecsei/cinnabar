using System.Buffers.Binary;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;

namespace Cinnabar.Editor.Tests;

public sealed class CameraLensTextTests
{
    // Camera's fields that the text reads, at offsets of their own.
    static readonly FieldInfo[] Fields =
    [
        Field("vertical_fov", 0, FieldKind.F32),
        Field("projection", 4, FieldKind.Enum),
        Field("focal_length", 8, FieldKind.F32),
        Field("sensor_height", 12, FieldKind.F32),
        Field("aperture", 16, FieldKind.F32),
        Field("focus_distance", 20, FieldKind.F32),
        Field("focus", 24, FieldKind.Entity),
    ];

    static FieldInfo Field(string name, uint offset, FieldKind kind) =>
        new(name, offset, kind, kind == FieldKind.Enum ? FieldKind.U8 : kind, [], false, false, 0, 0, false, false, 0, "");

    static byte[] Camera(float fov = 0, byte projection = 0, float focal = 0, float sensor = 0, float aperture = 0, float focus = 0, ulong entity = 0)
    {
        var data = new byte[32];
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(0), fov);
        data[4] = projection;
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(8), focal);
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(12), sensor);
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(16), aperture);
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(20), focus);
        BinaryPrimitives.WriteUInt64LittleEndian(data.AsSpan(24), entity);
        return data;
    }

    [Fact]
    public void A_focal_length_shows_its_field_of_view()
    {
        Assert.Equal("A 50 mm lens on a 24 mm sensor: 27° vertical. No depth of field: the aperture is 0.",
            CameraLensText.Describe(Fields, Camera(fov: 1, focal: 50)));
        Assert.Equal("A 35 mm lens on a 15.6 mm sensor: 25.1° vertical. f/2.8, focused at 3 m.",
            CameraLensText.Describe(Fields, Camera(focal: 35, sensor: 15.6f, aperture: 2.8f, focus: 3)));
    }

    [Fact]
    public void A_field_of_view_shows_its_focal_length()
    {
        Assert.Equal("60° vertical: a 20.8 mm lens on a 24 mm sensor. f/1.4, focused on the focus entity.",
            CameraLensText.Describe(Fields, Camera(aperture: 1.4f, focus: 3, entity: 7)));
        Assert.Equal("Orthographic: no lens, and no depth of field.", CameraLensText.Describe(Fields, Camera(projection: 1)));
        Assert.Null(CameraLensText.Describe([], []));
    }
}
