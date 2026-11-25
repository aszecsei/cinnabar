using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tools;

public enum CutsceneRowKind
{
    Binding,
    Track,
    Channel,
}

public enum CutsceneItemKind
{
    Section,
    Range,
    Trigger,
    Key,
    Marker,
}

/// <summary>
/// Something that the timeline draws: on a row, a section or a range as a bar, or a trigger or a key at its time, and on
/// the ruler, a marker at its time, on the cutscene's time.
/// </summary>
public sealed record CutsceneTimelineItem(CutsceneItemKind Kind, int Start, int End, string Path)
{
    /// <summary>What a section's bar says: a subtitle's line, a presentation's kind, a camera cut's camera, or the ID. A marker's name.</summary>
    public string? Label { get; init; }

    /// <summary>A marker's color as <c>#rrggbb</c>, or null for the default.</summary>
    public string? Color { get; init; }

    /// <summary>A section's <c>ease_in</c> and <c>ease_out</c> in ticks, which its handles set. 0 for a camera cut, whose blends are its own.</summary>
    public int EaseIn { get; init; }

    public int EaseOut { get; init; }

    /// <summary>An animation's or a sound's clip under its section, when the index knows the clip's length.</summary>
    public CutsceneClipSpan? Clip { get; init; }

    /// <summary>A sound section's peak file, by its path in the cache, or null when the daemon has none.</summary>
    public string? Peaks { get; init; }

    /// <summary>A sound section's gain, which scales its waveform.</summary>
    public CutsceneGain Gain { get; init; } = CutsceneGain.One;

    /// <summary>An animation section's clip events, from its binding's graph, in the clip's ticks.</summary>
    public IReadOnlyList<CutsceneClipEvent> Events { get; init; } = [];

    /// <summary>
    /// A trigger's or a range's warning, when no behaviour that its track sends to handles its name (see
    /// docs/editor/cutscene-editor.md#events), or null.
    /// </summary>
    public string? Warning { get; init; }

    /// <summary>The time that the bar draws over: its span, and the faded parts of its clip before and after it.</summary>
    public (double Start, double End) Reach => Clip is { } clip && CutsceneTimelineLayout.Hints(Start, End, clip) is var hints
        ? (hints.HeadStart ?? Start, hints.TailEnd ?? End)
        : (Start, End);
}

/// <summary>
/// What the content index knows of a section's clip or sound: its name, its length in ticks, or null before it has
/// cooked, and a sound's peak file, or null before the daemon has made it.
/// </summary>
public sealed record CutsceneClipInfo(string Name, int? Length, string? Peaks = null);

/// <summary>
/// An animation's or a sound's clip under its section (see docs/editor/cutscene-editor.md#loops-and-hints): the clip's
/// ticks where the section starts (<c>offset</c>), the clip's ticks for each of the cutscene's (<c>speed</c>, 1 for a
/// sound), whether it loops, and the clip's length in ticks, above 0.
/// </summary>
public sealed record CutsceneClipSpan(int Offset, double Speed, bool Loop, int Length);

/// <summary>
/// The parts of a clip's pass that a section cuts off, on the cutscene's time: where the pass that the section starts in
/// began, where the pass that it ends in would end, and where a clip that does not loop ends inside the section. Each is
/// null when there is none.
/// </summary>
public sealed record CutsceneClipHints(double? HeadStart, double? TailEnd, double? ClipEnd);

/// <summary>
/// A clip's marks in view, in the time area's pixels: a line at each loop, with marks closer than 2 pixels as one run,
/// where a clip that does not loop ends, and its faded head and tail.
/// </summary>
public sealed record CutsceneClipMarks(IReadOnlyList<(double X0, double X1)> Loops, double? End, (double X0, double X1)? Head, (double X0, double X1)? Tail);

/// <summary>
/// Which rows the timeline shows (see docs/editor/cutscene-editor.md#search-and-filter): those whose binding's or
/// track's name holds a text, ignoring case, with keysIn, only the tracks with a key in that span of time, and with
/// bindings, only those bindings and their tracks (see docs/editor/cutscene-editor.md#selection-sync).
/// </summary>
public sealed record CutsceneRowFilter(string Text, (int Start, int End)? KeysIn, IReadOnlySet<int>? Bindings = null)
{
    public static readonly CutsceneRowFilter None = new("", null);

    public bool IsNone => Text.Length == 0 && KeysIn == null && Bindings == null;
}

public enum CutsceneBindingKind
{
    /// <summary>It names an entity of a scene, with <c>possess</c>.</summary>
    Possessed,
    /// <summary>It spawns a prefab for the cutscene, with <c>spawn</c>.</summary>
    Spawned,
    /// <summary>A script gives its entity when it plays the cutscene, with <c>provided = true</c>: a script slot.</summary>
    Provided,
    /// <summary>It has none of <c>possess</c>, <c>spawn</c> and <c>provided</c>, or more than one.</summary>
    Unknown,
}

public enum CutsceneBindingState
{
    Bound,
    /// <summary>Its entity's scene is not open in the editor.</summary>
    NotLoaded,
    /// <summary>Its entity, its scene or its prefab is missing.</summary>
    Broken,
}

/// <summary>
/// What a binding's row shows (see docs/editor/cutscene-editor.md#bindings): whether it possesses or spawns, the name of
/// its entity or prefab, and whether that is there, with the reason when it is not.
/// </summary>
public sealed record CutsceneBindingInfo(CutsceneBindingKind Kind, string? TargetName, CutsceneBindingState State, string? Reason = null)
{
    /// <summary>Whether the binding is a camera, which a scene view can look through (see docs/editor/cutscene-editor.md#look-through).</summary>
    public bool Camera { get; init; }
}

/// <summary>A row of the timeline: a binding, a track or one of a track's channels, with what it draws.</summary>
public sealed class CutsceneTimelineRow
{
    internal CutsceneTimelineRow(CutsceneRowKind kind, string path, string label, int depth)
    {
        Kind = kind;
        Path = path;
        Label = label;
        Depth = depth;
    }

    public CutsceneRowKind Kind { get; }

    /// <summary>The path of the binding or track that the row is, or of its track for a channel's row.</summary>
    public string Path { get; }

    public string Label { get; }

    public int Depth { get; }

    /// <summary>A track's kind, or for a channel's row, its track's.</summary>
    public string? TrackKind { get; internal set; }

    /// <summary>A track's ID, or for a channel's row, its track's.</summary>
    public int? TrackId { get; internal set; }

    /// <summary>A channel's name, for a channel's row.</summary>
    public string? Channel { get; internal set; }

    /// <summary>Whether the row has rows under it that a fold hides or shows.</summary>
    public bool CanFold { get; internal set; }

    /// <summary>Whether the rows under it are hidden.</summary>
    public bool Folded { get; internal set; }

    /// <summary>For a binding's row, what it binds and whether that is there, when the layout was given a way to tell.</summary>
    public CutsceneBindingInfo? Binding { get; internal set; }

    /// <summary>Whether the track's asset sets <c>muted = true</c>, which no player plays.</summary>
    public bool AssetMuted { get; internal set; }

    /// <summary>The row's top in content pixels, under the ruler.</summary>
    public double Top { get; internal set; }

    /// <summary>The sections and ranges, in start order.</summary>
    public List<CutsceneTimelineItem> Bars { get; } = [];

    /// <summary>The triggers, in time order.</summary>
    public List<CutsceneTimelineItem> Points { get; } = [];

    /// <summary>The keys, in time order: all of a track's on its row, and one channel's on a channel's row.</summary>
    public List<CutsceneTimelineItem> Keys { get; } = [];
}

/// <summary>A row as it is on screen, with what of it is in view.</summary>
public sealed record CutsceneVisibleRow(CutsceneTimelineRow Row, double Y, IReadOnlyList<CutsceneVisibleBar> Bars, IReadOnlyList<CutsceneKeyGlyph> Points, IReadOnlyList<CutsceneKeyGlyph> Keys)
{
    /// <summary>The triggers in view as flags and badges (see <see cref="CutsceneTimelineLayout.Flags"/>).</summary>
    public IReadOnlyList<CutsceneEventFlag> Flags { get; init; } = [];
}

/// <summary>
/// Triggers that draw as one flag (see docs/editor/cutscene-editor.md#flags-on-the-timeline): one with its name, or several, closer than
/// the first one's name is wide, as a badge with their count. X is the first one's, in the time area's pixels, and the
/// flag takes the pixels from X to X + Width.
/// </summary>
public sealed record CutsceneEventFlag(double X, double Width, IReadOnlyList<CutsceneTimelineItem> Items)
{
    public bool Badge => Items.Count > 1;

    public IEnumerable<string> Paths => Items.Select(i => i.Path);

    /// <summary>What the flag says: the trigger's name, or the badge's count.</summary>
    public string Text => Badge ? Items.Count.ToString(System.Globalization.CultureInfo.InvariantCulture) : Items[0].Label ?? "";
}

/// <summary>A bar in view, from x0 to x1 in the time area's pixels.</summary>
public sealed record CutsceneVisibleBar(double X0, double X1, CutsceneTimelineItem Item);

/// <summary>
/// A glyph for keys or triggers: one, or several closer than 2 pixels that draw as one, as
/// <see cref="TimelineGeometry.Runs"/> merges a profiler's zones.
/// </summary>
public sealed record CutsceneKeyGlyph(double X, IReadOnlyList<CutsceneTimelineItem> Items)
{
    public IEnumerable<string> Paths => Items.Select(i => i.Path);
}

public enum CutsceneHitKind
{
    None,
    /// <summary>The ruler, where a click or a drag moves the playhead.</summary>
    Ruler,
    RangeStart,
    RangeEnd,
    /// <summary>The handle at the end of the length.</summary>
    Length,
    /// <summary>A row's header, which selects its binding or track.</summary>
    Header,
    Fold,
    /// <summary>A track's mute toggle, each user's, which only the preview hears.</summary>
    Mute,
    /// <summary>A camera binding's toggle, which makes the active scene view look through the camera.</summary>
    LookThrough,
    /// <summary>A track's solo toggle, each user's, which only the preview hears.</summary>
    Solo,
    Lock,
    /// <summary>A marker's flag on the ruler.</summary>
    Marker,
    Key,
    Trigger,
    Body,
    StartEdge,
    EndEdge,
    /// <summary>A section's ease in handle, at the top of its bar, which sets its <c>ease_in</c>.</summary>
    EaseIn,
    /// <summary>A section's ease out handle, at the top of its bar, which sets its <c>ease_out</c>.</summary>
    EaseOut,
    /// <summary>The time area where nothing is, on a row or under the rows.</summary>
    Empty,
}

/// <summary>What a point of the timeline is on: its kind, its row, the paths of what it names, and its time.</summary>
public sealed record CutsceneHit(CutsceneHitKind Kind, CutsceneTimelineRow? Row, IReadOnlyList<string> Paths, double Tick);

/// <summary>
/// The timeline of a cutscene (see docs/editor/cutscene-editor.md#the-timeline) as rows, and what is where on them: the
/// pure part of the view, which tests call without a window. Points are in the control's pixels: the header gutter on
/// the left, the ruler at the top, and the time area to the right of the one and under the other. Times are ticks.
/// </summary>
public sealed class CutsceneTimelineLayout
{
    public const double Gutter = 220;
    public const double RulerHeight = 30;
    /// <summary>The range bar: the bottom of the ruler.</summary>
    public const double RangeBarHeight = 8;
    public const double RowHeight = 22;
    public const double Indent = 14;
    /// <summary>How near an edge or a key a point is on it.</summary>
    public const double Grab = 5;
    /// <summary>Keys closer than this draw as one glyph.</summary>
    public const double MergeWidth = 2;
    /// <summary>From a trigger's time to its flag's text.</summary>
    public const double FlagInset = 8;
    /// <summary>The width that a flag's text takes for each character, so the draw and the hit test agree without a font.</summary>
    public const double FlagCharWidth = 6;
    /// <summary>The room after a flag's text, and around a badge's count.</summary>
    public const double FlagPad = 4;
    /// <summary>The width of each of a track header's toggles: mute, solo and lock, from left to right at its right end.</summary>
    public const double LockWidth = 22;
    /// <summary>The marker flags' strip: the top of the ruler.</summary>
    public const double MarkerHeight = 12;
    /// <summary>The top of a row in which a press is on a section's ease handles, not on its edges or body.</summary>
    public const double HandleBand = 9;
    /// <summary>The size of an ease handle's square.</summary>
    public const double HandleSize = 6;
    /// <summary>A label needs this many pixels of its bar in view.</summary>
    public const double LabelMinWidth = 16;

    /// <summary>The left edge of the mute toggle in a track's header.</summary>
    public const double MuteX = Gutter - 3 * LockWidth;

    /// <summary>The left edge of the solo toggle in a track's header.</summary>
    public const double SoloX = Gutter - 2 * LockWidth;

    // The order of the tracks that no binding has, at the top.
    static readonly string[] MasterOrder = ["camera_cut", "audio", "event", "presentation", "sub_sequence"];

    CutsceneTimelineLayout(List<CutsceneTimelineRow> rows, List<CutsceneTimelineItem> markers, int length, int rate, (int Start, int End) range)
    {
        Rows = rows;
        Markers = markers;
        Length = length;
        Rate = rate;
        Range = range;
    }

    public IReadOnlyList<CutsceneTimelineRow> Rows { get; }

    /// <summary>The markers, in time order.</summary>
    public IReadOnlyList<CutsceneTimelineItem> Markers { get; }

    public int Length { get; }

    public int Rate { get; }

    /// <summary>The ticks of a frame at the display rate.</summary>
    public int FrameTicks => CutsceneFile.TicksPerSecond / Rate;

    /// <summary>The part that plays.</summary>
    public (int Start, int End) Range { get; }

    /// <summary>The rows' height, under the ruler.</summary>
    public double ContentHeight => Rows.Count * RowHeight;

    /// <summary>
    /// The rows of a cutscene: the tracks that no binding has first (camera cuts, audio, events, presentation and
    /// sub-sequences), then each binding with its tracks under it, and under a track, a row for each channel name of its
    /// sections. A binding shows its tracks unless toggled is folding it, and a track hides its channels unless toggled
    /// opens it: toggled holds the paths whose fold is not the default. A filter leaves out the tracks that it does not
    /// show, and a binding with none of its tracks shown, unless the text names the binding and no span is given. A
    /// filter's bindings leave out every other binding, and the tracks that no binding has. bindingInfo tells each
    /// binding's row what it binds, and clipInfo each animation or audio section's clip, by its GUID, what it is.
    /// clipEvents gives an animation track's clip's events, by the track and the clip's GUID, from its binding's graph.
    /// </summary>
    public static CutsceneTimelineLayout Build(CutsceneFile file, IReadOnlySet<string> toggled, CutsceneRowFilter? filter = null,
        Func<CutsceneBlock, CutsceneBindingInfo?>? bindingInfo = null, Func<string, CutsceneClipInfo?>? clipInfo = null,
        Func<CutsceneBlock, string, IReadOnlyList<CutsceneClipEvent>>? clipEvents = null, Func<CutsceneBlock, string?>? eventWarning = null)
    {
        var sources = new ClipSources(clipInfo, clipEvents, eventWarning);
        filter ??= CutsceneRowFilter.None;
        var rows = new List<CutsceneTimelineRow>();
        var bindingIds = file.Bindings.Select(b => b.Id).OfType<int>().ToHashSet();
        int? BindingOf(CutsceneBlock track) =>
            track.Get("binding") is { } text && CutsceneFile.TryParseId(text, out var id) && bindingIds.Contains(id) ? id : null;
        bool Names(string? name) => filter.Text.Length == 0 || (name?.Contains(filter.Text, StringComparison.OrdinalIgnoreCase) ?? false);
        bool HasKeysIn(CutsceneBlock track) => filter.KeysIn is not { } span || track.Children.Any(s => s is { Kind: CutsceneBlockKind.Section, Start: { } start }
            && s.Descendants().Any(k => k.Kind == CutsceneBlockKind.Key && k.Start is { } t && start + t >= span.Start && start + t <= span.End));
        var master = file.Tracks.Where(t => BindingOf(t) == null && filter.Bindings == null)
            .OrderBy(t => Array.IndexOf(MasterOrder, t.TrackKind) is var i and >= 0 ? i : MasterOrder.Length)
            .Where(t => Names(TrackLabel(t)) && HasKeysIn(t))
            .ToList();
        foreach (var track in master)
        {
            AddTrack(rows, file, track, 0, toggled, sources);
        }
        foreach (var binding in file.Bindings)
        {
            if (filter.Bindings != null && (binding.Id is not { } id || !filter.Bindings.Contains(id)))
            {
                continue;
            }
            var path = CutsceneFile.PathOf(binding);
            var named = filter.Text.Length > 0 && Names(binding.Name);
            var tracks = file.Tracks.Where(t => binding.Id != null && BindingOf(t) == binding.Id)
                .Where(t => (named || Names(TrackLabel(t))) && HasKeysIn(t))
                .ToList();
            var textOrKeys = filter.Text.Length > 0 || filter.KeysIn != null;
            if (textOrKeys && tracks.Count == 0 && !(named && filter.KeysIn == null))
            {
                continue;
            }
            var row = new CutsceneTimelineRow(CutsceneRowKind.Binding, path, binding.Name ?? $"binding {binding.Id}", 0)
            {
                CanFold = tracks.Count > 0,
                Folded = toggled.Contains(path),
                Binding = bindingInfo?.Invoke(binding),
            };
            rows.Add(row);
            if (row.Folded)
            {
                continue;
            }
            foreach (var track in tracks)
            {
                AddTrack(rows, file, track, 1, toggled, sources);
            }
        }
        for (var i = 0; i < rows.Count; i++)
        {
            rows[i].Top = i * RowHeight;
        }
        var markers = file.Markers.Where(m => m.Start != null)
            .Select(m => new CutsceneTimelineItem(CutsceneItemKind.Marker, m.Start!.Value, m.Start!.Value, CutsceneFile.PathOf(m))
            {
                Label = m.Name,
                Color = m.Get("color") is { } color ? TextQuote.Unquote(color) : null,
            })
            .OrderBy(m => m.Start)
            .ToList();
        return new CutsceneTimelineLayout(rows, markers, file.Length ?? 0, file.Rate, CutsceneEdits.RangeOf(file));
    }

    static string TrackLabel(CutsceneBlock track) => string.IsNullOrEmpty(track.Name) ? track.TrackKind ?? "track" : track.Name;

    // What the editor tells a build of the clips under sections.
    sealed record ClipSources(Func<string, CutsceneClipInfo?>? Info, Func<CutsceneBlock, string, IReadOnlyList<CutsceneClipEvent>>? Events,
        Func<CutsceneBlock, string?>? EventWarning);

    static void AddTrack(List<CutsceneTimelineRow> rows, CutsceneFile file, CutsceneBlock track, int depth, IReadOnlySet<string> toggled,
        ClipSources sources)
    {
        var path = CutsceneFile.PathOf(track);
        var label = TrackLabel(track);
        var channels = track.Children.Where(c => c.Kind == CutsceneBlockKind.Section)
            .SelectMany(s => s.Children.Where(c => c.Kind == CutsceneBlockKind.Channel))
            .Select(c => c.Name).OfType<string>().Distinct().ToList();
        var row = new CutsceneTimelineRow(CutsceneRowKind.Track, path, label, depth)
        {
            TrackKind = track.TrackKind,
            TrackId = track.Id,
            CanFold = channels.Count > 0,
            Folded = !toggled.Contains(path),
            AssetMuted = track.Get("muted")?.Trim() == "true",
        };
        rows.Add(row);
        foreach (var child in track.Children)
        {
            switch (child)
            {
                case { Kind: CutsceneBlockKind.Section, Start: { } s, End: { } e }:
                {
                    var guid = track.TrackKind is "animation" or "audio" && child.Get("asset") is { } asset ? asset.Trim().TrimStart('$') : null;
                    var clip = guid != null ? sources.Info?.Invoke(guid) : null;
                    var eased = track.TrackKind != "camera_cut";
                    var audio = track.TrackKind == "audio";
                    row.Bars.Add(new CutsceneTimelineItem(CutsceneItemKind.Section, s, e, CutsceneFile.PathOf(child))
                    {
                        Label = SectionLabel(file, track, child, clip),
                        EaseIn = eased ? Ticks(child, "ease_in") : 0,
                        EaseOut = eased ? Ticks(child, "ease_out") : 0,
                        Clip = SpanOf(track, child, clip),
                        Peaks = audio ? clip?.Peaks : null,
                        Gain = audio ? CutsceneGain.Of(track, child) : CutsceneGain.One,
                        Events = track.TrackKind == "animation" && guid != null ? sources.Events?.Invoke(track, guid) ?? [] : [],
                    });
                    foreach (var (key, keyPath) in Keys(child, null))
                    {
                        row.Keys.Add(new CutsceneTimelineItem(CutsceneItemKind.Key, s + key.Start!.Value, s + key.Start!.Value, keyPath));
                    }
                    break;
                }
                case { Kind: CutsceneBlockKind.Range, Start: { } s, End: { } e }:
                    row.Bars.Add(new CutsceneTimelineItem(CutsceneItemKind.Range, s, e, CutsceneFile.PathOf(child)) { Label = child.Name, Warning = sources.EventWarning?.Invoke(child) });
                    break;
                case { Kind: CutsceneBlockKind.Trigger, Start: { } t }:
                    row.Points.Add(new CutsceneTimelineItem(CutsceneItemKind.Trigger, t, t, CutsceneFile.PathOf(child)) { Label = child.Name, Warning = sources.EventWarning?.Invoke(child) });
                    break;
            }
        }
        row.Bars.Sort((a, b) => a.Start.CompareTo(b.Start));
        row.Points.Sort((a, b) => a.Start.CompareTo(b.Start));
        row.Keys.Sort((a, b) => a.Start.CompareTo(b.Start));
        if (row.Folded)
        {
            return;
        }
        foreach (var name in channels)
        {
            var channel = new CutsceneTimelineRow(CutsceneRowKind.Channel, path, name, depth + 1)
            {
                TrackKind = track.TrackKind,
                TrackId = track.Id,
                Channel = name,
            };
            foreach (var section in track.Children.Where(c => c.Kind == CutsceneBlockKind.Section && c.Start != null))
            {
                foreach (var (key, keyPath) in Keys(section, name))
                {
                    var at = section.Start!.Value + key.Start!.Value;
                    channel.Keys.Add(new CutsceneTimelineItem(CutsceneItemKind.Key, at, at, keyPath));
                }
            }
            channel.Keys.Sort((a, b) => a.Start.CompareTo(b.Start));
            rows.Add(channel);
        }
    }

    // A section's keys with a time, of one channel or of all, with their paths, counted here rather than looked up for
    // each key.
    static IEnumerable<(CutsceneBlock Key, string Path)> Keys(CutsceneBlock section, string? channel)
    {
        var sectionPath = CutsceneFile.PathOf(section);
        foreach (var block in section.Children.Where(c => c.Kind == CutsceneBlockKind.Channel && (channel == null || c.Name == channel)))
        {
            var index = 0;
            foreach (var key in block.Children)
            {
                if (key.Kind != CutsceneBlockKind.Key)
                {
                    continue;
                }
                if (key.Start != null)
                {
                    yield return (key, $"{sectionPath}/channel:{block.Name}/key:{index}");
                }
                index++;
            }
        }
    }

    // What a section's bar says: a presentation section's line or kind, a camera cut's camera, an animation's or a
    // sound's clip, or else its ID.
    static string SectionLabel(CutsceneFile file, CutsceneBlock track, CutsceneBlock section, CutsceneClipInfo? clip) => track.TrackKind switch
    {
        "animation" or "audio" when clip != null => clip.Name,
        "presentation" => section.Get("text") is { } text ? TextQuote.Unquote(text) ?? text : section.Get("kind") ?? "",
        "camera_cut" => section.Get("camera") is { } camera && CutsceneFile.TryParseId(camera, out var id)
            ? file.Bindings.FirstOrDefault(b => b.Id == id)?.Name ?? $"binding {id}"
            : "",
        _ => $"#{section.Id}",
    };

    static int Ticks(CutsceneBlock block, string key) =>
        block.Get(key)?.Trim() is { } text && CutsceneFile.TryParseTicks(text, out var ticks) ? ticks : 0;

    /// <summary>
    /// A section's clip, when the index knows its length, or null. A sound with a <c>pitch</c> channel plays at a rate
    /// that changes over the section, so it has none, and neither its loops nor its hints show.
    /// </summary>
    public static CutsceneClipSpan? SpanOf(CutsceneBlock track, CutsceneBlock section, CutsceneClipInfo? clip)
    {
        if (clip?.Length is not { } length || length <= 0)
        {
            return null;
        }
        var animation = track.TrackKind == "animation";
        if (!animation && section.Children.Any(c => c.Kind == CutsceneBlockKind.Channel && c.Name == "pitch"))
        {
            return null;
        }
        var speed = animation && section.Get("speed") is { } text
            && double.TryParse(text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var value) && value > 0
            ? value
            : 1;
        return new CutsceneClipSpan(Ticks(section, "offset"), speed, section.Get("loop")?.Trim() == "true", length);
    }

    /// <summary>
    /// The parts of a clip's pass that a section from start to end cuts off (see docs/editor/cutscene-editor.md#loops-and-hints),
    /// on the cutscene's time. The clip's time at t is <c>offset + (t - start) × speed</c>. A clip that loops shows the
    /// rest of the pass that it starts in before the start, and the rest of the pass that it ends in after the end. A
    /// clip that does not loop shows the part of its clip before its offset, the part past the end, and where it ends
    /// inside the section, after which the pose holds or the sound is silent.
    /// </summary>
    public static CutsceneClipHints Hints(int start, int end, CutsceneClipSpan clip)
    {
        double length = clip.Length, offset = clip.Offset, speed = clip.Speed;
        // Less than half a tick of clip is none.
        const double Least = 0.5;
        if (clip.Loop)
        {
            var phase = offset % length;
            var rest = (offset + (end - start) * speed) % length;
            return new CutsceneClipHints(
                phase > Least ? start - phase / speed : null,
                rest > Least && length - rest > Least ? end + (length - rest) / speed : null,
                null);
        }
        var clipEnd = start + (length - offset) / speed;
        return new CutsceneClipHints(
            offset > Least && offset < length ? start - offset / speed : null,
            clipEnd > end + Least / speed ? clipEnd : null,
            clipEnd < end - Least / speed ? Math.Max(clipEnd, start) : null);
    }

    /// <summary>
    /// A section's clip marks in view: a mark at each loop inside the section, only those in view, and one run over the
    /// visible part when they are closer than <see cref="MergeWidth"/>; where a clip that does not loop ends; and its
    /// <see cref="Hints"/> as spans. Pixels are the time area's, and width is its width.
    /// </summary>
    public static CutsceneClipMarks ClipMarks(int start, int end, CutsceneClipSpan clip, TimelineView view, double width)
    {
        var hints = Hints(start, end, clip);
        var loops = new List<(double X0, double X1)>();
        if (clip.Loop)
        {
            double length = clip.Length, offset = clip.Offset, speed = clip.Speed;
            var from = Math.Max(start, view.At(0));
            var to = Math.Min(end, view.At(width));
            // The k-th loop is where the clip's time is k lengths: past the offset, so not at the start, and before the end.
            var first = Math.Floor(offset / length) + 1;
            double At(double k) => start + (k * length - offset) / speed;
            var spacing = length / speed / view.PerPixel;
            var k0 = Math.Max(first, Math.Ceiling(((from - start) * speed + offset) / length));
            if (from < to && At(first) < end && At(k0) <= to)
            {
                if (spacing < MergeWidth)
                {
                    loops.Add((view.X(At(k0)), view.X(Math.Min(to, end - 1))));
                }
                else
                {
                    for (var k = k0; At(k) < end && At(k) <= to; k++)
                    {
                        var x = view.X(At(k));
                        loops.Add((x, x));
                    }
                }
            }
        }
        return new CutsceneClipMarks(
            loops,
            hints.ClipEnd is { } clipEnd ? view.X(clipEnd) : null,
            hints.HeadStart is { } head ? (view.X(head), view.X(start)) : null,
            hints.TailEnd is { } tail ? (view.X(end), view.X(tail)) : null);
    }

    /// <summary>
    /// Where a bar's label goes in the time area: 4 pixels into the part of the bar in view, so a section that starts
    /// off screen still shows its label, with the room to its visible end. Null when less than
    /// <see cref="LabelMinWidth"/> is in view.
    /// </summary>
    public static (double X, double Room)? LabelRoom(double x0, double x1, double width)
    {
        var x = Math.Max(x0, 0) + 4;
        var room = Math.Min(x1, width) - 4 - x;
        return room >= LabelMinWidth ? (x, room) : null;
    }

    /// <summary>
    /// Where sections in view overlap, from x0 to x1, in start order: where they blend over each other, through the
    /// earlier one's ease out and the later one's ease in.
    /// </summary>
    public static List<(double X0, double X1)> Overlaps(IReadOnlyList<CutsceneVisibleBar> bars)
    {
        var overlaps = new List<(double X0, double X1)>();
        var reach = double.NegativeInfinity;
        foreach (var bar in bars)
        {
            if (bar.Item.Kind != CutsceneItemKind.Section)
            {
                continue;
            }
            if (bar.X0 < reach)
            {
                overlaps.Add((bar.X0, Math.Min(bar.X1, reach)));
            }
            reach = Math.Max(reach, bar.X1);
        }
        return overlaps;
    }

    /// <summary>Whether a row's sections have ease handles: a track's row of any kind but camera cuts, whose blends are their own.</summary>
    public static bool HasHandles(CutsceneTimelineRow row) => row.Kind == CutsceneRowKind.Track && row.TrackKind != "camera_cut";

    /// <summary>
    /// A section's ease handles' x in the time area: the ease in's at its start and its ease in, and the ease out's at its
    /// end less its ease out. Null for a bar too narrow for them, which is only its body.
    /// </summary>
    public static (double In, double Out)? Handles(CutsceneTimelineItem bar, TimelineView view)
    {
        if (bar.Kind != CutsceneItemKind.Section || view.X(bar.End) - view.X(bar.Start) < 3 * Grab)
        {
            return null;
        }
        return (view.X(bar.Start + bar.EaseIn), view.X(bar.End - bar.EaseOut));
    }

    /// <summary>The band at the bottom of a row where an animation section's clip events sit, and where a hover names them.</summary>
    public const double EventBand = 6;

    /// <summary>
    /// The names of the clip events nearest a point of the control, within <see cref="Grab"/>, in the bottom
    /// <see cref="EventBand"/> of an animation section's bar: what a hover shows. It is not a hit, so a press there is on
    /// the section. Null where no event is near.
    /// </summary>
    public IReadOnlyList<string>? EventsAt(double x, double y, TimelineView view, double scrollY, double width)
    {
        if (x < Gutter || RowAt(y, scrollY) is not { Kind: CutsceneRowKind.Track, TrackKind: "animation" } row
            || RulerHeight + row.Top - scrollY + RowHeight - y > EventBand)
        {
            return null;
        }
        var px = x - Gutter;
        var nearest = double.PositiveInfinity;
        var names = new List<string>();
        foreach (var bar in row.Bars)
        {
            if (bar.Clip is not { } clip || bar.Events.Count == 0)
            {
                continue;
            }
            foreach (var tick in CutsceneWaveform.EventTicks(bar, clip, bar.Events, view, width))
            {
                var distance = Math.Abs(tick.X - px);
                if (distance > Grab || distance > nearest + MergeWidth)
                {
                    continue;
                }
                if (distance < nearest - MergeWidth)
                {
                    names.Clear();
                }
                nearest = Math.Min(nearest, distance);
                if (!names.Contains(tick.Name))
                {
                    names.Add(tick.Name);
                }
            }
        }
        return names.Count > 0 ? names : null;
    }

    /// <summary>The row at a y in the control, or null over the ruler or under the rows.</summary>
    public CutsceneTimelineRow? RowAt(double y, double scrollY)
    {
        if (y < RulerHeight)
        {
            return null;
        }
        var index = (int)Math.Floor((y - RulerHeight + scrollY) / RowHeight);
        return index >= 0 && index < Rows.Count ? Rows[index] : null;
    }

    /// <summary>
    /// What is in view: the rows between the ruler and the bottom, and of each, the bars, triggers and keys inside the
    /// time area's width, with keys and triggers closer than 2 pixels merged into one glyph. This is all that a redraw
    /// reads, so its cost is the timeline's.
    /// </summary>
    public List<CutsceneVisibleRow> Visible(TimelineView view, double width, double scrollY, double height)
    {
        var result = new List<CutsceneVisibleRow>();
        var first = Math.Max((int)Math.Floor(scrollY / RowHeight), 0);
        var last = Math.Min((int)Math.Ceiling((scrollY + Math.Max(height - RulerHeight, 0)) / RowHeight) - 1, Rows.Count - 1);
        // An item a few pixels outside still draws, so its edge does not pop in.
        var from = view.At(-Grab);
        var to = view.At(width + Grab);
        for (var i = first; i <= last; i++)
        {
            var row = Rows[i];
            var bars = new List<CutsceneVisibleBar>();
            foreach (var bar in row.Bars)
            {
                var (reachStart, reachEnd) = bar.Reach;
                if (reachEnd >= from && reachStart <= to)
                {
                    bars.Add(new CutsceneVisibleBar(view.X(bar.Start), view.X(bar.End), bar));
                }
            }
            result.Add(new CutsceneVisibleRow(row, RulerHeight + row.Top - scrollY, bars, Glyphs(row.Points, view, from, to), Glyphs(row.Keys, view, from, to))
            {
                Flags = [.. FlagsInView(row, view).TakeWhile(f => f.X <= view.X(to))],
            });
        }
        return result;
    }

    /// <summary>
    /// The triggers' flags, from glyphs in time order: a glyph joins the flag before it while it is closer to that flag's
    /// start than the flag is wide. A flag is as wide as its name, and a badge as its count, whichever is wider once it
    /// has more than one.
    /// </summary>
    public static List<CutsceneEventFlag> Flags(IReadOnlyList<CutsceneKeyGlyph> glyphs)
    {
        var flags = new List<CutsceneEventFlag>();
        var items = new List<CutsceneTimelineItem>();
        double x = 0, width = 0;
        void Close()
        {
            if (items.Count > 0)
            {
                flags.Add(new CutsceneEventFlag(x, width, [.. items]));
                items.Clear();
            }
        }
        foreach (var glyph in glyphs)
        {
            if (items.Count > 0 && glyph.X < x + width)
            {
                items.AddRange(glyph.Items);
                width = Math.Max(width, FlagWidth(items.Count.ToString(System.Globalization.CultureInfo.InvariantCulture)));
                continue;
            }
            Close();
            x = glyph.X;
            items.AddRange(glyph.Items);
            width = FlagWidth(items.Count > 1 ? items.Count.ToString(System.Globalization.CultureInfo.InvariantCulture) : items[0].Label ?? "");
        }
        Close();
        return flags;
    }

    /// <summary>How wide a flag is that says the text.</summary>
    public static double FlagWidth(string text) => FlagInset + text.Length * FlagCharWidth + FlagPad;

    // A row's flags from the left edge of the view on, which the draw and the hit test both group from, so a badge holds
    // the same triggers in each.
    static List<CutsceneEventFlag> FlagsInView(CutsceneTimelineRow row, TimelineView view) =>
        row.Points.Count == 0 ? [] : Flags(Glyphs(row.Points, view, view.At(-Grab), double.PositiveInfinity));

    static List<CutsceneKeyGlyph> Glyphs(List<CutsceneTimelineItem> items, TimelineView view, double from, double to)
    {
        var glyphs = new List<CutsceneKeyGlyph>();
        // The items are in time order, so the first in view is found by a binary search.
        var lo = 0;
        var hi = items.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (items[mid].Start < from)
            {
                lo = mid + 1;
            }
            else
            {
                hi = mid;
            }
        }
        var spans = new List<(double, double)>();
        var end = lo;
        for (; end < items.Count && items[end].Start <= to; end++)
        {
            var x = view.X(items[end].Start);
            spans.Add((x, x));
        }
        foreach (var run in TimelineGeometry.Runs(spans, MergeWidth))
        {
            var group = new CutsceneTimelineItem[run.Count];
            for (var k = 0; k < run.Count; k++)
            {
                group[k] = items[lo + run.First + k];
            }
            glyphs.Add(new CutsceneKeyGlyph((spans[run.First].Item1 + spans[run.First + run.Count - 1].Item1) / 2, group));
        }
        return glyphs;
    }

    /// <summary>What a point of the control is on.</summary>
    public CutsceneHit HitTest(double x, double y, TimelineView view, double scrollY)
    {
        var tick = view.At(x - Gutter);
        if (y < RulerHeight)
        {
            if (x < Gutter)
            {
                return new CutsceneHit(CutsceneHitKind.None, null, [], tick);
            }
            var tx = x - Gutter;
            // A marker's flag before the handles, as it sits over them.
            if (y < MarkerHeight && Nearest(Markers, view, tx) is { } markers)
            {
                return new CutsceneHit(CutsceneHitKind.Marker, null, markers, tick);
            }
            if (y >= RulerHeight - RangeBarHeight)
            {
                if (Math.Abs(tx - view.X(Range.End)) <= Grab)
                {
                    return new CutsceneHit(CutsceneHitKind.RangeEnd, null, [], tick);
                }
                if (Math.Abs(tx - view.X(Range.Start)) <= Grab)
                {
                    return new CutsceneHit(CutsceneHitKind.RangeStart, null, [], tick);
                }
            }
            else if (Math.Abs(tx - view.X(Length)) <= Grab)
            {
                return new CutsceneHit(CutsceneHitKind.Length, null, [], tick);
            }
            return new CutsceneHit(CutsceneHitKind.Ruler, null, [], tick);
        }
        var row = RowAt(y, scrollY);
        if (x < Gutter)
        {
            if (row == null)
            {
                return new CutsceneHit(CutsceneHitKind.None, null, [], tick);
            }
            var foldX = 4 + row.Depth * Indent;
            if (row.CanFold && x >= foldX && x < foldX + Indent)
            {
                return new CutsceneHit(CutsceneHitKind.Fold, row, [row.Path], tick);
            }
            if (row.Binding is { Camera: true, State: CutsceneBindingState.Bound } && x >= Gutter - LockWidth)
            {
                return new CutsceneHit(CutsceneHitKind.LookThrough, row, [row.Path], tick);
            }
            if (row.Kind == CutsceneRowKind.Track && x >= MuteX)
            {
                var kind = x >= Gutter - LockWidth ? CutsceneHitKind.Lock : x >= SoloX ? CutsceneHitKind.Solo : CutsceneHitKind.Mute;
                return new CutsceneHit(kind, row, [row.Path], tick);
            }
            return new CutsceneHit(CutsceneHitKind.Header, row, [row.Path], tick);
        }
        if (row == null)
        {
            return new CutsceneHit(CutsceneHitKind.Empty, null, [], tick);
        }
        var px = x - Gutter;
        // In the top of a row, a section's ease handles come first, over its keys and edges, so a key at its start does not
        // take its handle: the nearest within Grab, and of two as near, the bar drawn last. Where a section's two handles
        // meet, a point left of them is on the ease in, which ends there, and a point right of them on the ease out.
        if (y - (RulerHeight + row.Top - scrollY) < HandleBand && HasHandles(row))
        {
            CutsceneHit? best = null;
            var nearest = double.PositiveInfinity;
            for (var i = row.Bars.Count - 1; i >= 0; i--)
            {
                if (Handles(row.Bars[i], view) is not { } handles)
                {
                    continue;
                }
                foreach (var (hx, kind) in new[] { (handles.Out, CutsceneHitKind.EaseOut), (handles.In, CutsceneHitKind.EaseIn) })
                {
                    var distance = Math.Abs(px - hx);
                    var meets = distance == nearest && kind == CutsceneHitKind.EaseIn && px < hx && best?.Paths[0] == row.Bars[i].Path;
                    if (distance <= Grab && (distance < nearest || meets))
                    {
                        nearest = distance;
                        best = new CutsceneHit(kind, row, [row.Bars[i].Path], tick);
                    }
                }
            }
            if (best != null)
            {
                return best;
            }
        }
        // Keys first, as they sit on the bars, then triggers, then the bars' edges and bodies.
        if (Nearest(row.Keys, view, px) is { } keys)
        {
            return new CutsceneHit(CutsceneHitKind.Key, row, keys, tick);
        }
        // A trigger's diamond, with the others of its flag, then the bars, then the rest of a flag: its name or its badge.
        var flags = FlagsInView(row, view);
        if (flags.Where(f => Math.Abs(f.X - px) <= Grab).MinBy(f => Math.Abs(f.X - px)) is { } diamond)
        {
            return new CutsceneHit(CutsceneHitKind.Trigger, row, [.. diamond.Paths], tick);
        }
        // A bar under the point first, the last of them, as it draws over the ones before it: where two bars meet, each
        // edge is the side of its own bar. Then an edge just outside a bar.
        for (var pass = 0; pass < 2; pass++)
        {
            for (var i = row.Bars.Count - 1; i >= 0; i--)
            {
                var bar = row.Bars[i];
                var x0 = view.X(bar.Start);
                var x1 = view.X(bar.End);
                var inside = px >= x0 && px <= x1;
                if (pass == 0 ? !inside : px < x0 - Grab || px > x1 + Grab)
                {
                    continue;
                }
                // A bar too narrow for both edges and a body is its body.
                if (x1 - x0 < 3 * Grab)
                {
                    return new CutsceneHit(CutsceneHitKind.Body, row, [bar.Path], tick);
                }
                if (Math.Abs(px - x0) <= Grab)
                {
                    return new CutsceneHit(CutsceneHitKind.StartEdge, row, [bar.Path], tick);
                }
                if (Math.Abs(px - x1) <= Grab)
                {
                    return new CutsceneHit(CutsceneHitKind.EndEdge, row, [bar.Path], tick);
                }
                return new CutsceneHit(CutsceneHitKind.Body, row, [bar.Path], tick);
            }
        }
        if (flags.FirstOrDefault(f => px >= f.X && px <= f.X + f.Width) is { } flag)
        {
            return new CutsceneHit(CutsceneHitKind.Trigger, row, [.. flag.Paths], tick);
        }
        return new CutsceneHit(CutsceneHitKind.Empty, row, [], tick);
    }

    // The items nearest to a pixel within the grab distance, with the others that draw in the same glyph.
    static List<string>? Nearest(IReadOnlyList<CutsceneTimelineItem> items, TimelineView view, double px)
    {
        var best = double.MaxValue;
        foreach (var item in items)
        {
            best = Math.Min(best, Math.Abs(view.X(item.Start) - px));
        }
        if (best > Grab)
        {
            return null;
        }
        return [.. items.Where(i => Math.Abs(view.X(i.Start) - px) <= best + MergeWidth).Select(i => i.Path)];
    }

    /// <summary>
    /// The paths of what a box covers, from (x0, y0) to (x1, y1) in the control's pixels in any order: the keys and
    /// triggers in it, and the bars that it overlaps.
    /// </summary>
    public List<string> InBox(double x0, double y0, double x1, double y1, TimelineView view, double scrollY)
    {
        var (left, right) = (Math.Min(x0, x1) - Gutter, Math.Max(x0, x1) - Gutter);
        var (top, bottom) = (Math.Min(y0, y1), Math.Max(y0, y1));
        var from = view.At(left);
        var to = view.At(right);
        var paths = new List<string>();
        foreach (var row in Rows)
        {
            var rowTop = RulerHeight + row.Top - scrollY;
            if (rowTop + RowHeight < top || rowTop > bottom)
            {
                continue;
            }
            paths.AddRange(row.Keys.Concat(row.Points).Where(i => i.Start >= from && i.Start <= to).Select(i => i.Path));
            paths.AddRange(row.Bars.Where(b => b.End >= from && b.Start <= to).Select(b => b.Path));
        }
        return [.. paths.Distinct()];
    }

    /// <summary>
    /// The times that a drag snaps to, besides frames and the playhead: the edges of the bars, the triggers, the keys and
    /// the markers that the drag does not move.
    /// </summary>
    public List<int> SnapTargets(IReadOnlySet<string> moving)
    {
        var targets = new HashSet<int> { 0, Length };
        foreach (var marker in Markers.Where(m => !moving.Contains(m.Path)))
        {
            targets.Add(marker.Start);
        }
        foreach (var row in Rows.Where(r => r.Kind == CutsceneRowKind.Track))
        {
            foreach (var bar in row.Bars.Where(b => !moving.Contains(b.Path)))
            {
                targets.Add(bar.Start);
                targets.Add(bar.End);
            }
            foreach (var item in row.Points.Concat(row.Keys).Where(i => !moving.Contains(i.Path)))
            {
                targets.Add(item.Start);
            }
        }
        return [.. targets.Order()];
    }

    /// <summary>The times that Ctrl+Left and Ctrl+Right go to: 0, the length, the markers, and the edges of the sections, ranges and triggers.</summary>
    public List<int> Edges()
    {
        var edges = new HashSet<int> { 0, Length };
        foreach (var marker in Markers)
        {
            edges.Add(marker.Start);
        }
        foreach (var row in Rows.Where(r => r.Kind == CutsceneRowKind.Track))
        {
            foreach (var bar in row.Bars)
            {
                edges.Add(bar.Start);
                edges.Add(bar.End);
            }
            foreach (var point in row.Points)
            {
                edges.Add(point.Start);
            }
        }
        return [.. edges.Order()];
    }

    /// <summary>
    /// The names that a camera cut track's row shows over its cuts (see docs/editor/cutscene-editor.md#the-cut-strip):
    /// each cut's camera, from the cut's start, or the view's left edge, up to the next cut's start, or the view's right
    /// edge, so a name shows past a short cut's end when the track has a gap after it. A name with less than 16 pixels of
    /// room is left out. <paramref name="width"/> is the time area's width.
    /// </summary>
    public static IReadOnlyList<(double X, double Room, string Label)> CutNames(IReadOnlyList<CutsceneVisibleBar> bars, double width)
    {
        var names = new List<(double, double, string)>();
        for (var i = 0; i < bars.Count; i++)
        {
            if (bars[i].Item.Label is not { Length: > 0 } label)
            {
                continue;
            }
            var x = Math.Max(bars[i].X0, 0);
            var end = Math.Min(i + 1 < bars.Count ? bars[i + 1].X0 : width, width);
            var room = end - x - 6;
            if (room >= 16)
            {
                names.Add((x, room, label));
            }
        }
        return names;
    }

    /// <summary>
    /// The shot at a time, as the Game view's frame counter names it: the camera of the cutscene's own camera cut section
    /// over the time, from its start up to its end, or null when none is. A cut track that the asset mutes, or whose ID
    /// is in <paramref name="silent"/>, names none, as the game shows none.
    /// </summary>
    public static string? ShotAt(CutsceneFile file, int tick, IEnumerable<int>? silent = null)
    {
        var quiet = silent?.ToHashSet() ?? [];
        var cuts = file.Tracks
            .Where(t => t.TrackKind == "camera_cut" && t.Get("muted")?.Trim() != "true" && !(t.Id is { } id && quiet.Contains(id)))
            .Select(t => t.Id).OfType<int>().ToHashSet();
        if (cuts.Count == 0)
        {
            return null;
        }
        var layout = Build(file, new HashSet<string>());
        return layout.Rows
            .Where(r => r.Kind == CutsceneRowKind.Track && r.TrackId is { } id && cuts.Contains(id))
            .SelectMany(r => r.Bars)
            .LastOrDefault(b => b.Start <= tick && (tick < b.End || (tick == b.End && b.End == layout.Length)))?.Label;
    }

    /// <summary>
    /// The times of the keys and of the edges of the sections, ranges and triggers on the tracks whose IDs are in a set,
    /// or on every track with null, and the start and the end, in order: where Up and Down move the playhead.
    /// </summary>
    public List<int> KeyEdges(IReadOnlySet<int>? tracks)
    {
        var edges = new HashSet<int> { 0, Length };
        foreach (var row in Rows.Where(r => r.Kind == CutsceneRowKind.Track && (tracks == null || r.TrackId is { } id && tracks.Contains(id))))
        {
            foreach (var bar in row.Bars)
            {
                edges.Add(bar.Start);
                edges.Add(bar.End);
            }
            foreach (var item in row.Points.Concat(row.Keys))
            {
                edges.Add(item.Start);
            }
        }
        return [.. edges.Order()];
    }

    /// <summary>The span of what the paths name, for F, or null when they name nothing on the timeline.</summary>
    public (int Start, int End)? SpanOf(IReadOnlySet<string> paths)
    {
        var items = Rows.SelectMany(r => r.Bars.Concat(r.Points).Concat(r.Keys)).Concat(Markers).Where(i => paths.Contains(i.Path)).ToList();
        return items.Count == 0 ? null : (items.Min(i => i.Start), items.Max(i => i.End));
    }
}

/// <summary>Where a dragged time lands: on a target within 6 pixels, or else on the nearest frame.</summary>
public static class TimelineSnap
{
    /// <summary>How near a target a time snaps to it, in pixels.</summary>
    public const double Distance = 6;

    /// <summary>
    /// Snaps a time: to the nearest of the targets within 6 pixels, which is the guide's time, or else to the nearest
    /// frame, with no guide. Off, the time is only rounded to a tick.
    /// </summary>
    public static (int Tick, int? Guide) Snap(double tick, IReadOnlyList<int> targets, double ticksPerPixel, int frameTicks, bool enabled)
    {
        if (!enabled)
        {
            return ((int)Math.Round(tick), null);
        }
        int? best = null;
        var bestDistance = Distance * ticksPerPixel;
        // The targets are in order, so the nearest is beside where the time would go.
        var at = BinarySearch(targets, tick);
        for (var i = Math.Max(at - 1, 0); i <= Math.Min(at, targets.Count - 1); i++)
        {
            var d = Math.Abs(targets[i] - tick);
            if (d <= bestDistance)
            {
                best = targets[i];
                bestDistance = d;
            }
        }
        if (best is { } target)
        {
            return (target, target);
        }
        return ((int)(Math.Round(tick / frameTicks) * frameTicks), null);
    }

    // The index of the first target at or after a time.
    static int BinarySearch(IReadOnlyList<int> targets, double tick)
    {
        var lo = 0;
        var hi = targets.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (targets[mid] < tick)
            {
                lo = mid + 1;
            }
            else
            {
                hi = mid;
            }
        }
        return lo;
    }
}
