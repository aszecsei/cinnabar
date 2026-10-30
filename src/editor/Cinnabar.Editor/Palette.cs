using Avalonia.Media;
using Avalonia.Media.Immutable;

namespace Cinnabar.Editor;

/// <summary>
/// The colors that code-built views share. The styles in Styles.axaml spell the same colors out, as XAML cannot name
/// these.
/// </summary>
static class Palette
{
    /// <summary>The editor's red, which marks what is selected or active.</summary>
    public static readonly Color Accent = Color.Parse("#E34234");

    /// <summary>A failure: an error line, a failed asset, a node with a problem.</summary>
    public static readonly Color Error = Color.Parse("#F0605A");

    /// <summary>A warning, or something that is starting.</summary>
    public static readonly Color Warning = Color.Parse("#E8B04A");

    /// <summary>The frame graph's wait time, a deeper amber than <see cref="Warning"/>.</summary>
    public static readonly Color Wait = Color.Parse("#D9A441");

    /// <summary>The outline of a color swatch.</summary>
    public static readonly Color SwatchBorder = Color.Parse("#55555C");

    public static readonly IBrush ErrorBrush = new ImmutableSolidColorBrush(Error);

    public static readonly IBrush WarningBrush = new ImmutableSolidColorBrush(Warning);
}
