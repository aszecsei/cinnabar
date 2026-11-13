using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Decisions;

/// <summary>
/// The decision editor (see docs/editor/decision-editor.md#decision-editor): the decision's technique and blackboard,
/// its problems and the selected agent's blackboard on the left, its canvas, and the selected node's details on the
/// right. Docking can rebuild the view at any time, so its state is in its <see cref="DecisionEditor"/>.
/// </summary>
public sealed class DecisionEditorView : DockPanel
{
    readonly EditorShell _shell;
    readonly DecisionEditor _editor;
    readonly TextBlock _status = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };

    public DecisionEditorView(EditorShell shell, DecisionEditor editor)
    {
        _shell = shell;
        _editor = editor;
        var canvas = new BehaviorTreeCanvas(shell, editor);

        var toolbar = new DockPanel { Margin = new Thickness(8, 4) };
        var save = new Button { Content = CommandViews.Icon("save", 16), Classes = { "viewport-tool" }, Focusable = false, Margin = new Thickness(0, 0, 8, 0) };
        ToolTip.SetTip(save, "Save (Ctrl+S)");
        save.Click += (_, _) => shell.SaveGraph(editor);
        DockPanel.SetDock(save, DockSide.Left);
        toolbar.Children.Add(save);
        var text = SmallButton("Open in Script Editor", "Edit the decision's text. Save first: this editor does not read the file again.", () => shell.OpenScript(editor.Document.Path));
        DockPanel.SetDock(text, DockSide.Left);
        toolbar.Children.Add(text);
        var frame = SmallButton("Frame", "Pan and zoom so the whole tree is in view (F)", canvas.Frame);
        DockPanel.SetDock(frame, DockSide.Left);
        toolbar.Children.Add(frame);
        DockPanel.SetDock(_status, DockSide.Right);
        toolbar.Children.Add(_status);
        toolbar.Children.Add(new Panel());
        var top = new Border { Child = toolbar, BorderBrush = new SolidColorBrush(Color.Parse("#333337")), BorderThickness = new Thickness(0, 0, 0, 1) };
        SetDock(top, DockSide.Top);
        Children.Add(top);

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("240,4,*,4,300") };
        grid.Children.Add(new DecisionPanel(shell, editor));
        var leftSplit = new GridSplitter { ResizeDirection = GridResizeDirection.Columns };
        Grid.SetColumn(leftSplit, 1);
        grid.Children.Add(leftSplit);
        Grid.SetColumn(canvas, 2);
        grid.Children.Add(canvas);
        var rightSplit = new GridSplitter { ResizeDirection = GridResizeDirection.Columns };
        Grid.SetColumn(rightSplit, 3);
        grid.Children.Add(rightSplit);
        var details = new DecisionNodeDetails(shell, editor);
        Grid.SetColumn(details, 4);
        grid.Children.Add(details);
        Children.Add(grid);

        new ViewSubscriptions(this, attached: Show)
            .Add(() => _editor.Changed += Show, () => _editor.Changed -= Show)
            .Add(() => _editor.ProblemsChanged += Show, () => _editor.ProblemsChanged -= Show)
            .Add(() => _shell.Cook.StateChanged += Show, () => _shell.Cook.StateChanged -= Show);
    }

    void Show()
    {
        var parts = new List<string>();
        var errors = _editor.Problems.Count(p => p.Error);
        if (!_shell.Cook.Linked)
        {
            parts.Add("waiting for the cook daemon");
        }
        else if (_editor.CookError != null)
        {
            parts.Add(errors == 1 ? "1 error" : $"{errors} errors");
        }
        else
        {
            parts.Add("cooks");
        }
        if (_editor.Document.IsDirty)
        {
            parts.Add("not saved");
        }
        _status.Text = string.Join("  ·  ", parts);
        _status.Classes.Set("warning", _editor.CookError != null);
        ToolTip.SetTip(_status, _editor.CookError);
    }
}

/// <summary>
/// The decision editor's left panel: the technique, the blackboard that the decision names, the problems of no node,
/// and, while the game plays, the selected agent's blackboard. It only looks: nothing here writes to the game.
/// </summary>
sealed class DecisionPanel : ScrollViewer
{
    protected override Type StyleKeyOverride => typeof(ScrollViewer);

    readonly EditorShell _shell;
    readonly DecisionEditor _editor;
    readonly StackPanel _content = new() { Margin = new Thickness(8), Spacing = 2 };
    readonly StackPanel _live = new() { Spacing = 2 };
    string _shown = "";

    public DecisionPanel(EditorShell shell, DecisionEditor editor)
    {
        _shell = shell;
        _editor = editor;
        Content = new StackPanel { Children = { _content, new Border { Margin = new Thickness(8, 0), Child = _live } } };
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.CatalogChanged += Refresh, () => _editor.CatalogChanged -= Refresh)
            .Add(() => _editor.ProblemsChanged += Refresh, () => _editor.ProblemsChanged -= Refresh)
            .Add(() => _editor.LiveChanged += ShowLive, () => _editor.LiveChanged -= ShowLive);
    }

    void Refresh()
    {
        var blackboards = _editor.Blackboards;
        var guid = _editor.Document.Graph.Blackboard;
        var shown = $"{_editor.Technique}|{guid}|{string.Join(",", blackboards.Select(b => b.Guid + b.Path))}"
            + $"|{string.Join("|", _editor.Problems.Where(p => p.Node == null).Select(p => p.Line + p.Text))}";
        if (shown != _shown)
        {
            _shown = shown;
            Build(blackboards, guid);
        }
        ShowLive();
    }

    void Build(IReadOnlyList<Link.Cook.Asset> blackboards, string? guid)
    {
        _content.Children.Clear();
        _content.Children.Add(Heading("Decision"));
        _content.Children.Add(Row("Technique", new TextBlock { Text = (_editor.Technique ?? "none").Replace('_', ' '), VerticalAlignment = VerticalAlignment.Center }));
        if (_editor.Technique is not "behavior_tree")
        {
            _content.Children.Add(Dim("The canvas draws this technique's nodes without their links, which the details show as the file writes them."));
        }
        var names = blackboards.Select(AssetIndex.DisplayName).ToList();
        var current = blackboards.FirstOrDefault(b => b.Guid == guid);
        var missing = current == null ? (guid == null ? "none" : $"missing {guid}") : null;
        _content.Children.Add(Row("Blackboard", Choice(missing == null ? names : [.. names, missing], missing ?? AssetIndex.DisplayName(current!), picked =>
        {
            if (picked != missing)
            {
                _editor.SetBlackboard(blackboards[names.IndexOf(picked)].Guid);
            }
        })));
        if (current != null)
        {
            _content.Children.Add(SmallButton("Open Blackboard", "Edit the blackboard's keys", () => _shell.OpenBlackboard(current)));
        }
        var problems = _editor.Problems.Where(p => p.Node == null).ToList();
        if (problems.Count > 0)
        {
            _content.Children.Add(Heading("Problems"));
            foreach (var p in problems)
            {
                var text = AnimationGraphs.AnimationGraphPanel.ProblemText(p);
                if (p.Line > 0)
                {
                    text.Text = $"Line {p.Line}: {p.Text}";
                }
                _content.Children.Add(text);
            }
        }
    }

    // The selected agent's blackboard, as the game last sent it.
    void ShowLive()
    {
        _live.Children.Clear();
        if (_shell.IsEditing)
        {
            return;
        }
        _live.Children.Add(Heading("Live"));
        if (_editor.Live is not { } view)
        {
            _live.Children.Add(Dim(_editor.LiveWaiting ?? ""));
            return;
        }
        foreach (var value in view.Values)
        {
            _live.Children.Add(Row(value.Name, new SelectableTextBlock { Text = value.Text, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap }));
        }
    }
}
