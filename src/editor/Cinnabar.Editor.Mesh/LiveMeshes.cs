using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Mesh;

/// <summary>
/// A mesh as the live mesh messages carry it (see docs/editor/mesh-editing.md#live-meshes): the file's structure, which
/// the game bakes with the same bake as the cooker. The editor sends the whole mesh when its topology or mappings
/// change, and only the positions for a drag's step.
/// </summary>
public static class LiveMeshes
{
    public static Wire.LiveMesh Mesh(string guid, MeshData mesh) => new(
        Convert.FromHexString(guid),
        [.. mesh.Materials.Select((material, slot) => (material, slot)).Where(m => m.material.Length > 0)
            .Select(m => new Wire.LiveMaterial((uint)m.slot, Convert.FromHexString(m.material)))],
        Positions(mesh),
        [.. mesh.Faces.Select(f => new Wire.LiveFace((uint)f.Slot, [.. f.Corners.Select(c => (uint)c)], Mapping(f.Mapping)))],
        [.. mesh.SharpEdges.Select(e => new Wire.LiveEdge((uint)e.A, (uint)e.B))]);

    public static Wire.LiveMeshVertices Vertices(string guid, MeshData mesh) => new(Convert.FromHexString(guid), Positions(mesh));

    public static Wire.ReleaseLiveMesh Release(string guid) => new(Convert.FromHexString(guid));

    /// <summary>
    /// Whether a change from one snapshot to another moved vertices only, so a <see cref="Vertices"/> message carries
    /// it: the faces, the sharp edges and the materials are the same arrays, and the vertex count is the same.
    /// </summary>
    public static bool IsVerticesOnly(MeshData before, MeshData after) =>
        before.Faces == after.Faces && before.SharpEdges == after.SharpEdges && before.Materials == after.Materials
        && before.Vertices.Length == after.Vertices.Length;

    static float[] Positions(MeshData mesh)
    {
        var positions = new float[mesh.Vertices.Length * 3];
        for (var i = 0; i < mesh.Vertices.Length; i++)
        {
            var v = mesh.Vertices[i];
            (positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]) = ((float)v.X, (float)v.Y, (float)v.Z);
        }
        return positions;
    }

    static Wire.LiveMapping Mapping(Mapping m) => new(
        [(float)m.UAxis.X, (float)m.UAxis.Y, (float)m.UAxis.Z],
        [(float)m.VAxis.X, (float)m.VAxis.Y, (float)m.VAxis.Z],
        [(float)m.ScaleU, (float)m.ScaleV],
        [(float)m.ShiftU, (float)m.ShiftV],
        (float)m.Rotation);
}
