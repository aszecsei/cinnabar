using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Tools;
using GizmoKind = Cinnabar.Editor.Link.Protocol.GizmoKind;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The Create tool's primitives: the kind and parameters, and the primitive that fills a dragged box, made again in place
/// while its parameters change.
/// </summary>
public sealed partial class MeshToolRunner
{
    /// <summary>Picks the primitive that the Create tool makes, and turns the tool on.</summary>
    public void SetPrimitive(PrimitiveKind kind)
    {
        Primitive = kind;
        if (_session.MeshTool != MeshTool.Create)
        {
            _session.SetMeshTool(MeshTool.Create);
        }
        _session.OnMeshModeChanged();
    }

    /// <summary>
    /// Changes the primitives' parameters. The last primitive made, if it is the last edit, is made again with them in
    /// place of its undo entry, so the sides can be set after seeing the cylinder.
    /// </summary>
    public void SetPrimitiveParameters(PrimitiveParameters parameters)
    {
        PrimitiveParameters = parameters;
        if (_lastPrimitive is { } last && CanRemakePrimitive(last))
        {
            // The remake's own undo fires selection and mesh events, which must not forget the primitive.
            _remaking = true;
            try
            {
                _shell.Scene!.Undo();
                MakePrimitive(last.Corner, last.Size, last.Axis, last.Mesh);
            }
            finally
            {
                _remaking = false;
            }
        }
        _session.OnMeshModeChanged();
    }

    bool _remaking;

    // The last primitive's entry is the last edit, and nothing is open.
    bool CanRemakePrimitive(LastPrimitive last) =>
        _shell.Scene != null && !_shell.Scene.InTransaction && _shell.Scene.Position == last.Position && _shell.Scene.History.Count == last.Position;

    // The primitive filling a box, as faces of an edited mesh or as a new mesh and entity.
    internal void MakePrimitive(long[] corner, Vec3 size, int axis, string? mesh)
    {
        if (_shell.Scene == null)
        {
            return;
        }
        // The entry goes where the position is: a remake has undone the entry before, which the new one replaces.
        var position = _shell.Scene.Position;
        if (mesh != null && _session.FindMeshData(mesh) is { } data && _session.PlacementOf(mesh) is { } placement)
        {
            var made = Primitives.Make(Primitive, Vec3.Zero, size, axis, PrimitiveParameters, _session.Texture.NewFaceScale(data.Materials[0]), data.Materials[0]);
            var cornerRelative = _shell.Camera.RelativeTo(corner);
            var local = made.With(vertices: made.Vertices.Select(v => placement.ToLocal(cornerRelative + v)));
            var after = Append(data, local);
            if (_shell.Edit(Primitive.ToString(), new MeshOperation(mesh, data, after, _session.Meshes)))
            {
                _session.SetMeshSelection(new MeshSelection(MeshElement.Faces, [.. Enumerable.Range(data.Faces.Length, made.Faces.Length).Select(i => new MeshItem(mesh, i))]));
                _lastPrimitive = new LastPrimitive(position + 1, corner, size, axis, mesh);
            }
            return;
        }
        var block = Primitives.Make(Primitive, Vec3.Zero, size, axis, PrimitiveParameters, _session.Texture.NewFaceScale(_session.DefaultMeshMaterial), _session.DefaultMeshMaterial);
        var name = _session.NewMeshName(Primitive.ToString().ToLowerInvariant());
        var (create, document) = NewMeshEntity(name, block, new Pose(corner, Quat.Identity, [1, 1, 1]), []);
        if (!_shell.Edit(Primitive.ToString(), new CreateMesh(document, _session.Meshes), create))
        {
            return;
        }
        _lastPrimitive = new LastPrimitive(position + 1, corner, size, axis, null);
        _shell.SelectScene(create.Created.Id);
        if (_session.InMeshMode)
        {
            _session.AddEditedMesh(document.Guid, create.Created.Id);
            _session.SetMeshSelection(new MeshSelection(MeshElement.Faces, [.. Enumerable.Range(0, block.Faces.Length).Select(i => new MeshItem(document.Guid, i))]));
        }
    }
}
