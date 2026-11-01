using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;
using AssetIndex = Cinnabar.Editor.Content.AssetIndex;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.AnimationGraphs;

/// <summary>
/// An animation graph's entry state and root motion joint, its parameters and its clips, each with the problems on its
/// line, and the problems on no line that the panel shows otherwise. A new name renames it in what reads it.
/// </summary>
sealed class AnimationGraphPanel : ScrollViewer
{
    static readonly string[] Types = ["float", "bool", "trigger"];

    readonly EditorShell _shell;
    readonly AnimationGraphEditor _editor;
    readonly StackPanel _content = new() { Margin = new Thickness(8), Spacing = 4 };
    string _shown = "";

    public AnimationGraphPanel(EditorShell shell, AnimationGraphEditor editor)
    {
        _shell = shell;
        _editor = editor;
        Content = _content;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.ProblemsChanged += Refresh, () => _editor.ProblemsChanged -= Refresh)
            .Add(() => _shell.Assets.Changed += Rebuild, () => _shell.Assets.Changed -= Rebuild);
    }

    AnimationGraphFile Graph => _editor.Document.Graph;

    void Rebuild()
    {
        _shown = "";
        Refresh();
    }

    // The panel builds again only when what it shows changed, so a box keeps its focus while a drag moves a node.
    void Refresh()
    {
        var shown = string.Join("|", Graph.Params.Select(p => p.Name + " " + p.Type + " " + p.Default))
            + "||" + string.Join("|", Graph.Clips.Select(c => c.Name + c.Guid + string.Join(",", c.Events)))
            + "||" + Graph.Entry + "|" + Graph.RootMotion + "|" + string.Join(",", _editor.StateNames)
            + "||" + string.Join("|", _editor.Problems.Where(p => p.Node == null).Select(p => p.Line + p.Text));
        if (shown == _shown)
        {
            return;
        }
        _shown = shown;
        _content.Children.Clear();

        _content.Children.Add(Heading("Graph"));
        _content.Children.Add(Row("Entry", Choice(_editor.StateNames, Graph.Entry, _editor.SetEntry)));
        _content.Children.Add(Row("Root motion", ValueBox(Graph.RootMotion ?? "", "no joint", _editor.SetRootMotion)));
        AddProblems(_editor.Problems.Where(p => p.Node == null && Graph.BlockAt(p.Line) is AnimationGraphSetting));

        var add = new Button { Content = "Add", Classes = { "field-button" } };
        var menu = new MenuFlyout();
        foreach (var type in Types)
        {
            var item = new MenuItem { Header = type };
            item.Click += (_, _) => _editor.AddParam(type);
            menu.Items.Add(item);
        }
        add.Flyout = menu;
        _content.Children.Add(Header("Parameters", add));
        if (!Graph.Params.Any())
        {
            _content.Children.Add(Dim("Parameters are values that gameplay sets, which blends and conditions read."));
        }
        foreach (var p in Graph.Params)
        {
            _content.Children.Add(ParamView(p));
        }

        _content.Children.Add(Header("Clips", SmallButton("Add", "Add a clip, which states and blends play by its name.", () => _editor.AddClip())));
        foreach (var c in Graph.Clips)
        {
            _content.Children.Add(ClipView(c));
        }

        // What is on no node and on no row here.
        var general = _editor.Problems.Where(p => p.Node == null && Graph.BlockAt(p.Line) is null or AnimationGraphOther).ToList();
        if (general.Count > 0)
        {
            _content.Children.Add(Heading("Problems"));
            AddProblems(general);
        }
    }

    static Control Header(string title, Control button)
    {
        var panel = new DockPanel { Margin = new Thickness(0, 6, 0, 0) };
        DockPanel.SetDock(button, DockSide.Right);
        panel.Children.Add(button);
        panel.Children.Add(Heading(title));
        return panel;
    }

    void AddProblems(IEnumerable<GraphProblem> problems)
    {
        foreach (var p in problems)
        {
            _content.Children.Add(ProblemText(p));
        }
    }

    public static SelectableTextBlock ProblemText(GraphProblem p) => new()
    {
        Text = p.Text,
        Classes = { p.Error ? "error" : "warning" },
        TextWrapping = TextWrapping.Wrap,
        FontSize = 12,
    };

    void Refuse(string name)
    {
        _shell.Console.Add(Model.LogLevel.Warning, $"animation graph: {name} is not a name, or another has it");
        Rebuild();
    }

    Control ParamView(AnimationGraphParam p)
    {
        var (name, type, value) = (p.Name, p.Type, p.Default);
        var panel = new StackPanel { Spacing = 2 };
        var box = ValueBox(name, "name", text =>
        {
            if (!_editor.SetParam(name, text.Trim(), type, value))
            {
                Refuse(text);
            }
        });
        var types = Types.Contains(type) ? Types : [.. Types, type];
        var choice = Choice(types, type, t => _editor.SetParam(name, name, t, t == "trigger" ? null : t == "bool" ? "false" : "0"));
        choice.Width = 80;
        var top = new DockPanel();
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 2,
            Children = { choice, SmallButton("×", "Remove it", () => _editor.RemoveParam(name)) },
        };
        DockPanel.SetDock(buttons, DockSide.Right);
        top.Children.Add(buttons);
        top.Children.Add(box);
        panel.Children.Add(top);
        if (type == "bool")
        {
            panel.Children.Add(Row("Default", Choice(["false", "true"], value ?? "false", v => _editor.SetParam(name, name, type, v))));
        }
        else if (type == "float")
        {
            panel.Children.Add(Row("Default", ValueBox(value ?? "", "0", text =>
            {
                if (text.Trim() == "")
                {
                    _editor.SetParam(name, name, type, null);
                }
                else if (Numbers(text, 1) is { } n)
                {
                    _editor.SetParam(name, name, type, n.Write());
                }
                else
                {
                    _shell.Console.Add(Model.LogLevel.Warning, $"animation graph: {name}'s default is a number");
                    Rebuild();
                }
            })));
        }
        foreach (var problem in _editor.Problems.Where(q => q.Node == null && Graph.BlockAt(q.Line) == p))
        {
            panel.Children.Add(ProblemText(problem));
        }
        return new Border { Classes = { "value-box" }, Padding = new Thickness(6), Child = panel };
    }

    // What the menu calls an animation: its name, and the file that has it when it is a sub-asset.
    static string AnimationName(Asset a) =>
        AssetIndex.IsSubasset(a) ? $"{Path.GetFileNameWithoutExtension(a.Path)} / {AssetIndex.DisplayName(a)}" : AssetIndex.DisplayName(a);

    Control ClipView(AnimationGraphClip c)
    {
        var (name, guid) = (c.Name, c.Guid);
        var panel = new StackPanel { Spacing = 2 };
        var box = ValueBox(name, "name", text =>
        {
            if (!_editor.SetClip(name, text.Trim(), guid))
            {
                Refuse(text);
            }
        });
        var top = new DockPanel();
        var remove = SmallButton("×", "Remove it", () => _editor.RemoveClip(name));
        DockPanel.SetDock(remove, DockSide.Right);
        top.Children.Add(remove);
        top.Children.Add(box);
        panel.Children.Add(top);

        var animations = _shell.Assets.Assets.Values.Where(a => a.Kind == AssetKind.Animation).OrderBy(AnimationName, StringComparer.OrdinalIgnoreCase).ToList();
        var names = animations.Select(AnimationName).ToList();
        var current = animations.Find(a => a.Guid == guid);
        // An animation that the content does not have shows as missing, and stays until another is picked.
        var missing = current == null ? (guid.All(ch => ch == '0') ? "none" : $"missing {guid}") : null;
        panel.Children.Add(Row("Animation", Choice(missing == null ? names : [.. names, missing], missing ?? AnimationName(current!), picked =>
        {
            if (picked != missing)
            {
                _editor.SetClip(name, name, animations[names.IndexOf(picked)].Guid);
            }
        })));
        foreach (var e in c.Events)
        {
            panel.Children.Add(new TextBlock { Text = e, Classes = { "empty" }, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis });
        }
        foreach (var problem in _editor.Problems.Where(q => q.Node == null && Graph.BlockAt(q.Line) == c))
        {
            panel.Children.Add(ProblemText(problem));
        }
        return new Border { Classes = { "value-box" }, Padding = new Thickness(6), Child = panel };
    }
}
