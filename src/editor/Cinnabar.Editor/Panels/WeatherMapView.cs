using System.Globalization;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Shell;
using CommunityToolkit.Mvvm.Input;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The Weather Map panel (see docs/editor/shell-and-panels.md#weather-map): the atmosphere volume's weather map as an
/// image that fills the panel, with its red, green and blue the clouds' coverage, precipitation and type; a brush that
/// paints one channel toward a value, or toward 0 with Shift, each stroke written to the PNG when it ends; Ctrl+Z,
/// while the panel has the focus, undoes a stroke; and New Weather Map, which fills the map from noise, making the
/// file when the volume has none. The map, its file and the strokes are the shell's <see cref="WeatherMapSession"/>.
/// </summary>
public sealed class WeatherMapView : DockPanel
{
    static readonly IReadOnlyList<string> Channels = ["Coverage", "Precipitation", "Type"];

    readonly EditorShell _shell;
    readonly WeatherMapSession _session;
    readonly Image _image = new() { Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _status = new() { Classes = { "dim" }, TextWrapping = TextWrapping.Wrap };
    readonly Button _undo;
    readonly Button _revert;
    Button? _generate;
    readonly SectionExpander _sections = new();
    WriteableBitmap? _bitmap;

    // The brush, which lasts while the panel is open.
    WeatherChannel _channel = WeatherChannel.Coverage;
    double _radius = 24;
    double _strength = 0.5;
    double _hardness = 0.5;
    double _value = 1;
    // Whether the stroke under way paints toward 0, as Shift was held when it began.
    bool _erasing;

    // What a new map is made of.
    WeatherGeneration _generation = new();

    public WeatherMapView(EditorShell shell)
    {
        _shell = shell;
        _session = shell.WeatherMaps;
        Focusable = true;
        _undo = new Button { Content = "Undo Stroke", HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Center };
        ToolTip.SetTip(_undo, "Undo the last stroke, or the last Generate, and write the file again (Ctrl+Z while the panel has the focus).");
        _undo.Click += (_, _) => _session.UndoStroke();
        _revert = new Button { Content = "Revert to Saved", HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Center };
        ToolTip.SetTip(_revert, "Read the file again, dropping the strokes since.");
        _revert.Click += (_, _) => _session.RevertToSaved();
        KeyBindings.Add(new KeyBinding
        {
            Gesture = new KeyGesture(Key.Z, KeyModifiers.Control),
            Command = new RelayCommand(() => _session.UndoStroke(), () => TopLevel.GetTopLevel(this)?.FocusManager?.GetFocusedElement() is not TextBox),
        });

        var top = new StackPanel { Classes = { "properties" }, Spacing = 4 };
        top.Children.Add(new StackPanel { Classes = { "properties-header" }, Children = { new TextBlock { Text = "Weather Map", Classes = { "title" } } } });
        top.Children.Add(_status);
        top.Children.Add(_sections.Create("Brush", Brush()));
        top.Children.Add(_sections.Create("New Weather Map", Generation()));
        var buttons = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*"), ColumnSpacing = 4 };
        Grid.SetColumn(_revert, 1);
        buttons.Children.Add(_undo);
        buttons.Children.Add(_revert);
        top.Children.Add(buttons);
        SetDock(top, Avalonia.Controls.Dock.Top);
        Children.Add(new ScrollViewer { Content = top, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, MaxHeight = 360 });

        var canvas = new Border { Background = new SolidColorBrush(Color.FromRgb(24, 24, 24)), Child = _image, Margin = new Thickness(4), Cursor = new Cursor(StandardCursorType.Cross) };
        ToolTip.SetTip(canvas, "Red is the coverage, green the precipitation and blue the type. Drag to paint the brush's channel toward its value, with Shift toward 0.");
        canvas.PointerPressed += OnPointerPressed;
        canvas.PointerMoved += OnPointerMoved;
        canvas.PointerReleased += OnPointerReleased;
        canvas.PointerCaptureLost += (_, _) => _session.EndStroke();
        Children.Add(canvas);

        new ViewSubscriptions(this, attached: () => { _session.Sync(); Show(); }, detached: DropBitmap)
            .Add(() => _session.Changed += Show, () => _session.Changed -= Show)
            .Add(() => _shell.SceneChanged += _session.Sync, () => _shell.SceneChanged -= _session.Sync)
            .Add(() => _shell.Assets.Changed += _session.Sync, () => _shell.Assets.Changed -= _session.Sync)
            .Add(() => _shell.Cook.StateChanged += _session.Sync, () => _shell.Cook.StateChanged -= _session.Sync);
    }

    // The brush: its channel, its radius in texels, how far each stroke moves a texel, how much of it is full, and the value it paints toward.
    Control Brush()
    {
        var rows = new StackPanel { Spacing = 2 };
        rows.Children.Add(Kit.Row("Channel", Kit.Choice(Channels, Channels[(int)_channel], c => _channel = (WeatherChannel)Channels.ToList().IndexOf(c))));
        rows.Children.Add(Kit.Row("Radius", Slider(1, 128, _radius, v => _radius = v, "0")));
        rows.Children.Add(Kit.Row("Strength", Slider(0, 1, _strength, v => _strength = v, "0.00")));
        rows.Children.Add(Kit.Row("Hardness", Slider(0, 1, _hardness, v => _hardness = v, "0.00")));
        rows.Children.Add(Kit.Row("Value", Slider(0, 1, _value, v => _value = v, "0.00")));
        return rows;
    }

    // A slider with its value beside it.
    static Control Slider(double min, double max, double value, Action<double> set, string format)
    {
        var text = new TextBlock { Width = 36, VerticalAlignment = VerticalAlignment.Center, Text = value.ToString(format, CultureInfo.InvariantCulture) };
        var slider = new Slider { Minimum = min, Maximum = max, Value = value, Classes = { "value-slider" }, VerticalAlignment = VerticalAlignment.Center };
        slider.PropertyChanged += (_, e) =>
        {
            if (e.Property == RangeBase.ValueProperty)
            {
                set(slider.Value);
                text.Text = slider.Value.ToString(format, CultureInfo.InvariantCulture);
            }
        };
        var panel = new DockPanel { LastChildFill = true };
        SetDock(text, Avalonia.Controls.Dock.Right);
        panel.Children.Add(text);
        panel.Children.Add(slider);
        return panel;
    }

    // What a new map is made of, and the button that makes it.
    Control Generation()
    {
        var rows = new StackPanel { Spacing = 2 };
        var sizes = WeatherMapSession.Sizes.Select(s => s.ToString(CultureInfo.InvariantCulture)).ToList();
        rows.Children.Add(Kit.Row("Size", Kit.Choice(sizes, _generation.Size.ToString(CultureInfo.InvariantCulture), s => _generation = _generation with { Size = int.Parse(s, CultureInfo.InvariantCulture) })));
        rows.Children.Add(Kit.Row("Seed", Number(_generation.Seed, v => _generation = _generation with { Seed = (int)v })));
        rows.Children.Add(Kit.Row("Scale", Number(_generation.Scale, v => _generation = _generation with { Scale = Math.Clamp(v, 1, 64) })));
        rows.Children.Add(Kit.Row("Octaves", Number(_generation.Octaves, v => _generation = _generation with { Octaves = (int)Math.Clamp(v, 1, 8) })));
        rows.Children.Add(Kit.Row("Coverage Bias", Number(_generation.CoverageBias, v => _generation = _generation with { CoverageBias = Math.Clamp(v, -1, 1) })));
        rows.Children.Add(Kit.Row("Precipitation Bias", Number(_generation.PrecipitationBias, v => _generation = _generation with { PrecipitationBias = Math.Clamp(v, -1, 1) })));
        rows.Children.Add(Kit.Row("Type Bias", Number(_generation.TypeBias, v => _generation = _generation with { TypeBias = Math.Clamp(v, -1, 1) })));
        var generate = new Button { Content = "Generate", HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Center };
        ToolTip.SetTip(generate, "Fill the map from noise: cells of the scale across it, with a few that rain. Without a map, write a new one under the scene's content root and name it in the clouds, as one undo entry.");
        generate.Click += (_, _) => _session.Generate(_generation);
        _generate = generate;
        rows.Children.Add(generate);
        return rows;
    }

    static Control Number(double value, Action<double> set) =>
        Kit.ValueBox(value.ToString("0.###", CultureInfo.InvariantCulture), "", text =>
        {
            if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var v))
            {
                set(v);
            }
        });

    // Shows the map, and what the session says of it.
    void Show()
    {
        _status.Text = _session.Status();
        _undo.IsEnabled = _session.Strokes > 0 && !_session.IsPainting;
        _revert.IsEnabled = _session.State is WeatherMapSession.MapState.Indexed or WeatherMapSession.MapState.Written;
        if (_generate != null)
        {
            // Without a map, Generate edits the scene, which the game's play does not allow.
            _generate.IsEnabled = _session.State is not (WeatherMapSession.MapState.None or WeatherMapSession.MapState.Unknown) || _shell.CanEditScene;
        }
        if (_session.Map is not { } map)
        {
            DropBitmap();
            return;
        }
        if (_bitmap != null && (_bitmap.PixelSize.Width != map.Width || _bitmap.PixelSize.Height != map.Height))
        {
            DropBitmap();
        }
        if (_bitmap == null)
        {
            _bitmap = new WriteableBitmap(new PixelSize(map.Width, map.Height), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Opaque);
        }
        using (var buffer = _bitmap.Lock())
        {
            var row = new byte[map.Width * 4];
            for (var y = 0; y < map.Height; y++)
            {
                var from = y * map.Width * 4;
                for (var x = 0; x < map.Width; x++)
                {
                    // The map is RGBA; the bitmap is BGRA.
                    row[x * 4] = map.Rgba[from + x * 4 + 2];
                    row[x * 4 + 1] = map.Rgba[from + x * 4 + 1];
                    row[x * 4 + 2] = map.Rgba[from + x * 4];
                    row[x * 4 + 3] = 255;
                }
                Marshal.Copy(row, 0, buffer.Address + y * buffer.RowBytes, row.Length);
            }
        }
        _image.Source = _bitmap;
        _image.InvalidateVisual();
    }

    // The bitmap is disposed after the image stops showing it.
    void DropBitmap()
    {
        _image.Source = null;
        _bitmap?.Dispose();
        _bitmap = null;
    }

    // The texel under the pointer, for an image that Uniform stretching centers in its bounds, or null off the map.
    (double X, double Y)? Texel(PointerEventArgs e)
    {
        if (_session.Map is not { } map || _image.Bounds.Width <= 0 || _image.Bounds.Height <= 0)
        {
            return null;
        }
        var position = e.GetPosition(_image);
        var scale = Math.Min(_image.Bounds.Width / map.Width, _image.Bounds.Height / map.Height);
        var offsetX = (_image.Bounds.Width - map.Width * scale) / 2;
        var offsetY = (_image.Bounds.Height - map.Height * scale) / 2;
        return ((position.X - offsetX) / scale, (position.Y - offsetY) / scale);
    }

    void OnPointerPressed(object? sender, PointerPressedEventArgs e)
    {
        Focus();
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed || Texel(e) is not { } texel)
        {
            return;
        }
        _erasing = e.KeyModifiers.HasFlag(KeyModifiers.Shift);
        _session.BeginStroke();
        if (_session.IsPainting)
        {
            e.Pointer.Capture((IInputElement?)sender);
            _session.Paint(_channel, texel.X, texel.Y, _radius, _strength, _hardness, _erasing ? 0 : _value);
            e.Handled = true;
        }
    }

    void OnPointerMoved(object? sender, PointerEventArgs e)
    {
        if (_session.IsPainting && Texel(e) is { } texel)
        {
            _session.Paint(_channel, texel.X, texel.Y, _radius, _strength, _hardness, _erasing ? 0 : _value);
        }
    }

    void OnPointerReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (_session.IsPainting)
        {
            e.Pointer.Capture(null);
            _session.EndStroke();
            e.Handled = true;
        }
    }
}
