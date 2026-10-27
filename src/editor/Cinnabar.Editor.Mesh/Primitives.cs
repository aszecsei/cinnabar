using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>
/// The generators that new geometry starts as (see docs/editor/mesh-editing.md#primitives-and-draw): each takes its
/// parameters and gives a mesh, closed and fronting out, with a mapping on every face.
/// </summary>
public static class Primitives
{
    /// <summary>
    /// A box between two corners, in the mesh's space, as the cooker's mesh template is: six quads, clockwise seen from
    /// their fronts, world-aligned mappings at a scale, every edge sharp, and the material in slot 0.
    /// </summary>
    public static MeshData Block(Vec3 min, Vec3 max, double mappingScale = Mapping.DefaultScale, string material = "")
    {
        var (lo, hi) = (new Vec3(Math.Min(min.X, max.X), Math.Min(min.Y, max.Y), Math.Min(min.Z, max.Z)),
            new Vec3(Math.Max(min.X, max.X), Math.Max(min.Y, max.Y), Math.Max(min.Z, max.Z)));
        Vec3[] vertices =
        [
            new(lo.X, lo.Y, lo.Z), new(hi.X, lo.Y, lo.Z), new(hi.X, lo.Y, hi.Z), new(lo.X, lo.Y, hi.Z),
            new(lo.X, hi.Y, lo.Z), new(hi.X, hi.Y, lo.Z), new(hi.X, hi.Y, hi.Z), new(lo.X, hi.Y, hi.Z),
        ];
        int[][] corners = [[0, 1, 2, 3], [4, 7, 6, 5], [0, 4, 5, 1], [2, 6, 7, 3], [3, 7, 4, 0], [1, 5, 6, 2]];
        var faces = corners.Select(c => new MeshFace(0, [.. c], Mapping.WorldAligned(MeshData.FaceNormal([.. vertices], [.. c]), mappingScale)));
        MeshEdge[] sharp = [new(0, 1), new(1, 2), new(2, 3), new(3, 0), new(4, 5), new(5, 6), new(6, 7), new(7, 4), new(0, 4), new(1, 5), new(2, 6), new(3, 7)];
        return new MeshData([material], vertices, faces, sharp);
    }
}
