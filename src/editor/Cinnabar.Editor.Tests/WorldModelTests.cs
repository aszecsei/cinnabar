using System.Buffers.Binary;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Tests;

public class WorldModelTests
{
    static ulong Handle(uint index, uint generation = 1) => (ulong)generation << 32 | index;

    static EntityInfo Info(ulong entity, ulong parent = 0, bool active = true, string name = "", ulong sceneId = 0, params ulong[] components) =>
        new(entity, name, sceneId, parent, active, components);

    static WorldModel Snapshot(params EntityInfo[] entities)
    {
        var world = new WorldModel();
        world.Apply(new EntitySnapshot(entities));
        return world;
    }

    [Fact]
    public void ASnapshotBuildsTheHierarchyInHandleOrder()
    {
        var world = Snapshot(Info(Handle(5)), Info(Handle(2), parent: Handle(5)), Info(Handle(1), parent: Handle(5)), Info(Handle(3)));

        Assert.True(world.HasWorld);
        Assert.Equal([Handle(3), Handle(5)], world.Roots.Select(n => n.Handle));
        Assert.Equal([Handle(1), Handle(2)], world.Find(Handle(5))!.Children.Select(n => n.Handle));
    }

    [Fact]
    public void ADeltaReparentsAddsAndRemoves()
    {
        var world = Snapshot(Info(Handle(1)), Info(Handle(2)), Info(Handle(3), parent: Handle(1)));
        var changes = 0;
        world.EntitiesChanged += () => changes++;

        world.Apply(new EntityDelta([Info(Handle(3), parent: Handle(2)), Info(Handle(4), active: false)], [Handle(1)]));

        Assert.Equal(1, changes);
        Assert.Null(world.Find(Handle(1)));
        Assert.Equal([Handle(3)], world.Find(Handle(2))!.Children.Select(n => n.Handle));
        Assert.False(world.Find(Handle(4))!.Active);
    }

    [Fact]
    public void AnEntityWhoseParentIsUnknownIsARoot()
    {
        var world = Snapshot(Info(Handle(1), parent: Handle(9)));

        Assert.Equal([Handle(1)], world.Roots.Select(n => n.Handle));
    }

    [Fact]
    public void ACycleDoesNotHideEntities()
    {
        var world = Snapshot(Info(Handle(1), parent: Handle(2)), Info(Handle(2), parent: Handle(1)));

        var all = new List<EntityNode>();
        void Walk(EntityNode n)
        {
            all.Add(n);
            n.Children.ToList().ForEach(Walk);
        }
        world.Roots.ToList().ForEach(Walk);
        Assert.Equal(2, all.Count);
    }

    [Fact]
    public void ASlotReusedByANewGenerationIsANewEntity()
    {
        var world = Snapshot(Info(Handle(1, generation: 1)));

        world.Apply(new EntityDelta([Info(Handle(1, generation: 2))], [Handle(1, generation: 1)]));

        Assert.Null(world.Find(Handle(1, generation: 1)));
        Assert.NotNull(world.Find(Handle(1, generation: 2)));
        Assert.Equal("Entity(1:2)", world.Find(Handle(1, generation: 2))!.ToString());
    }

    [Fact]
    public void ValuesOfAnUnknownEntityAreIgnoredAndDestroyedOnesForgotten()
    {
        var world = Snapshot(Info(Handle(1)));
        world.Apply(new EntityValues(Handle(1), [], []));
        world.Apply(new EntityValues(Handle(7), [], []));

        Assert.NotNull(world.Values(Handle(1)));
        Assert.Null(world.Values(Handle(7)));
        world.Apply(new EntityDelta([], [Handle(1)]));
        Assert.Null(world.Values(Handle(1)));
    }

    [Fact]
    public void ClearForgetsEverything()
    {
        var world = Snapshot(Info(Handle(1)));
        world.Apply(new ComponentTypes([new ComponentType(1, "Transform", 48, [])]));

        world.Clear();

        Assert.False(world.HasWorld);
        Assert.Empty(world.Entities);
        Assert.Empty(world.Types);
        Assert.Equal("0x0000000000000001", world.TypeName(1));
    }

    static FieldInfo Field(FieldKind kind, uint offset = 0, FieldKind enumBase = FieldKind.U8, params EnumValue[] values) =>
        new("f", offset, kind, enumBase, values, false, false, 0, 0, "");

    [Fact]
    public void FieldsDecodeEachKind()
    {
        var data = new byte[64];
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(0), 1.5f);
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(4), -2f);
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(8), 0.700034f);
        BinaryPrimitives.WriteInt64LittleEndian(data.AsSpan(16), 3_000L << 24);
        BinaryPrimitives.WriteUInt64LittleEndian(data.AsSpan(40), Handle(3, 2));
        data[48] = 5;
        data[49] = 1;
        BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(52), -70000);

        Assert.Equal("1.5", FieldValues.Format(Field(FieldKind.F32), data));
        var vector = FieldValues.Display(Field(FieldKind.Vector3), data);
        Assert.Equal(DisplayKind.Axes, vector.Kind);
        Assert.Equal(["1.5", "-2", "0.7"], vector.Axes);
        var position = FieldValues.Display(Field(FieldKind.Position, 16), data);
        Assert.Equal(["3,000 m", "0 m", "0 m"], position.Axes);
        Assert.Contains("(3,000, 0, 0)", position.Tooltip);
        Assert.Equal("Entity(3:2)", FieldValues.Format(Field(FieldKind.Entity, 40), data));
        Assert.Equal(Handle(3, 2), FieldValues.Display(Field(FieldKind.Entity, 40), data).Entity);
        Assert.Equal("Very Busy", FieldValues.Format(Field(FieldKind.Enum, 48, FieldKind.U8, new EnumValue("Idle", 0), new EnumValue("Very_Busy", 5)), data));
        Assert.True(FieldValues.Display(Field(FieldKind.Bool, 49), data).Flag);
        Assert.Equal("-70,000", FieldValues.Format(Field(FieldKind.I32, 52), data));

        // An asset field's 16 bytes are its GUID, and zero is none.
        var asset = new byte[16];
        Assert.Equal(DisplayKind.Asset, FieldValues.Display(Field(FieldKind.Asset), asset).Kind);
        Assert.Equal("", FieldValues.Display(Field(FieldKind.Asset), asset).Text);
        asset[0] = 0x9d;
        Assert.Equal("9d" + new string('0', 30), FieldValues.Display(Field(FieldKind.Asset), asset).Text);
        Assert.Equal("none", FieldValues.Format(Field(FieldKind.Entity, 56), data));
    }

    [Fact]
    public void ARotationShowsAsEulerAnglesWithTheQuaternionInItsTooltip()
    {
        var q = FieldValues.Quaternion(0, 0, 90);
        var data = new byte[16];
        for (var i = 0; i < 4; i++)
        {
            BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(i * 4), (float)q[i]);
        }

        var display = FieldValues.Display(Field(FieldKind.Quaternion), data);

        Assert.Equal(["0°", "0°", "90°"], display.Axes);
        Assert.Contains("Quaternion: (0, 0, 0.707, 0.707)", display.Tooltip);
    }

    [Theory]
    [InlineData(0, 0, 0)]
    [InlineData(30, 0, 0)]
    [InlineData(0, 45, 0)]
    [InlineData(0, 0, -120)]
    [InlineData(20, -135, 60)]
    [InlineData(-89, 10, 170)]
    [InlineData(10, 180, -30)]
    public void EulerAnglesRoundTripThroughAQuaternion(double x, double y, double z)
    {
        var q = FieldValues.Quaternion(x, y, z);
        var euler = FieldValues.Euler(q[0], q[1], q[2], q[3]);

        Assert.Equal(x, euler[0], 3);
        Assert.Equal(y, euler[1], 3);
        Assert.Equal(z, euler[2], 3);
    }

    [Fact]
    public void AtGimbalLockZIsZeroAndTheRotationIsKept()
    {
        var q = FieldValues.Quaternion(90, 30, 20);
        var euler = FieldValues.Euler(q[0], q[1], q[2], q[3]);
        var again = FieldValues.Quaternion(euler[0], euler[1], euler[2]);

        Assert.Equal(0, euler[2], 6);
        // The same rotation: q and -q are equal, so compare the absolute dot product.
        Assert.Equal(1, Math.Abs(q.Zip(again, (a, b) => a * b).Sum()), 4);
    }

    [Theory]
    [InlineData("Previous_Transform", "Previous Transform")]
    [InlineData("inner.amount", "Inner › Amount")]
    [InlineData("layout_hash", "Layout Hash")]
    [InlineData("speed", "Speed")]
    public void NamesAreHumanized(string name, string expected) => Assert.Equal(expected, FieldValues.Humanize(name));

    [Theory]
    [InlineData(0.6, "0.6 m")]
    [InlineData(9_999, "9,999 m")]
    [InlineData(12_500, "12.5 km")]
    [InlineData(-150_000_000_000, "-150 Gm")]
    public void DistancesScaleTheirUnit(double meters, string expected) => Assert.Equal(expected, FieldValues.Distance(meters));

    [Theory]
    [InlineData(-0.0001, "0")]
    [InlineData(1234567.891, "1,234,567.891")]
    [InlineData(0.700034, "0.7")]
    public void NumbersReadCleanly(double value, string expected) => Assert.Equal(expected, FieldValues.Number(value));

    [Fact]
    public void AFieldPastTheEndOfItsComponentIsNull() =>
        Assert.Null(FieldValues.Format(Field(FieldKind.Quaternion, 8), new byte[16]));

    [Fact]
    public void AnUnnamedEnumValueShowsItsNumber() =>
        Assert.Equal("3", FieldValues.Format(Field(FieldKind.Enum, 0, FieldKind.U8, new EnumValue("Idle", 0)), [3]));
}
