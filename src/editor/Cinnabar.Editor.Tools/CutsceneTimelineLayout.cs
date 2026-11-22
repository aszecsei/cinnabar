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
}

/// <summary>
/// Which rows the timeline shows (see docs/editor/cutscene-editor.md#search-and-filter): those whose binding's or
/// track's name holds a text, ignoring case, and with keysIn, only the tracks with a key in that span of time.
/// </summary>
public sealed record CutsceneRowFilter(string Text, (int Start, int End)? KeysIn)
{
    public static readonly CutsceneRowFilter None = new("", null);

    public bool IsNone => Text.Length == 0 && KeysIn == null;
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
public sealed record CutsceneVisibleRow(CutsceneTimelineRow Row, double Y, IReadOnlyList<CutsceneVisibleBar> Bars, IReadOnlyList<CutsceneKeyGlyph> Points, IReadOnlyList<CutsceneKeyGlyph> Keys);

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
    /// <summary>The width of each of a track header's toggles: mute, solo and lock, from left to right at its right end.</summary>
    public const double LockWidth = 22;
    /// <summary>The marker flags' strip: the top of the ruler.</summary>
    public const double MarkerHeight = 12;

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
    /// show, and a binding with none of its tracks shown, unless the text names the binding and no span is given.
    /// </summary>
    public static CutsceneTimelineLayout Build(CutsceneFile file, IReadOnlySet<string> toggled, CutsceneRowFilter? filter = null)
    {
        filter ??= CutsceneRowFilter.None;
        var rows = new List<CutsceneTimelineRow>();
        var bindingIds = file.Bindings.Select(b => b.Id).OfType<int>().ToHashSet();
        int? BindingOf(CutsceneBlock track) =>
            track.Get("binding") is { } text && CutsceneFile.TryParseTicks(text, out var id) && bindingIds.Contains(id) ? id : null;
        bool Names(string? name) => filter.Text.Length == 0 || (name?.Contains(filter.Text, StringComparison.OrdinalIgnoreCase) ?? false);
        bool HasKeysIn(CutsceneBlock track) => filter.KeysIn is not { } span || track.Children.Any(s => s is { Kind: CutsceneBlockKind.Section, Start: { } start }
            && s.Descendants().Any(k => k.Kind == CutsceneBlockKind.Key && k.Start is { } t && start + t >= span.Start && start + t <= span.End));
        var master = file.Tracks.Where(t => BindingOf(t) == null)
            .OrderBy(t => Array.IndexOf(MasterOrder, t.TrackKind) is var i and >= 0 ? i : MasterOrder.Length)
            .Where(t => Names(TrackLabel(t)) && HasKeysIn(t))
            .ToList();
        foreach (var track in master)
        {
            AddTrack(rows, file, track, 0, toggled);
        }
        foreach (var binding in file.Bindings)
        {
            var path = CutsceneFile.PathOf(binding);
            var named = filter.Text.Length > 0 && Names(binding.Name);
            var tracks = file.Tracks.Where(t => binding.Id != null && BindingOf(t) == binding.Id)
                .Where(t => (named || Names(TrackLabel(t))) && HasKeysIn(t))
                .ToList();
            if (!filter.IsNone && tracks.Count == 0 && !(named && filter.KeysIn == null))
            {
                continue;
            }
            var row = new CutsceneTimelineRow(CutsceneRowKind.Binding, path, binding.Name ?? $"binding {binding.Id}", 0)
            {
                CanFold = tracks.Count > 0,
                Folded = toggled.Contains(path),
            };
            rows.Add(row);
            if (row.Folded)
            {
                continue;
            }
            foreach (var track in tracks)
            {
                AddTrack(rows, file, track, 1, toggled);
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

    static void AddTrack(List<CutsceneTimelineRow> rows, CutsceneFile file, CutsceneBlock track, int depth, IReadOnlySet<string> toggled)
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
                    row.Bars.Add(new CutsceneTimelineItem(CutsceneItemKind.Section, s, e, CutsceneFile.PathOf(child)) { Label = SectionLabel(file, track, child) });
                    foreach (var (key, keyPath) in Keys(child, null))
                    {
                        row.Keys.Add(new CutsceneTimelineItem(CutsceneItemKind.Key, s + key.Start!.Value, s + key.Start!.Value, keyPath));
                    }
                    break;
                case { Kind: CutsceneBlockKind.Range, Start: { } s, End: { } e }:
                    row.Bars.Add(new CutsceneTimelineItem(CutsceneItemKind.Range, s, e, CutsceneFile.PathOf(child)));
                    break;
                case { Kind: CutsceneBlockKind.Trigger, Start: { } t }:
                    row.Points.Add(new CutsceneTimelineItem(CutsceneItemKind.Trigger, t, t, CutsceneFile.PathOf(child)));
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

    // What a section's bar says: a presentation section's line or kind, a camera cut's camera, or else its ID.
    static string SectionLabel(CutsceneFile file, CutsceneBlock track, CutsceneBlock section) => track.TrackKind switch
    {
        "presentation" => section.Get("text") is { } text ? TextQuote.Unquote(text) ?? text : section.Get("kind") ?? "",
        "camera_cut" => section.Get("camera") is { } camera && CutsceneFile.TryParseTicks(camera, out var id)
            ? file.Bindings.FirstOrDefault(b => b.Id == id)?.Name ?? $"binding {id}"
            : "",
        _ => $"#{section.Id}",
    };

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
                if (bar.End >= from && bar.Start <= to)
                {
                    bars.Add(new CutsceneVisibleBar(view.X(bar.Start), view.X(bar.End), bar));
                }
            }
            result.Add(new CutsceneVisibleRow(row, RulerHeight + row.Top - scrollY, bars, Glyphs(row.Points, view, from, to), Glyphs(row.Keys, view, from, to)));
        }
        return result;
    }

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
        // Keys first, as they sit on the bars, then triggers, then the bars' edges and bodies.
        if (Nearest(row.Keys, view, px) is { } keys)
        {
            return new CutsceneHit(CutsceneHitKind.Key, row, keys, tick);
        }
        if (Nearest(row.Points, view, px) is { } points)
        {
            return new CutsceneHit(CutsceneHitKind.Trigger, row, points, tick);
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
    /// The shot at a time, as the Game view's frame counter names it: the camera of the cutscene's own camera cut section
    /// over the time, from its start up to its end, or null when none is. A muted cut track names none.
    /// </summary>
    public static string? ShotAt(CutsceneFile file, int tick)
    {
        var cuts = file.Tracks
            .Where(t => t.TrackKind == "camera_cut" && t.Get("muted")?.Trim() != "true")
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
