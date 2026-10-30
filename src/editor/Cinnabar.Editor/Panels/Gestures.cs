using Avalonia;

namespace Cinnabar.Editor.Panels;

/// <summary>When a press that moves has become a drag.</summary>
static class Gestures
{
    /// <summary>A press that moves less than this, in control units, is a click.</summary>
    public const double ClickSlop = 4;

    /// <summary>Whether a press has moved farther than the slop in a straight line.</summary>
    public static bool MovedPast(Vector moved) => Math.Sqrt(moved.X * moved.X + moved.Y * moved.Y) > ClickSlop;

    /// <summary>Whether a press has moved the slop or more, counting across and down: for lists, where a drag starts.</summary>
    public static bool MovedPastAcrossAndDown(Vector moved) => !(Math.Abs(moved.X) + Math.Abs(moved.Y) < ClickSlop);
}
