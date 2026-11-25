using System.Globalization;

namespace Cinnabar.Editor.Document;

/// <summary>A sub-sequence section as the shot list shows it: its path, its span on the cutscene's time and its child's GUID.</summary>
public sealed record CutsceneShot(string Path, int Start, int End, string? Guid);

/// <summary>
/// The shots of a cutscene (see docs/editor/cutscene-editor.md#shot-list): its sub-sequence sections in time order, a
/// reorder of them on their track, and a new shot that moves blocks into a new child.
/// </summary>
public static class CutsceneShots
{
    /// <summary>Every sub-sequence section with a span, on every sub-sequence track, in start order and then the file's.</summary>
    public static IReadOnlyList<CutsceneShot> Shots(CutsceneFile file) =>
    [
        .. file.Tracks.Where(t => t.TrackKind == "sub_sequence")
            .SelectMany(t => t.Children)
            .Where(s => s is { Kind: CutsceneBlockKind.Section, Start: not null, End: not null })
            .OrderBy(s => s.Start)
            .Select(s => new CutsceneShot(CutsceneFile.PathOf(s), s.Start!.Value, s.End!.Value, CutsceneSubSequences.GuidOf(s))),
    ];

    /// <summary>
    /// Why a shot cannot take the place of another, or null when it can: both are sub-sequence sections of one track
    /// that is not locked.
    /// </summary>
    public static string? ReorderRefusal(CutsceneFile file, string path, string toPath, IReadOnlySet<int>? locked)
    {
        if (file.Find(path) is not { Kind: CutsceneBlockKind.Section } moving || file.Find(toPath) is not { Kind: CutsceneBlockKind.Section } onto
            || CutsceneEdits.TrackOf(moving)?.TrackKind != "sub_sequence")
        {
            return "No shot is there.";
        }
        if (moving.Parent != onto.Parent)
        {
            return "A shot moves only among the shots of its own track.";
        }
        return CutsceneEdits.IsLocked(moving, locked) ? "The shots' track is locked." : null;
    }

    /// <summary>
    /// Moves a shot to the place of another on its track, as a drag in the shot list does. The sections from the one
    /// place to the other are laid out again in their new order from the first one's start: each keeps its length, and
    /// each place keeps the gap before it, so the span that they fill stays the same and the later sections stay where
    /// they are. Nothing changes when <see cref="ReorderRefusal"/> refuses. Returns the moved sections' paths, in their
    /// new order.
    /// </summary>
    public static IReadOnlyList<string> Reorder(CutsceneFile file, string path, string toPath, IReadOnlySet<int>? locked = null)
    {
        if (ReorderRefusal(file, path, toPath, locked) != null)
        {
            return [];
        }
        var moving = file.Find(path)!;
        var track = moving.Parent!;
        var sections = track.Children.Where(s => s is { Kind: CutsceneBlockKind.Section, Start: not null, End: not null }).OrderBy(s => s.Start).ToList();
        var from = sections.IndexOf(moving);
        var to = sections.IndexOf(file.Find(toPath)!);
        if (from == to)
        {
            return [path];
        }
        var lo = Math.Min(from, to);
        var places = sections.GetRange(lo, Math.Abs(to - from) + 1);
        var gaps = places.Select((s, i) => i == 0 ? 0 : s.Start!.Value - places[i - 1].End!.Value).ToList();
        var order = places.ToList();
        order.Remove(moving);
        order.Insert(to - lo, moving);
        var spans = new List<(CutsceneBlock Section, int Start, int End)>();
        var at = places[0].Start!.Value;
        for (var i = 0; i < order.Count; i++)
        {
            at += gaps[i];
            var length = order[i].End!.Value - order[i].Start!.Value;
            spans.Add((order[i], at, at + length));
            at += length;
        }
        foreach (var (section, start, end) in spans)
        {
            section.SetSpan(start, end);
        }
        CutsceneFile.SortChildren(track);
        return [.. order.Select(CutsceneFile.PathOf)];
    }

    /// <summary>
    /// Makes a new shot (see docs/editor/cutscene-editor.md#new-shots): moves the sections, triggers and ranges that
    /// paths name, with their keys, into a child, and puts a sub-sequence section that plays the child in their place.
    /// A key takes its section, a sound takes its subtitles, and blocks on locked tracks stay.
    /// <list type="bullet">
    /// <item>The span is from the first start to the last end. With no blocks, it is from at to the next shot's start,
    /// or for the child's length.</item>
    /// <item>The child takes the parent's rate, the span's length, a copy of each binding that the blocks name at its
    /// ID, and the blocks, pasted to start at 0 on tracks like theirs.</item>
    /// <item>The new section has the name, and a <c>bind N = N</c> for each copied binding, so the child acts on the
    /// parent's entities.</item>
    /// </list>
    /// Returns the new section's path, or null when paths name blocks and each one is on a locked track.
    /// </summary>
    public static string? NewShot(CutsceneFile parent, CutsceneFile child, IReadOnlyList<string> paths, int at, string childGuid, string name, IReadOnlySet<int>? locked = null)
    {
        var named = paths.Select(parent.Find).OfType<CutsceneBlock>()
            .Select(b => b.Kind is CutsceneBlockKind.Key or CutsceneBlockKind.Channel ? CutsceneEdits.SectionOf(b) : b)
            .OfType<CutsceneBlock>()
            .Where(b => b.Kind is CutsceneBlockKind.Section or CutsceneBlockKind.Trigger or CutsceneBlockKind.Range)
            .Distinct()
            .ToList();
        var blocks = named.Where(b => !CutsceneEdits.IsLocked(b, locked) && b.Start != null).ToList();
        if (named.Count > 0 && blocks.Count == 0)
        {
            return null;
        }
        blocks.AddRange(CutsceneEdits.Followers(parent, [.. blocks.Where(b => b.Kind == CutsceneBlockKind.Section)], locked).Except(blocks));

        var frame = CutsceneFile.TicksPerSecond / parent.Rate;
        int start, end;
        if (blocks.Count > 0)
        {
            start = blocks.Min(b => b.Start!.Value);
            end = Math.Max(blocks.Max(b => CutsceneEdits.AbsoluteEnd(b) ?? 0), start + frame);
        }
        else
        {
            start = Math.Clamp(at, 0, CutsceneEdits.LengthOf(parent));
            var next = Shots(parent).Where(s => s.Start > start).Select(s => s.Start).DefaultIfEmpty(int.MaxValue).Min();
            end = next != int.MaxValue ? next : start + (child.Length ?? CutsceneFile.TicksPerSecond * 10);
        }

        // The bindings that the blocks and their tracks name, and the bindings that those name, as a parent or a target.
        var ids = new SortedSet<int>();
        foreach (var block in blocks)
        {
            if (CutsceneEdits.TrackOf(block) is { } track)
            {
                if (CutsceneEdits.BindingOf(track) is { } binding)
                {
                    ids.Add(binding);
                }
                ids.UnionWith(CutsceneBindings.NamedBindings(track));
            }
            foreach (var under in block.Descendants())
            {
                ids.UnionWith(CutsceneBindings.NamedBindings(under));
            }
        }
        var byId = parent.Bindings.Where(b => b.Id != null).GroupBy(b => b.Id!.Value).ToDictionary(g => g.Key, g => g.First());
        var queue = new Queue<int>(ids);
        while (queue.Count > 0)
        {
            if (byId.TryGetValue(queue.Dequeue(), out var binding))
            {
                foreach (var more in CutsceneBindings.NamedBindings(binding).Where(ids.Add))
                {
                    queue.Enqueue(more);
                }
            }
        }
        ids.IntersectWith(byId.Keys);

        // The child: its rate and length, the bindings at their IDs before its tracks, then the blocks.
        child.Root.Set("rate", parent.Rate.ToString(CultureInfo.InvariantCulture));
        var index = child.Root.Children.ToList().FindIndex(c => c.Kind is CutsceneBlockKind.Binding or CutsceneBlockKind.Track);
        foreach (var id in ids)
        {
            child.Insert(child.Root, index < 0 ? child.Root.Children.Count : index++, byId[id].Copy());
        }
        var blockPaths = blocks.Select(CutsceneFile.PathOf).ToList();
        if (CutsceneEdits.Copy(parent, blockPaths) is { } clip)
        {
            CutsceneEdits.Paste(child, clip, 0, null, addTracks: true);
        }
        CutsceneEdits.SetLength(child, end - start);

        // The parent: the blocks go, and the new section plays the child over their span.
        CutsceneEdits.Delete(parent, blockPaths, ripple: false, locked);
        if (CutsceneEdits.AddClipSection(parent, "sub_sequence", null, start, end - start, childGuid, locked) is not { } path)
        {
            return null;
        }
        var section = parent.Find(path)!;
        section.SetName(name);
        foreach (var id in ids)
        {
            section.Set($"bind {Format(id)}", Format(id));
        }
        return path;
    }

    static string Format(int value) => value.ToString(CultureInfo.InvariantCulture);
}
