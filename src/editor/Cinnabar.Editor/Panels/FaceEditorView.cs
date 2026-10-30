using System.Globalization;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The Face panel (see docs/editor/mesh-editing.md#mesh-mode), Hammer's face edit sheet: the selected faces' material
/// with a picker and a drop target, their mapping's fields, with the axes read-only and the scale, shift and rotation
/// edited with the properties panel's boxes and drags, the texture's size and the faces' density, the hotspot each
/// sits on, and the texture tools as buttons. With several faces, a field whose values differ shows a dash, and an
/// edit sets each.
/// </summary>
public sealed class FaceEditorView : ScrollViewer
{
    readonly EditorShell _shell;
    readonly StackPanel _content = new() { Classes = { "properties" } };
    readonly Dictionary<string, FieldView> _views = [];
    readonly HashSet<string> _collapsed = [];
    // The tool buttons' hooks on their commands, which outlive the panel's rows.
    readonly List<Action> _unhook = [];
    TextBlock? _title;
    // Null when the rows are not built: before the first attach, and after a detach drops the hooks.
    string? _structure;

    public FaceEditorView(EditorShell shell)
    {
        _shell = shell;
        Content = _content;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        AttachedToVisualTree += (_, _) =>
        {
            _shell.MeshModeChanged += Refresh;
            _shell.Meshes.Changed += OnMeshChanged;
            _shell.Assets.Changed += Refresh;
            _shell.SceneChanged += Refresh;
            Refresh();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _shell.MeshModeChanged -= Refresh;
            _shell.Meshes.Changed -= OnMeshChanged;
            _shell.Assets.Changed -= Refresh;
            _shell.SceneChanged -= Refresh;
            Unhook();
            _structure = null;
        };
    }

    void Unhook()
    {
        foreach (var unhook in _unhook)
        {
            unhook();
        }
        _unhook.Clear();
    }

    void OnMeshChanged(MeshDocument document, MeshData data) => Refresh();

    // The panel rebuilds when which faces are selected changes, and shows new values otherwise.
    void Refresh()
    {
        var structure = _shell.CanRunTextureTool ? string.Join(";", _shell.SelectedFaces.Select(f => $"{f.Guid}:{f.Face}")) : "";
        if (structure != _structure)
        {
            _structure = structure;
            Rebuild();
        }
        ShowValues();
    }

    void Rebuild()
    {
        Unhook();
        _content.Children.Clear();
        _views.Clear();
        _title = null;
        if (!_shell.CanRunTextureTool)
        {
            _content.Children.Add(new TextBlock
            {
                Text = _shell.InMeshMode ? "Select faces to edit their material and texture." : "In mesh mode, the selected faces' material and texture mapping appear here.",
                Classes = { "empty" },
                TextWrapping = TextWrapping.Wrap,
            });
            return;
        }
        _title = new TextBlock { FontWeight = FontWeight.SemiBold };
        _content.Children.Add(new StackPanel { Classes = { "properties-header" }, Children = { _title } });

        var assets = new AssetContext(_shell.Assets, "material", _shell.RevealAsset) { First = EditorShell.DevMaterials.Select(d => d.Guid).ToHashSet() };
        _content.Children.Add(Group("Material",
        [
            ("Material", "material", new AssetView(assets, new MappingEditor(_shell, MappingField.Material)), null),
            ("Texture", "texture", new BoxView(numeric: false, null), null),
            ("Density", "density", new BoxView(numeric: false, null), null),
        ]));
        var scale = new MappingEditor(_shell, MappingField.Scale);
        var shift = new MappingEditor(_shell, MappingField.Shift);
        var rotation = new MappingEditor(_shell, MappingField.Rotation);
        _content.Children.Add(Group("Mapping",
        [
            ("U Axis", "u", new BoxView(numeric: false, null), null),
            ("V Axis", "v", new BoxView(numeric: false, null), null),
            ("Scale", "scale", new AxesView(scale, 2), null),
            ("Shift", "shift", new AxesView(shift, 2), null),
            ("Rotation", "rotation", new BoxView(numeric: true, rotation), rotation),
            ("Hotspot", "hotspot", new BoxView(numeric: false, null), null),
        ]));
        _content.Children.Add(Tools());
    }

    // A group of rows: a name, a view, and for a number, the editor whose scrub the name drags.
    Control Group(string title, IReadOnlyList<(string Name, string Key, FieldView View, IFieldEditor? Scrub)> fields)
    {
        var rows = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), Classes = { "fields" } };
        var row = 0;
        foreach (var (name, key, view, scrub) in fields)
        {
            rows.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            var label = new TextBlock { Text = name, Classes = { "field-name" }, VerticalAlignment = VerticalAlignment.Center };
            if (scrub != null)
            {
                ToolTip.SetTip(label, $"{name}. Drag to change it.");
                FieldView.Scrubbable(label, scrub, 0);
            }
            Grid.SetRow(label, row);
            Grid.SetRow(view.Control, row);
            Grid.SetColumn(view.Control, 1);
            rows.Children.Add(label);
            rows.Children.Add(view.Control);
            _views[key] = view;
            row++;
        }
        return Expander(title, rows);
    }

    // The texture tools as buttons, in rows by what they do.
    Control Tools()
    {
        var panel = new StackPanel { Spacing = 4 };
        void Row(string label, params (string Text, string Command)[] buttons)
        {
            var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
            foreach (var (text, id) in buttons)
            {
                var command = _shell.Commands.Get(id);
                var button = new Button { Content = text, Classes = { "field-button" }, Margin = new Avalonia.Thickness(0, 0, 4, 4), IsEnabled = command.CanExecute };
                ToolTip.SetTip(button, command.Description);
                button.Click += (_, _) => command.Execute();
                void Enable() => button.IsEnabled = command.CanExecute;
                command.Changed += Enable;
                _unhook.Add(() => command.Changed -= Enable);
                wrap.Children.Add(button);
            }
            panel.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children = { new TextBlock { Text = label, Classes = { "field-name" }, Width = 52, VerticalAlignment = VerticalAlignment.Top, Margin = new Avalonia.Thickness(0, 4, 0, 0) }, wrap },
            });
        }
        Row("Align", ("World", EditorCommands.TextureAlignWorld), ("Face", EditorCommands.TextureAlignFace), ("To Edge", EditorCommands.TextureAlignEdge), ("To Face", EditorCommands.TextureAlignToFace));
        Row("Fit", ("Both", EditorCommands.TextureFit), ("U", EditorCommands.TextureFitU), ("V", EditorCommands.TextureFitV));
        Row("Justify", ("Left", EditorCommands.TextureJustifyLeft), ("Right", EditorCommands.TextureJustifyRight), ("Top", EditorCommands.TextureJustifyTop), ("Bottom", EditorCommands.TextureJustifyBottom), ("Center", EditorCommands.TextureJustifyCenter));
        Row("Flip", ("U", EditorCommands.TextureFlipU), ("V", EditorCommands.TextureFlipV));
        Row("Hotspot", ("Apply", EditorCommands.TextureHotspot), ("Next", EditorCommands.TextureHotspotNext), ("Random", EditorCommands.TextureHotspotRandom));
        Row("Scale", ("Reset", EditorCommands.TextureResetScale), ("Up", EditorCommands.TextureScaleUp), ("Down", EditorCommands.TextureScaleDown));
        return Expander("Tools", panel);
    }

    Control Expander(string title, Control content)
    {
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

    void ShowValues()
    {
        if (_title == null || _views.Count == 0)
        {
            return;
        }
        var faces = _shell.SelectedFaces.Select(f => (f.Guid, f.Face, Mesh: _shell.Meshes.Find(f.Guid)?.Data)).Where(f => f.Mesh != null && f.Face < f.Mesh.Faces.Length).ToList();
        var meshes = faces.Select(f => f.Guid).Distinct().Count();
        _title.Text = $"{faces.Count} {(faces.Count == 1 ? "Face" : "Faces")} of {meshes} {(meshes == 1 ? "mesh" : "meshes")}";
        if (faces.Count == 0)
        {
            return;
        }
        var materials = faces.Select(f => f.Mesh!.Materials[f.Mesh!.Faces[f.Face].Slot]).Distinct().ToList();
        var mappings = faces.Select(f => f.Mesh!.Faces[f.Face].Mapping).ToList();
        Show("material", new FieldDisplay(DisplayKind.Asset, materials[0], [], false, 0,
            materials.Count > 1 ? $"The faces have {materials.Count} materials; an edit sets them all." : null));

        var textures = materials.Select(_shell.MaterialTexture).ToList();
        var texture = textures.Count == 1 ? textures[0] : null;
        Show("texture", Text(textures.Count > 1 ? "—" : texture is var (guid, width, height)
            ? $"{(_shell.Assets.Find(guid) is { } t ? Cinnabar.Editor.Content.AssetIndex.DisplayName(t) : guid)}, {width} × {height}"
            : "none", texture == null && textures.Count == 1 ? "The material samples no texture that the tools can measure by. A tool_texture line in its source names one." : null));
        var densities = textures.Count == 1 && texture is var (_, w, h)
            ? mappings.Select(m => MeshTexture.Density(m, w, h)).Distinct().ToList() : [];
        Show("density", Text(densities is [{ } d] ? $"{Number(d.U)} × {Number(d.V)} px/m, project {Number(_shell.TexelDensity)}"
            : densities.Count > 1 ? "—" : $"project {Number(_shell.TexelDensity)} px/m",
            "The faces' texels per meter along u and v, from the scale and the texture's size, and the project's density, which Reset Scale sets."));

        Show("u", Text(Same(mappings.Select(m => Axis(m.UAxis))), "The texture's u axis in the mesh's space. Align sets it."));
        Show("v", Text(Same(mappings.Select(m => Axis(m.VAxis))), "The texture's v axis in the mesh's space."));
        Show("scale", Axes(Same(mappings.Select(m => Number(m.ScaleU))), Same(mappings.Select(m => Number(m.ScaleV))), "Meters per texture repeat along u and v. Drag a marker, or type."));
        Show("shift", Axes(Same(mappings.Select(m => Number(m.ShiftU))), Same(mappings.Select(m => Number(m.ShiftV))), "The texture's shift in repeats along u and v."));
        Show("rotation", new FieldDisplay(DisplayKind.Number, Same(mappings.Select(m => Number(m.Rotation) + "°")), [], false, 0, "The texture's rotation about the mapping's origin, in degrees."));

        string hotspot;
        string? tooltip = null;
        var problem = false;
        if (textures.Count != 1 || texture is not var (_, tw, th))
        {
            hotspot = "—";
        }
        else if (_shell.MaterialHotspots(materials[0]) is { Count: > 0 } hotspots)
        {
            var current = faces.Select(f => MeshTexture.CurrentHotspot(f.Mesh!, f.Face, f.Mesh!.Faces[f.Face].Mapping, hotspots, tw, th)).Distinct().ToList();
            if (current is [{ } index])
            {
                var rect = hotspots[index];
                problem = faces.Any(f => MeshTexture.LeavesHotspot(f.Mesh!, f.Face, f.Mesh!.Faces[f.Face].Mapping, rect, tw, th));
                hotspot = $"{index + 1} of {hotspots.Count}, {rect.Width} × {rect.Height}{(problem ? ", left" : "")}";
                tooltip = problem ? "The texture leaves the hotspot's rectangle, so the face shows beyond the tileable piece. Hotspot maps it back." : "The hotspot rectangle that the faces sit on, by its line in the material's source.";
            }
            else if (current is [null])
            {
                hotspot = "off every rectangle";
                problem = true;
                tooltip = "The faces' UVs are on none of the material's hotspots. Hotspot maps them onto the best one.";
            }
            else
            {
                hotspot = "—";
            }
        }
        else
        {
            hotspot = "none";
            tooltip = "The material's source has no hotspot lines, so Hotspot fits the texture instead.";
        }
        Show("hotspot", Text(hotspot, tooltip));
        if (_views.TryGetValue("hotspot", out var view))
        {
            view.Control.Classes.Set("warning", problem);
        }
    }

    void Show(string key, FieldDisplay value)
    {
        if (_views.TryGetValue(key, out var view))
        {
            view.Show(value);
        }
    }

    static FieldDisplay Text(string text, string? tooltip) => new(DisplayKind.Text, text, [], false, 0, tooltip);

    static FieldDisplay Axes(string u, string v, string tooltip) => new(DisplayKind.Axes, $"{u}, {v}", [u, v], false, 0, tooltip);

    static string Same(IEnumerable<string> values)
    {
        var distinct = values.Distinct().ToList();
        return distinct.Count == 1 ? distinct[0] : "—";
    }

    static string Number(double value) => value.ToString("0.###", CultureInfo.InvariantCulture);

    // A unit axis by name, or its components.
    static string Axis(Vec3 v)
    {
        (Vec3 Unit, string Name)[] units = [(Vec3.UnitX, "+x"), (-Vec3.UnitX, "-x"), (Vec3.UnitY, "+y"), (-Vec3.UnitY, "-y"), (Vec3.UnitZ, "+z"), (-Vec3.UnitZ, "-z")];
        foreach (var (unit, name) in units)
        {
            if ((v - unit).Length < 1e-6)
            {
                return name;
            }
        }
        return $"{Number(v.X)}, {Number(v.Y)}, {Number(v.Z)}";
    }
}

enum MappingField
{
    Material,
    Scale,
    Shift,
    Rotation,
}

/// <summary>
/// Edits one field of the selected faces' mappings through the shell: a typed value sets it as one undo entry, and a
/// drag of its name or an axis's marker changes it from where each face's value was, in one entry from begin to end.
/// </summary>
sealed class MappingEditor(EditorShell shell, MappingField field) : IFieldEditor
{
    const double ScaleStep = 0.01;
    const double ShiftStep = 0.01;
    const double DegreeStep = 0.5;

    bool _scrubbing;

    public IReadOnlyList<string> Options => [];

    public bool Commit(int axis, string text)
    {
        var trimmed = text.Trim().TrimEnd('°');
        if (!double.TryParse(trimmed.Replace(",", ""), NumberStyles.Float, CultureInfo.InvariantCulture, out var value))
        {
            shell.Console.Add(LogLevel.Warning, $"edit: \"{text}\" is not a number");
            return false;
        }
        return field switch
        {
            MappingField.Scale when value == 0 => Refuse("a scale of 0 would put the whole texture at one point"),
            MappingField.Scale => shell.SetTextureScale(axis == 1 ? null : value, axis == 0 ? null : value),
            MappingField.Shift => shell.SetTextureShift(axis == 1 ? null : value, axis == 0 ? null : value),
            MappingField.Rotation => shell.SetTextureRotation(value),
            _ => false,
        };
    }

    bool Refuse(string reason)
    {
        shell.Console.Add(LogLevel.Warning, $"edit: {reason}");
        return false;
    }

    public void SetFlag(bool value)
    {
    }

    public void SetEntity(ulong handle)
    {
    }

    public void SetAsset(string guid)
    {
        if (field == MappingField.Material)
        {
            shell.SetFaceMaterial(guid);
        }
    }

    public void Choose(string option)
    {
    }

    public void BeginScrub(int axis)
    {
        if (field != MappingField.Material)
        {
            _scrubbing = shell.BeginMappingScrub($"Drag Texture {field}");
        }
    }

    public void Scrub(int axis, double pixels, KeyModifiers modifiers)
    {
        if (!_scrubbing)
        {
            return;
        }
        var scale = modifiers.HasFlag(KeyModifiers.Shift) ? 10 : modifiers.HasFlag(KeyModifiers.Control) ? 0.1 : 1;
        var delta = pixels * scale;
        shell.PreviewMappings((_, _, m) => field switch
        {
            MappingField.Scale => axis == 0 ? m with { ScaleU = NonZero(m.ScaleU + delta * ScaleStep, m.ScaleU) } : m with { ScaleV = NonZero(m.ScaleV + delta * ScaleStep, m.ScaleV) },
            MappingField.Shift => axis == 0 ? m with { ShiftU = m.ShiftU + delta * ShiftStep } : m with { ShiftV = m.ShiftV + delta * ShiftStep },
            MappingField.Rotation => MeshTexture.Rotate(m, delta * DegreeStep),
            _ => m,
        });
    }

    // A scale that a drag takes through 0 skips it, so the texture never collapses to a point.
    static double NonZero(double value, double was) => Math.Abs(value) < 1e-6 ? Math.CopySign(1e-6, was) : value;

    public void EndScrub()
    {
        if (_scrubbing)
        {
            _scrubbing = false;
            shell.EndMappingScrub();
        }
    }

    public void SetNumbers(double[] values)
    {
    }
}
