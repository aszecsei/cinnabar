using System.Buffers.Binary;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Tests;

public class WorldModelTests
{
    static ulong Handle(uint index, uint generation = 1) => (ulong)generation << 32 | index;

    static EntityInfo Info(ulong entity, ulong parent = 0, bool active = true, params ulong[] components) =>
        new(entity, parent, active, components);

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
        new("f", offset, kind, enumBase, values, false, false, 0, 0);

    [Fact]
    public void FieldsDecodeEachKind()
    {
        var data = new byte[64];
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(0), 1.5f);
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(4), -2f);
        BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(8), 0.25f);
        BinaryPrimitives.WriteInt64LittleEndian(data.AsSpan(16), 3L << 24);
        BinaryPrimitives.WriteUInt64LittleEndian(data.AsSpan(40), Handle(3, 2));
        data[48] = 5;
        data[49] = 1;
        BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(52), -7);

        Assert.Equal("1.5", FieldValues.Format(Field(FieldKind.F32), data));
        Assert.Equal("(1.5, -2, 0.25)", FieldValues.Format(Field(FieldKind.Vector3), data));
        Assert.Equal("(3, 0, 0) m", FieldValues.Format(Field(FieldKind.Position, 16), data));
        Assert.Equal("Entity(3:2)", FieldValues.Format(Field(FieldKind.Entity, 40), data));
        Assert.Equal(Handle(3, 2), FieldValues.Entity(Field(FieldKind.Entity, 40), data));
        Assert.Equal("Busy", FieldValues.Format(Field(FieldKind.Enum, 48, FieldKind.U8, new EnumValue("Idle", 0), new EnumValue("Busy", 5)), data));
        Assert.Equal("true", FieldValues.Format(Field(FieldKind.Bool, 49), data));
        Assert.Equal("-7", FieldValues.Format(Field(FieldKind.I32, 52), data));
        Assert.Equal("none", FieldValues.Format(Field(FieldKind.Entity, 56), data));
    }

    [Fact]
    public void AFieldPastTheEndOfItsComponentIsNull() =>
        Assert.Null(FieldValues.Format(Field(FieldKind.Quaternion, 8), new byte[16]));

    [Fact]
    public void AnUnnamedEnumValueShowsItsNumber() =>
        Assert.Equal("3", FieldValues.Format(Field(FieldKind.Enum, 0, FieldKind.U8, new EnumValue("Idle", 0)), [3]));
}
