using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Document;

/// <summary>
/// The scene as a <c>Load_Scene</c> message, which replaces the host's world (see docs/editor.md#document-model). The
/// editor sends it when the link connects, after a soft restart, and when it opens a scene. Operations use the same
/// conversions for their parts, and the game's commands the ones back from the wire.
/// </summary>
public static class SceneSnapshot
{
    public static Wire.LoadScene ToMessage(Scene scene) => new([.. scene.Entities.Select(Entity)]);

    public static Wire.SceneEntity Entity(SceneEntity e) => new(
        e.Id,
        e.Name,
        e.Parent,
        e.Active,
        [.. e.Components.Select(Component)],
        [.. e.Behaviours.Select(b => new Wire.SceneBehaviour(Convert.FromHexString(b.Script), [.. b.Fields.Select(Field)]))]);

    public static Wire.SceneComponent Component(SceneComponent c) => new(c.Id, c.Name, [.. c.Fields.Select(Field)]);

    public static Wire.SceneField Field(SceneField f) => new(f.Name, Value(f.Value));

    public static SceneEntity FromWire(Wire.SceneEntity e)
    {
        var entity = new SceneEntity(e.Id) { Name = e.Name, Parent = e.Parent, Active = e.Active };
        entity.Components.AddRange(e.Components.Select(FromWire));
        entity.Behaviours.AddRange(e.Behaviours.Select(b => new SceneBehaviour(Convert.ToHexStringLower(b.Script), [.. b.Fields.Select(FromWire)])));
        return entity;
    }

    public static SceneComponent FromWire(Wire.SceneComponent c) => new(c.Id, c.Name, [.. c.Fields.Select(FromWire)]);

    public static SceneField FromWire(Wire.SceneField f) => new(f.Name, FromWire(f.Value));

    public static SceneValue FromWire(Wire.SceneValue v) => v.Kind switch
    {
        Wire.SceneValueKind.Bool => SceneValue.Of(v.Ints[0] != 0),
        Wire.SceneValueKind.String => SceneValue.String(v.Text),
        Wire.SceneValueKind.Name => SceneValue.Name(v.Text),
        Wire.SceneValueKind.Entity => SceneValue.EntityRef(v.Entity),
        Wire.SceneValueKind.Asset => SceneValue.AssetRef(v.Asset.All(b => b == 0) ? "" : Convert.ToHexStringLower(v.Asset)),
        _ => SceneValue.Of([.. Enumerable.Range(0, Math.Min((int)v.Count, 4))
            .Select(i => (v.Integer & (1 << i)) != 0 ? SceneNumber.Of(v.Ints[i]) : SceneNumber.Of(v.Floats[i]))]),
    };

    public static Wire.SceneValue Value(SceneValue v)
    {
        var ints = new long[4];
        var floats = new double[4];
        byte integer = 0;
        for (var i = 0; i < v.Numbers.Count; i++)
        {
            var n = v.Numbers[i];
            floats[i] = n.Float;
            if (n.Integer is { } exact)
            {
                // A u64 beyond a long's range goes with its bits, as the game reads it.
                ints[i] = exact > long.MaxValue ? (long)(ulong)exact : (long)exact;
                integer |= (byte)(1 << i);
            }
        }
        if (v.Kind == SceneValueKind.Bool)
        {
            ints[0] = v.Bool ? 1 : 0;
        }
        return new Wire.SceneValue(
            (Wire.SceneValueKind)v.Kind,
            (byte)v.Numbers.Count,
            integer,
            ints,
            floats,
            v.Text,
            v.Entity,
            v.Asset == "" ? new byte[16] : Convert.FromHexString(v.Asset));
    }
}
