using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Tools;

/// <summary>
/// What a graph canvas asks of its graph's geometry, whatever the graph draws: the rectangle that holds everything, which
/// framing fits in view, and the things that a box selects.
/// </summary>
public interface IGraphLayout
{
    /// <summary>The rectangle around everything that the graph draws, or null when it draws nothing.</summary>
    GraphRect? Extent();

    /// <summary>The IDs of what a box between two corners, in canvas units, selects.</summary>
    IEnumerable<int> InBox(Vec2 a, Vec2 b);
}
