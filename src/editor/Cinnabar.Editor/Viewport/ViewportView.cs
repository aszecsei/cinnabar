using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Input.TextInput;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// One view of the game, as a document (see docs/editor/viewport.md#views): its frames, its view, and the stats over them.
/// A scene view also has the tool palette and the camera's speed, and its title in a quad, and the input that drives the editor's tools. The right
/// button flies with WASD, Q and E; Alt with the left button orbits, the middle button pans, and the wheel dollies. The
/// left button selects, drags a box, or drags the gizmo. Q, W, E and R pick a tool, X switches the gizmo's space, F frames
/// the selection, and H hides it. A material dragged from the content browser shows on the submesh under the mouse, and
/// drops onto it. The mouse makes a scene view the active one, which the shell's tools act in. A scene view keeps all of
/// this while the game plays. The Game view has none of it: it gives the game its keyboard, mouse, text and gamepads
/// while the game plays and the view has the focus, with a frame in the mode's color around it, and is passive otherwise.
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
    readonly EditorViewport _viewport;
    readonly ViewportSession _session;
    readonly Border _activeFrame;
    readonly ComboBox _view;
    readonly TextBlock _title;
    // The title, the view menu and the view box at the top: their presses are theirs, not the frame's.
    readonly StackPanel _header;
    bool _showingView;
    readonly ViewportControl _control;
    readonly Border _overlay;
    // The Game view's notice that the world has no camera; null in a scene view.
    readonly Border? _noCamera;
    readonly TextBlock _stats;
    readonly Border _box;
    readonly TextBlock _speed;
    readonly Border _modeFrame;
    readonly List<(ToggleButton Button, string Command)> _tools = [];
    StackPanel _elements = new();
    readonly DispatcherTimer _timer;
    readonly DispatcherTimer _flyTimer;
    readonly DispatcherTimer _gamepadTimer;
    // Steps the camera's turn to an axis while one runs (see EditorShell.StepTurn).
    readonly DispatcherTimer _turnTimer;
    long _lastTurn;
    // A scene view's menu of the views along the axes and the projections, and the button that names the view.
    readonly TextBlock _lookText = new();
    readonly GamepadPoller _gamepads = new(GamepadPoller.ReadXInput);
    bool _pollingGamepads;
    readonly GameInput.Characters _characters = new();
    // Above the overlay of the camera's speed.
    const double CompositionBottom = 44;
    readonly TextBlock _composition;
    readonly Border _compositionOverlay;
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

    // The game has the keyboard and the mouse of the Game view only.
    bool InputGoesToGame => _viewport.IsGame && _shell.InputGoesToGame;

    public ViewportView(EditorShell shell, EditorViewport viewport)
    {
        _shell = shell;
        _viewport = viewport;
        _session = viewport.Session;
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
        _activeFrame = new Border { Classes = { "viewport-active" }, BorderThickness = new Thickness(1), IsHitTestVisible = false };
        Children.Add(_activeFrame);
        _modeFrame = new Border { Classes = { "viewport-frame" }, BorderThickness = new Thickness(2), IsHitTestVisible = false };
        Children.Add(_modeFrame);

        _stats = new TextBlock { FontFamily = new FontFamily("Consolas"), FontSize = 12 };
        _overlay = Overlay(_stats, HorizontalAlignment.Right, VerticalAlignment.Top);
        _overlay.IsHitTestVisible = false;
        if (_viewport.IsGame)
        {
            Children.Add(_overlay);
            _noCamera = Overlay(new TextBlock { Text = "No camera in the scene: showing a default view", FontSize = 12 }, HorizontalAlignment.Center, VerticalAlignment.Top);
            _noCamera.Margin = new Thickness(8, 44, 8, 8);
            _noCamera.IsHitTestVisible = false;
            _noCamera.IsVisible = false;
            Children.Add(_noCamera);
        }
        else
        {
            // The view gizmo is in the corner, under the stats while they show.
            var corner = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
            corner.Children.Add(_overlay);
            corner.Children.Add(new ViewGizmoControl(shell, viewport) { Margin = new Thickness(8), HorizontalAlignment = HorizontalAlignment.Right });
            Children.Add(corner);
        }

        _speed = new TextBlock { FontSize = 11 };
        var speed = Overlay(_speed, HorizontalAlignment.Left, VerticalAlignment.Bottom);
        speed.IsHitTestVisible = false;
        if (!_viewport.IsGame)
        {
            Children.Add(speed);
            Children.Add(Palette());
        }
        // What this viewport shows in place of the lit scene, which the ribbon's View choice also sets for the one it acts on.
        _view = new ComboBox
        {
            Classes = { "viewport-view" },
            ItemsSource = EditorShell.DebugViewNames,
            Focusable = false,
        };
        // A scene view is named while it has company in the Scene, so the four can be told apart.
        _title = new TextBlock
        {
            Text = viewport.Title,
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 6, 0),
            Foreground = Brushes.White,
            Opacity = 0.8,
        };
        var header = _header = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(8),
            IsHitTestVisible = true,
        };
        header.Children.Add(_title);
        if (!_viewport.IsGame)
        {
            header.Children.Add(LookButton());
        }
        header.Children.Add(_view);
        ToolTip.SetTip(_view, "What this viewport shows: the lit scene, or a debug view of what makes it.");
        _view.SelectionChanged += (_, _) =>
        {
            if (!_showingView && _view.SelectedIndex >= 0)
            {
                _shell.ApplyViewportSettings(_viewport, _viewport.Settings with { DebugView = (Link.Protocol.DebugView)_view.SelectedIndex });
            }
        };
        Children.Add(header);

        if (!_viewport.IsGame)
        {
            DragDrop.SetAllowDrop(this, true);
            AddHandler(DragDrop.DragOverEvent, (_, e) => OnDragOver(e));
            AddHandler(DragDrop.DragLeaveEvent, (_, _) => EndMaterialDrag());
            AddHandler(DragDrop.DropEvent, (_, e) => OnDrop(e));
        }

        _timer = new DispatcherTimer(TimeSpan.FromMilliseconds(500), DispatcherPriority.Background, (_, _) => UpdateStats());
        _flyTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Input, (_, _) => FlyStep());
        _gamepadTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Input, (_, _) => PollGamepads());
        _turnTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Input, (_, _) => TurnStep());

        _composition = new TextBlock { FontSize = 14 };
        _compositionOverlay = Overlay(_composition, HorizontalAlignment.Left, VerticalAlignment.Bottom);
        _compositionOverlay.Margin = new Thickness(8, 8, 8, CompositionBottom);
        _compositionOverlay.IsHitTestVisible = false;
        _compositionOverlay.IsVisible = false;
        Children.Add(_compositionOverlay);
        // The IME is on only while the game has the input. Elsewhere in the viewport a key is a tool's.
        var textClient = new GameTextClient(this, new Rect(16, CompositionBottom, 0, 16), ShowComposition);
        TextInputMethodClientRequested += (_, e) =>
        {
            if (InputGoesToGame)
            {
                e.Client = textClient;
            }
        };

        // The game's keys are the Game view's, so only its focus gives them to the game.
        GotFocus += (_, _) =>
        {
            _shell.ActivateViewport(_viewport);
            if (_viewport.IsGame)
            {
                _shell.GameViewHasFocus = true;
            }
        };
        // Keys that are released elsewhere would keep the camera flying, or stay down in the game.
        LostFocus += (_, _) =>
        {
            _held.Clear();
            if (_viewport.IsGame)
            {
                _shell.GameViewHasFocus = false;
                _shell.SendInput(GameInput.ReleaseAll());
            }
        };
        DoubleTapped += (_, e) =>
        {
            if (!_viewport.IsGame && !OnHeader(e) && _control.FramePoint(e.GetPosition(this)) is { } pixel)
            {
                _shell.ActivateViewport(_viewport);
                _shell.Mesh.EnterMeshModeAt(pixel);
            }
        };
        AttachedToVisualTree += (_, _) =>
        {
            _session.ViewChanged += ShowOverlay;
            _shell.ToolsChanged += ShowTools;
            _shell.Mesh.MeshModeChanged += ShowTools;
            if (!_viewport.IsGame)
            {
                _viewport.Camera.Changed += ShowSpeed;
                _viewport.Camera.Changed += ShowLook;
                _viewport.TurnStarted += StartTurn;
                ShowLook();
            }
            _shell.ModeChanged += ShowMode;
            _shell.ActiveViewportChanged += ShowActive;
            _shell.ViewportsChanged += ShowActive;
            _shell.SceneViewsChanged += ShowTitle;
            _shell.ViewportSettingsChanged += ShowView;
            _timer.Start();
            if (_viewport.IsGame)
            {
                _gamepadTimer.Start();
                _shell.WorldCameraChanged += ShowCamera;
                _viewport.FocusRequested += TakeFocus;
                ShowCamera();
                TakeFocus();
            }
            ShowMode();
            ShowTools();
            ShowSpeed();
            ShowActive();
            ShowTitle();
            ShowView();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _session.ViewChanged -= ShowOverlay;
            _shell.ToolsChanged -= ShowTools;
            _shell.Mesh.MeshModeChanged -= ShowTools;
            if (!_viewport.IsGame)
            {
                _viewport.Camera.Changed -= ShowSpeed;
                _viewport.Camera.Changed -= ShowLook;
                _viewport.TurnStarted -= StartTurn;
            }
            _shell.ModeChanged -= ShowMode;
            _shell.ActiveViewportChanged -= ShowActive;
            _shell.ViewportsChanged -= ShowActive;
            _shell.SceneViewsChanged -= ShowTitle;
            _shell.ViewportSettingsChanged -= ShowView;
            if (_viewport.IsGame)
            {
                _shell.WorldCameraChanged -= ShowCamera;
                _viewport.FocusRequested -= TakeFocus;
            }
            _timer.Stop();
            _flyTimer.Stop();
            _gamepadTimer.Stop();
            _turnTimer.Stop();
        };
        UpdateStats();
    }

    // The viewport that the View tab acts on has a frame around it while more than one viewport is shown.
    void ShowActive() => _activeFrame.Classes.Set("active", _shell.SettingsViewport == _viewport && _shell.ShownViewports.Skip(1).Any());

    // The button that names the view along an axis and its projection, with a menu of the axes' views and the projections.
    Control LookButton()
    {
        var menu = new MenuFlyout();
        var axes = new List<(MenuItem Item, ViewAxis Axis)>();
        foreach (var axis in Enum.GetValues<ViewAxis>())
        {
            var item = new MenuItem { Header = axis.ToString(), ToggleType = MenuItemToggleType.Radio, GroupName = "axis" };
            item.Click += (_, _) =>
            {
                _shell.ActivateViewport(_viewport);
                _shell.LookAlong(_viewport, axis);
            };
            menu.Items.Add(item);
            axes.Add((item, axis));
        }
        menu.Items.Add(new Separator());
        var projections = new List<(MenuItem Item, Link.Protocol.CameraProjection Projection)>();
        foreach (var projection in Enum.GetValues<Link.Protocol.CameraProjection>())
        {
            var item = new MenuItem { Header = projection.ToString(), ToggleType = MenuItemToggleType.Radio, GroupName = "projection" };
            item.Click += (_, _) =>
            {
                _shell.ActivateViewport(_viewport);
                _shell.SetProjection(_viewport, projection);
            };
            menu.Items.Add(item);
            projections.Add((item, projection));
        }
        // The checks show the camera as it is when the menu opens.
        menu.Opening += (_, _) =>
        {
            var aligned = ViewGizmo.Aligned(_viewport.Camera);
            foreach (var (item, axis) in axes)
            {
                item.IsChecked = axis == aligned;
            }
            foreach (var (item, projection) in projections)
            {
                item.IsChecked = projection == _viewport.Camera.Projection;
            }
        };
        _lookText.VerticalAlignment = VerticalAlignment.Center;
        var button = new Button { Content = _lookText, Classes = { "viewport-look" }, Focusable = false, Flyout = menu, Margin = new Thickness(0, 0, 4, 0) };
        ToolTip.SetTip(button, "Which way this view looks, and its projection: look along an axis, or switch between perspective and orthographic.");
        return button;
    }

    void ShowLook() =>
        _lookText.Text = $"{ViewGizmo.Label(_viewport.Camera)} ▾";

    void StartTurn()
    {
        _lastTurn = Environment.TickCount64;
        _turnTimer.Start();
    }

    // Each tick moves the turn on by the time since the last, until it ends or something else moves the camera.
    void TurnStep()
    {
        var now = Environment.TickCount64;
        var elapsed = now - _lastTurn;
        _lastTurn = now;
        if (!_shell.StepTurn(_viewport, elapsed))
        {
            _turnTimer.Stop();
        }
    }

    bool OnHeader(RoutedEventArgs e) => e.Source is Visual source && _header.IsVisualAncestorOf(source);

    void ShowTitle() => _title.IsVisible = !_viewport.IsGame && _shell.SceneDocumentViews.Count > 1;

    void ShowView()
    {
        _showingView = true;
        _view.SelectedIndex = (int)_viewport.Settings.DebugView;
        _showingView = false;
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
        Add(EditorCommands.NavPathTool);
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
        // The mode's frame is around the Game view, which shows the game as it plays.
        _modeFrame.Classes.Set("playing", _viewport.IsGame && _shell.Mode == Link.Protocol.EditorMode.Play);
        _modeFrame.Classes.Set("paused", _viewport.IsGame && _shell.Mode == Link.Protocol.EditorMode.Paused);
        if (InputGoesToGame)
        {
            EndGesture();
        }
        RequeryTextInput();
        ShowSpeed();
    }

    // The IME asks again whether the view has a text client, which it has only while the game has the input. The event's
    // own args type, as a handler typed for it on the route casts to it. Internal to the tests.
    internal void RequeryTextInput() =>
        RaiseEvent(new TextInputMethodClientRequeryRequestedEventArgs { RoutedEvent = InputMethod.TextInputMethodClientRequeryRequestedEvent });

    // The Game view takes the keyboard focus when the shell asks, as Play does, so the game has the keys at once. Docking
    // attaches the view after the tab changes, so the focus moves once it has.
    void TakeFocus()
    {
        if (_viewport.TakeFocusRequest())
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (VisualRoot != null)
                {
                    Focus();
                }
            });
        }
    }

    // The Game view says so when the world has no camera, over the default view that the game draws then.
    void ShowCamera()
    {
        if (_noCamera != null)
        {
            _noCamera.IsVisible = _shell.World.HasWorld && !_shell.WorldHasCamera;
        }
    }

    void ShowSpeed()
    {
        if (!_viewport.IsGame)
        {
            _speed.Text = $"{FormatSpeed(_viewport.Camera.Speed)}   ·   {_shell.Tool}, {_shell.Space}{(_shell.Snap ? ", snapping" : "")}"
                + (_shell.Mesh.InMeshMode ? $"   ·   grid {Mesh.MeshGrid.Format(_shell.Mesh.GridSize)}" : "");
        }
    }

    static string FormatSpeed(double metersPerSecond) => metersPerSecond >= 1000 ? $"{metersPerSecond / 1000:0.##} km/s" : $"{metersPerSecond:0.##} m/s";

    static SelectMode ModeOf(KeyModifiers modifiers) =>
        modifiers.HasFlag(KeyModifiers.Shift) ? SelectMode.Add : modifiers.HasFlag(KeyModifiers.Control) ? SelectMode.Toggle : SelectMode.Replace;

    // The material that a drag carries, with the frame pixel under it, or null when the viewport does not take it.
    (string Guid, Vec2 Pixel)? DraggedMaterial(DragEventArgs e) =>
        _shell.IsEditing && ContentBrowserView.Dropped(e) is { } guid && _shell.IsMaterial(guid) && _control.FramePoint(e.GetPosition(this)) is { } pixel
            ? (guid, pixel) : null;

    // The prefab or part of one that a drag carries, the first of several, with the frame pixel under it, or null when it
    // carries none.
    (string Guid, ulong Node, Vec2 Pixel)? DraggedPrefab(DragEventArgs e)
    {
        if (!_shell.IsEditing || _shell.Mesh.InMeshMode || _control.FramePoint(e.GetPosition(this)) is not { } pixel)
        {
            return null;
        }
        if (ContentBrowserView.DroppedParts(e) is [var (part, node), ..])
        {
            return (part, node, pixel);
        }
        return ContentBrowserView.Dropped(e) is { } guid && _shell.PrefabToPlace(guid) is { } prefab ? (prefab, 0, pixel) : null;
    }

    void OnDragOver(DragEventArgs e)
    {
        _shell.ActivateViewport(_viewport);
        if (DraggedPrefab(e) is var (prefab, node, at))
        {
            e.DragEffects = DragDropEffects.Copy;
            e.Handled = true;
            _dragPixel = ((int)Math.Floor(at.X), (int)Math.Floor(at.Y));
            PickUnderDrag(prefab, isPrefab: true, node);
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
            _shell.Mesh.Texture.PreviewFaceMaterial(pixel, guid);
            return;
        }
        _dragPixel = ((int)Math.Floor(pixel.X), (int)Math.Floor(pixel.Y));
        PickUnderDrag(guid);
    }

    // Picks the pixel under the drag, one pick at a time, and shows the material, or the prefab's instance, where each
    // answer finds.
    void PickUnderDrag(string guid, bool isPrefab = false, ulong node = 0)
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
                _shell.PreviewPrefab(guid, _shell.DropPoint(new Vec2(pixel.X + 0.5, pixel.Y + 0.5), result), node);
            }
            else
            {
                _shell.PreviewMaterial(_shell.MaterialTargetOf(result), guid);
            }
            PickUnderDrag(guid, isPrefab, node);
        });
    }

    void OnDrop(DragEventArgs e)
    {
        if (DraggedPrefab(e) is var (prefab, node, at))
        {
            e.Handled = true;
            EndPicks();
            // The instance stays where the drag last showed it, or where the drop is if no pick has answered. Alt makes plain
            // entities of it.
            var unpack = e.KeyModifiers.HasFlag(KeyModifiers.Alt);
            if (!_shell.CommitPrefab(unpack))
            {
                _shell.PreviewPrefab(prefab, _shell.DropPoint(at, null), node);
                _shell.CommitPrefab(unpack);
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
            _shell.Mesh.Texture.DropFaceMaterial(pixel, guid);
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
        // A ComboBox leaves its press unhandled and opens on the release, which a gesture's capture would take from it.
        if (_gesture != Gesture.None || OnHeader(e))
        {
            return;
        }
        _shell.ActivateViewport(_viewport);
        Focus();
        var point = e.GetCurrentPoint(this);
        if (InputGoesToGame)
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
        if (_viewport.IsGame)
        {
            return;
        }
        var alt = e.KeyModifiers.HasFlag(KeyModifiers.Alt);
        _start = _last = point.Position;
        if (point.Properties.IsRightButtonPressed)
        {
            // An orthographic view has no way to look around in: its right button moves it in its plane.
            _gesture = alt ? Gesture.Dolly : _viewport.Camera.IsOrthographic ? Gesture.Pan : Gesture.Fly;
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
        if (InputGoesToGame)
        {
            ForwardMove(position);
            return;
        }
        if (_viewport.IsGame)
        {
            return;
        }
        // Looking and orbiting turn by frame pixels, so they feel the same at any window scale.
        var delta = (position - _last) * _control.FrameScale;
        _last = position;
        switch (_gesture)
        {
            case Gesture.None:
                // The mouse over a viewport makes it the active one, so the gizmo's hover is in its frame.
                _shell.ActivateViewport(_viewport);
                if (_shell.ActiveViewport == _viewport && _control.FramePoint(position) is { } hover)
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
                _viewport.Camera.Look(delta.X, delta.Y);
                break;
            case Gesture.Orbit:
                _shell.Orbit(_viewport.Camera, delta.X, delta.Y);
                break;
            case Gesture.Pan:
                _viewport.Camera.Pan(delta.X, delta.Y, _viewport.FrameSize.Height);
                break;
            case Gesture.Dolly:
                _viewport.Camera.Dolly(-delta.Y * DollyPerPixel);
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
        if (InputGoesToGame)
        {
            if (GameInput.Button(e.GetCurrentPoint(this).Properties.PointerUpdateKind) is { } button)
            {
                _shell.SendInput(GameInput.Up(button));
            }
            e.Pointer.Capture(null);
            return;
        }
        if (_viewport.IsGame)
        {
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
                if (_control.FramePoint(position) is { } pixel && !_shell.Mesh.Tools.AddToolPoint(pixel) && !_shell.AddNavPoint(pixel))
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
        if (InputGoesToGame)
        {
            _shell.SendInput(GameInput.Scroll(e.Delta.Y));
            e.Handled = true;
            return;
        }
        if (_viewport.IsGame)
        {
            return;
        }
        if (_gesture == Gesture.Fly)
        {
            _viewport.Camera.ChangeSpeed(e.Delta.Y);
        }
        else
        {
            _viewport.Camera.Dolly(e.Delta.Y);
        }
        e.Handled = true;
    }

    protected override void OnTextInput(TextInputEventArgs e)
    {
        base.OnTextInput(e);
        if (InputGoesToGame && e.Text is { } text && _characters.Join(text) is { Length: > 0 } joined)
        {
            _shell.SendInput(GameInput.Text(joined));
            e.Handled = true;
        }
    }

    void ShowComposition(string text, int cursor)
    {
        _composition.Text = text;
        _compositionOverlay.IsVisible = text.Length > 0;
        _shell.SendInput(GameInput.Composition(text, cursor));
    }

    // The pads belong to the viewport while it has the game's input and its window is the active one: XInput answers
    // whichever window asks. A viewport that loses them lets go of everything, and tells the game about them again later.
    void PollGamepads()
    {
        if (_viewport.IsGame && _shell.GameHasKeys && TopLevel.GetTopLevel(this) is WindowBase { IsActive: true })
        {
            _pollingGamepads = true;
            _shell.SendInput(_gamepads.Poll(Environment.TickCount64));
        }
        else if (_pollingGamepads)
        {
            _pollingGamepads = false;
            _shell.SendInput(GameInput.ReleaseAll());
            _gamepads.Forget();
        }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (InputGoesToGame)
        {
            if (GameInput.Key(e.Key) is { } key)
            {
                _shell.SendInput(GameInput.Down(key));
            }
            // The function keys stay the editor's too, so F5 and Shift+F5 work while the game has the keys. A key that may
            // type stays unhandled for its character, and the shortcuts leave it alone by themselves (see ShortcutCommand).
            e.Handled = e.Key is not (>= Avalonia.Input.Key.F1 and <= Avalonia.Input.Key.F24) && !GameInput.TypesCharacter(e.KeySymbol, e.KeyModifiers);
            return;
        }
        if (_viewport.IsGame)
        {
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
        if (_shell.Mesh.Texture.CanRunTextureTool && (e.KeyModifiers & ~(KeyModifiers.Shift | KeyModifiers.Control)) == 0)
        {
            var multiplier = e.KeyModifiers.HasFlag(KeyModifiers.Shift) ? 10 : e.KeyModifiers.HasFlag(KeyModifiers.Control) ? 0.1 : 1;
            var ran = e.Key switch
            {
                Key.Left => _shell.Mesh.Texture.ShiftTexture(1, 0, multiplier),
                Key.Right => _shell.Mesh.Texture.ShiftTexture(-1, 0, multiplier),
                Key.Up => _shell.Mesh.Texture.ShiftTexture(0, 1, multiplier),
                Key.Down => _shell.Mesh.Texture.ShiftTexture(0, -1, multiplier),
                Key.OemComma => _shell.Mesh.Texture.RotateTexture(1, multiplier),
                Key.OemPeriod => _shell.Mesh.Texture.RotateTexture(-1, multiplier),
                Key.OemPlus => _shell.Mesh.Texture.ScaleTexture(1, multiplier),
                Key.OemMinus => _shell.Mesh.Texture.ScaleTexture(-1, multiplier),
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
            Key.N => EditorCommands.NavPathTool,
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
        else if (e.Key == Key.Escape && (_shell.Mesh.MeshTool != MeshTool.Select || _shell.Mesh.Tools.ToolPointCount > 0))
        {
            if (_shell.Mesh.Tools.ToolPointCount > 0)
            {
                _shell.Mesh.Tools.CancelToolPoints();
            }
            else
            {
                _shell.Mesh.SetMeshTool(MeshTool.Select);
            }
            e.Handled = true;
        }
        else if (e.Key is Key.Enter or Key.Return && _shell.Mesh.Tools.ToolPointCount > 0)
        {
            _shell.Mesh.Tools.ApplyToolPoints();
            e.Handled = true;
        }
        else if (e.Key == Key.Back && _shell.Mesh.Tools.ToolPointCount > 0)
        {
            _shell.Mesh.Tools.RemoveLastToolPoint();
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
        if (InputGoesToGame && GameInput.Key(e.Key) is { } key)
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
        _viewport.Camera.Fly(direction, seconds, boost);
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
