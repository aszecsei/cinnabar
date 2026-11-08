using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// What mesh mode is in the middle of, as one value (see docs/editor/mesh-editing.md#mesh-mode): nothing; a distance
/// tool that waits for the gizmo drag that sets its distance, with its undo entry open; the points of a Cut or a Draw; the
/// Create tool's drag of a block; or a drag of the Face panel's mapping fields, with its entry open.
/// <see cref="MeshSession.Begin"/> is the way into one, and it ends the one before it.
/// </summary>
internal abstract record MeshInteraction
{
    public static readonly Idle None = new();

    public sealed record Idle : MeshInteraction;

    /// <summary>A tool whose distance the next gizmo drag sets: its entry, each mesh's snapshot and selection from before it ran, and how to run it.</summary>
    public sealed record PendingDistance(SceneEdit Edit, Vec3 Axis, bool Magnitude, Dictionary<string, (MeshData Start, IReadOnlyList<int> Selected)> Meshes,
        Func<MeshData, IEnumerable<int>, double, ToolResult> Run) : MeshInteraction;

    /// <summary>The clicks of a Cut or a Draw: points on one mesh, or for a Draw that starts on nothing, points on the grid.</summary>
    public abstract record ToolPoints : MeshInteraction
    {
        public abstract int Count { get; }

        /// <summary>Points on an edited mesh, which a Cut cuts through or a Draw draws a face of.</summary>
        public sealed record OnMesh(string Mesh) : ToolPoints
        {
            public List<CutPoint> Points { get; } = [];
            public override int Count => Points.Count;
        }

        /// <summary>A Draw's corners on the grid plane, which make a new mesh and entity.</summary>
        public sealed record OnGrid : ToolPoints
        {
            public List<long[]> Points { get; } = [];
            public override int Count => Points.Count;
        }
    }

    /// <summary>The Create tool's drag on the grid plane, from Start to Corner.</summary>
    public sealed record BlockDrag(long[] Origin, int Axis, long[] Start, long[] Corner) : MeshInteraction;

    /// <summary>A drag of the Face panel's mapping fields, in its own entry.</summary>
    public sealed record MappingScrub(SceneEdit Edit) : MeshInteraction;
}

public sealed partial class MeshSession
{
    /// <summary>
    /// What mesh mode is in the middle of. Only <see cref="Begin"/>, <see cref="Update"/>, <see cref="Ended"/> and the ends
    /// (<see cref="Settle"/> and <see cref="Cancel"/>) change it.
    /// </summary>
    internal MeshInteraction Interaction { get; private set; } = MeshInteraction.None;

    /// <summary>
    /// Starts an interaction: it first ends the one under way as it is, so a waiting distance tool commits and a Cut's or a
    /// Draw's points apply. Then <paramref name="start"/> makes the new one, and may open its entry; null starts nothing.
    /// A drag that the mouse holds, of a block or of the mapping fields, is not ended for another: nothing starts until it
    /// ends.
    /// </summary>
    internal T? Begin<T>(Func<T?> start) where T : MeshInteraction
    {
        if (Interaction is MeshInteraction.BlockDrag or MeshInteraction.MappingScrub)
        {
            return null;
        }
        Settle();
        if (start() is not { } next)
        {
            return null;
        }
        Interaction = next;
        OnMeshModeChanged();
        return next;
    }

    /// <summary>
    /// Ends the interaction under way as it is, as <see cref="Begin"/> does before a new one. A drag that the mouse holds
    /// is not ended so: its own release or its panel ends it.
    /// </summary>
    internal void Settle()
    {
        if (Interaction is not (MeshInteraction.BlockDrag or MeshInteraction.MappingScrub))
        {
            End(keep: true);
        }
    }

    /// <summary>
    /// Ends a distance tool that waits, as it is, so that an edit can run in place of its open entry. A Cut's or a Draw's
    /// points hold no entry, and stay; a mapping drag's entry is its panel's, which ends it, and until then an edit is
    /// refused.
    /// </summary>
    internal void EndOpenEntry()
    {
        if (Interaction is MeshInteraction.PendingDistance)
        {
            Settle();
        }
    }

    /// <summary>Escape: ends the interaction under way without what it did. False when there was none.</summary>
    internal bool Cancel() => End(keep: false);

    /// <summary>Cancels the interaction under way when it is a <typeparamref name="T"/>.</summary>
    internal void Cancel<T>() where T : MeshInteraction
    {
        if (Interaction is T)
        {
            Cancel();
        }
    }

    /// <summary>Puts an interaction that moves on, such as a block drag to its next corner, in place of the one it was.</summary>
    internal void Update(MeshInteraction from, MeshInteraction to)
    {
        if (ReferenceEquals(Interaction, from))
        {
            Interaction = to;
            OnMeshModeChanged();
        }
    }

    /// <summary>An interaction's entry ended, however it ended: the interaction is over, if it is still the one under way.</summary>
    internal void Ended(MeshInteraction which)
    {
        if (ReferenceEquals(Interaction, which))
        {
            Interaction = MeshInteraction.None;
        }
    }

    // The one end of an interaction. It is no longer under way before its end runs, so what the end does, such as an
    // entry's Ended or a Draw's edit, sees no interaction.
    bool End(bool keep)
    {
        var current = Interaction;
        if (current is MeshInteraction.Idle)
        {
            return false;
        }
        Interaction = MeshInteraction.None;
        switch (current)
        {
        case MeshInteraction.PendingDistance pending when keep:
            pending.Edit.Commit();
            break;
        case MeshInteraction.PendingDistance pending:
            pending.Edit.Cancel();
            break;
        case MeshInteraction.MappingScrub scrub when keep:
            scrub.Edit.Commit();
            break;
        case MeshInteraction.MappingScrub scrub:
            scrub.Edit.Cancel();
            break;
        case MeshInteraction.ToolPoints points when keep:
            Tools.Apply(points);
            break;
        case MeshInteraction.ToolPoints or MeshInteraction.BlockDrag:
            // Points or a block that are not kept leave nothing; a block that is kept ends through EndBlock.
            break;
        }
        OnMeshModeChanged();
        return true;
    }
}
