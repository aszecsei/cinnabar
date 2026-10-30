using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Tools;
using AssetKind = Cinnabar.Editor.Link.Cook.AssetKind;
using GizmoKind = Cinnabar.Editor.Link.Protocol.GizmoKind;
using GizmoPart = Cinnabar.Editor.Link.Protocol.GizmoPart;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The Create tool's drag on the grid plane: the footprint of a block, where it ends as a primitive, and the names and material
/// of the meshes it makes.
/// </summary>
public sealed partial class MeshSession
{
    /// <summary>Starts a primitive: a drag on the grid plane from a pixel, which becomes its footprint.</summary>
    public bool BeginBlock(Vec2 pixel)
    {
        if (!_shell.IsEditing || _shell.Scene == null || MeshTool != MeshTool.Create)
        {
            return false;
        }
        Tools.CommitPendingDistance();
        var (origin, axis) = GridPlane();
        if (PointOnGrid(pixel, origin, axis) is not { } start)
        {
            return false;
        }
        _blockDrag = new BlockDrag(origin, axis, start, start);
        OnMeshModeChanged();
        return true;
    }

    public void DragBlock(Vec2 pixel)
    {
        if (_blockDrag is not { } drag || PointOnGrid(pixel, drag.Origin, drag.Axis) is not { } corner)
        {
            return;
        }
        _blockDrag = drag with { Corner = corner };
        OnMeshModeChanged();
    }

    /// <summary>Ends a Block drag: a new mesh and entity with the footprint, a grid cell high, or faces of the primary edited mesh.</summary>
    public void EndBlock(bool forceEntity = false)
    {
        if (_blockDrag is not { } drag)
        {
            return;
        }
        _blockDrag = null;
        var size = Vec3.Between(drag.Start, drag.Corner);
        if (size.Length < GridSize * 0.5)
        {
            OnMeshModeChanged();
            return;
        }
        // The block's height is a grid cell along the plane's axis, from the plane.
        var up = MeshGrid.AxisVector(drag.Axis) * GridSize;
        var min = new Vec3(Math.Min(size.X, 0), Math.Min(size.Y, 0), Math.Min(size.Z, 0));
        var max = new Vec3(Math.Max(size.X, 0), Math.Max(size.Y, 0), Math.Max(size.Z, 0)) + up;
        var corner = min.Offset(drag.Start);
        var primary = InMeshMode && !forceEntity ? _editedMeshes.Keys.FirstOrDefault(g => FindMeshData(g) != null && PlacementOf(g) != null) : null;
        Tools.MakePrimitive(corner, max - min, drag.Axis, primary);
    }

    public void CancelBlock()
    {
        if (_blockDrag != null)
        {
            _blockDrag = null;
            OnMeshModeChanged();
        }
    }

    /// <summary>The block being dragged: its footprint's corners as raw positions, or null.</summary>
    public (long[] Start, long[] Corner)? BlockFootprint => _blockDrag is { } d ? (d.Start, d.Corner) : null;

    internal long[]? PointOnGrid(Vec2 pixel, long[] origin, int axis)
    {
        var (width, height) = _shell.FrameSize;
        var ray = _shell.Camera.Ray(pixel, width, height);
        if (MeshGrid.HitPlane(_shell.Camera.RelativeTo(origin), MeshGrid.AxisVector(axis), ray) is not { } hit)
        {
            return null;
        }
        return SnapToGrid(hit);
    }

    // A name that no entity of the scene and no open mesh has: block, block_2 and on.
    internal string NewMeshName(string stem)
    {
        for (var n = 1; ; n++)
        {
            var name = n == 1 ? stem : $"{stem}_{n}";
            if (_shell.Scene!.Expanded.Flat.Entities.All(e => e.Name != name) && Meshes.Documents.All(d => Path.GetFileNameWithoutExtension(d.Path) != name))
            {
                return name;
            }
        }
    }

    /// <summary>The project's default mesh material, for new faces: <c>mesh.default_material</c>, or the engine's dev_gray.</summary>
    public string DefaultMeshMaterial =>
        ProjectSettings.Get(_shell.ProjectPath, "mesh.default_material") is { Length: 32 } guid && guid.All(Uri.IsHexDigit) ? guid.ToLowerInvariant() : DevGrayMaterial;

    /// <summary>The engine's dev_gray material instance (see docs/editor/mesh-editing.md#dev-materials).</summary>
    public const string DevGrayMaterial = "5a1c3e7f9b2d4f608a1c3e5f7a9b0c2d";

    // The dragged block's footprint: the grid plane and the two snapped corners.
    readonly record struct BlockDrag(long[] Origin, int Axis, long[] Start, long[] Corner);
}

/// <summary>
/// Adds a new mesh document to the set, as Block does for a new mesh, on the scene's undo stack beside the entity
/// that places it. Undo removes the document; a file it was saved to meanwhile stays, unreferenced.
/// </summary>
public sealed record CreateMesh(MeshDocument Document, MeshSet Meshes) : Operation(0)
{
    public override Operation Apply(Scene scene)
    {
        Meshes.Add(Document);
        return new RemoveMesh(Document, Meshes);
    }

    public override Wire.Operation? ToWire() => null;
}

public sealed record RemoveMesh(MeshDocument Document, MeshSet Meshes) : Operation(0)
{
    public override Operation Apply(Scene scene)
    {
        Meshes.Remove(Document.Guid);
        return new CreateMesh(Document, Meshes);
    }

    public override Wire.Operation? ToWire() => null;
}
