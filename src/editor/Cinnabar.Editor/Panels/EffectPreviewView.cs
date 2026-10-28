using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Cinnabar.Editor.Materials;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// An effect's preview (see docs/rendering/particles.md#previews): the effect playing over a ground, which dragging turns
/// about and the wheel moves nearer or farther, under a toolbar that opens the effect's text in the script editor.
/// </summary>
public sealed class EffectPreviewView : DockPanel
{
    public EffectPreviewView(EditorShell shell, EffectPreview preview)
    {
        var toolbar = new DockPanel { Margin = new Thickness(8, 4) };
        var edit = new Button { Content = "Edit in Script Editor", Focusable = false, Margin = new Thickness(0, 0, 8, 0) };
        ToolTip.SetTip(edit, "Open the effect's text. The preview shows each save once it cooks.");
        edit.Click += (_, _) => shell.OpenScript(preview.Path);
        DockPanel.SetDock(edit, DockSide.Left);
        toolbar.Children.Add(edit);
        toolbar.Children.Add(new TextBlock { Text = preview.Path, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextTrimming = Avalonia.Media.TextTrimming.CharacterEllipsis });
        DockPanel.SetDock(toolbar, DockSide.Top);
        Children.Add(toolbar);
        Children.Add(new PreviewPane(shell, preview));
    }
}
