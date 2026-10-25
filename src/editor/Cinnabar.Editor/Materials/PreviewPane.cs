using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Viewport;
using PreviewMesh = Cinnabar.Editor.Link.Protocol.PreviewMesh;

namespace Cinnabar.Editor.Materials;

/// <summary>
/// The material's preview (see docs/rendering.md#material-previews): the game's frames of the material on a mesh, which
/// the editor copies as it does the viewport's. Dragging turns the camera about the mesh, the wheel moves it nearer or
/// farther, and the buttons pick the mesh.
/// </summary>
sealed class PreviewPane : Grid
{
    readonly MaterialEditor _editor;
    readonly List<(ToggleButton Button, PreviewMesh Mesh)> _meshes = [];
    readonly TextBlock _waiting = new() { Classes = { "empty" }, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12) };
    Point _last;
    bool _dragging;

    public PreviewPane(EditorShell shell, MaterialEditor editor)
    {
        _editor = editor;
        Background = new SolidColorBrush(Color.Parse("#141416"));
        ClipToBounds = true;
        if (editor.Preview is not { } session)
        {
            _waiting.Text = $"Every one of the {EditorShell.MaxPreviews} previews is in use. Close another material to see this one.";
            Children.Add(_waiting);
            return;
        }
        Children.Add(_waiting);
        Children.Add(new ViewportControl { Session = session });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, Margin = new Thickness(6), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom };
        foreach (var mesh in Enum.GetValues<PreviewMesh>().Where(m => m != PreviewMesh.Asset))
        {
            var button = new ToggleButton { Content = mesh.ToString(), Classes = { "viewport-tool" }, FontSize = 11, Focusable = false };
            button.Click += (_, _) =>
            {
                _editor.SetMesh(mesh);
                ShowMesh();
            };
            buttons.Children.Add(button);
            _meshes.Add((button, mesh));
        }
        Children.Add(new Border
        {
            Child = buttons,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Bottom,
            Background = new SolidColorBrush(Color.FromArgb(0xc0, 0x20, 0x20, 0x24)),
            CornerRadius = new CornerRadius(3),
            Margin = new Thickness(6),
        });
        ShowMesh();
        var timer = new Avalonia.Threading.DispatcherTimer(TimeSpan.FromMilliseconds(250), Avalonia.Threading.DispatcherPriority.Background, (_, _) => ShowWaiting(shell, session));
        AttachedToVisualTree += (_, _) => timer.Start();
        DetachedFromVisualTree += (_, _) => timer.Stop();
        ShowWaiting(shell, session);
    }

    void ShowWaiting(EditorShell shell, ViewportSession session)
    {
        _waiting.IsVisible = !session.HasPicture;
        _waiting.Text = shell.Host.Linked ? "The preview draws once the material cooks." : "The preview needs the host.";
    }

    void ShowMesh()
    {
        foreach (var (button, mesh) in _meshes)
        {
            button.IsChecked = mesh == _editor.Mesh;
        }
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (_editor.Preview == null || !e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
        {
            return;
        }
        _dragging = true;
        _last = e.GetPosition(this);
        e.Pointer.Capture(this);
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (!_dragging)
        {
            return;
        }
        var position = e.GetPosition(this);
        var delta = position - _last;
        _last = position;
        _editor.Orbit(delta.X, delta.Y);
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        _dragging = false;
        e.Pointer.Capture(null);
    }

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        _editor.Zoom(e.Delta.Y);
        e.Handled = true;
    }
}
