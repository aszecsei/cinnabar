using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Commands;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Ribbon;

/// <summary>
/// The command palette (see docs/editor/shell-and-panels.md#commands): an overlay that searches every command by name. Enter runs the
/// selected command, and Escape or a click outside closes it.
/// </summary>
public sealed class CommandPalette : Grid
{
    readonly CommandViews _views;
    readonly TextBox _query = new() { PlaceholderText = "Search commands", Classes = { "palette-query" } };
    readonly ListBox _results = new() { Classes = { "palette-results" }, MaxHeight = 360 };
    IInputElement? _returnFocus;

    internal CommandPalette(CommandViews views)
    {
        _views = views;
        IsVisible = false;
        Background = new SolidColorBrush(Color.FromArgb(0x50, 0, 0, 0));
        // Recycling a container builds the template once with no item.
        _results.ItemTemplate = new FuncDataTemplate<Command>((command, _) => command == null ? new Control() : Row(command));
        var box = new Border
        {
            Classes = { "palette" },
            Width = 560,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 72, 0, 0),
            Child = new StackPanel { Children = { _query, _results } },
        };
        Children.Add(box);

        PointerPressed += (_, e) =>
        {
            if (!box.IsPointerOver)
            {
                Close();
                e.Handled = true;
            }
        };
        _query.TextChanged += (_, _) => Refresh();
        _query.KeyDown += OnQueryKey;
        _results.DoubleTapped += (_, _) => RunSelected();
    }

    public void Open()
    {
        _returnFocus = TopLevel.GetTopLevel(this)?.FocusManager?.GetFocusedElement();
        IsVisible = true;
        _query.Text = "";
        Refresh();
        _query.Focus();
    }

    public void Close()
    {
        IsVisible = false;
        _returnFocus?.Focus();
        _returnFocus = null;
    }

    void Refresh()
    {
        _results.ItemsSource = CommandSearch.Find(_views.Commands, _query.Text ?? "");
        _results.SelectedIndex = _results.ItemCount > 0 ? 0 : -1;
    }

    void OnQueryKey(object? sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Escape:
                Close();
                break;
            case Key.Enter:
                RunSelected();
                break;
            case Key.Down:
                _results.SelectedIndex = Math.Min(_results.SelectedIndex + 1, _results.ItemCount - 1);
                _results.ScrollIntoView(_results.SelectedIndex);
                break;
            case Key.Up:
                _results.SelectedIndex = Math.Max(_results.SelectedIndex - 1, 0);
                _results.ScrollIntoView(_results.SelectedIndex);
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    void RunSelected()
    {
        if (_results.SelectedItem is Command command)
        {
            // Close first, so a command that moves focus, such as showing a panel, keeps it.
            Close();
            command.Execute();
        }
    }

    Control Row(Command command)
    {
        var label = command.IsToggle ? $"{command.Label}{(command.IsChecked ? "  (on)" : "")}" : command.Label;
        var shortcut = new TextBlock { Text = _views.KeyBindings.ShortcutOf(command.Id) ?? "", Classes = { "dim" } };
        var row = new DockPanel { Opacity = command.CanExecute ? 1 : 0.45 };
        DockPanel.SetDock(shortcut, DockSide.Right);
        row.Children.Add(shortcut);
        row.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children =
            {
                CommandViews.Icon(command.Icon, 16) ?? new Control { Width = 16 },
                new TextBlock { Text = label },
                new TextBlock { Text = command.Id, Classes = { "dim" } },
            },
        });
        return row;
    }
}
