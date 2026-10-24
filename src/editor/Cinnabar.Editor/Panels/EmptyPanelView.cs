using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Cinnabar.Editor.Panels;

/// <summary>A panel with nothing to show yet, and a line that says what will appear in it.</summary>
public sealed class EmptyPanelView : Border
{
    public EmptyPanelView(string message)
    {
        Padding = new Thickness(16);
        Child = new TextBlock
        {
            Text = message,
            Classes = { "empty" },
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 260,
        };
    }
}
