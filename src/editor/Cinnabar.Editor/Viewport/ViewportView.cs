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
/// One view of the game, as a document (see docs/editor/viewport.md#views): its frames, its toolbar, and the stats over them.
/// A scene view also has the view gizmo and the camera's speed, and the input that drives the editor's tools. The right
/// button flies with WASD, Q and E; Alt with the left button orbits, the middle button pans, and the wheel dollies. The
/// left button selects, drags a box, or drags the gizmo. Q, W, E and R pick a tool, X switches the gizmo's space, F frames
/// the selection, and H hides it. A material dragged from the content browser shows on the submesh under the mouse, and
/// drops onto it. The mouse makes a scene view the active one, which the shell's tools act in. A scene view keeps all of
/// this while the game plays. The Game view has none of it: it gives the game its keyboard, mouse, text and gamepads
/// while the game plays and the view has the focus, with a frame in the mode's color around it, and is passive otherwise.
/// While it has the keyboard it is the focused command scope (see docs/editor/shell-and-panels.md#commands), which gives
/// Cancel, Esc, its order here.
/// </summary>
public sealed class ViewportView : Grid, Commands.ICommandScope
{
    // Wheel notches per pixel of an Alt and right button drag.
    const double DollyPerPixel = 1.0 / 40;

    enum Gesture
    {
        None,
        Click,
        Box,
        // A drag of one of the shell's left tools, which _drag holds.
        Drag,
        Fly,
        Orbit,
        Pan,
        Dolly,
    }

    readonly EditorShell _shell;
    readonly EditorViewport _viewport;
    readonly ViewportSession _session;
    readonly Border _activeFrame;
    // The menus at the top left: their presses are theirs, not the frame's.
    readonly ViewportToolbar _toolbar;
    readonly FrameGuidesOverlay _guides;
    readonly ViewportControl _control;
    readonly Border _overlay;
    // The Game view's notice that the world has no camera; null in a scene view.
    readonly Border? _noCamera;
    readonly Border? _counter;
    readonly TextBlock _counterText = new() { FontFamily = new FontFamily("Consolas"), FontSize = 12 };
    readonly TextBlock _stats;
    readonly Border _box;
    readonly TextBlock _speed;
    readonly Border _modeFrame;
    // Red around a scene view while auto-key turns its edits of bound entities into keys.
    readonly Border _autoKeyFrame;
    readonly DispatcherTimer _timer;
    readonly DispatcherTimer _flyTimer;
    readonly DispatcherTimer _gamepadTimer;
    // Steps the camera's turn to an axis while one runs (see EditorShell.StepTurn).
    readonly DispatcherTimer _turnTimer;
    long _lastTurn;
    readonly GamepadPoller _gamepads = new(GamepadPoller.ReadXInput);
    bool _pollingGamepads;
    readonly GameInput.Characters _characters = new();
    // Above the overlay of the camera's speed.
    const double CompositionBottom = 44;
    readonly TextBlock _composition;
    readonly Border _compositionOverlay;
    readonly HashSet<Key> _held = [];
    Gesture _gesture;
    // The left tool's drag while the gesture is Drag, else null.
    IViewportDrag? _drag;
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
    // Where the last pick under a prefab drag put the prefab, which a Ctrl drop spawns a cutscene's binding at.
    long[]? _dropPoint;
    // A click's press while a cutscene's tab is active or holds the preview, and entities are selected: the pick under
    // it, which a drag that starts on a selected entity turns into a drag of the entity to the timeline. Null for none.
    // Each press has its number, so an answer to an earlier press does nothing.
    PressPick? _pressPick;
    int _presses;

    abstract record PressPick(int Press)
    {
        public sealed record Waiting(int Press, PointerPressedEventArgs Event) : PressPick(Press);

        public sealed record OnSelected(int Press, ulong Handle, PointerPressedEventArgs Event) : PressPick(Press);
    }

    // The game has the keyboard and the mouse of the Game view only.
    bool InputGoesToGame => _viewport.IsGame && _shell.InputGoesToGame;

    /// <summary>The view's viewport, of the shell's.</summary>
    public EditorViewport Viewport => _viewport;

    public ViewportView(EditorShell shell, EditorViewport viewport)
    {
        _shell = shell;
        _viewport = viewport;
        _session = viewport.Session;
        Background = Brushes.Black;
        Focusable = true;
        ClipToBounds = true;
        FocusFollower.Scope(this, shell.Commands, this);
        ScopeShortcuts.Attach(this, Commands.ShortcutScopes.Viewport, shell, KeysFree);
        _control = new ViewportControl { Session = _session };
        Children.Add(_control);
        _guides = new FrameGuidesOverlay(_control, GuideState);
        Children.Add(_guides);

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
        _autoKeyFrame = new Border { Classes = { "auto-key-frame" }, BorderThickness = new Thickness(2), IsHitTestVisible = false };
        Children.Add(_autoKeyFrame);

        _stats = new TextBlock { FontFamily = new FontFamily("Consolas"), FontSize = 12 };
        _overlay = Overlay(_stats, HorizontalAlignment.Right, VerticalAlignment.Top);
        _overlay.IsHitTestVisible = false;
        if (_viewport.IsGame)
        {
            Children.Add(_overlay);
            // The cutscene preview's frame counter: its timecode, frame and shot, at the bottom, clear of the view's header.
            _counter = Overlay(_counterText, HorizontalAlignment.Left, VerticalAlignment.Bottom);
            _counter.IsHitTestVisible = false;
            _counter.IsVisible = false;
            Children.Add(_counter);
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
        }
        _toolbar = new ViewportToolbar(shell, viewport);
        Children.Add(_toolbar);

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
                _viewport.TurnStarted += StartTurn;
            }
            _shell.ModeChanged += ShowMode;
            _shell.Keying.Changed += ShowAutoKey;
            _shell.ActiveViewportChanged += ShowActive;
            _shell.ViewportsChanged += ShowActive;
            _shell.GuidesChanged += ShowGuides;
            _shell.Looks.Changed += ShowLook;
            _shell.CutscenePreview.Changed += _guides.InvalidateVisual;
            _shell.CutscenePreview.PlayheadMoved += _guides.InvalidateVisual;
            _session.ViewChanged += _guides.InvalidateVisual;
            _timer.Start();
            if (_viewport.IsGame)
            {
                _gamepadTimer.Start();
                _shell.WorldCameraChanged += ShowCamera;
                _viewport.FocusRequested += TakeFocus;
                _shell.CutscenePreview.Changed += ShowCounter;
                _shell.CutscenePreview.PlayheadMoved += ShowCounter;
                ShowCounter();
                ShowCamera();
                TakeFocus();
            }
            ShowMode();
            ShowAutoKey();
            ShowTools();
            ShowSpeed();
            ShowActive();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _session.ViewChanged -= ShowOverlay;
            _shell.ToolsChanged -= ShowTools;
            _shell.Mesh.MeshModeChanged -= ShowTools;
            if (!_viewport.IsGame)
            {
                _viewport.Camera.Changed -= ShowSpeed;
                _viewport.TurnStarted -= StartTurn;
            }
            _shell.ModeChanged -= ShowMode;
            _shell.Keying.Changed -= ShowAutoKey;
            _shell.ActiveViewportChanged -= ShowActive;
            _shell.ViewportsChanged -= ShowActive;
            _shell.GuidesChanged -= ShowGuides;
            _shell.Looks.Changed -= ShowLook;
            _shell.CutscenePreview.Changed -= _guides.InvalidateVisual;
            _shell.CutscenePreview.PlayheadMoved -= _guides.InvalidateVisual;
            _session.ViewChanged -= _guides.InvalidateVisual;
            if (_viewport.IsGame)
            {
                _shell.WorldCameraChanged -= ShowCamera;
                _viewport.FocusRequested -= TakeFocus;
                _shell.CutscenePreview.Changed -= ShowCounter;
                _shell.CutscenePreview.PlayheadMoved -= ShowCounter;
            }
            _timer.Stop();
            _flyTimer.Stop();
            _gamepadTimer.Stop();
            _turnTimer.Stop();
        };
        UpdateStats();
    }

    // The viewport that the viewport commands act on has a frame around it while more than one viewport is shown.
    void ShowActive() => _activeFrame.Classes.Set("active", _shell.SettingsViewport == _viewport && _shell.ShownViewports.Skip(1).Any());

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

    // What the frame guides draw: the view's guides, and the camera that it looks through, if any.
    FrameGuideState GuideState()
    {
        var (aspect, info) = _shell.Looks.CameraInfoOf(_viewport);
        return new FrameGuideState(_viewport.Guides, aspect, info);
    }

    void ShowGuides(EditorViewport viewport)
    {
        if (viewport == _viewport)
        {
            _guides.InvalidateVisual();
        }
    }

    void ShowLook(int viewport)
    {
        if (viewport == _viewport.Index)
        {
            _guides.InvalidateVisual();
            ShowSpeed();
        }
    }

    void ShowCounter()
    {
        var text = _shell.CutscenePreview.FrameCounter();
        _counter!.IsVisible = text != null;
        _counterText.Text = text ?? "";
    }

    bool OnHeader(RoutedEventArgs e) => e.Source is Visual source && (source == _toolbar || _toolbar.IsVisualAncestorOf(source));

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

    // The tool, the space and snapping are the Scene's, in its tool strip: here only what the status line says changes.
    void ShowTools() => ShowSpeed();

    void ShowAutoKey() => _autoKeyFrame.Classes.Set("on", !_viewport.IsGame && _shell.Keying.AutoKeyShows);

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
        if (_viewport.IsGame)
        {
            return;
        }
        // A view that looks through a camera says what its fly, orbit and pan move, or why they move nothing.
        switch (_shell.Looks[_viewport.Index])
        {
            case ViewLook.Camera { Pilot: Pilot.Ready ready }:
                _speed.Text = $"Piloting   ·   {FormatSpeed(ready.Camera.Speed)}   ·   Esc for the editor camera";
                return;
            case ViewLook.Through:
                _speed.Text = $"{_shell.Looks.PilotRefusal(_viewport.Index)}   ·   Esc for the editor camera";
                return;
        }
        _speed.Text = $"{FormatSpeed(_viewport.Camera.Speed)}   ·   {_shell.Tool}, {_shell.Space}{(_shell.Snap ? ", snapping" : "")}"
            + (_shell.Mesh.InMeshMode ? $"   ·   grid {Mesh.MeshGrid.Format(_shell.Mesh.GridSize)}" : "");
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
        // A drop places by the editor camera's ray, which a view that looks through a camera does not draw from.
        if (Looking)
        {
            e.DragEffects = DragDropEffects.None;
            e.Handled = true;
            return;
        }
        if (DraggedPrefab(e) is var (prefab, node, at))
        {
            e.DragEffects = SpawnTarget(e, node) != null ? DragDropEffects.Link : DragDropEffects.Copy;
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
                _dropPoint = _shell.DropPoint(new Vec2(pixel.X + 0.5, pixel.Y + 0.5), result);
                _shell.PreviewPrefab(guid, _dropPoint, node);
            }
            else
            {
                _shell.PreviewMaterial(_shell.MaterialTargetOf(result), guid);
            }
            PickUnderDrag(guid, isPrefab, node);
        });
    }

    // The cutscene that a Ctrl drop of a whole prefab adds a spawned binding to: the one that holds the preview (see
    // docs/editor/cutscene-editor.md#possess-and-spawn), or null.
    CutsceneEditor? SpawnTarget(DragEventArgs e, ulong node) =>
        e.KeyModifiers.HasFlag(KeyModifiers.Control) && node == 0 && _shell.CutscenePreview.Owner is { } owner && !owner.Document.InTransaction ? owner : null;

    void OnDrop(DragEventArgs e)
    {
        if (Looking)
        {
            EndMaterialDrag();
            return;
        }
        if (DraggedPrefab(e) is var (prefab, node, at))
        {
            e.Handled = true;
            // Ctrl spawns the prefab for the cutscene, where the drag showed it, and leaves the scene as it was.
            if (SpawnTarget(e, node) is { } cutscene)
            {
                var point = _dropPoint ?? _shell.DropPoint(at, null);
                EndPicks();
                _shell.CancelPrefab();
                cutscene.SpawnAt(prefab, point);
                return;
            }
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
        _dropPoint = null;
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
        if (Looking)
        {
            // A view that looks through a camera moves the camera, or nothing, and a click selects (see
            // docs/editor/cutscene-editor.md#pilot): the editor's tools act in the editor camera's view.
            _gesture = point.Properties.IsRightButtonPressed ? alt ? Gesture.Dolly : Gesture.Fly
                : point.Properties.IsMiddleButtonPressed ? Gesture.Pan
                : point.Properties.IsLeftButtonPressed ? alt ? Gesture.Orbit : Gesture.Click
                : Gesture.None;
            if (_gesture is Gesture.Fly or Gesture.Dolly or Gesture.Pan or Gesture.Orbit)
            {
                _shell.Looks.BeginGesture(_viewport.Index);
            }
            if (_gesture == Gesture.Fly)
            {
                _lastFly = Environment.TickCount64;
                _flyTimer.Start();
            }
            if (_gesture != Gesture.None)
            {
                e.Pointer.Capture(this);
                e.Handled = true;
            }
            return;
        }
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
            else if (_control.FramePoint(point.Position) is { } pixel && BeginDrag(pixel, KeysOf(e.KeyModifiers)) is { } drag)
            {
                _gesture = Gesture.Drag;
                _drag = drag;
            }
            else
            {
                _gesture = Gesture.Click;
                PickUnderPress(point.Position, e);
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
                if (!Looking && _shell.ActiveViewport == _viewport && _control.FramePoint(position) is { } hover)
                {
                    foreach (var tool in _shell.LeftTools)
                    {
                        tool.Hover(hover);
                    }
                }
                break;
            case Gesture.Drag:
                if (_control.FramePoint(position) is { } dragged)
                {
                    _drag?.Move(dragged, KeysOf(e.KeyModifiers));
                }
                break;
            case Gesture.Fly:
                MoveCamera(c => c.Look(delta.X, delta.Y));
                break;
            case Gesture.Orbit when Looking:
                MoveCamera(c => c.Orbit(delta.X, delta.Y));
                break;
            case Gesture.Orbit:
                _shell.Orbit(_viewport.Camera, delta.X, delta.Y);
                break;
            case Gesture.Pan:
                MoveCamera(c => c.Pan(delta.X, delta.Y, _viewport.FrameSize.Height));
                break;
            case Gesture.Dolly:
                MoveCamera(c => c.Dolly(-delta.Y * DollyPerPixel));
                break;
            case Gesture.Click when Looking:
                break;
            case Gesture.Click:
                if ((position - _start) is var moved && Gestures.MovedPast(moved))
                {
                    // A drag that starts on a selected entity takes it to the cutscene's timeline. A pick that has not
                    // answered yet, or found no selected entity, makes it a box select.
                    if (_pressPick is PressPick.OnSelected { Handle: var handle, Event: var pressed })
                    {
                        EndGesture();
                        e.Pointer.Capture(null);
                        _ = DragEntity(pressed, handle);
                        break;
                    }
                    _pressPick = null;
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
        // A pilot's gesture ends with the release, which keys it with auto-key.
        _shell.Looks.EndGesture(_viewport.Index, cancel: false);
        switch (_gesture)
        {
            case Gesture.Drag:
                _drag?.End(KeysOf(e.KeyModifiers));
                break;
            case Gesture.Click when Looking:
                // Ctrl, or an armed pick, picks the camera's focus there (see docs/editor/cutscene-editor.md#focus).
                if (_control.FramePoint(position) is { } picked)
                {
                    _shell.ClickInLook(_viewport.Index, picked, mode, e.KeyModifiers.HasFlag(KeyModifiers.Control));
                }
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
        _shell.Looks.EndGesture(_viewport.Index, cancel: false);
        // The gizmo commits what it moved; the other tools put it back.
        _drag?.Lost();
        EndGesture();
    }

    // Picks under a click's press while a cutscene's tab is active or holds the preview, and entities are selected, so a
    // drag from a selected entity can take it to the timeline (see docs/editor/cutscene-editor.md#possess-and-spawn).
    void PickUnderPress(Point position, PointerPressedEventArgs e)
    {
        _pressPick = null;
        if ((_shell.ActiveCutscene ?? _shell.CutscenePreview.Owner) == null || _shell.Selection.Entities.Count == 0 || _shell.Mesh.InMeshMode || _control.FramePoint(position) is not { } pixel)
        {
            return;
        }
        var press = ++_presses;
        var waiting = new PressPick.Waiting(press, e);
        _pressPick = waiting;
        if (!_shell.PickSelectedAt(pixel, handle =>
            {
                if (_pressPick == waiting)
                {
                    _pressPick = handle != 0 ? new PressPick.OnSelected(press, handle, e) : null;
                }
            }))
        {
            _pressPick = null;
        }
    }

    // Drags an entity out of the viewport as the Outliner does, so the cutscene's timeline possesses it, with the rest of
    // the selection.
    static async Task DragEntity(PointerPressedEventArgs e, ulong handle)
    {
        var data = new DataTransfer();
        data.Add(DataTransferItem.Create(EntityView.EntityFormat, handle.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        await DragDrop.DoDragDropAsync(e, data, DragDropEffects.Move | DragDropEffects.Link);
    }

    // The first of the shell's left tools that starts a drag at a press, or null for a click.
    IViewportDrag? BeginDrag(Vec2 pixel, DragKeys keys)
    {
        foreach (var tool in _shell.LeftTools)
        {
            if (tool.TryBegin(pixel, keys) is { } drag)
            {
                return drag;
            }
        }
        return null;
    }

    static DragKeys KeysOf(KeyModifiers modifiers) =>
        new(modifiers.HasFlag(KeyModifiers.Shift), modifiers.HasFlag(KeyModifiers.Control));

    void EndGesture()
    {
        _pressPick = null;
        _gesture = Gesture.None;
        _drag = null;
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
        if (Looking)
        {
            // A pilot's moves end with a mouse release, which keys them, so the wheel only changes the flying speed.
            if (_gesture == Gesture.Fly)
            {
                MoveCamera(c => c.ChangeSpeed(e.Delta.Y));
            }
        }
        else if (_gesture == Gesture.Fly)
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
        // A key that flies is the camera's until it is released: when the right button goes up first, the key's repeats
        // would pick a tool, as W picks Move.
        if (_gesture == Gesture.Fly || _held.Contains(e.Key))
        {
            _held.Add(e.Key);
            e.Handled = true;
            return;
        }
        // The tools', mesh mode's and the texture tools' keys, and Esc, are the view's scoped shortcuts (see KeysFree),
        // which come before this. What is left is Enter and Backspace, which the mesh tools' points have.
        if (e.KeyModifiers != KeyModifiers.None)
        {
            return;
        }
        if (e.Key is Key.Enter or Key.Return && _shell.Mesh.Tools.ToolPointCount > 0)
        {
            _shell.Mesh.Tools.ApplyToolPoints();
            e.Handled = true;
        }
        else if (e.Key == Key.Back && _shell.Mesh.Tools.ToolPointCount > 0)
        {
            _shell.Mesh.Tools.RemoveLastToolPoint();
            e.Handled = true;
        }
    }

    // Whether the view's scoped shortcuts may have a key (see docs/editor/shell-and-panels.md#commands): not while the game has the
    // keys or in the Game view, and not a key that flies while it is the camera's, so that it reaches OnKeyDown's _held.
    // Esc is Cancel's even in a flight, which it takes back while the view looks through a camera.
    bool KeysFree(Key key) =>
        !InputGoesToGame && !_viewport.IsGame && (key == Key.Escape || (_gesture != Gesture.Fly && !_held.Contains(key)));

    /// <summary>
    /// Cancel, which Esc runs while the view has the keyboard, in this order:
    /// <list type="number">
    /// <item>In a view that looks through a camera: an armed pick of its focus, then a pilot's gesture, a flight too, or
    /// else the look itself.</item>
    /// <item>A flight, which keeps Esc and cancels nothing.</item>
    /// <item>A drag of one of the shell's left tools.</item>
    /// <item>The shell's <see cref="EditorShell.ViewportCancels"/>: a binding's pick, then mesh mode.</item>
    /// </list>
    /// </summary>
    public Commands.ScopedCommand? Handler(string commandId) => commandId switch
    {
        EditorCommands.Cancel => Commands.ScopedCommand.FirstOf(
        [
            (() => Looking && _gesture == Gesture.None && _shell.FocusPickArmed(_viewport.Index), () => _shell.CancelFocusPick(_viewport.Index)),
            (() => Looking && _shell.Looks.CanEscape(_viewport.Index), EscapeLook),
            (() => _gesture == Gesture.Fly, () => { }),
            (() => _drag != null, CancelDrag),
            .. _shell.ViewportCancels,
        ]),
        _ => null,
    };

    void EscapeLook()
    {
        _shell.Looks.Escape(_viewport.Index);
        if (_gesture is Gesture.Fly or Gesture.Dolly or Gesture.Pan or Gesture.Orbit)
        {
            EndGesture();
        }
    }

    void CancelDrag()
    {
        _drag?.Cancel();
        EndGesture();
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
        MoveCamera(c => c.Fly(direction, seconds, boost));
    }

    // Whether the view draws through a camera of the cutscene, not its own (see docs/editor/cutscene-editor.md#look-through).
    bool Looking => !_viewport.IsGame && _shell.Looks[_viewport.Index] is not ViewLook.Editor;

    // A camera gesture moves the view's own camera, or the one that it pilots, or nothing while it pilots none.
    void MoveCamera(Action<EditorCamera> move)
    {
        if (Looking)
        {
            _shell.Looks.Move(_viewport.Index, move);
        }
        else
        {
            move(_viewport.Camera);
        }
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
