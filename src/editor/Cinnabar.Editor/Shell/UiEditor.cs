using System.Globalization;
using System.Text;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Tools;
using PreviewMesh = Cinnabar.Editor.Link.Protocol.PreviewMesh;

namespace Cinnabar.Editor.Shell;

/// <summary>A problem of a UI document's text: on a node, on a style, or on the document, at its line and column.</summary>
public sealed record UiProblem(int? Node, string? Style, string Text, bool Error, int Line = 0, int Column = 0);

/// <summary>
/// An open UI document in the UI editor (see docs/editor/ui-editor.md#ui-editor): its document, the selected element or
/// style, the problems of the last check of its text, and its preview, which the game draws on a screen of a size and
/// a UI scale picked here. Every change sends the unsaved text to the cook daemon a moment after the last one, and the
/// game reports where the cooked text's elements went, which outlines and picks them. The view turns input into calls
/// here, so tests can drive the editor without a window.
/// </summary>
public sealed class UiEditor : PreviewOwner, IGraphEditor
{
    /// <summary>The screens that the canvas offers, as players have them.</summary>
    public static readonly IReadOnlyList<(string Label, int Width, int Height)> Screens =
    [
        ("1280 × 720", 1280, 720),
        ("1920 × 1080", 1920, 1080),
        ("2560 × 1440", 2560, 1440),
        ("3840 × 2160", 3840, 2160),
    ];

    /// <summary>The elements that the palette adds, with the text that each starts as.</summary>
    public static readonly IReadOnlyList<(string Kind, string Text)> Palette =
    [
        ("box", "<box/>"),
        ("row", "<row/>"),
        ("column", "<column/>"),
        ("stack", "<stack/>"),
        ("text", "<text>Text</text>"),
        ("image", "<image/>"),
        ("button", "<button>Button</button>"),
        ("field", "<field/>"),
    ];

    // REFERENCE_HEIGHT and MIN_SCALE in lib/engine/ui/ui.odin, and ui.scale's range in lib/engine/project/project.odin.
    const double ReferenceHeight = 1080;
    const double MinScale = 0.5;
    const double MinScaleFactor = 0.25;
    const double MaxScaleFactor = 4;
    public const string ScaleKey = "ui.scale";

    // The daemon checks the text this long after the last change, so typing or a drag checks once.
    static readonly TimeSpan CheckDelay = TimeSpan.FromMilliseconds(250);

    readonly List<UiProblem> _problems = [];
    readonly Dictionary<string, string> _bindings = [];
    readonly HashSet<string> _states = [];
    int _checkVersion;
    bool _checking;
    bool _checkAgain;
    bool _showsUnsaved;

    internal UiEditor(EditorShell shell, UiDocument document, int? previewId = null) : base(shell, previewId, 0, 0, 1, 1)
    {
        Document = document;
        Document.Changed += OnDocumentChanged;
        ScaleFactor = ProjectScale(shell.ProjectPath);
    }

    public UiDocument Document { get; }

    IGraphDocument IGraphEditor.Document => Document;

    public string Noun => "UI document";

    public override string Guid => Document.Guid;

    public override bool PicksMesh => false;

    public override PreviewMesh Mesh => PreviewMesh.Plane;

    public override string Waiting => "The document draws once it cooks.";

    protected override bool ShowsUnsavedText => _showsUnsaved;

    public override void SetMesh(PreviewMesh mesh)
    {
    }

    public UiFile File => Document.Graph;

    /// <summary>The selected node, by its index, or null.</summary>
    public int? SelectedNode { get; private set; }

    /// <summary>The selected style, by its name, which the properties show in place of a node's, or null.</summary>
    public string? SelectedStyle { get; private set; }

    public IReadOnlyList<UiProblem> Problems => _problems;

    /// <summary>The last check found an error, so the preview draws the last text that cooked.</summary>
    public string? CookError { get; private set; }

    /// <summary>The screen that the document is laid out on, in pixels.</summary>
    public (int Width, int Height) Screen { get; private set; } = (1920, 1080);

    /// <summary>What multiplies the scale of the screen's height: the project's ui.scale, until the toolbar changes it.</summary>
    public double ScaleFactor { get; private set; }

    /// <summary>The UI scale of the screen, as the game works it out.</summary>
    public double Scale => Math.Max(Screen.Height / ReferenceHeight, MinScale) * ScaleFactor;

    /// <summary>Whether the view fits the screen in the canvas, which it does until it is zoomed or panned.</summary>
    public bool Fitted { get; private set; } = true;

    /// <summary>How many of the preview's pixels a pixel of the screen takes, and where the screen's corner is in them.</summary>
    public double ViewScale { get; private set; } = 1;
    public double ViewX { get; private set; }
    public double ViewY { get; private set; }

    public UiPreviewBackground Background { get; private set; }

    /// <summary>The states that the selected node shows in the preview, in place of the player's.</summary>
    public IReadOnlyCollection<string> States => _states;

    /// <summary>The values that the preview gives the document's bindings, which the file does not keep.</summary>
    public IReadOnlyDictionary<string, string> BindingValues => _bindings;

    /// <summary>The names that the document's text binds, in order.</summary>
    public IReadOnlyList<string> BindingNames
    {
        get
        {
            var names = new List<string>();
            foreach (var e in File.AllElements())
            {
                foreach (var text in e.Attributes.Where(a => a.Name is "text" or "placeholder").Select(a => a.Value).Append(e.Text))
                {
                    foreach (var name in UiFile.Bindings(text))
                    {
                        if (!names.Contains(name))
                        {
                            names.Add(name);
                        }
                    }
                }
            }
            return names;
        }
    }

    /// <summary>Where the game last drew the elements, or null before it has.</summary>
    public UiPreviewLayout? Layout { get; private set; }

    /// <summary>The layout is of the text as it is now, so its nodes are the document's.</summary>
    public bool LayoutCurrent => Layout != null && Layout.Key == Fnv.Hash64(Encoding.UTF8.GetBytes(Document.Text));

    /// <summary>The document or its state changed.</summary>
    public event Action? Changed;

    public event Action? SelectionChanged;

    public event Action? ProblemsChanged;

    /// <summary>The game reported a new layout, or the view or the screen changed.</summary>
    public event Action? ViewChanged;

    /// <summary>The project's ui.scale, as the game reads it: the user's file over the project's, from 0.25 to 4, or 1.</summary>
    public static double ProjectScale(string projectPath)
    {
        var text = ProjectSettings.Get(ProjectSettings.UserPath(projectPath), ScaleKey) ?? ProjectSettings.Get(projectPath, ScaleKey);
        return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var scale) && scale is >= MinScaleFactor and <= MaxScaleFactor ? scale : 1;
    }

    void OnDocumentChanged()
    {
        if (SelectedNode is { } node && node >= File.Nodes.Count)
        {
            SelectedNode = null;
            SelectionChanged?.Invoke();
        }
        if (SelectedStyle is { } style && File.Style(style) == null)
        {
            SelectedStyle = null;
            SelectionChanged?.Invoke();
        }
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
        // A color picker's steps check too, a moment after the last, so the canvas follows the picker.
        ScheduleCheck();
    }

    // Selection.

    public void Select(int? node)
    {
        if (node is { } n && (n < 0 || n >= File.Nodes.Count))
        {
            node = null;
        }
        if (node == SelectedNode && SelectedStyle == null)
        {
            return;
        }
        SelectedNode = node;
        SelectedStyle = null;
        SelectionChanged?.Invoke();
        SendSettings();
    }

    public void SelectStyle(string? name)
    {
        SelectedStyle = name != null && File.Style(name) != null ? name : null;
        SelectionChanged?.Invoke();
    }

    public UiNode? Selected => SelectedNode is { } n && n < File.Nodes.Count ? File.Nodes[n] : null;

    // The node of an element at a path after an edit.
    void SelectPath(IReadOnlyList<int> path)
    {
        SelectedNode = File.At(path) is { Node: >= 0 } e ? e.Node : null;
        SelectedStyle = null;
        SelectionChanged?.Invoke();
        SendSettings();
    }

    // Edits. Each is one undo entry.

    /// <summary>Sets an attribute of a node's element, or of a style, or takes it out with null.</summary>
    public void SetAttribute(int node, string name, string? value)
    {
        var n = File.Nodes[node];
        if (n.ButtonText || (name == "text" && n.Kind is "text" or "button" or "field" && n.Element.Text != ""))
        {
            SetText(node, value ?? "");
            return;
        }
        var path = File.PathOf(n.Element);
        Document.Edit(value == null ? $"Clear {name}" : $"Set {name}", f => f.SetAttribute(f.At(path)!, name, value));
    }

    public void SetStyleAttribute(string style, string name, string? value)
    {
        if (File.Style(style) is not { } s)
        {
            return;
        }
        var path = File.PathOf(s.Element);
        Document.Edit(value == null ? $"Clear {name}" : $"Set {name}", f => f.SetAttribute(f.At(path)!, name, value));
    }

    /// <summary>Starts an undo entry that the steps of a color picker's session or a drag change, until <see cref="EndScrub"/>.</summary>
    public void BeginScrub(string label)
    {
        if (!Document.InTransaction)
        {
            Document.Begin(label);
        }
    }

    /// <summary>Sets an attribute of a node, or of a style when <paramref name="node"/> is null, as a step of the open entry.</summary>
    public void Scrub(int? node, string? style, string name, string value)
    {
        UiElement? target = node is { } n && n < File.Nodes.Count ? File.Nodes[n].Element : style != null ? File.Style(style)?.Element : null;
        if (target == null || !Document.InTransaction)
        {
            return;
        }
        var path = File.PathOf(target);
        Document.Step(f => f.SetAttribute(f.At(path)!, name, value));
    }

    public void EndScrub()
    {
        if (Document.InTransaction)
        {
            Document.Commit();
        }
    }

    /// <summary>Sets the text of a text, a button or a field, or of a button's text node.</summary>
    public void SetText(int node, string text)
    {
        var path = File.PathOf(File.Nodes[node].Element);
        Document.Edit("Set text", f => f.SetText(f.At(path)!, text));
    }

    /// <summary>Whether a node can hold children: not a text, an image, a field or a button's text.</summary>
    public bool Holds(int node)
    {
        var n = File.Nodes[node];
        return !n.ButtonText && n.Kind is not ("text" or "image" or "field") && !(n.Kind == "button" && n.Element.Text != "")
            && !(n.Kind == "template" && n.Element.Children.Count > 0);
    }

    /// <summary>Adds an element of the palette among a node's children, at an index of them or last, and selects it.</summary>
    public void Add(string text, int parent, int? index = null)
    {
        if (!Holds(parent))
        {
            return;
        }
        var e = File.Nodes[parent].Element;
        var path = File.PathOf(e).ToList();
        var at = index ?? e.Children.Count;
        Document.Edit("Add element", f => f.Insert(f.At(path)!, at, text));
        path.Add(at);
        SelectPath(path);
    }

    /// <summary>Adds a template to the root, with one box in it, by a new id.</summary>
    public void AddTemplate()
    {
        if (File.Root is not { } root)
        {
            return;
        }
        var ids = File.AllElements().Select(e => e.Get("id")).ToHashSet();
        var n = 1;
        while (ids.Contains($"template_{n}"))
        {
            n++;
        }
        var path = File.PathOf(root).ToList();
        var at = root.Children.Count;
        Document.Edit("Add template", f => f.Insert(f.At(path)!, at, $"<template id=\"template_{n}\"><box/></template>"));
        path.Add(at);
        SelectPath(path);
    }

    /// <summary>
    /// Whether a node can move among another's children: not the root, not a button's text, not into itself or one
    /// that holds nothing, and a template only under the root.
    /// </summary>
    public bool CanMove(int node, int parent)
    {
        var n = File.Nodes[node];
        if (n.Parent < 0 || n.ButtonText || !Holds(parent) && !(File.Nodes[parent].Kind == "template" && File.Nodes[node].Parent == parent))
        {
            return false;
        }
        if (n.Kind == "template" && parent != 0)
        {
            return false;
        }
        for (var p = parent; p >= 0; p = File.Nodes[p].Parent)
        {
            if (p == node)
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>Moves a node to an index among a parent's elements, as they are before the move, and keeps it selected.</summary>
    public void Move(int node, int parent, int index)
    {
        if (!CanMove(node, parent))
        {
            return;
        }
        var element = File.Nodes[node].Element;
        var target = File.Nodes[parent].Element;
        var from = File.PathOf(element);
        var to = File.PathOf(target).ToList();
        var sameParent = element.Parent == target;
        var oldIndex = from[^1];
        if (sameParent && (index == oldIndex || index == oldIndex + 1))
        {
            return;
        }
        Document.Edit("Move element", f => f.Move(f.At(from)!, f.At(to)!, index));
        // The parent's path loses one where the element left before it.
        if (to.Count >= from.Count && to.Take(from.Count - 1).SequenceEqual(from.Take(from.Count - 1)) && to[from.Count - 1] > oldIndex)
        {
            to[from.Count - 1]--;
        }
        to.Add(sameParent && index > oldIndex ? index - 1 : index);
        SelectPath(to);
    }

    /// <summary>The index of a node's element among its parent's elements, which <see cref="Move"/> and <see cref="Add"/> count by.</summary>
    public int IndexOf(int node)
    {
        var e = File.Nodes[node].Element;
        return e.Parent?.Children.IndexOf(e) ?? 0;
    }

    public void Duplicate(int node)
    {
        var n = File.Nodes[node];
        if (n.Parent < 0 || n.ButtonText)
        {
            return;
        }
        var path = File.PathOf(n.Element);
        IReadOnlyList<int> copy = path;
        Document.Edit("Duplicate element", f => copy = f.Duplicate(f.At(path)!));
        SelectPath(copy);
    }

    public void Delete(int node)
    {
        var n = File.Nodes[node];
        if (n.Parent < 0)
        {
            return;
        }
        if (n.ButtonText)
        {
            SetText(node, "");
            return;
        }
        var path = File.PathOf(n.Element);
        var parent = n.Parent;
        Document.Edit("Delete element", f => f.Remove(f.At(path)!));
        Select(parent < File.Nodes.Count ? parent : null);
    }

    /// <summary>Gives a node an id, or takes it with "". An id that is not one, or that another element has, is refused.</summary>
    public bool SetId(int node, string id)
    {
        if (id != "" && (!UiFile.ValidId(id) || File.Nodes.Any(n => n.Index != node && !n.ButtonText && n.Id == id && n.InTemplate == File.Nodes[node].InTemplate)))
        {
            _shell.Console.Add(Model.LogLevel.Warning, $"UI document: {id} is not an id of lowercase letters, digits, _ and -, or another element has it");
            return false;
        }
        SetAttribute(node, "id", id == "" ? null : id);
        return true;
    }

    /// <summary>Sets the styles that a node names, in order.</summary>
    public void SetStyles(int node, IEnumerable<string> styles)
    {
        var list = string.Join(' ', styles.Distinct());
        SetAttribute(node, "style", list == "" ? null : list);
    }

    /// <summary>Adds a style, or a variant of one for a state, and selects it. A name that the document has is refused.</summary>
    public bool AddStyle(string name)
    {
        var colon = name.IndexOf(':');
        var bare = colon < 0 ? name : name[..colon];
        if (!UiFile.ValidId(bare) || colon >= 0 && !UiFile.States.Contains(name[(colon + 1)..]) || File.Style(name) != null || File.Root == null)
        {
            _shell.Console.Add(Model.LogLevel.Warning, $"UI document: {name} is not a new style's name");
            return false;
        }
        Document.Edit($"Add style {name}", f => f.AddStyle(name));
        SelectStyle(name);
        return true;
    }

    public bool RenameStyle(string from, string to)
    {
        if (!UiFile.ValidId(to) || File.Styles.Any(s => s.Base == to))
        {
            _shell.Console.Add(Model.LogLevel.Warning, $"UI document: {to} is not a new style's name");
            return false;
        }
        Document.Edit($"Rename style {from}", f => f.RenameStyle(from, to));
        SelectStyle(SelectedStyle is { } s && s.StartsWith(from, StringComparison.Ordinal) ? to + s[from.Length..] : SelectedStyle);
        return true;
    }

    public void DeleteStyle(string name)
    {
        if (File.Style(name) is not { } s)
        {
            return;
        }
        var path = File.PathOf(s.Element);
        Document.Edit($"Delete style {name}", f => f.Remove(f.At(path)!));
        SelectStyle(null);
    }

    /// <summary>The nodes that take a style: by their kind, or by naming it.</summary>
    public IEnumerable<UiNode> TakersOf(string style)
    {
        var s = File.Style(style);
        if (s == null)
        {
            return [];
        }
        var b = File.Style(s.Base);
        return File.Nodes.Where(n => b != null && File.StylesOf(n).Contains(b));
    }

    /// <summary>The values of a node's attributes, and where each comes from, with the states that it shows in the preview.</summary>
    public IReadOnlyDictionary<string, UiValue> Values(int node)
    {
        var inherited = _shell.Assets.UiAttributes.Where(a => a.Inherited).Select(a => a.Name).ToHashSet();
        if (inherited.Count == 0)
        {
            inherited = ["font", "size", "color", "text_align", "line_height", "wrap"];
        }
        return UiCascade.Resolve(File, node, inherited, n => n == SelectedNode ? _states : []);
    }

    // The preview's settings.

    public void SetScreen(int width, int height)
    {
        Screen = (Math.Clamp(width, 16, 16384), Math.Clamp(height, 16, 16384));
        Fitted = true;
        SendSettings();
        ViewChanged?.Invoke();
        Changed?.Invoke();
    }

    public void SetScaleFactor(double factor)
    {
        ScaleFactor = Math.Clamp(factor, MinScaleFactor, MaxScaleFactor);
        SendSettings();
        Changed?.Invoke();
    }

    public void SetBackground(UiPreviewBackground background)
    {
        Background = background;
        SendSettings();
        Changed?.Invoke();
    }

    /// <summary>Shows a state on the selected node, or stops showing it.</summary>
    public void SetState(string state, bool shown)
    {
        if (shown ? _states.Add(state) : _states.Remove(state))
        {
            SendSettings();
            Changed?.Invoke();
        }
    }

    public void SetBinding(string name, string value)
    {
        _bindings[name] = value;
        SendSettings();
        Changed?.Invoke();
    }

    /// <summary>Fits the screen in the canvas, as it is until the view is zoomed or panned.</summary>
    public void Fit()
    {
        Fitted = true;
        SendSettings();
        ViewChanged?.Invoke();
    }

    /// <summary>Shows the screen at a zoom of its pixels, 1 for one pixel of the preview each, about a point of the preview.</summary>
    public void ZoomView(double scale, double aboutX, double aboutY)
    {
        FitView();
        scale = Math.Clamp(scale, 0.02, 16);
        var (sx, sy) = ((aboutX - ViewX) / ViewScale, (aboutY - ViewY) / ViewScale);
        ViewScale = scale;
        ViewX = aboutX - sx * scale;
        ViewY = aboutY - sy * scale;
        Fitted = false;
        SendSettings();
        ViewChanged?.Invoke();
    }

    /// <summary>Moves the view by pixels of the preview.</summary>
    public void Pan(double dx, double dy)
    {
        FitView();
        ViewX += dx;
        ViewY += dy;
        Fitted = false;
        SendSettings();
        ViewChanged?.Invoke();
    }

    // A fitted view's scale and corner follow the preview's size.
    void FitView()
    {
        if (!Fitted)
        {
            return;
        }
        var (w, h) = Size;
        ViewScale = Math.Min((double)w / Screen.Width, (double)h / Screen.Height);
        ViewX = Math.Round((w - Screen.Width * ViewScale) / 2);
        ViewY = Math.Round((h - Screen.Height * ViewScale) / 2);
    }

    /// <summary>A point of the preview, in its pixels, on the screen.</summary>
    public (double X, double Y) ToScreen(double x, double y) => ((x - ViewX) / ViewScale, (y - ViewY) / ViewScale);

    /// <summary>A point of the screen in the preview's pixels.</summary>
    public (double X, double Y) ToPreview(double x, double y) => (x * ViewScale + ViewX, y * ViewScale + ViewY);

    protected override void SendSettings()
    {
        FitView();
        if (PreviewId is not { } id)
        {
            return;
        }
        uint states = 0;
        for (var i = 0; i < UiFile.States.Count; i++)
        {
            if (_states.Contains(UiFile.States[i]))
            {
                states |= 1u << i;
            }
        }
        var forced = SelectedNode is { } n && states != 0 ? (uint)n : uint.MaxValue;
        var bindings = BindingNames.Select(name => new UiPreviewBinding(name, _bindings.GetValueOrDefault(name, ""))).ToArray();
        _shell.Host.Send(new UiPreviewSettings((uint)id, Screen.Width, Screen.Height, (float)Scale, (float)ViewScale, (float)ViewX, (float)ViewY,
            Size.Width, Size.Height, Background, forced, (byte)states, bindings));
    }

    /// <summary>The game drew the preview's elements here.</summary>
    internal void OnLayout(UiPreviewLayout layout)
    {
        Layout = layout;
        ViewChanged?.Invoke();
    }

    /// <summary>The topmost node shown at a point of the screen, by the last layout, or null.</summary>
    public int? Pick(double x, double y) => LayoutCurrent ? UiCanvasGeometry.Pick(Layout!.Nodes.Select(Box).ToList(), x, y) : null;

    /// <summary>Where the game last drew a node, or null when the layout is not of the text as it is, or does not have it.</summary>
    public UiBox? BoxOf(int node)
    {
        if (!LayoutCurrent)
        {
            return null;
        }
        foreach (var n in Layout!.Nodes)
        {
            if (n.Source == node)
            {
                return Box(n);
            }
        }
        return null;
    }

    static UiBox Box(UiLayoutNode n) => new((int)n.Source, n.Shown, Rect(n.Rect), Rect(n.Content), Rect(n.Clip));

    static UiRect Rect(float[] r) => new(r[0], r[1], r[2], r[3]);

    // The check: a moment after the last change, the daemon reads the unsaved text. Only one check runs at a time, and a
    // change during it checks again after it.

    void ScheduleCheck()
    {
        var version = ++_checkVersion;
        _ = Task.Delay(CheckDelay).ContinueWith(_ =>
        {
            if (version == _checkVersion)
            {
                _ = CookNow();
            }
        }, SynchronizationContext.Current == null ? TaskScheduler.Default : TaskScheduler.FromCurrentSynchronizationContext());
    }

    public async Task CookNow()
    {
        if (_shell.Cook.State != Content.CookState.Linked)
        {
            return;
        }
        if (_checking)
        {
            _checkAgain = true;
            return;
        }
        _checking = true;
        try
        {
            do
            {
                _checkAgain = false;
                var text = Document.Text;
                var result = await _shell.Cook.CookPreview(Guid, text);
                // From the first text that cooks, the preview draws what the daemon cooks and not the saved document.
                if (result.Error == "" && !_showsUnsaved)
                {
                    _showsUnsaved = true;
                    SendPreview();
                }
                ShowProblems(text, result);
            }
            while (_checkAgain);
        }
        finally
        {
            _checking = false;
        }
    }

    /// <summary>
    /// Shows the answer to a check of a text, each problem on the element or the style at its line and column. An
    /// answer about another text is dropped: the document changed since, so another check will come.
    /// </summary>
    public void ShowProblems(string text, PreviewResult result)
    {
        if (text != Document.Text)
        {
            return;
        }
        _problems.Clear();
        foreach (var p in result.Problems)
        {
            var mine = string.Equals(Path.GetFullPath(p.File == "" ? "." : p.File), Document.Path, StringComparison.OrdinalIgnoreCase);
            var (line, column) = ((int)p.Line, (int)Math.Max(p.Column, 1));
            var node = mine && line > 0 ? File.NodeAt(line, column) : null;
            var style = mine && line > 0 && node == null ? File.StyleAt(line, column)?.Name : null;
            var where = mine || p.File == "" ? "" : $"{Path.GetFileName(p.File)}:{p.Line}: ";
            _problems.Add(new UiProblem(node, style, where + p.Text, p.Error, mine ? line : 0, mine ? column : 0));
        }
        CookError = result.Error == "" ? null : result.Error;
        ProblemsChanged?.Invoke();
    }

    public override void Dispose()
    {
        base.Dispose();
        Document.Changed -= OnDocumentChanged;
    }
}
