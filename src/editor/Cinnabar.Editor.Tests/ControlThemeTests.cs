using System.Reflection;
using System.Runtime.CompilerServices;
using System.Xml.Linq;
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

    // A resource dictionary with two entries of one key fails to load, and the editor with it, at startup; tests that
    // never load the icons do not see it.
    [Fact]
    public void EveryIconHasAKeyOfItsOwn()
    {
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
        var icons = XDocument.Load(Path.Combine(SourceDirectory(), "..", "Cinnabar.Editor", "Icons", "Icons.axaml"));
        var repeated = icons.Descendants()
            .Select(e => (string?)e.Attribute(x + "Key"))
            .OfType<string>()
            .GroupBy(k => k)
            .Where(g => g.Count() > 1)
            .Select(g => g.Key)
            .ToList();
        Assert.Empty(repeated);
    }

    private static string SourceDirectory([CallerFilePath] string path = "") => Path.GetDirectoryName(path)!;
}
