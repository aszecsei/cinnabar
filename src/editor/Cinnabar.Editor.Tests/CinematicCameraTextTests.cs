using System.Buffers.Binary;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;

namespace Cinnabar.Editor.Tests;

public sealed class CinematicCameraTextTests
{
    // Cinematic_Camera's fields, at their offsets.
    static readonly FieldInfo[] Fields =
    [
        Field("focal_length", 0, FieldKind.F32),
        Field("sensor_width", 4, FieldKind.F32),
        Field("sensor_height", 8, FieldKind.F32),
        Field("focus_distance", 12, FieldKind.F32),
        Field("aperture", 16, FieldKind.F32),
        Field("focus", 24, FieldKind.Entity),
    ];

    static FieldInfo Field(string name, uint offset, FieldKind kind) =>
        new(name, offset, kind, kind, [], false, false, 0, 0, false, false, 0, "");

    static byte[] Lens(float focal = 0, float width = 0, float height = 0, float focus = 0, float aperture = 0, ulong entity = 0)
    {
        var data = new byte[32];
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(0), focal);
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(4), width);
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(8), height);
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(12), focus);
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(16), aperture);
        BinaryPrimitives.WriteUInt64LittleEndian(data.AsSpan(24), entity);
        return data;
    }

    [Fact]
    public void A_lens_shows_its_field_of_view_and_aspect()
    {
        Assert.Equal("A 50 mm lens on a 36 × 24 mm sensor (Full frame): 27° vertical, 1.5:1. No depth of field: the aperture is 0.",
            CinematicCameraText.Describe(Fields, Lens(focal: 50, width: 36, height: 24)));
        Assert.Equal("A 35 mm lens on a 24.89 × 18.66 mm sensor (Super 35): 29.9° vertical, 1.33:1. f/2.8, focused at 3 m.",
            CinematicCameraText.Describe(Fields, Lens(focal: 35, width: 24.89f, height: 18.66f, focus: 3, aperture: 2.8f)));
    }

    [Fact]
    public void Zeros_take_the_defaults_and_a_focus_entity_shows()
    {
        Assert.Equal("A 35 mm lens on a 36 × 24 mm sensor (Full frame): 37.8° vertical, 1.5:1. f/1.4, focused on the focus entity.",
            CinematicCameraText.Describe(Fields, Lens(aperture: 1.4f, focus: 3, entity: 7)));
        Assert.Equal("A 35 mm lens on a 36 × 24 mm sensor (Full frame): 37.8° vertical, 1.5:1. f/2, focused at 10 m.",
            CinematicCameraText.Describe(Fields, Lens(aperture: 2)));
        Assert.Null(CinematicCameraText.Describe([], []));
    }

    [Fact]
    public void A_sensor_is_named_by_its_preset()
    {
        Assert.Equal("Super 16", CinematicCameraText.SensorName(12.52, 7.41));
        Assert.Equal("Full frame", CinematicCameraText.SensorName(0, 0));
        Assert.Null(CinematicCameraText.SensorName(30, 20));
        Assert.Equal((24.89f, 18.66f), ((float, float))CinematicCameraText.Sensor(Fields, Lens(width: 24.89f, height: 18.66f)));
    }
}
