using System.Text.Json.Serialization;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Which of the four scene views are in the Scene document (see docs/editor/viewport.md#views): the one piece of state
/// that the layout of the Scene is. The values are the views' numbers as bits.
/// </summary>
[Flags]
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum SceneViewSet
{
    None = 0,
    Perspective = 1 << 0,
    Top = 1 << 1,
    Front = 1 << 2,
    Side = 1 << 3,
    All = Perspective | Top | Front | Side,
}

/// <summary>A preset is a name for a set of scene views, which choosing it sets and nothing more.</summary>
public sealed record ScenePreset(string Name, SceneViewSet Views)
{
    public static readonly ScenePreset Single = new("Single", SceneViewSet.Perspective);
    public static readonly ScenePreset TwoSideBySide = new("Two Side by Side", SceneViewSet.Perspective | SceneViewSet.Top);
    public static readonly ScenePreset Quad = new("Quad", SceneViewSet.All);

    /// <summary>What the layout is called when it is none of the presets.</summary>
    public const string Custom = "Custom";

    public static IReadOnlyList<ScenePreset> All { get; } = [Single, TwoSideBySide, Quad];

    /// <summary>The preset whose name is this, in any case and with or without spaces, or null.</summary>
    public static ScenePreset? Find(string name) =>
        All.FirstOrDefault(p => string.Equals(p.Name.Replace(" ", ""), name.Replace(" ", ""), StringComparison.OrdinalIgnoreCase));

    /// <summary>The name of the preset that sets exactly these views, or <see cref="Custom"/>.</summary>
    public static string NameOf(SceneViewSet views) => All.FirstOrDefault(p => p.Views == views)?.Name ?? Custom;
}

/// <summary>A scene view's place in the Scene's grid, in the grid's tracks.</summary>
public sealed record SceneCell(int View, int Row, int Column, int RowSpan, int ColumnSpan);

/// <summary>A splitter between views, in the grid's tracks.</summary>
public sealed record SceneSplitter(bool Vertical, int Row, int Column, int RowSpan, int ColumnSpan);

/// <summary>
/// Where the Scene document puts the scene views that are in it (see docs/editor/viewport.md#views). The grid has a track
/// for a row or a column of views and a thin one for the splitter between two, so it is one or three tracks each way.
/// </summary>
public sealed record SceneGrid(int Rows, int Columns, IReadOnlyList<SceneCell> Cells, IReadOnlyList<SceneSplitter> Splitters)
{
    /// <summary>
    /// The quad's places are Perspective at the top left, Top at the top right, Front at the bottom left and Side at the
    /// bottom right, and the views that are in keep them, with what is empty collapsed:
    /// <list type="bullet">
    /// <item>One view fills the document.</item>
    /// <item>Two views in the same column of the quad (Perspective and Front, or Top and Side) are stacked, the one of the top row above. Any other two sit side by side, the one of the left column on the left.</item>
    /// <item>Three views make a split row of two and a row of one, which spans the width.</item>
    /// <item>Four views are the quad.</item>
    /// </list>
    /// </summary>
    public static SceneGrid Arrange(SceneViewSet views)
    {
        bool Has(SceneViewSet view) => views.HasFlag(view);
        var count = Enumerable.Range(0, 4).Count(i => views.HasFlag((SceneViewSet)(1 << i)));
        var (p, t, f, s) = (Has(SceneViewSet.Perspective), Has(SceneViewSet.Top), Has(SceneViewSet.Front), Has(SceneViewSet.Side));
        if (count <= 1)
        {
            var only = Enumerable.Range(0, 4).FirstOrDefault(i => views.HasFlag((SceneViewSet)(1 << i)));
            return new SceneGrid(1, 1, [new SceneCell(only, 0, 0, 1, 1)], []);
        }
        if (count == 2)
        {
            var (first, second) = Enumerable.Range(0, 4).Where(i => views.HasFlag((SceneViewSet)(1 << i))).ToArray() is [var a, var b] ? (a, b) : (0, 0);
            if ((p && f) || (t && s))
            {
                return new SceneGrid(3, 1, [new SceneCell(first, 0, 0, 1, 1), new SceneCell(second, 2, 0, 1, 1)], [new SceneSplitter(false, 1, 0, 1, 1)]);
            }
            // Side by side, the left column's view first: Front and Top are the diagonal pair that the numbers put the other way.
            var (left, right) = first % 2 == 0 ? (first, second) : (second, first);
            return new SceneGrid(1, 3, [new SceneCell(left, 0, 0, 1, 1), new SceneCell(right, 0, 2, 1, 1)], [new SceneSplitter(true, 0, 1, 1, 1)]);
        }
        List<SceneCell> cells = [];
        void Row(int row, int leftView, bool hasLeft, int rightView, bool hasRight)
        {
            if (hasLeft && hasRight)
            {
                cells.Add(new SceneCell(leftView, row, 0, 1, 1));
                cells.Add(new SceneCell(rightView, row, 2, 1, 1));
            }
            else
            {
                cells.Add(new SceneCell(hasLeft ? leftView : rightView, row, 0, 1, 3));
            }
        }
        Row(0, 0, p, 1, t);
        Row(2, 2, f, 3, s);
        List<SceneSplitter> splitters = [new SceneSplitter(false, 1, 0, 1, 3)];
        var (topSplit, bottomSplit) = (p && t, f && s);
        if (topSplit || bottomSplit)
        {
            // One splitter moves the column in both rows when both are split.
            splitters.Add(topSplit && bottomSplit ? new SceneSplitter(true, 0, 1, 3, 1) : new SceneSplitter(true, topSplit ? 0 : 2, 1, 1, 1));
        }
        return new SceneGrid(3, 3, [.. cells.OrderBy(c => c.View)], splitters);
    }
}
