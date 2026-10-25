using System.Buffers.Binary;
using System.Globalization;
using Avalonia.Input;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;
using Operation = Cinnabar.Editor.Document.Operation;
using SceneValue = Cinnabar.Editor.Document.SceneValue;

namespace Cinnabar.Editor.Panels;

/// <summary>What an edited field holds, for both component fields and behaviour fields.</summary>
enum EditKind
{
    Bool,
    Integer,
    F32,
    F64,
    Enum,
    Vector2,
    Vector3,
    /// <summary>Edited as Euler angles in degrees, as it shows.</summary>
    Quaternion,
    /// <summary>Edited in meters, with m, km, Mm or Gm, and stored raw.</summary>
    Position,
    Entity,
    Asset,
    Text,
}

/// <summary>
/// Edits one field of the selected entities: each edit becomes an operation for each entity that sets the field in the
/// document and on the host, in one undo entry (see docs/editor.md#properties). The value to change comes from the
/// host's values, which the panel passes in as it gets them, so an axis edit keeps each entity's other axes exactly.
/// </summary>
sealed class FieldEditor : IFieldEditor
{
    // A drag moves a number by this much per pixel, ten times as much with Shift and a tenth with Ctrl.
    const double FloatStep = 0.01;
    const double DegreeStep = 0.5;
    const double MeterStep = 0.01;
    const double PixelsPerInteger = 4;

    readonly EditorShell _shell;
    readonly string _label;
    readonly EditKind _kind;
    readonly Func<ulong, SceneValue?, Operation> _operation;
    readonly ulong[] _entities;
    readonly SceneValue?[] _currents;
    readonly (Int128 Min, Int128 Max) _range;
    readonly EnumValue[] _enum;
    SceneValue?[]? _starts;

    FieldEditor(EditorShell shell, ulong[] entities, string label, EditKind kind, Func<ulong, SceneValue?, Operation> operation, (Int128, Int128) range = default, EnumValue[]? enumValues = null)
    {
        _shell = shell;
        _entities = entities;
        _currents = new SceneValue?[entities.Length];
        _label = label;
        _kind = kind;
        _operation = operation;
        _range = range;
        _enum = enumValues ?? [];
        Options = [.. _enum.Select(v => FieldValues.Humanize(v.Name))];
    }

    /// <summary>The scene IDs of the entities that an edit sets, the primary one last.</summary>
    public IReadOnlyList<ulong> Entities => _entities;

    /// <summary>The primary entity's value as the host last sent it, or null before the first.</summary>
    public SceneValue? Current
    {
        get => _currents[^1];
        set => _currents[^1] = value;
    }

    /// <summary>Sets an entity's value as the host sent it, by its index in <see cref="Entities"/>.</summary>
    public void SetCurrent(int index, SceneValue? value) => _currents[index] = value;

    public IReadOnlyList<string> Options { get; }

    /// <summary>An editor for a component's field, or null for a field that the editor cannot set.</summary>
    public static FieldEditor? ForComponent(EditorShell shell, ulong sceneId, ulong component, FieldInfo field) =>
        ForComponent(shell, [sceneId], component, field);

    /// <summary>An editor for a component's field of several entities, the primary one last.</summary>
    public static FieldEditor? ForComponent(EditorShell shell, ulong[] sceneIds, ulong component, FieldInfo field)
    {
        if (field.ReadOnly)
        {
            return null;
        }
        Operation Set(ulong id, SceneValue? v) => new SetField(id, component, field.Name, v);
        var label = $"Set {FieldValues.Humanize(field.Name)}";
        return field.Kind switch
        {
            FieldKind.Bool => new FieldEditor(shell, sceneIds, label, EditKind.Bool, Set),
            FieldKind.F32 => new FieldEditor(shell, sceneIds, label, EditKind.F32, Set),
            FieldKind.F64 => new FieldEditor(shell, sceneIds, label, EditKind.F64, Set),
            FieldKind.Enum => new FieldEditor(shell, sceneIds, label, EditKind.Enum, Set, Range(field.EnumBase), field.EnumValues),
            FieldKind.Vector2 => new FieldEditor(shell, sceneIds, label, EditKind.Vector2, Set),
            FieldKind.Vector3 => new FieldEditor(shell, sceneIds, label, EditKind.Vector3, Set),
            FieldKind.Quaternion => new FieldEditor(shell, sceneIds, label, EditKind.Quaternion, Set),
            FieldKind.Position => new FieldEditor(shell, sceneIds, label, EditKind.Position, Set),
            FieldKind.Entity => new FieldEditor(shell, sceneIds, label, EditKind.Entity, Set),
            FieldKind.Asset => new FieldEditor(shell, sceneIds, label, EditKind.Asset, Set),
            _ => new FieldEditor(shell, sceneIds, label, EditKind.Integer, Set, Range(field.Kind)),
        };
    }

    /// <summary>An editor for a behaviour's field, or null for a kind that the editor cannot set.</summary>
    public static FieldEditor? ForBehaviour(EditorShell shell, ulong sceneId, string script, BehaviourField field)
    {
        Operation Set(ulong id, SceneValue? v) => new SetBehaviourField(id, script, field.Name, v);
        var label = $"Set {FieldValues.Humanize(field.Name)}";
        EditKind? kind = field.Kind switch
        {
            BehaviourFieldKind.Number => EditKind.F64,
            BehaviourFieldKind.Boolean => EditKind.Bool,
            BehaviourFieldKind.String => EditKind.Text,
            BehaviourFieldKind.Vector => EditKind.Vector3,
            BehaviourFieldKind.Entity or BehaviourFieldKind.Nil => EditKind.Entity,
            _ => null,
        };
        return kind is { } k ? new FieldEditor(shell, [sceneId], label, k, Set) : null;
    }

    // One operation for each entity, with the value that each gets.
    Operation[] Operations(Func<SceneValue?, SceneValue?> value) =>
        [.. _entities.Select((id, i) => (id, v: value(_currents[i]))).Where(x => x.v != null).Select(x => _operation(x.id, x.v))];

    Operation[] Operations(SceneValue value) => [.. _entities.Select(id => _operation(id, value))];

    /// <summary>Resets the field of every entity, so the scene no longer sets it.</summary>
    public void Reset() => _shell.Edit($"Reset {_label["Set ".Length..]}", [.. _entities.Select(id => _operation(id, null))]);

    static (Int128, Int128) Range(FieldKind kind) => kind switch
    {
        FieldKind.I8 => (sbyte.MinValue, sbyte.MaxValue),
        FieldKind.I16 => (short.MinValue, short.MaxValue),
        FieldKind.I32 => (int.MinValue, int.MaxValue),
        FieldKind.I64 => (long.MinValue, long.MaxValue),
        FieldKind.U8 => (0, byte.MaxValue),
        FieldKind.U16 => (0, ushort.MaxValue),
        FieldKind.U32 => (0, uint.MaxValue),
        _ => (0, ulong.MaxValue),
    };

    /// <summary>A component field's value from the component's bytes, as a scene stores it.</summary>
    public static SceneValue? Read(FieldInfo field, ReadOnlySpan<byte> component, Func<ulong, ulong> sceneIdOf)
    {
        var kind = field.Kind == FieldKind.Enum ? field.EnumBase : field.Kind;
        var size = FieldValues.Size(kind);
        if (field.Offset + size > component.Length)
        {
            return null;
        }
        var data = component.Slice((int)field.Offset, size);
        var floats = new double[4];
        var longs = new long[3];
        if (field.Kind is FieldKind.Vector2 or FieldKind.Vector3 or FieldKind.Quaternion)
        {
            for (var i = 0; i < size / 4; i++)
            {
                floats[i] = BinaryPrimitives.ReadSingleLittleEndian(data[(i * 4)..]);
            }
        }
        else if (field.Kind == FieldKind.Position)
        {
            for (var i = 0; i < 3; i++)
            {
                longs[i] = BinaryPrimitives.ReadInt64LittleEndian(data[(i * 8)..]);
            }
        }
        switch (field.Kind)
        {
            case FieldKind.Bool:
                return SceneValue.Of(data[0] != 0);
            case FieldKind.F32:
                return SceneValue.Of(SceneNumber.Of((double)BinaryPrimitives.ReadSingleLittleEndian(data)));
            case FieldKind.F64:
                return SceneValue.Of(SceneNumber.Of(BinaryPrimitives.ReadDoubleLittleEndian(data)));
            case FieldKind.Vector2:
                return SceneValue.Of(SceneNumber.Of(floats[0]), SceneNumber.Of(floats[1]));
            case FieldKind.Vector3:
                return SceneValue.Of(SceneNumber.Of(floats[0]), SceneNumber.Of(floats[1]), SceneNumber.Of(floats[2]));
            case FieldKind.Quaternion:
                return SceneValue.Of(SceneNumber.Of(floats[0]), SceneNumber.Of(floats[1]), SceneNumber.Of(floats[2]), SceneNumber.Of(floats[3]));
            case FieldKind.Position:
                return SceneValue.Of([.. longs.Select(SceneNumber.Of)]);
            case FieldKind.Entity:
                return SceneValue.EntityRef(sceneIdOf(BinaryPrimitives.ReadUInt64LittleEndian(data)));
            case FieldKind.Asset:
                return SceneValue.AssetRef(FieldValues.AssetGuid(data));
            case FieldKind.Enum:
                var value = Integer(kind, data);
                var name = field.EnumValues.FirstOrDefault(v => v.Value == value)?.Name;
                return name != null ? SceneValue.Name(name) : Exact(value);
            default:
                return Exact(Integer(kind, data));
        }
    }

    /// <summary>A behaviour field's value, as a scene stores it.</summary>
    public static SceneValue? Read(BehaviourField field, Func<ulong, ulong> sceneIdOf) => field.Kind switch
    {
        BehaviourFieldKind.Number => SceneValue.Of(SceneNumber.Of(field.Number)),
        BehaviourFieldKind.Boolean => SceneValue.Of(field.Boolean),
        BehaviourFieldKind.String => SceneValue.String(field.Text),
        BehaviourFieldKind.Vector => SceneEdits.Floats(field.Vector[0], field.Vector[1], field.Vector[2]),
        BehaviourFieldKind.Entity => SceneValue.EntityRef(sceneIdOf(field.Entity)),
        BehaviourFieldKind.Nil => SceneValue.EntityRef(0),
        _ => null,
    };

    static SceneValue Exact(Int128 value) => SceneValue.Of(new SceneNumber((double)value, value));

    static Int128 Integer(FieldKind kind, ReadOnlySpan<byte> data) => kind switch
    {
        FieldKind.I8 => (sbyte)data[0],
        FieldKind.U8 => data[0],
        FieldKind.I16 => BinaryPrimitives.ReadInt16LittleEndian(data),
        FieldKind.U16 => BinaryPrimitives.ReadUInt16LittleEndian(data),
        FieldKind.I32 => BinaryPrimitives.ReadInt32LittleEndian(data),
        FieldKind.U32 => BinaryPrimitives.ReadUInt32LittleEndian(data),
        FieldKind.I64 => BinaryPrimitives.ReadInt64LittleEndian(data),
        _ => BinaryPrimitives.ReadUInt64LittleEndian(data),
    };

    public bool Commit(int axis, string text)
    {
        if (Parse(axis, text, out var error) == null)
        {
            _shell.Console.Add(LogLevel.Warning, $"edit: {error}");
            return false;
        }
        return _shell.Edit(_label, Operations(current => Parse(axis, text, current, out _)));
    }

    public void SetFlag(bool value) => _shell.Edit(_label, Operations(SceneValue.Of(value)));

    public void SetEntity(ulong handle)
    {
        var sceneId = handle == 0 ? 0 : _shell.World.Find(handle)?.SceneId ?? 0;
        if (handle != 0 && sceneId == 0)
        {
            _shell.Console.Add(LogLevel.Warning, $"edit: {EntityNode.Format(handle)} is not in the scene, so a field cannot refer to it");
            return;
        }
        _shell.Edit(_label, Operations(SceneValue.EntityRef(sceneId)));
    }

    public void SetAsset(string guid) => _shell.Edit(_label, Operations(SceneValue.AssetRef(guid)));

    public void Choose(string option)
    {
        var index = Options.ToList().IndexOf(option);
        if (index >= 0)
        {
            _shell.Edit(_label, Operations(SceneValue.Name(_enum[index].Name)));
        }
    }

    public void BeginScrub(int axis)
    {
        if (_currents.Any(c => c == null) || _kind is EditKind.Bool or EditKind.Enum or EditKind.Entity or EditKind.Asset or EditKind.Text)
        {
            return;
        }
        _starts = [.. _currents];
        _shell.BeginEdit($"Drag {_label["Set ".Length..]}");
    }

    public void Scrub(int axis, double pixels, KeyModifiers modifiers)
    {
        if (_starts is not { } starts)
        {
            return;
        }
        var scale = modifiers.HasFlag(KeyModifiers.Shift) ? 10 : modifiers.HasFlag(KeyModifiers.Control) ? 0.1 : 1;
        // Each entity changes by the same amount from its own value.
        SceneValue? Value(SceneValue start) => _kind switch
        {
            EditKind.Integer => Clamp(start.Numbers[0].Integer!.Value + (Int128)Math.Round(pixels / PixelsPerInteger * scale)),
            EditKind.F32 => SceneEdits.Floats(start.Numbers[0].Float + pixels * FloatStep * scale),
            EditKind.F64 => SceneValue.Of(SceneNumber.Of(start.Numbers[0].Float + pixels * FloatStep * scale)),
            EditKind.Vector2 or EditKind.Vector3 => WithAxis(start, axis, start.Numbers[axis].Float + pixels * FloatStep * scale),
            EditKind.Quaternion => Turned(start, axis, d => d + pixels * DegreeStep * scale),
            EditKind.Position => Moved(start, axis, m => m + pixels * MeterStep * scale),
            _ => null,
        };
        var ops = _entities.Select((id, i) => Value(starts[i]!) is { } v ? _operation(id, v) : null).OfType<Operation>().ToList();
        if (ops.Count > 0)
        {
            _shell.PreviewEdit(ops);
        }
    }

    public void SetNumbers(double[] values)
    {
        SceneValue? value = _kind switch
        {
            EditKind.Integer => Clamp((Int128)Math.Round(values[0])),
            EditKind.F32 => SceneEdits.Floats(values[0]),
            EditKind.F64 => SceneValue.Of(SceneNumber.Of(values[0])),
            EditKind.Vector2 or EditKind.Vector3 => SceneEdits.Floats(values),
            _ => null,
        };
        if (value == null)
        {
            return;
        }
        if (_starts != null)
        {
            _shell.PreviewEdit(Operations(value));
        }
        else
        {
            _shell.Edit(_label, Operations(value));
        }
    }

    public void EndScrub()
    {
        if (_starts != null)
        {
            _starts = null;
            _shell.CommitEdit();
        }
    }

    /// <summary>The value that typed text gives the primary entity, or null with the reason.</summary>
    public SceneValue? Parse(int axis, string text, out string? error) => Parse(axis, text, Current, out error);

    // An axis takes the typed value, and keeps the entity's own other axes.
    SceneValue? Parse(int axis, string text, SceneValue? current, out string? error)
    {
        error = null;
        var trimmed = text.Trim();
        switch (_kind)
        {
            case EditKind.Text:
                return SceneValue.String(text);
            case EditKind.Integer:
                if (!Int128.TryParse(trimmed.Replace(",", ""), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var integer))
                {
                    error = $"\"{text}\" is not an integer";
                    return null;
                }
                if (integer < _range.Min || integer > _range.Max)
                {
                    error = $"{integer} is not in the field's range, {_range.Min} to {_range.Max}";
                    return null;
                }
                return Exact(integer);
            case EditKind.F32 or EditKind.F64 or EditKind.Vector2 or EditKind.Vector3:
                if (!TryNumber(trimmed, out var number))
                {
                    error = $"\"{text}\" is not a number";
                    return null;
                }
                return _kind switch
                {
                    EditKind.F32 => SceneEdits.Floats(number),
                    EditKind.F64 => SceneValue.Of(SceneNumber.Of(number)),
                    _ => current is { } v ? WithAxis(v, axis, number) : null,
                };
            case EditKind.Quaternion:
                if (!TryNumber(trimmed.TrimEnd('°').Replace("deg", ""), out var degrees))
                {
                    error = $"\"{text}\" is not an angle in degrees";
                    return null;
                }
                return current is { } q ? Turned(q, axis, _ => degrees) : null;
            case EditKind.Position:
                if (!TryDistance(trimmed, out var meters))
                {
                    error = $"\"{text}\" is not a distance, such as 12.5 or 3 km";
                    return null;
                }
                return current is { } p ? Moved(p, axis, _ => meters) : null;
            default:
                error = "this field takes no typed value";
                return null;
        }
    }

    SceneValue? Clamp(Int128 value) => Exact(Int128.Clamp(value, _range.Min, _range.Max));

    static SceneValue WithAxis(SceneValue v, int axis, double value) =>
        SceneEdits.Floats([.. v.Numbers.Select((n, i) => i == axis ? value : n.Float)]);

    // A rotation shows as Euler angles, so an edit of one angle keeps the other two as they show.
    static SceneValue Turned(SceneValue q, int axis, Func<double, double> change)
    {
        var euler = FieldValues.Euler(q.Numbers[0].Float, q.Numbers[1].Float, q.Numbers[2].Float, q.Numbers[3].Float);
        euler[axis] = change(euler[axis]);
        return SceneEdits.Floats(FieldValues.Quaternion(euler[0], euler[1], euler[2]));
    }

    // One axis in meters, and the others kept as their raw values.
    static SceneValue Moved(SceneValue p, int axis, Func<double, double> change)
    {
        var raw = p.Numbers.Select(n => (long)n.Integer!.Value).ToArray();
        raw[axis] = (long)Math.Round(change(raw[axis] / Pose.Unit) * Pose.Unit);
        return SceneValue.Of([.. raw.Select(SceneNumber.Of)]);
    }

    static bool TryNumber(string text, out double value) =>
        double.TryParse(text.Replace(",", ""), NumberStyles.Float, CultureInfo.InvariantCulture, out value);

    // A distance as the panel shows one, such as 150 Gm, or a plain number of meters.
    static bool TryDistance(string text, out double meters)
    {
        (string Unit, double Scale)[] units = [("Gm", 1e9), ("Mm", 1e6), ("km", 1e3), ("m", 1)];
        foreach (var (unit, scale) in units)
        {
            if (text.EndsWith(unit, StringComparison.Ordinal) && TryNumber(text[..^unit.Length].Trim(), out var value))
            {
                meters = value * scale;
                return true;
            }
        }
        return TryNumber(text, out meters);
    }
}
