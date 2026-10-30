using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Host;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Tools;
using GizmoPart = Cinnabar.Editor.Link.Protocol.GizmoPart;
using PickResult = Cinnabar.Editor.Link.Protocol.PickResult;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// What the mesh session and its parts need of the editor shell, so that they see the shell only through this: the
/// scene and its undo stack, the camera and the gizmo, the selection, the host, the cook and the console.
/// </summary>
interface IMeshHost
{
    /// <summary>The open scene, or null.</summary>
    SceneDocument? Scene { get; }

    /// <summary>The editor's camera.</summary>
    EditorCamera Camera { get; }

    /// <summary>The console that mesh warnings and errors go to.</summary>
    ConsoleLog Console { get; }

    /// <summary>The editor's context flags, which commands read.</summary>
    EditorContext Context { get; }

    /// <summary>The editor's commands, which a change of the mode refreshes.</summary>
    CommandRegistry Commands { get; }

    /// <summary>The link to the host, which draws live meshes and the mesh overlay.</summary>
    HostSession Host { get; }

    /// <summary>The cook session, whose finished cooks release the live meshes.</summary>
    CookSession Cook { get; }

    /// <summary>The index of the project's assets.</summary>
    AssetIndex Assets { get; }

    /// <summary>The mirror of the game's world.</summary>
    WorldModel World { get; }

    /// <summary>The selected entities, by handle.</summary>
    Selection Selection { get; }

    /// <summary>The path of the project file.</summary>
    string ProjectPath { get; }

    /// <summary>Runs every gizmo drag.</summary>
    GizmoController Gizmos { get; }

    /// <summary>The gizmo's tool.</summary>
    Tool Tool { get; }

    /// <summary>The gizmo's space.</summary>
    Space Space { get; }

    /// <summary>Gizmo drags round to <see cref="Snapping"/>'s steps.</summary>
    bool Snap { get; }

    /// <summary>The steps of snapping.</summary>
    Snapping Snapping { get; }

    /// <summary>The gizmo part under the mouse, or the one that a drag holds.</summary>
    GizmoPart HotPart { get; }

    /// <summary>The frame's size in pixels.</summary>
    (double Width, double Height) FrameSize { get; }

    /// <summary>Whether the editor is in its Edit mode.</summary>
    bool IsEditing { get; }

    /// <summary>Whether a scene is open and the editor is in its Edit mode.</summary>
    bool CanEditScene { get; }

    /// <summary>The primary selected entity of the scene, or null.</summary>
    SceneEntity? SelectedSceneEntity { get; }

    /// <summary>The selected entities of the scene.</summary>
    IReadOnlyList<SceneEntity> SelectedSceneEntities { get; }

    /// <summary>Selects an entity of the scene.</summary>
    void SelectScene(ulong sceneId);

    /// <summary>Whether an entity can be picked: it is not locked or hidden.</summary>
    bool Pickable(ulong handle);

    /// <summary>The instance that an entity is inside, or null.</summary>
    InstanceEntity? InstanceOf(ulong sceneId);

    /// <summary>Applies operations as one undo entry labelled for the history.</summary>
    bool Edit(string label, params Operation[] operations);

    /// <summary>Opens an undo entry that previews fill.</summary>
    void BeginEdit(string label);

    /// <summary>Applies operations to the open entry in place of the last preview.</summary>
    bool PreviewEdit(IReadOnlyList<Operation> ops);

    /// <summary>Closes the open entry as an undo step.</summary>
    void CommitEdit();

    /// <summary>Closes the open entry and puts back what it changed.</summary>
    void CancelEdit();

    /// <summary>Whether a GUID names a material or a material instance.</summary>
    bool IsMaterial(string guid);

    /// <summary>Commits the material preview of a drop.</summary>
    bool CommitMaterial();

    /// <summary>Cancels the material preview of a drop.</summary>
    void CancelMaterial();

    /// <summary>Highlights the gizmo part under the mouse.</summary>
    void HoverGizmo(Vec2 pixel);

    /// <summary>Sends the gizmo to the host when it changed.</summary>
    void SendGizmo();

    /// <summary>Ends a gizmo drag and puts what it edited back.</summary>
    void CancelGizmo();

    /// <summary>Finds what is drawn at a pixel without selecting it.</summary>
    bool PickPixel(Vec2 pixel, Action<PickResult> then);

    /// <summary>Puts a file's problems in the console.</summary>
    void Report(string area, string path, IEnumerable<(int Line, string Message, bool IsError)> problems);
}
