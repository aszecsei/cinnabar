using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using static Cinnabar.Editor.Panels.Kit;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The details strip of a cutscene (see docs/editor/cutscene-editor.md#the-tab): the selected block's fields, with a
/// row for each of its settings. A time's name scrubs it a frame a pixel, in one undo entry, and Esc cancels the drag.
/// </summary>
sealed class CutsceneDetails : DetailsPanel
{
    readonly CutsceneEditor _editor;

    public CutsceneDetails(CutsceneEditor editor)
        : base(new StackPanel { Margin = new Thickness(8), Spacing = 2, MaxWidth = 520, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Left })
    {
        _editor = editor;
        Subscriptions.Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh);
    }

    // A drag shows in the outline and the toolbar. Its own rows build again only when it ends.
    protected override bool Holds => _editor.Document.InTransaction && _editor.Selected != null;

    protected override string ShownKey()
    {
        var block = _editor.Selected;
        // A binding's state and whether a delete can remove it depend on the scenes and the other blocks.
        var binding = block?.Kind == CutsceneBlockKind.Binding ? BindingKey(block) : "";
        return block == null ? "" : $"{_editor.Selection}#{string.Join("\n", block.LineTexts)}#{_editor.File.Rate}{binding}";
    }

    protected override void Fill()
    {
        var block = _editor.Selected;
        if (block == null)
        {
            Rows.Add(Dim("Select a row, a section, an event, a key or a marker to see its details."));
            return;
        }
        var rate = _editor.File.Rate;
        Rows.Add(Heading(block.Kind.ToString()));
        if (block.Id is { } id)
        {
            Rows.Add(Row("ID", new TextBlock { Text = id.ToString(System.Globalization.CultureInfo.InvariantCulture), FontSize = 12 }));
        }
        switch (block.Kind)
        {
            case CutsceneBlockKind.Binding or CutsceneBlockKind.Track:
                if (block.TrackKind is { } kind)
                {
                    Rows.Add(Row("Kind", new TextBlock { Text = kind, FontSize = 12 }));
                }
                Rows.Add(Row("Name", ValueBox(block.Name ?? "", "name", text =>
                    _editor.EditSelected("Rename", b => b.SetName(text.Trim())))));
                if (block.Kind == CutsceneBlockKind.Binding)
                {
                    AddBindingRows(block);
                    if (block.Id is { } camera && _editor.IsCamera(block))
                    {
                        Rows.Add(new CutsceneLensRows(_editor, camera));
                    }
                }
                break;
            case CutsceneBlockKind.Section or CutsceneBlockKind.Range:
                Rows.Add(TicksRow("Start", "Move Start", b => b.Start, (b, t) => b.SetSpan(t, b.End ?? t + 1), rate));
                Rows.Add(TicksRow("End", "Move End", b => b.End, (b, t) => b.SetSpan(b.Start ?? 0, t), rate));
                break;
            case CutsceneBlockKind.Trigger:
                Rows.Add(TicksRow("Time", "Move Trigger", b => b.Start, (b, t) => b.SetTime(t), rate));
                break;
            case CutsceneBlockKind.Key:
                Rows.Add(TicksRow("Time", "Move Key", b => b.Start, (b, t) => b.SetTime(t), rate));
                Rows.Add(Row("Value", ValueBox(block.KeyValue ?? "", "value", text =>
                    _editor.EditSelected("Set Key Value", b => b.SetKeyValue(text)))));
                Rows.Add(Row("Interpolation", ValueBox(block.KeyInterpolation ?? "", "linear", text =>
                    _editor.EditSelected("Set Interpolation", b => b.SetKeyInterpolation(text)))));
                break;
            case CutsceneBlockKind.Marker:
                // The markers stay in time order, as the editor keeps them.
                Rows.Add(TicksRow("Time", "Move Marker", b => b.Start, (b, t) =>
                {
                    b.SetTime(Math.Min(t, _editor.File.Length ?? t));
                    CutsceneFile.SortChildren(b.Parent!);
                }, rate));
                Rows.Add(Row("Name", ValueBox(block.Name ?? "", NotEmpty("a name"), "name", text =>
                    _editor.EditSelected("Rename Marker", b => b.SetName(text.Trim())))));
                Rows.Add(Row("Color", ValueBox(block.Get("color") is { } color ? TextQuote.Unquote(color) ?? color : "", "#f5a623", text =>
                {
                    var hex = text.Trim();
                    _editor.EditSelected("Set Marker Color", b => b.Set("color", hex.Length == 0 ? null : TextQuote.Quote(hex.StartsWith('#') ? hex : "#" + hex)));
                })));
                break;
            case CutsceneBlockKind.Cutscene:
                Rows.Add(TicksRow("length", "Set Length", b => _editor.File.Length, (b, t) => b.Set("length", Format(Math.Max(t, 1))), rate));
                break;
        }
        foreach (var (key, value) in block.Fields)
        {
            if ((block.Kind == CutsceneBlockKind.Cutscene && key == "length") || (block.Kind == CutsceneBlockKind.Marker && key == "color"))
            {
                continue;
            }
            var name = key;
            Rows.Add(Row(name, ValueBox(value, NotEmpty("a value: the × removes the field"), "value", text =>
                _editor.EditSelected($"Set {name}", b => b.Set(name, text.Trim()))), SmallButton("×", $"Remove {name}", () => _editor.EditSelected($"Remove {name}", b => b.Set(name, null)))));
        }
        if (block.Kind is not (CutsceneBlockKind.Key or CutsceneBlockKind.Channel or CutsceneBlockKind.Marker))
        {
            Rows.Add(Row("Add", ValueBox("", ValueFormats.Text.Where(t => Field(t) != null, "a name and a value, such as name = value"), "name = value", text =>
            {
                var (key, value) = Field(text)!.Value;
                _editor.EditSelected($"Set {key}", b => b.Set(key, value));
            })));
        }
    }

    // What a binding's rows depend on besides its lines: its state, the stand-in, an armed pick, the candidates, and
    // what a convert, a stand-in and a delete would refuse, which the selected entities change.
    string BindingKey(CutsceneBlock block)
    {
        var id = block.Id ?? 0;
        var candidates = string.Join(",", _editor.CandidatesOf(block).Select(c => c.Entity));
        var refusals = string.Join("|", Kinds.Select(_editor.ConvertRefusal));
        return $"#{_editor.InfoOf(block)}#{_editor.DeleteBindingRefusal()}#{_editor.StandInOf(id)}#{_editor.Picking}#{_editor.PickRefusal()}"
            + $"#{candidates}#{refusals}#{_editor.StandInRefusal()}";
    }

    static readonly CutsceneBindingKind[] Kinds = [CutsceneBindingKind.Possessed, CutsceneBindingKind.Spawned, CutsceneBindingKind.Provided];

    // A binding's rows (see docs/editor/cutscene-editor.md#bindings): what it binds and whether that is there, a script
    // slot's stand-in, a broken binding's Pick and the entities with its name, the converts and Delete's refusal.
    void AddBindingRows(CutsceneBlock block)
    {
        var id = block.Id ?? 0;
        var info = _editor.InfoOf(block);
        var what = info.Kind switch
        {
            CutsceneBindingKind.Possessed => "Possesses",
            CutsceneBindingKind.Spawned => "Spawns",
            CutsceneBindingKind.Provided => "Stand-in",
            _ => "Binds",
        };
        var target = info.TargetName ?? (info.Kind == CutsceneBindingKind.Provided && _editor.StandInOf(id) == null ? "none" : "?");
        Rows.Add(Row(what, new TextBlock { Text = target, FontSize = 12 }));
        if (info.Kind == CutsceneBindingKind.Provided)
        {
            Rows.Add(Dim($"A script gives this binding's entity when it plays the cutscene, as bindings = {{ [\"{block.Name}\"] = entity }}. "
                + "The stand-in is yours, for the preview, and is not saved in the cutscene."));
            var use = SmallButton("Use Selection", _editor.StandInRefusal() ?? "Preview the slot with the selected entity.", _editor.StandInSelection);
            use.IsEnabled = _editor.StandInRefusal() == null;
            var prefab = PrefabPicker(guid => _editor.SetStandIn(id, CutsceneBindings.FormatPrefab(guid))).Button("Prefab…");
            prefab.HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Left;
            ToolTip.SetTip(prefab, "Preview the slot with a prefab that the preview spawns.");
            var clear = SmallButton("Clear", "Preview the slot with nothing: its tracks do nothing.", () => _editor.SetStandIn(id, null));
            clear.IsEnabled = _editor.StandInOf(id) != null;
            Rows.Add(Row("", use, prefab, clear));
        }
        if (info.Reason is { } reason)
        {
            Rows.Add(Dim(info.State == CutsceneBindingState.NotLoaded ? $"Not loaded: {reason}" : $"Broken: {reason}"));
        }
        if (info.Kind == CutsceneBindingKind.Possessed && info.State == CutsceneBindingState.Broken)
        {
            var armed = _editor.Picking?.Binding == id;
            var pick = SmallButton(armed ? "Cancel Pick" : "Pick", armed
                ? "Select an entity in the viewport or the Outliner for the binding to possess. Esc cancels."
                : _editor.PickRefusal() ?? "Point the binding at the next entity that you select in the viewport or the Outliner.", () =>
                {
                    if (!_editor.CancelPick())
                    {
                        _editor.ArmPick();
                    }
                });
            pick.IsEnabled = armed || _editor.PickRefusal() == null;
            Rows.Add(Row("Fix", pick));
            if (armed)
            {
                Rows.Add(Dim("Select the entity for the binding to possess, in the viewport or the Outliner."));
            }
            foreach (var candidate in _editor.CandidatesOf(block))
            {
                Rows.Add(Row("", SmallButton($"{candidate.Name} in {candidate.Scene}", "Point the binding at this entity, which has its name.",
                    () => _editor.RebindTo(id, candidate.Entity))));
            }
        }
        var converts = new List<Control>();
        foreach (var kind in Kinds.Where(k => k != info.Kind))
        {
            var refusal = _editor.ConvertRefusal(kind);
            var label = kind switch
            {
                CutsceneBindingKind.Possessed => "Possessed",
                CutsceneBindingKind.Spawned => "Spawned",
                _ => "Script Slot",
            };
            var button = SmallButton(label, refusal ?? $"Make the binding {label.ToLowerInvariant()}, and keep its tracks.", () => _editor.Convert(kind));
            button.IsEnabled = refusal == null;
            converts.Add(button);
        }
        if (converts.Count > 0)
        {
            Rows.Add(Row("Convert to", converts[0], [.. converts.Skip(1)]));
        }
        if (_editor.DeleteBindingRefusal() is { } deleteRefusal)
        {
            Rows.Add(Dim($"Delete: {deleteRefusal}"));
        }
    }

    readonly HashSet<string> _prefabFolders = [];

    CatalogPicker PrefabPicker(Action<string> pick) => PrefabPicker(_editor, pick, _prefabFolders);

    /// <summary>A picker of the prefabs that the asset index knows, which gives the GUID of the one picked.</summary>
    internal static CatalogPicker PrefabPicker(CutsceneEditor editor, Action<string> pick, HashSet<string> folders) => new("Search prefabs",
        () => [.. editor.KnownPrefabs().Select(p => new CatalogItem(p.Guid, p.Name, ""))],
        item => pick(item.Id), folders, _ => null)
    {
        Note = () => editor.KnownPrefabs().Count == 0 ? "The asset index knows no prefab yet." : null,
    };

    static string Format(int ticks) => ValueFormats.Ticks.Format(ticks);

    // A name or a field's value, which is never empty: removing a field is the × beside it.
    static IValueFormat<string> NotEmpty(string problem) => ValueFormats.Text.Where(t => t.Trim().Length > 0, problem);

    // A typed field: a name and a value, both of them there.
    static (string Key, string Value)? Field(string text)
    {
        var at = text.IndexOf('=');
        var (key, value) = at > 0 ? (text[..at].Trim(), text[(at + 1)..].Trim()) : ("", "");
        return key.Length == 0 || value.Length == 0 ? null : (key, value);
    }

    // A time in ticks, typed or scrubbed by its name a frame a pixel.
    Control TicksRow(string name, string label, Func<CutsceneBlock, int?> read, Action<CutsceneBlock, int> write, int rate)
    {
        var block = _editor.Selected!;
        var value = read(block);
        var row = Row(name, ValueBox(value is { } v ? Format(v) : "", ValueFormats.Ticks, "ticks", ticks => _editor.EditSelected(label, b => write(b, ticks))), new TextBlock
        {
            Text = value is { } t ? CutsceneTime.Timecode(t, rate) : "",
            Classes = { "empty" },
            FontSize = 12,
            VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
            Margin = new Thickness(6, 0, 0, 0),
        });
        // The name takes the keyboard's focus when a scrub begins, so Esc reaches the view and cancels the scrub.
        var handle = row.Children[0];
        handle.Focusable = true;
        handle.PointerPressed += (_, _) => handle.Focus();
        FieldView.Scrubbable(handle, new TicksScrub(_editor, label, read, write, CutsceneTime.FrameTicks(rate)), 0);
        return row;
    }

    // A drag on a time's name: a frame a pixel, ten with Shift, in one undo entry from begin to end.
    sealed class TicksScrub(CutsceneEditor editor, string label, Func<CutsceneBlock, int?> read, Action<CutsceneBlock, int> write, int frame) : IFieldEditor
    {
        // The time when the drag began, while one is under way.
        int? _start;

        public bool Commit(int axis, string text)
        {
            if (!CutsceneFile.TryParseTicks(text.Trim(), out var ticks))
            {
                return false;
            }
            editor.EditSelected(label, b => write(b, ticks));
            return true;
        }

        public void BeginScrub(int axis)
        {
            _start = editor.Selected is { } block && read(block) is { } start && editor.BeginField(label) ? start : null;
        }

        public void Scrub(int axis, double pixels, KeyModifiers modifiers)
        {
            if (_start is not { } start)
            {
                return;
            }
            var frames = (long)Math.Round(pixels * ScrubSession.Scale(modifiers));
            var ticks = (int)Math.Clamp(start + frames * frame, 0, int.MaxValue);
            editor.StepField(b => write(b, ticks));
        }

        // Only a drag that this scrub began: one that another began, or that Esc cancelled, is not this one's to end.
        public void EndScrub()
        {
            if (_start == null)
            {
                return;
            }
            _start = null;
            editor.EndField(cancel: false);
        }
    }
}
