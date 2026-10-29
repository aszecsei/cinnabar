using System.Globalization;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;
using FieldInfo = Cinnabar.Editor.Link.Protocol.FieldInfo;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The Atmosphere panel (see docs/editor/shell-and-panels.md#atmosphere): the scene's sky, sun, ambient light, night
/// and fog in one place, whatever is selected. Its rows are the atmosphere volume's Environment and Fog, as the
/// properties panel has them, and a linked sun's light's color and intensity; the sun's azimuth and elevation turn the
/// linked light, or set the sky's own sun. It watches the volume and the light for their values while it shows them.
/// </summary>
public sealed class AtmosphereView : ScrollViewer
{
    readonly EditorShell _shell;
    readonly WorldModel _world;
    readonly StackPanel _content = new() { Classes = { "properties" } };
    readonly FieldGrid _grid;
    // Groups that the user collapsed, by title.
    readonly HashSet<string> _collapsed = [];
    // The sun's angles' views, which show what the document has, and the handles that the panel watches.
    readonly List<(FieldView View, bool Elevation)> _angles = [];
    ulong[] _watched = [];
    string _structure = "";

    public AtmosphereView(EditorShell shell)
    {
        _shell = shell;
        _world = shell.World;
        _grid = new FieldGrid(shell);
        Content = _content;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        AttachedToVisualTree += (_, _) =>
        {
            _world.EntitiesChanged += Refresh;
            _world.TypesChanged += Refresh;
            _world.ValuesChanged += OnValuesChanged;
            _shell.SceneChanged += Refresh;
            _shell.ModeChanged += Refresh;
            Refresh();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _world.EntitiesChanged -= Refresh;
            _world.TypesChanged -= Refresh;
            _world.ValuesChanged -= OnValuesChanged;
            _shell.SceneChanged -= Refresh;
            _shell.ModeChanged -= Refresh;
            Watch([]);
            _structure = "";
        };
    }

    void OnValuesChanged(ulong entity)
    {
        if (_watched.Contains(entity))
        {
            ShowValues();
        }
    }

    // The panel rebuilds when what it shows changes: the volume, its components, its mode, its sun, and their
    // handles. An edit of a value only shows the new value.
    void Refresh()
    {
        var structure = Structure();
        if (structure != _structure)
        {
            _structure = structure;
            Rebuild();
        }
        else
        {
            _grid.ShowDocument();
        }
        ShowValues();
    }

    string Structure()
    {
        if (_shell.AtmosphereVolume is not { } volume)
        {
            return $"none|{_shell.IsEditing}|{_shell.Scene != null}";
        }
        var sun = _shell.AtmosphereSun;
        return $"{volume.Id}|{string.Join(",", volume.Components.Select(c => c.Id))}|{Atmosphere.ModeOf(volume)}|{sun?.Id}|" +
            $"{_world.FindScene(volume.Id)?.Handle}|{(sun == null ? 0 : _world.FindScene(sun.Id)?.Handle)}|{_world.Types.Count}";
    }

    void Watch(ulong[] handles)
    {
        foreach (var gone in _watched.Except(handles))
        {
            _shell.Unwatch(gone);
        }
        foreach (var added in handles.Except(_watched))
        {
            _shell.Watch(added);
        }
        _watched = handles;
    }

    static string Owner(ulong sceneId, ulong component) => $"{sceneId:x16}:{component:x16}";

    void Rebuild()
    {
        _content.Children.Clear();
        _grid.Clear();
        _angles.Clear();
        var volume = _shell.AtmosphereVolume;
        var node = volume == null ? null : _world.FindScene(volume.Id);
        var environment = _world.Type(SceneEdits.EnvironmentId);
        if (volume == null || !volume.Components.Any(c => c.Id == SceneEdits.EnvironmentId))
        {
            Watch([]);
            if (!_shell.IsEditing || _shell.Scene == null)
            {
                _content.Children.Add(Empty("The scene's sky, sun, ambient light and fog appear here while it is edited."));
                return;
            }
            _content.Children.Add(Empty(volume == null
                ? "The scene has no global volume for its sky, sun, ambient light and fog."
                : $"{volume.Name} has no Environment for its sky, sun and ambient light."));
            _content.Children.Add(CommandButton("Create Atmosphere", EditorCommands.AtmosphereSelect));
            return;
        }
        if (node == null || environment == null)
        {
            Watch([]);
            _content.Children.Add(Empty("The atmosphere's settings appear when the game has its volume."));
            return;
        }
        var sun = _shell.AtmosphereSun;
        var sunNode = sun == null ? null : _world.FindScene(sun.Id);
        Watch(sunNode == null ? [node.Handle] : [node.Handle, sunNode.Handle]);

        _content.Children.Add(Header(volume));
        var fields = environment.Fields.ToDictionary(f => f.Name);
        FieldRow? Environment(string name, string? label = null) =>
            fields.TryGetValue(name, out var f) ? Row(volume, SceneEdits.EnvironmentId, f, label) : null;
        IEnumerable<FieldRow> Prefixed(string prefix) =>
            environment.Fields.Where(f => f.Name.StartsWith(prefix, StringComparison.Ordinal))
                .Select(f => Row(volume, SceneEdits.EnvironmentId, f, FieldValues.Humanize(f.Name[prefix.Length..])));
        var atmosphere = Atmosphere.ModeOf(volume) == "Atmosphere";
        var texture = Atmosphere.ModeOf(volume) == "Texture";

        // The sun: its light, where it is, and how bright it is.
        var sunRows = new List<FieldRow?> { Environment(Atmosphere.Sun, "Light") };
        var sunTail = new List<FieldRow?>();
        if (sun != null && sunNode != null && _world.Type(SceneEdits.DirectionalLightId) is { } light)
        {
            sunTail.AddRange(light.Fields.Where(f => f.Name is "color" or "intensity").Select(f => (FieldRow?)Row(sun, SceneEdits.DirectionalLightId, f)));
        }
        else
        {
            sunTail.Add(Environment("sun_illuminance", "Illuminance"));
        }
        sunTail.Add(Environment("sun_disc_size", "Disc Size"));
        var note = atmosphere ? null
            : texture ? "The texture's sun is its image's. A linked light still lights the world."
            : "The Flat sky draws no sun. A linked light still lights the world.";
        _content.Children.Add(Group("Sun", new StackPanel
        {
            Spacing = 4,
            Children = { _grid.Rows(sunRows.OfType<FieldRow>()), Angles(), _grid.Rows(sunTail.OfType<FieldRow>()) },
        }, note));

        // The sky and the ambient light: Flat's colors, the atmosphere's air, or the texture with Flat's colors until it
        // is ready.
        var sky = new List<FieldRow?> { Environment(Atmosphere.Mode), Environment("ambient_intensity") };
        if (atmosphere)
        {
            sky.AddRange(Prefixed("atmosphere."));
        }
        else if (texture)
        {
            sky.AddRange([Environment("texture"), Environment("texture_intensity", "Intensity"), Environment("texture_rotation", "Rotation"),
                Environment("background"), Environment("sky", "Sky Color"), Environment("ground", "Ground Color")]);
        }
        else
        {
            sky.AddRange([Environment("background"), Environment("sky", "Sky Color"), Environment("ground", "Ground Color")]);
        }
        _content.Children.Add(Group(atmosphere ? "Sky" : "Sky and Ambient Light", _grid.Rows(sky.OfType<FieldRow>())));
        if (atmosphere)
        {
            _content.Children.Add(Group("Night", _grid.Rows(Prefixed("night."))));
        }

        // The fog, once the volume has a Fog.
        if (volume.Components.Any(c => c.Id == SceneEdits.FogId) && _world.Type(SceneEdits.FogId) is { } fog)
        {
            _content.Children.Add(Group("Fog", _grid.Rows(fog.Fields.Select(f => Row(volume, SceneEdits.FogId, f)))));
        }
        else
        {
            _content.Children.Add(Group("Fog", CommandButton("Add Fog", EditorCommands.AtmosphereFog)));
        }
    }

    // A row of a component's field of the volume or the sun, as the properties panel has it.
    FieldRow Row(SceneEntity entity, ulong component, FieldInfo f, string? label = null)
    {
        var editor = FieldEditor.ForComponent(_shell, entity.Id, component, f);
        Func<bool> isSet = () => _shell.Scene?.Expanded.Flat.Find(entity.Id)?.Components.Find(c => c.Id == component) is { } c
            && c.Fields.Any(x => x.Name == f.Name || (f.HasOverride && x.Name == f.Name + SceneEdits.OverrideSuffix));
        return FieldRow.Of(Owner(entity.Id, component), f, editor, editor != null ? isSet : null, () => editor?.Reset()) with { Label = label };
    }

    // The sun's azimuth and elevation, which a drag or a slider changes as one undo entry.
    Grid Angles()
    {
        var rows = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), Classes = { "fields" } };
        var row = 0;
        foreach (var (label, elevation, range) in new[] { ("Azimuth", false, (0.0, 360.0)), ("Elevation", true, (-90.0, 90.0)) })
        {
            rows.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            var editor = new SunAngleEditor(_shell, elevation);
            var name = new TextBlock { Text = label, Classes = { "field-name" }, VerticalAlignment = VerticalAlignment.Center };
            ToolTip.SetTip(name, elevation
                ? "Degrees above the horizon: below 0 is night. Drag to change it."
                : "Degrees from +z toward +x. Drag to change it.");
            FieldView.Scrubbable(name, editor, 0);
            var view = FieldView.Create(DisplayKind.Number, _shell.Selection.Select, EntityNode.Format, editor, range: range);
            Grid.SetRow(name, row);
            Grid.SetRow(view.Control, row);
            Grid.SetColumn(view.Control, 1);
            rows.Children.Add(name);
            rows.Children.Add(view.Control);
            _angles.Add((view, elevation));
            row++;
        }
        return rows;
    }

    void ShowValues()
    {
        ulong SceneIdOf(ulong handle) => _world.Find(handle)?.SceneId ?? 0;
        foreach (var handle in _watched)
        {
            if (_world.Values(handle) is not { } values || _world.Find(handle) is not { } node)
            {
                continue;
            }
            foreach (var component in values.Components)
            {
                if (_world.Type(component.Id) is { } type)
                {
                    _grid.ShowComponent(Owner(node.SceneId, component.Id), type, component.Data, SceneIdOf);
                }
            }
        }
        if (_shell.Scene is { } document && _shell.AtmosphereVolume is { } volume)
        {
            var (azimuth, elevation) = Atmosphere.SunAngles(document.Expanded.Flat, volume);
            foreach (var (view, isElevation) in _angles)
            {
                var degrees = isElevation ? elevation : azimuth;
                view.Show(new FieldDisplay(DisplayKind.Number, degrees.ToString("0.##", CultureInfo.InvariantCulture), [], false, 0, null));
            }
        }
    }

    Control Header(SceneEntity volume)
    {
        var title = new TextBlock { Text = "Atmosphere", Classes = { "title" } };
        var select = new Button { Content = volume.Name.Length > 0 ? volume.Name : "Volume", Classes = { "badge-button" }, VerticalAlignment = VerticalAlignment.Center };
        ToolTip.SetTip(select, "Select the volume that holds the atmosphere");
        select.Click += (_, _) => _shell.SelectScene(volume.Id);
        var top = new DockPanel { Children = { select, title } };
        DockPanel.SetDock(select, Avalonia.Controls.Dock.Right);
        return new StackPanel { Classes = { "properties-header" }, Children = { top } };
    }

    Control Group(string title, Control content, string? note = null)
    {
        if (note != null)
        {
            content = new StackPanel { Spacing = 4, Children = { new TextBlock { Text = note, Classes = { "dim" }, TextWrapping = TextWrapping.Wrap }, content } };
        }
        var expander = new Expander
        {
            Header = new TextBlock { Text = title, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center },
            Content = content,
            IsExpanded = !_collapsed.Contains(title),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Classes = { "component" },
        };
        expander.Expanded += (_, _) => _collapsed.Remove(title);
        expander.Collapsed += (_, _) => _collapsed.Add(title);
        return expander;
    }

    static TextBlock Empty(string text) => new() { Text = text, Classes = { "empty" }, TextWrapping = TextWrapping.Wrap };

    Button CommandButton(string label, string id)
    {
        var button = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Center };
        button.Click += (_, _) => _shell.Commands.Get(id).Execute();
        return button;
    }
}

/// <summary>
/// Edits the sun's azimuth or elevation (see <see cref="Atmosphere.Aim"/>): typed, from the slider, or dragged, which is
/// one undo entry from its start.
/// </summary>
sealed class SunAngleEditor(EditorShell shell, bool elevation) : IFieldEditor
{
    const double DegreeStep = 0.5;

    (double Azimuth, double Elevation) _start;
    bool _scrubbing;

    string Label => elevation ? "Set Sun Elevation" : "Set Sun Azimuth";

    public IReadOnlyList<string> Options => [];

    (double Azimuth, double Elevation)? Current =>
        shell.Scene is { } document && shell.AtmosphereVolume is { } volume ? Atmosphere.SunAngles(document.Expanded.Flat, volume) : null;

    // The edit that aims the sun at a value of this angle, from the other angle as it was.
    Document.Operation[] Aim((double Azimuth, double Elevation) from, double value)
    {
        if (shell.Scene is not { } document || shell.AtmosphereVolume is not { } volume)
        {
            return [];
        }
        return elevation
            ? Atmosphere.Aim(document.Expanded.Flat, volume, from.Azimuth, value)
            : Atmosphere.Aim(document.Expanded.Flat, volume, value, from.Elevation);
    }

    public bool Commit(int axis, string text)
    {
        if (!double.TryParse(text.Trim().TrimEnd('°').Replace(",", ""), NumberStyles.Float, CultureInfo.InvariantCulture, out var value))
        {
            shell.Console.Add(LogLevel.Warning, $"edit: \"{text}\" is not a number");
            return false;
        }
        return Current is { } current && shell.Edit(Label, Aim(current, value));
    }

    public void SetFlag(bool value)
    {
    }

    public void SetEntity(ulong handle)
    {
    }

    public void SetAsset(string guid)
    {
    }

    public void Choose(string option)
    {
    }

    public void BeginScrub(int axis)
    {
        if (Current is not { } current || !shell.IsEditing)
        {
            return;
        }
        _start = current;
        _scrubbing = true;
        shell.BeginEdit(Label);
    }

    public void Scrub(int axis, double pixels, KeyModifiers modifiers)
    {
        if (!_scrubbing)
        {
            return;
        }
        var step = DegreeStep * (modifiers.HasFlag(KeyModifiers.Shift) ? 10 : modifiers.HasFlag(KeyModifiers.Control) ? 0.1 : 1);
        shell.PreviewEdit(Aim(_start, (elevation ? _start.Elevation : _start.Azimuth) + pixels * step));
    }

    public void EndScrub()
    {
        if (_scrubbing)
        {
            _scrubbing = false;
            shell.CommitEdit();
        }
    }

    public void SetNumbers(double[] values)
    {
        if (values.Length == 0)
        {
            return;
        }
        if (_scrubbing)
        {
            shell.PreviewEdit(Aim(_start, values[0]));
        }
        else if (Current is { } current)
        {
            shell.Edit(Label, Aim(current, values[0]));
        }
    }
}
