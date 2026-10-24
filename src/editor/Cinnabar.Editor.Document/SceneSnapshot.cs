using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Document;

/// <summary>
/// The scene as a <c>Load_Scene</c> message, which replaces the host's world (see docs/editor.md#document-model). The
/// editor sends it when the link connects, after a soft restart, and when it opens a scene.
/// </summary>
public static class SceneSnapshot
{
    public static Wire.LoadScene ToMessage(Scene scene) =>
        new([.. scene.Entities.Select(e => new Wire.SceneEntity(
            e.Id,
            e.Name,
            e.Parent,
            e.Active,
            [.. e.Components.Select(c => new Wire.SceneComponent(c.Id, c.Name, Fields(c.Fields)))],
            [.. e.Behaviours.Select(b => new Wire.SceneBehaviour(Convert.FromHexString(b.Script), Fields(b.Fields)))]))]);

    static Wire.SceneField[] Fields(List<SceneField> fields) => [.. fields.Select(f => new Wire.SceneField(f.Name, Value(f.Value)))];

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
            v.Entity);
    }
}
