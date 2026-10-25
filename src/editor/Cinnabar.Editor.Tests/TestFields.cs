using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tests;

/// <summary>Field infos as the game sends them, with only what a test cares about given.</summary>
static class TestFields
{
    public static FieldInfo Of(FieldKind kind, uint offset = 0, FieldKind enumBase = FieldKind.U8, EnumValue[]? values = null,
        string name = "f", bool readOnly = false, (double Min, double Max)? range = null, bool color = false) =>
        new(name, offset, kind, enumBase, values ?? [], readOnly, range != null, range?.Min ?? 0, range?.Max ?? 0, color, "");
}
