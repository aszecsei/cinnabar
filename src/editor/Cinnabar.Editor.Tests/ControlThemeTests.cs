using System.Reflection;
using Avalonia.Controls;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

public sealed class ControlThemeTests
{
    // A theme is found by a control's style key, which is its own type unless it says otherwise, so a subclass of a
    // themed control that does not name its base has no template: a ScrollViewer without one does not scroll.
    [Fact]
    public void EveryScrollViewerOfTheEditorTakesScrollViewersTheme()
    {
        var missing = typeof(EditorShell).Assembly.GetTypes()
            .Where(t => t.IsSubclassOf(typeof(ScrollViewer)))
            .Where(t => t.GetProperty("StyleKeyOverride", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.DeclaredOnly) == null)
            .Select(t => t.FullName)
            .ToList();
        Assert.Empty(missing);
    }
}
