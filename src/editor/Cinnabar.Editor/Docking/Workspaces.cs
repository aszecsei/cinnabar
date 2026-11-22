using System.Text.Json;

namespace Cinnabar.Editor.Docking;

/// <summary>
/// An arrangement of the panels for one kind of work (see docs/editor/shell-and-panels.md#workspaces): which panels are
/// open and where, as a <see cref="LayoutFile"/>, and the ribbon tab that the work mostly uses. A panel that a
/// workspace leaves out is closed, not gone: the Window tab shows it again.
/// </summary>
public sealed record Workspace(string Id, string Label, string Description, string? RibbonTab, LayoutFile Layout);

/// <summary>
/// The workspaces, and what the user made of each. One is active. Switching keeps the arrangement that the user leaves,
/// so each workspace is as it was left, and a reset puts the active one back to its preset. <see cref="Switch"/>
/// alone changes the active workspace and what is kept while the editor runs, and <see cref="Load"/> takes both from
/// the file when it starts.
/// </summary>
public sealed class Workspaces
{
    public const string FileName = "workspaces.json";
    public const string DefaultId = "general";

    static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    readonly EditorLayout _layout;
    // What the user made of the workspaces that are not active, by ID. The active one's arrangement is the layout itself.
    readonly Dictionary<string, LayoutFile> _kept = [];

    public IReadOnlyList<Workspace> All { get; }

    public Workspace Active { get; private set; }

    /// <summary>The active workspace changed.</summary>
    public event Action? Changed;

    public Workspaces(EditorLayout layout, IReadOnlyList<Workspace> all)
    {
        _layout = layout;
        All = all;
        Active = all.First(w => w.Id == DefaultId);
    }

    public Workspace? Find(string idOrLabel) =>
        All.FirstOrDefault(w => w.Id == idOrLabel) ?? All.FirstOrDefault(w => string.Equals(w.Label, idOrLabel, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Makes a workspace the active one: keeps the arrangement that the user leaves, and shows the new workspace as it
    /// was left, or its preset the first time. A kept arrangement that no longer restores, as one from an editor with
    /// other panels, gives way to the preset. Returns false for the workspace that is active already.
    /// </summary>
    public bool Switch(Workspace workspace)
    {
        if (workspace == Active)
        {
            return false;
        }
        _kept[Active.Id] = _layout.Save();
        if (!_kept.Remove(workspace.Id, out var kept) || !_layout.Restore(kept))
        {
            _layout.Restore(workspace.Layout);
        }
        Active = workspace;
        Changed?.Invoke();
        return true;
    }

    /// <summary>Puts the active workspace back to its preset.</summary>
    public void Reset() => _layout.Restore(Active.Layout);

    /// <summary>The file's text: the active workspace's ID, and what the user made of the others.</summary>
    public string ToJson() => JsonSerializer.Serialize(new WorkspacesFile(Active.Id, _kept), Options);

    /// <summary>
    /// Takes the active workspace and the kept arrangements from the file's text, without changing the layout: the layout
    /// file has the active workspace's arrangement. Returns false and changes nothing for text that is not the file's.
    /// </summary>
    public bool Load(string json)
    {
        WorkspacesFile? file;
        try
        {
            file = JsonSerializer.Deserialize<WorkspacesFile>(json, Options);
        }
        catch (JsonException)
        {
            return false;
        }
        if (file?.Active == null || Find(file.Active) is not { } active)
        {
            return false;
        }
        _kept.Clear();
        foreach (var (id, layout) in file.Layouts ?? [])
        {
            if (id != active.Id && Find(id) != null && layout?.Version == LayoutFile.CurrentVersion)
            {
                _kept[id] = layout;
            }
        }
        Active = active;
        Changed?.Invoke();
        return true;
    }

    sealed record WorkspacesFile(string? Active, Dictionary<string, LayoutFile>? Layouts);
}

/// <summary>The editor's workspaces, one for each kind of work that arranges the panels its own way.</summary>
public static class WorkspacePresets
{
    const string Documents = "dock.documents";

    static SplitNode Row(string id, params LayoutNode[] children) => new(id, null, Vertical: false, children);

    static SplitNode Column(string id, double? proportion, params LayoutNode[] children) => new(id, proportion, Vertical: true, children);

    static ToolsNode Tools(string id, string alignment, double proportion, params string[] panels) => new(id, proportion, alignment, panels, panels[0]);

    static DocumentsNode Views(double? proportion, string active = ViewportDocument.SceneId) =>
        new(Documents, proportion, [ViewportDocument.SceneId, ViewportDocument.GameId], active);

    static LayoutFile File(LayoutNode root) => new(LayoutFile.CurrentVersion, root, []);

    /// <summary>
    /// The workspaces. <paramref name="general"/> is the layout that an editor without workspaces had, with every panel
    /// open, which the first one keeps.
    /// </summary>
    public static IReadOnlyList<Workspace> Create(LayoutFile general) =>
    [
        new(Workspaces.DefaultId, "General", "Every panel, for work that crosses disciplines.", "home", general),
        new("level", "Level Design", "The outliner, the scene and the content browser, for blocking out and placing.", "home", File(Row("dock.main",
            Tools(EditorLayout.LeftDock, "Left", 0.17, "outliner"),
            Column("dock.center", 0.63,
                Views(0.70),
                Tools(EditorLayout.BottomDock, "Bottom", 0.30, "contentBrowser", "console")),
            Tools(EditorLayout.RightDock, "Right", 0.20, "properties", "faceEditor", "sublevels", "undoHistory")))),
        new("environment", "Environment Art", "A tall content browser under the scene, and the face sheet beside the properties, for dressing a level.", "environment", File(Row("dock.main",
            Tools(EditorLayout.LeftDock, "Left", 0.15, "outliner"),
            Column("dock.center", 0.65,
                Views(0.56),
                Tools(EditorLayout.BottomDock, "Bottom", 0.44, "contentBrowser")),
            Column("dock.side", 0.20,
                Tools(EditorLayout.RightDock, "Right", 0.55, "properties", "undoHistory"),
                Tools("dock.right.lower", "Right", 0.45, "faceEditor"))))),
        new("lighting", "Lighting", "The atmosphere beside the properties, and the resource monitor under the scene, for lighting a level.", "lighting", File(Row("dock.main",
            Tools(EditorLayout.LeftDock, "Left", 0.15, "outliner"),
            Column("dock.center", 0.60,
                Views(0.76),
                Tools(EditorLayout.BottomDock, "Bottom", 0.24, "resourceMonitor", "console")),
            Column("dock.side", 0.25,
                Tools(EditorLayout.RightDock, "Right", 0.50, "properties", "undoHistory"),
                Tools("dock.right.lower", "Right", 0.50, "atmosphere", "weather"))))),
        new("scripting", "Scripting", "The scene and the game side by side over a tall console, for writing and running gameplay.", "scripting", File(Row("dock.main",
            Tools(EditorLayout.LeftDock, "Left", 0.15, "outliner"),
            Column("dock.center", 0.65,
                new SplitNode("dock.views", 0.58, Vertical: false,
                [
                    new DocumentsNode(Documents, 0.5, [ViewportDocument.SceneId], ViewportDocument.SceneId),
                    new DocumentsNode("dock.documents.game", 0.5, [ViewportDocument.GameId], ViewportDocument.GameId),
                ]),
                Tools(EditorLayout.BottomDock, "Bottom", 0.42, "console", "contentBrowser", "profiler")),
            Tools(EditorLayout.RightDock, "Right", 0.20, "properties", "undoHistory")))),
        new("cinematics", "Cinematics", "The scene and the game side by side over the cutscene editor, for building cutscenes.", "gameplay", File(Row("dock.main",
            Tools(EditorLayout.LeftDock, "Left", 0.15, "outliner"),
            Column("dock.center", 0.65,
                new SplitNode("dock.views", 0.45, Vertical: false,
                [
                    new DocumentsNode(Documents, 0.5, [ViewportDocument.SceneId], ViewportDocument.SceneId),
                    new DocumentsNode("dock.documents.game", 0.5, [ViewportDocument.GameId], ViewportDocument.GameId),
                ]),
                new DocumentsNode(EditorLayout.EditorDocumentsDock, 0.55, [])),
            Tools(EditorLayout.RightDock, "Right", 0.20, "properties", "undoHistory")))),
        new("performance", "Performance", "The profiler and the resource monitor under the scene, for finding what a frame costs.", "scripting", File(Row("dock.main",
            Column("dock.center", 0.78,
                Views(0.52),
                new SplitNode("dock.measure", 0.48, Vertical: false,
                [
                    Tools(EditorLayout.BottomDock, "Bottom", 0.62, "profiler", "console"),
                    Tools("dock.bottom.right", "Bottom", 0.38, "resourceMonitor"),
                ])),
            Tools(EditorLayout.RightDock, "Right", 0.22, "properties", "outliner")))),
    ];
}
