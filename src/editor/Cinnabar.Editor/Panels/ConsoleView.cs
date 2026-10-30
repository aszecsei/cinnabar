using System.Collections.Specialized;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using DockSide = Avalonia.Controls.Dock;

using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Panels;

/// <summary>The console panel: the log, which follows new lines while it is scrolled to the end.</summary>
public sealed class ConsoleView : DockPanel
{
    readonly ConsoleLog _log;
    readonly ListBox _list;

    public ConsoleView(ConsoleLog log)
    {
        _log = log;
        var clear = new Button { Content = "Clear", Padding = new Thickness(8, 2), Margin = new Thickness(4) };
        clear.Click += (_, _) => _log.Clear();
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Children = { clear } };
        SetDock(bar, DockSide.Top);
        Children.Add(bar);

        _list = new ListBox
        {
            ItemsSource = log.Lines,
            Classes = { "console" },
            ItemTemplate = new FuncDataTemplate<LogLine>((line, _) => new SelectableTextBlock
            {
                Text = line?.Text,
                Classes = { line?.Level.ToString().ToLowerInvariant() ?? "" },
                TextWrapping = TextWrapping.NoWrap,
            }),
        };
        Children.Add(_list);
        new ViewSubscriptions(this, attached: ScrollToEnd)
            .Add(() => _log.Lines.CollectionChanged += OnLinesChanged, () => _log.Lines.CollectionChanged -= OnLinesChanged);
    }

    void OnLinesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.Action == NotifyCollectionChangedAction.Add && IsAtEnd())
        {
            ScrollToEnd();
        }
    }

    bool IsAtEnd()
    {
        if (_list.Scroll is not { } scroll)
        {
            return true;
        }
        // A line's height of slack, so that a line added during the last scroll still counts as the end.
        return scroll.Offset.Y + scroll.Viewport.Height >= scroll.Extent.Height - 24;
    }

    void ScrollToEnd()
    {
        if (_log.Lines.Count > 0)
        {
            _list.ScrollIntoView(_log.Lines.Count - 1);
        }
    }
}
