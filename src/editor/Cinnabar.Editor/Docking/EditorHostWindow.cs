using Dock.Avalonia.Controls;

namespace Cinnabar.Editor.Docking;

/// <summary>
/// A floating panel's window. A window's key bindings are its own, so without the shell's a panel that pops out would lose
/// every shortcut, and Ctrl+Z or F12 would do nothing while it has the focus.
/// </summary>
public sealed class EditorHostWindow : HostWindow
{
    public EditorHostWindow(Action<Avalonia.Controls.Window> attachKeys)
    {
        // The Window style in Styles.axaml is for the type Window itself, not for this one.
        Background = Palette.WindowBrush;
        attachKeys(this);
    }

    // A subclass would otherwise have no theme: Avalonia looks one up by the exact type.
    protected override Type StyleKeyOverride => typeof(HostWindow);
}
