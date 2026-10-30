using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// Makes the collapsible sections of a panel and remembers which the user collapsed, by title, so a section keeps its
/// state when the panel builds again.
/// </summary>
sealed class SectionExpander
{
    readonly HashSet<string> _collapsed = [];

    /// <summary>A section's title, as its header shows it.</summary>
    public static TextBlock Title(string title) => new() { Text = title, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center };

    /// <summary>A section under its <paramref name="title"/>, or under a <paramref name="header"/> that has its own controls.</summary>
    public Expander Create(string title, Control content, Control? header = null, double opacity = 1)
    {
        var expander = new Expander
        {
            Header = header ?? Title(title),
            Content = content,
            IsExpanded = !_collapsed.Contains(title),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Classes = { "component" },
            Opacity = opacity,
        };
        expander.Expanded += (_, _) => _collapsed.Remove(title);
        expander.Collapsed += (_, _) => _collapsed.Add(title);
        return expander;
    }
}
