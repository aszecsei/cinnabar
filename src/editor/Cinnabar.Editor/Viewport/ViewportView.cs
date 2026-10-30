using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// The viewport panel: the frames, the tool palette, the camera's speed and the stats over them, and the input that
/// drives the editor's tools (see docs/editor/viewport.md#viewport). The right button flies with WASD, Q and E; Alt with the
/// left button orbits, the middle button pans, and the wheel dollies. The left button selects, drags a box, or drags
/// the gizmo. Q, W, E and R pick a tool, X switches the gizmo's space, F frames the selection, and H hides it. While
/// the game plays, the viewport gives the game its keyboard and mouse instead, unless the free camera is on, and a
/// frame in the mode's color goes around it. A material dragged from the content browser shows on the submesh under
/// the mouse, and drops onto it.
/// </summary>
public sealed class ViewportView : Grid
{
    // Wheel notches per pixel of an Alt and right button drag.
    const double DollyPerPixel = 1.0 / 40;

    enum Gesture
    {
        None,
        Click,
        Box,
        Gizmo,
        Fly,
        Orbit,
        Pan,
        Dolly,
        Block,
    }

    readonly EditorShell _shell;
    readonly ViewportSession _session;
    readonly ViewportControl _control;
    readonly Border _overlay;
    readonly TextBlock _stats;
    readonly Border _box;
    readonly TextBlock _speed;
    readonly Border _modeFrame;
    readonly List<(ToggleButton Button, string Command)> _tools = [];
    StackPanel _elements = new();
    readonly DispatcherTimer _timer;
    readonly DispatcherTimer _flyTimer;
    readonly HashSet<Key> _held = [];
    Gesture _gesture;
    Point _start;
    Point _last;
    long _lastFly;
    ulong _lastPresented;
    ulong _lastShown;
    long _lastTick = Environment.TickCount64;
    // A material drag: the pixel that it is over, the pixel of the pick that it last sent, whether that pick has not
    // answered, and a count that a drag's end bumps, so an answer from before it does nothing.
    (int X, int Y)? _dragPixel;
    (int X, int Y)? _pickedPixel;
    bool _dragPicking;
    int _dragGeneration;

    public ViewportView(EditorShell shell)
    {
        _shell = shell;
        _session = shell.Viewport;
        Background = Brushes.Black;
        Focusable = true;
        ClipToBounds = true;
        _control = new ViewportControl { Session = _session };
        Children.Add(_control);

        _box = new Border
        {
            Classes = { "selection-box" },
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            IsVisible = false,
            IsHitTestVisible = false,
        };
        Children.Add(_box);
        _modeFrame = new Border { Classes = { "viewport-frame" }, BorderThickness = new Thickness(2), IsHitTestVisible = false };
        Children.Add(_modeFrame);

        _stats = new TextBlock { FontFamily = new FontFamily("Consolas"), FontSize = 12 };
        _overlay = Overlay(_stats, HorizontalAlignment.Right, VerticalAlignment.Top);
        _overlay.IsHitTestVisible = false;
        Children.Add(_overlay);

        _speed = new TextBlock { FontSize = 11 };
        var speed = Overlay(_speed, HorizontalAlignment.Left, VerticalAlignment.Bottom);
        speed.IsHitTestVisible = false;
        Children.Add(speed);
        Children.Add(Palette());

        DragDrop.SetAllowDrop(this, true);
        AddHandler(DragDrop.DragOverEvent, (_, e) => OnDragOver(e));
        AddHandler(DragDrop.DragLeaveEvent, (_, _) => EndMaterialDrag());
        AddHandler(DragDrop.DropEvent, (_, e) => OnDrop(e));

        _timer = new DispatcherTimer(TimeSpan.FromMilliseconds(500), DispatcherPriority.Background, (_, _) => UpdateStats());
        _flyTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Input, (_, _) => FlyStep());
        // Keys that are released elsewhere would keep the camera flying, or stay down in the game.
        LostFocus += (_, _) =>
        {
            _held.Clear();
            _shell.SendInput(GameInput.ReleaseAll());
        };
        DoubleTapped += (_, e) =>
        {
            if (!_shell.InputGoesToGame && _control.FramePoint(e.GetPosition(this)) is { } pixel)
            {
                _shell.Mesh.EnterMeshModeAt(pixel);
            }
        };
        AttachedToVisualTree += (_, _) =>
        {
            _session.ViewChanged += ShowOverlay;
            _shell.ToolsChanged += ShowTools;
            _shell.Mesh.MeshModeChanged += ShowTools;
            _shell.Camera.Changed += ShowSpeed;
            _shell.ModeChanged += ShowMode;
            _timer.Start();
            ShowMode();
            ShowTools();
            ShowSpeed();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _session.ViewChanged -= ShowOverlay;
            _shell.ToolsChanged -= ShowTools;
            _shell.Mesh.MeshModeChanged -= ShowTools;
            _shell.Camera.Changed -= ShowSpeed;
            _shell.ModeChanged -= ShowMode;
            _timer.Stop();
            _flyTimer.Stop();
        };
        UpdateStats();
    }

    static Border Overlay(Control child, HorizontalAlignment horizontal, VerticalAlignment vertical) => new()
    {
        Child = child,
        HorizontalAlignment = horizontal,
        VerticalAlignment = vertical,
        Margin = new Thickness(8),
        Padding = new Thickness(8, 4),
        CornerRadius = new CornerRadius(3),
        Background = new SolidColorBrush(Color.FromArgb(0xc0, 0x20, 0x20, 0x24)),
    };

    // The tools, the gizmo's space and snapping, as buttons for their commands.
    Control Palette()
    {
        var panel = new StackPanel { Spacing = 2 };
        void Add(string command)
        {
            var c = _shell.Commands.Get(command);
            var button = new ToggleButton
            {
                Content = CommandViews.Icon(c.Icon, 16),
                Classes = { "viewport-tool" },
                Focusable = false,
            };
            ToolTip.SetTip(button, c.Description is { } d ? $"{c.Label}\n{d}" : c.Label);
            button.Click += (_, _) =>
            {
                c.Execute();
                ShowTools();
            };
            panel.Children.Add(button);
            _tools.Add((button, command));
        }
        Add(EditorCommands.SelectTool);
        Add(EditorCommands.MoveTool);
        Add(EditorCommands.RotateTool);
        Add(EditorCommands.ScaleTool);
        panel.Children.Add(new Border { Height = 6 });
        Add(EditorCommands.LocalSpace);
        Add(EditorCommands.Snap);
        // The element kinds, while mesh mode is on.
        _elements = new StackPanel { Spacing = 2, IsVisible = false };
        _elements.Children.Add(new Border { Height = 6 });
        panel.Children.Add(_elements);
        var elementPanel = panel;
        panel = _elements;
        Add(EditorCommands.MeshVertices);
        Add(EditorCommands.MeshEdges);
        Add(EditorCommands.MeshFaces);
        panel = elementPanel;
        var palette = Overlay(panel, HorizontalAlignment.Left, VerticalAlignment.Top);
        palette.Padding = new Thickness(3);
        return palette;
    }

    void ShowTools()
    {
        ShowSpeed();
        _elements.IsVisible = _shell.Mesh.InMeshMode;
        foreach (var (button, command) in _tools)
        {
            button.IsChecked = _shell.Commands.Get(command).IsChecked;
        }
    }

    void ShowMode()
    {
        _modeFrame.Classes.Set("playing", _shell.Mode == Link.Protocol.EditorMode.Play);
        _modeFrame.Classes.Set("paused", _shell.Mode == Link.Protocol.EditorMode.Paused);
        if (_shell.InputGoesToGame)
        {
            EndGesture();
        }
        ShowSpeed();
    }

    void ShowSpeed() => _speed.Text = $"{FormatSpeed(_shell.Camera.Speed)}   ·   {_shell.Tool}, {_shell.Space}{(_shell.Snap ? ", snapping" : "")}"
        + (_shell.Mesh.InMeshMode ? $"   ·   grid {Mesh.MeshGrid.Format(_shell.Mesh.GridSize)}" : "");

    static string FormatSpeed(double metersPerSecond) => metersPerSecond >= 1000 ? $"{metersPerSecond / 1000:0.##} km/s" : $"{metersPerSecond:0.##} m/s";

    static SelectMode ModeOf(KeyModifiers modifiers) =>
        modifiers.HasFlag(KeyModifiers.Shift) ? SelectMode.Add : modifiers.HasFlag(KeyModifiers.Control) ? SelectMode.Toggle : SelectMode.Replace;

    // The material that a drag carries, with the frame pixel under it, or null when the viewport does not take it.
    (string Guid, Vec2 Pixel)? DraggedMaterial(DragEventArgs e) =>
        _shell.IsEditing && ContentBrowserView.Dropped(e) is { } guid && _shell.IsMaterial(guid) && _control.FramePoint(e.GetPosition(this)) is { } pixel
            ? (guid, pixel) : null;

    // The prefab that a drag carries, with the frame pixel under it, or null when it carries none.
    (string Guid, Vec2 Pixel)? DraggedPrefab(DragEventArgs e) =>
        _shell.IsEditing && !_shell.Mesh.InMeshMode && ContentBrowserView.Dropped(e) is { } guid && _shell.IsPrefab(guid) && _control.FramePoint(e.GetPosition(this)) is { } pixel
            ? (guid, pixel) : null;

    void OnDragOver(DragEventArgs e)
    {
        if (DraggedPrefab(e) is var (prefab, at))
        {
            e.DragEffects = DragDropEffects.Copy;
            e.Handled = true;
            _dragPixel = ((int)Math.Floor(at.X), (int)Math.Floor(at.Y));
            PickUnderDrag(prefab, isPrefab: true);
            return;
        }
        if (DraggedMaterial(e) is not var (guid, pixel))
        {
            e.DragEffects = DragDropEffects.None;
            EndMaterialDrag();
            return;
        }
        e.DragEffects = DragDropEffects.Link;
        e.Handled = true;
        if (_shell.Mesh.InMeshMode)
        {
            // In mesh mode the editor picks the face itself, so the drag shows at once.
            _shell.Mesh.PreviewFaceMaterial(pixel, guid);
            return;
        }
        _dragPixel = ((int)Math.Floor(pixel.X), (int)Math.Floor(pixel.Y));
        PickUnderDrag(guid);
    }

    // Picks the pixel under the drag, one pick at a time, and shows the material, or the prefab's instance, where each
    // answer finds.
    void PickUnderDrag(string guid, bool isPrefab = false)
    {
        if (_dragPicking || _dragPixel is not { } pixel || pixel == _pickedPixel)
        {
            return;
        }
        var generation = _dragGeneration;
        _pickedPixel = pixel;
        _dragPicking = _shell.PickPixel(new Vec2(pixel.X, pixel.Y), result =>
        {
            if (generation != _dragGeneration)
            {
                return;
            }
            _dragPicking = false;
            if (isPrefab)
            {
                _shell.PreviewPrefab(guid, _shell.DropPoint(new Vec2(pixel.X + 0.5, pixel.Y + 0.5), result));
            }
            else
            {
                _shell.PreviewMaterial(_shell.MaterialTargetOf(result), guid);
            }
            PickUnderDrag(guid, isPrefab);
        });
    }

    void OnDrop(DragEventArgs e)
    {
        if (DraggedPrefab(e) is var (prefab, at))
        {
            e.Handled = true;
            EndPicks();
            // The instance stays where the drag last showed it, or where the drop is if no pick has answered.
            if (!_shell.CommitPrefab())
            {
                _shell.PreviewPrefab(prefab, _shell.DropPoint(at, null));
                _shell.CommitPrefab();
            }
            return;
        }
        var dragged = DraggedMaterial(e);
        EndPicks();
        if (dragged is not var (guid, pixel))
        {
            _shell.CancelMaterial();
            return;
        }
        e.Handled = true;
        if (_shell.Mesh.InMeshMode)
        {
            _shell.Mesh.DropFaceMaterial(pixel, guid);
            return;
        }
        var generation = _dragGeneration;
        if (!_shell.PickPixel(pixel, result =>
            {
                if (generation == _dragGeneration)
                {
                    _shell.DropMaterial(result, guid);
                }
            }))
        {
            _shell.CancelMaterial();
        }
    }

    // A drag that leaves the viewport, or stops carrying a material it takes, puts back what it showed.
    void EndMaterialDrag()
    {
        EndPicks();
        _shell.CancelMaterial();
        _shell.CancelPrefab();
    }

    void EndPicks()
    {
        _dragGeneration++;
        _dragPixel = _pickedPixel = null;
        _dragPicking = false;
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (_gesture != Gesture.None)
        {
            return;
        }
        Focus();
        var point = e.GetCurrentPoint(this);
        if (_shell.InputGoesToGame)
        {
            ForwardMove(point.Position);
            if (GameInput.Button(point.Properties.PointerUpdateKind) is { } button)
            {
                _shell.SendInput(GameInput.Down(button));
            }
            e.Pointer.Capture(this);
            e.Handled = true;
            return;
        }
        var alt = e.KeyModifiers.HasFlag(KeyModifiers.Alt);
        _start = _last = point.Position;
        if (point.Properties.IsRightButtonPressed)
        {
            _gesture = alt ? Gesture.Dolly : Gesture.Fly;
            if (_gesture == Gesture.Fly)
            {
                _lastFly = Environment.TickCount64;
                _flyTimer.Start();
            }
        }
        else if (point.Properties.IsMiddleButtonPressed)
        {
            _gesture = Gesture.Pan;
        }
        else if (point.Properties.IsLeftButtonPressed)
        {
            if (alt)
            {
                _gesture = Gesture.Orbit;
            }
            else if (_control.FramePoint(point.Position) is { } pixel && _shell.PressGizmo(pixel, extrude: e.KeyModifiers.HasFlag(KeyModifiers.Shift)))
            {
                _gesture = Gesture.Gizmo;
            }
            else if (_shell.Mesh.MeshTool == MeshTool.Create && _control.FramePoint(point.Position) is { } corner && _shell.Mesh.BeginBlock(corner))
            {
                _gesture = Gesture.Block;
            }
            else
            {
                _gesture = Gesture.Click;
            }
        }
        if (_gesture != Gesture.None)
        {
            e.Pointer.Capture(this);
            e.Handled = true;
        }
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var position = e.GetPosition(this);
        if (_shell.InputGoesToGame)
        {
            ForwardMove(position);
            return;
        }
        // Looking and orbiting turn by frame pixels, so they feel the same at any window scale.
        var delta = (position - _last) * _control.FrameScale;
        _last = position;
        switch (_gesture)
        {
            case Gesture.None:
                if (_control.FramePoint(position) is { } hover)
                {
                    _shell.HoverGizmo(hover);
                    _shell.Mesh.HoverMesh(hover);
                }
                break;
            case Gesture.Block:
                if (_control.FramePoint(position) is { } corner)
                {
                    _shell.Mesh.DragBlock(corner);
                }
                break;
            case Gesture.Fly:
                _shell.Camera.Look(delta.X, delta.Y);
                break;
            case Gesture.Orbit:
                _shell.Orbit(delta.X, delta.Y);
                break;
            case Gesture.Pan:
                _shell.Camera.Pan(delta.X, delta.Y, _shell.FrameSize.Height);
                break;
            case Gesture.Dolly:
                _shell.Camera.Dolly(-delta.Y * DollyPerPixel);
                break;
            case Gesture.Gizmo:
                if (_control.FramePoint(position) is { } drag)
                {
                    _shell.DragGizmo(drag, e.KeyModifiers.HasFlag(KeyModifiers.Control));
                }
                break;
            case Gesture.Click:
                if ((position - _start) is var moved && Gestures.MovedPast(moved))
                {
                    _gesture = Gesture.Box;
                    ShowBox(position);
                }
                break;
            case Gesture.Box:
                ShowBox(position);
                break;
        }
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        var position = e.GetPosition(this);
        if (_shell.InputGoesToGame)
        {
            if (GameInput.Button(e.GetCurrentPoint(this).Properties.PointerUpdateKind) is { } button)
            {
                _shell.SendInput(GameInput.Up(button));
            }
            e.Pointer.Capture(null);
            return;
        }
        var mode = ModeOf(e.KeyModifiers);
        switch (_gesture)
        {
            case Gesture.Gizmo:
                _shell.ReleaseGizmo();
                break;
            case Gesture.Block:
                _shell.Mesh.EndBlock(forceEntity: e.KeyModifiers.HasFlag(KeyModifiers.Control));
                break;
            case Gesture.Click:
                if (_control.FramePoint(position) is { } pixel && !_shell.Mesh.AddToolPoint(pixel))
                {
                    _shell.PickAt(pixel, mode);
                }
                break;
            case Gesture.Box:
                if (_control.FramePoint(_start) is { } a && _control.FramePoint(position) is { } b)
                {
                    _shell.PickBox(a, b, mode);
                }
                break;
        }
        EndGesture();
        e.Pointer.Capture(null);
    }

    protected override void OnPointerCaptureLost(PointerCaptureLostEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        if (_gesture == Gesture.Gizmo)
        {
            _shell.ReleaseGizmo();
        }
        if (_gesture == Gesture.Block)
        {
            _shell.Mesh.CancelBlock();
        }
        EndGesture();
    }

    void EndGesture()
    {
        _gesture = Gesture.None;
        _box.IsVisible = false;
        _flyTimer.Stop();
    }

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        if (_shell.InputGoesToGame)
        {
            _shell.SendInput(GameInput.Scroll(e.Delta.Y));
            e.Handled = true;
            return;
        }
        if (_gesture == Gesture.Fly)
        {
            _shell.Camera.ChangeSpeed(e.Delta.Y);
        }
        else
        {
            _shell.Camera.Dolly(e.Delta.Y);
        }
        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (_shell.InputGoesToGame)
        {
            if (GameInput.Key(e.Key) is { } key)
            {
                _shell.SendInput(GameInput.Down(key));
            }
            // The function keys stay the editor's too, so F5 and Shift+F5 work while the game has the keys.
            e.Handled = e.Key is not (>= Avalonia.Input.Key.F1 and <= Avalonia.Input.Key.F24);
            return;
        }
        if (_gesture == Gesture.Fly)
        {
            _held.Add(e.Key);
            e.Handled = true;
            return;
        }
        // The texture tools' keys, on the selected faces (see docs/editor/mesh-editing.md#texture-tools): Shift makes the
        // step ten times and Ctrl a tenth.
        if (_shell.Mesh.CanRunTextureTool && (e.KeyModifiers & ~(KeyModifiers.Shift | KeyModifiers.Control)) == 0)
        {
            var multiplier = e.KeyModifiers.HasFlag(KeyModifiers.Shift) ? 10 : e.KeyModifiers.HasFlag(KeyModifiers.Control) ? 0.1 : 1;
            var ran = e.Key switch
            {
                Key.Left => _shell.Mesh.ShiftTexture(1, 0, multiplier),
                Key.Right => _shell.Mesh.ShiftTexture(-1, 0, multiplier),
                Key.Up => _shell.Mesh.ShiftTexture(0, 1, multiplier),
                Key.Down => _shell.Mesh.ShiftTexture(0, -1, multiplier),
                Key.OemComma => _shell.Mesh.RotateTexture(1, multiplier),
                Key.OemPeriod => _shell.Mesh.RotateTexture(-1, multiplier),
                Key.OemPlus => _shell.Mesh.ScaleTexture(1, multiplier),
                Key.OemMinus => _shell.Mesh.ScaleTexture(-1, multiplier),
                _ => (bool?)null,
            };
            if (ran != null)
            {
                e.Handled = true;
                return;
            }
        }
        if (e.KeyModifiers != KeyModifiers.None)
        {
            return;
        }
        var command = e.Key switch
        {
            Key.Q => EditorCommands.SelectTool,
            Key.W => EditorCommands.MoveTool,
            Key.E => EditorCommands.RotateTool,
            Key.R => EditorCommands.ScaleTool,
            Key.X => EditorCommands.LocalSpace,
            Key.F => EditorCommands.FrameSelected,
            Key.H => EditorCommands.HideSelected,
            // Mesh mode's keys (see docs/editor/mesh-editing.md#mesh-mode).
            Key.Tab => EditorCommands.EditMesh,
            Key.D1 when _shell.Mesh.InMeshMode => EditorCommands.MeshVertices,
            Key.D2 when _shell.Mesh.InMeshMode => EditorCommands.MeshEdges,
            Key.D3 when _shell.Mesh.InMeshMode => EditorCommands.MeshFaces,
            Key.OemOpenBrackets => EditorCommands.MeshGridFiner,
            Key.OemCloseBrackets => EditorCommands.MeshGridCoarser,
            _ => null,
        };
        if (e.Key == Key.Escape && _gesture == Gesture.Gizmo)
        {
            _shell.CancelGizmo();
            _gesture = Gesture.None;
            e.Handled = true;
        }
        else if (e.Key == Key.Escape && _gesture == Gesture.Block)
        {
            _shell.Mesh.CancelBlock();
            EndGesture();
            e.Handled = true;
        }
        else if (e.Key == Key.Escape && _shell.Mesh.InMeshMode)
        {
            _shell.Mesh.EscapeMeshMode();
            e.Handled = true;
        }
        else if (e.Key == Key.Escape && (_shell.Mesh.MeshTool != MeshTool.Select || _shell.Mesh.ToolPointCount > 0))
        {
            if (_shell.Mesh.ToolPointCount > 0)
            {
                _shell.Mesh.CancelToolPoints();
            }
            else
            {
                _shell.Mesh.SetMeshTool(MeshTool.Select);
            }
            e.Handled = true;
        }
        else if (e.Key is Key.Enter or Key.Return && _shell.Mesh.ToolPointCount > 0)
        {
            _shell.Mesh.ApplyToolPoints();
            e.Handled = true;
        }
        else if (e.Key == Key.Back && _shell.Mesh.ToolPointCount > 0)
        {
            _shell.Mesh.RemoveLastToolPoint();
            e.Handled = true;
        }
        else if (command != null)
        {
            _shell.Commands.Get(command).Execute();
            e.Handled = true;
        }
    }

    protected override void OnKeyUp(KeyEventArgs e)
    {
        base.OnKeyUp(e);
        _held.Remove(e.Key);
        if (_shell.InputGoesToGame && GameInput.Key(e.Key) is { } key)
        {
            _shell.SendInput(GameInput.Up(key));
        }
    }

    // Each tick of a flight moves the camera by the keys that are held, for the time since the last tick.
    void FlyStep()
    {
        var now = Environment.TickCount64;
        var seconds = Math.Min((now - _lastFly) / 1000.0, 0.1);
        _lastFly = now;
        double Axis(Key positive, Key negative) => (_held.Contains(positive) ? 1 : 0) - (_held.Contains(negative) ? 1 : 0);
        var direction = new Vec3(Axis(Key.D, Key.A), Axis(Key.E, Key.Q), Axis(Key.W, Key.S));
        var boost = _held.Contains(Key.LeftShift) || _held.Contains(Key.RightShift) ? 4 : 1;
        _shell.Camera.Fly(direction, seconds, boost);
    }

    // The game sees the mouse in pixels of its frame.
    void ForwardMove(Point position)
    {
        if (_control.FramePoint(position) is { } pixel)
        {
            _shell.SendInput(GameInput.Move(pixel));
        }
    }

    void ShowBox(Point to)
    {
        _box.IsVisible = true;
        _box.Margin = new Thickness(Math.Min(_start.X, to.X), Math.Min(_start.Y, to.Y), 0, 0);
        _box.Width = Math.Abs(to.X - _start.X);
        _box.Height = Math.Abs(to.Y - _start.Y);
    }

    void ShowOverlay() => _overlay.IsVisible = _session.ShowStats;

    void UpdateStats()
    {
        ShowOverlay();
        var now = Environment.TickCount64;
        var seconds = Math.Max(now - _lastTick, 1) / 1000.0;
        _lastTick = now;
        // The host's rate comes from its frame numbers. A lower shown rate means that the viewport drops frames.
        var hostFps = (_session.FrameShown - Math.Min(_lastShown, _session.FrameShown)) / seconds;
        var shownFps = (_session.FramesPresented - _lastPresented) / seconds;
        _lastShown = _session.FrameShown;
        _lastPresented = _session.FramesPresented;
        var size = _session.FrameSize;
        _stats.Text = $"frame {_session.FrameShown}  {size.Width}x{size.Height}\nhost {hostFps:0.0} fps  shown {shownFps:0.0} fps\n{_session.AdapterName}\n{_session.Interop}";
    }
}
