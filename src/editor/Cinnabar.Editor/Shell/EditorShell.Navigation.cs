using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

// The Navigation Path tool's points (see docs/editor/viewport.md#navigation-path).
public sealed partial class EditorShell
{
    /// <summary>
    /// The points that the Navigation Path tool picked, as raw world positions: none, a start, or a start and a goal.
    /// With both, the game draws the navmesh path between them. SetNavPoints is the only writer.
    /// </summary>
    public IReadOnlyList<long[]> NavPoints { get; private set; } = [];

    /// <summary>
    /// Picks what is drawn at a pixel of the frame as the next point, once the pick answers: the first click is the start,
    /// the second the goal, and a third starts again. Returns false when the tool is not Navigation Path or mesh mode is on,
    /// so the click selects instead.
    /// </summary>
    public bool AddNavPoint(Vec2 pixel)
    {
        if (Tool != Tool.NavPath || Mesh.InMeshMode)
        {
            return false;
        }
        // A pick that the tool closes before it answers adds nothing.
        PickPixel(pixel, result =>
        {
            if (Tool != Tool.NavPath || Mesh.InMeshMode)
            {
                return;
            }
            // The same pixel centre as a drag's, and no snapping: a point on a navmesh is not on the grid.
            var at = DropPoint(new Vec2(Math.Floor(pixel.X) + 0.5, Math.Floor(pixel.Y) + 0.5), result, snap: false);
            SetNavPoints(NavPoints.Count == 1 ? [NavPoints[0], at] : [at]);
        });
        return true;
    }

    void ClearNavProbe() => SetNavPoints([]);

    // A new game state has no probe.
    void ResendNavProbe()
    {
        if (NavPoints.Count > 0)
        {
            SendNavProbe();
        }
    }

    void SetNavPoints(IReadOnlyList<long[]> points)
    {
        if (points.Count == 0 && NavPoints.Count == 0)
        {
            return;
        }
        NavPoints = points;
        SendNavProbe();
    }

    void SendNavProbe() => Host.Send(new NavProbe([.. NavPoints.Select(p => new NavProbePoint(p))]));
}
