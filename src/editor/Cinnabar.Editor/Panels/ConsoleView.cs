using System.Collections.Specialized;
using Avalonia;
using Avalonia.Threading;
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
    // A scroll to the end is posted, for the lines that came since the last layout.
    bool _scrollPosted;

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

    // A scroll into view lays the list out, so lines that come together scroll once, after them, and not once a line.
    // Whether the list was at the end is from the layout before them.
    void OnLinesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.Action is NotifyCollectionChangedAction.Add or NotifyCollectionChangedAction.Reset && !_scrollPosted && IsAtEnd())
        {
            _scrollPosted = true;
            Dispatcher.UIThread.Post(() =>
            {
                _scrollPosted = false;
                ScrollToEnd();
            }, DispatcherPriority.Background);
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
