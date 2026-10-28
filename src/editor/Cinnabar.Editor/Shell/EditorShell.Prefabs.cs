using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Tools;
using AssetKind = Cinnabar.Editor.Link.Cook.AssetKind;
using PickResult = Cinnabar.Editor.Link.Protocol.PickResult;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Instances of prefabs in the open scene (see docs/editor/prefabs.md#editing-an-instance): opening the prefabs that
/// it uses, dropping a prefab from the content browser, and Make Prefab and Unpack on the selection.
/// </summary>
public sealed partial class EditorShell
{
    // The instance that a drag of a prefab over the viewport shows, in its open undo entry.
    ulong _prefabDrop;

    /// <summary>The user asked to make a prefab of the selected entity. The window asks for a name, and calls <see cref="MakePrefab"/>.</summary>
    public event Action<string>? MakePrefabRequested;

    public bool IsPrefab(string guid) => Assets.Find(guid)?.Kind == AssetKind.Prefab;

    // Opens a prefab's document from its file, which the index names, for the scene's expansion.
    PrefabDocument? OpenPrefab(string guid)
    {
        if (Assets.Find(guid) is not { Kind: AssetKind.Prefab } asset || Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        var (document, problems) = PrefabDocument.Open(path, guid);
        Report(path, problems);
        return document;
    }

    // An instance whose prefab the index did not have when the scene expanded shows once the index has it.
    void ExpandArrivedPrefabs()
    {
        if (Scene == null || !Scene.Scene.Entities.Any(e => e.Prefab != "" && IsPrefab(e.Prefab) && Scene.Prefabs.Documents.All(d => d.Guid != e.Prefab)))
        {
            return;
        }
        Scene.Invalidate();
        ReportExpansion();
        SceneChanged?.Invoke();
        SendScene();
    }

    void ReportExpansion()
    {
        if (Scene != null)
        {
            Report(Scene.Path, Scene.Expanded.Problems);
        }
    }

    /// <summary>The instance that the entity is inside, by its outermost root's ID, and its path there, or null for a plain entity.</summary>
    public InstanceEntity? InstanceOf(ulong sceneId) => Scene?.Expanded.InstanceOf(sceneId);

    /// <summary>Whether the entity's block overrides anything of its prefab, as the outliner marks it.</summary>
    public bool IsOverridden(ulong sceneId) =>
        Scene != null && InstanceOf(sceneId) is { IsInstanceRoot: false } && Scene.Scene.Find(sceneId) != null;

    /// <summary>Whether a plain entity of the scene is under an instance's entity, as one that the scene added to it.</summary>
    public bool IsAddedToInstance(ulong sceneId)
    {
        var flat = Scene?.Expanded.Flat;
        var e = flat?.Find(sceneId);
        for (var depth = 0; e is { Parent: not 0 } && depth < 64; depth++)
        {
            if (InstanceOf(e.Parent) != null)
            {
                return true;
            }
            e = flat!.Find(e.Parent);
        }
        return false;
    }

    /// <summary>The entity as its prefab gives it, without its own overrides, or null for a plain entity.</summary>
    public SceneEntity? PrefabBase(ulong sceneId) => Scene == null ? null : PrefabEdits.Base(Scene, sceneId);

    /// <summary>The overrides of an instance's entity: its instance block or override block, or null for none.</summary>
    public SceneEntity? OverridesOf(ulong sceneId) => Scene != null && InstanceOf(sceneId) != null ? Scene.Scene.Find(sceneId) : null;

    /// <summary>A prefab's name, from its file, for labels such as the undo history's.</summary>
    public string PrefabName(string guid) =>
        Assets.Find(guid) is { } asset ? Path.GetFileNameWithoutExtension(asset.Path) : guid;

    /// <summary>
    /// Where a prefab dropped at a frame pixel lands: on what the pixel shows, or on the grid plane through the camera's
    /// pivot when it shows nothing, snapped to the grid when Snap is on.
    /// </summary>
    public long[] DropPoint(Vec2 pixel, PickResult? result)
    {
        var (width, height) = FrameSize;
        var ray = Camera.Ray(pixel, width, height);
        double distance;
        if (result is { Depth: > 0 } && Vec3.Dot(ray, Camera.Forward) is var cos and > 1e-6)
        {
            distance = result.Depth / cos;
        }
        else
        {
            var plane = Camera.RelativeTo(Camera.Pivot).Y;
            distance = Math.Abs(ray.Y) > 1e-6 && plane / ray.Y is var t and > 0 ? t : Camera.PivotDistance;
        }
        var point = (ray * distance).Offset(Camera.Position);
        if (Snap)
        {
            var step = GridSize * Pose.Unit;
            point = [.. point.Select(p => (long)(Math.Round(p / step) * step))];
        }
        return point;
    }

    /// <summary>
    /// Shows an instance of a prefab at a point while a drag is over the viewport, in an undo entry that stays open:
    /// the first point creates it, and the next ones move it.
    /// </summary>
    public void PreviewPrefab(string guid, long[] at)
    {
        if (Scene == null || !IsEditing || !IsPrefab(guid))
        {
            return;
        }
        var position = SceneEdits.TransformFields(new Pose(at, Quat.Identity, [1, 1, 1]))[0].Value;
        if (_prefabDrop != 0 && Scene.InTransaction)
        {
            PreviewEdit(new SetField(_prefabDrop, SceneEdits.TransformId, "position", position));
            return;
        }
        if (Scene.InTransaction)
        {
            return;
        }
        BeginEdit($"Create Instance {PrefabName(guid)}");
        var create = PrefabEdits.CreateInstance(Scene, guid, 0,
            new SceneComponent(SceneEdits.TransformId, "Transform", SceneEdits.TransformFields(new Pose(at, Quat.Identity, [1, 1, 1]))));
        _prefabDrop = create.Id;
        PreviewEdit(create);
    }

    /// <summary>Keeps the previewed instance as one undo entry and selects it. Returns false when nothing was previewed.</summary>
    public bool CommitPrefab()
    {
        if (_prefabDrop == 0 || Scene is not { InTransaction: true })
        {
            _prefabDrop = 0;
            return false;
        }
        var id = _prefabDrop;
        _prefabDrop = 0;
        CommitEdit();
        SelectScene(id);
        return true;
    }

    /// <summary>Takes back the instance that a drag showed.</summary>
    public void CancelPrefab()
    {
        if (_prefabDrop == 0)
        {
            return;
        }
        _prefabDrop = 0;
        if (Scene is { InTransaction: true })
        {
            CancelEdit();
        }
    }

    /// <summary>
    /// Adds an instance of a prefab as a child of an entity at the identity pose, or with 0, as a root at the origin,
    /// as a drop onto the outliner does, and selects it.
    /// </summary>
    public bool CreateInstance(string guid, ulong parent)
    {
        if (Scene == null || !IsPrefab(guid))
        {
            return false;
        }
        var pose = parent == 0
            ? new SceneComponent(SceneEdits.TransformId, "Transform", SceneEdits.TransformFields(Pose.Identity))
            : new SceneComponent(SceneEdits.LocalTransformId, "Local_Transform", [
                new("offset", SceneEdits.Floats(0, 0, 0)), new("rotation", SceneEdits.Floats(0, 0, 0, 1)), new("scale", SceneEdits.Floats(1, 1, 1))]);
        BlockOperation create;
        try
        {
            create = PrefabEdits.CreateInstance(Scene, guid, parent, pose);
        }
        catch (InvalidOperationException e)
        {
            Console.Add(LogLevel.Error, $"edit: {e.Message}");
            return false;
        }
        if (!Edit($"Create Instance {PrefabName(guid)}", create))
        {
            return false;
        }
        SelectScene(create.Id);
        return true;
    }

    public void RequestMakePrefab()
    {
        if (SelectedSceneEntity is { } entity)
        {
            MakePrefabRequested?.Invoke(entity.Name.Length > 0 ? entity.Name : "new_prefab");
        }
    }

    /// <summary>
    /// Makes a prefab of the selected entity and its descendants in the content browser's folder, and replaces them with
    /// an instance of it, as one undo entry. The prefab's file is written at the next save.
    /// </summary>
    public bool MakePrefab(string name)
    {
        if (Scene == null || SelectedSceneEntity is not { } entity)
        {
            return false;
        }
        var folder = ContentFolder ?? (Assets.FindRoot("game") is { } game ? new ContentFolder(game.Name, "") : null);
        if (folder == null || Assets.FindRoot(folder.Root) is not { } root)
        {
            Console.Add(LogLevel.Error, "edit: Make Prefab writes the prefab in the content browser's folder. Choose one first.");
            return false;
        }
        var file = name.Trim();
        if (file.EndsWith(SceneFile.PrefabExtension, StringComparison.OrdinalIgnoreCase))
        {
            file = file[..^SceneFile.PrefabExtension.Length];
        }
        var path = Path.Combine(root.Dir, folder.Path, file + SceneFile.PrefabExtension);
        if (file.Length == 0 || file.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || File.Exists(path) || Scene.Prefabs.Documents.Any(d => d.Path == Path.GetFullPath(path)))
        {
            Console.Add(LogLevel.Error, $"edit: cannot make the prefab {path}: the name is taken or is not a file's");
            return false;
        }
        try
        {
            var (ops, prefab) = PrefabEdits.MakePrefab(Scene, entity.Id, path);
            if (Edit($"Make Prefab {file}", ops))
            {
                Console.Add(LogLevel.Info, $"edit: made the prefab {path}, which the next save writes");
                SelectScene(entity.Id);
                return true;
            }
        }
        catch (InvalidOperationException e)
        {
            Console.Add(LogLevel.Error, $"edit: cannot make a prefab: {e.Message}");
        }
        return false;
    }

    /// <summary>Makes the selected instances' entities plain entities of the scene: one level, or with completely, every nesting.</summary>
    public bool UnpackSelected(bool completely)
    {
        if (Scene == null)
        {
            return false;
        }
        var roots = SelectedSceneEntities.Where(e => InstanceOf(e.Id) is { IsInstanceRoot: true }).ToList();
        if (roots.Count == 0)
        {
            Console.Add(LogLevel.Info, "edit: Unpack takes an instance's root. Select one in the outliner.");
            return false;
        }
        var verb = completely ? "Unpack Completely" : "Unpack";
        try
        {
            return Edit(roots.Count == 1 ? $"{verb} {Label(roots[0])}" : $"{verb} {roots.Count} Instances",
                [.. roots.SelectMany(r => completely ? PrefabEdits.UnpackCompletely(Scene, r.Id) : PrefabEdits.Unpack(Scene, r.Id))]);
        }
        catch (InvalidOperationException e)
        {
            Console.Add(LogLevel.Error, $"edit: cannot {verb.ToLowerInvariant()}: {e.Message}");
            return false;
        }
    }

    /// <summary>Shows the prefab of the selected entity's instance in the content browser.</summary>
    public void SelectPrefabAsset()
    {
        if (SelectedSceneEntity is { } entity && InstanceOf(entity.Id) is { } info && Scene?.Scene.Find(info.Instance)?.Prefab is { Length: > 0 } guid)
        {
            RevealAsset(info.Prefab != "" ? info.Prefab : guid);
        }
    }
}
