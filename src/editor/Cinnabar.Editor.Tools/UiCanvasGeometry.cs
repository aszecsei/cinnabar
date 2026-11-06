namespace Cinnabar.Editor.Tools;

/// <summary>A rectangle of a UI screen in its pixels, from its top left corner to its bottom right.</summary>
public readonly record struct UiRect(double X0, double Y0, double X1, double Y1)
{
    public double Width => X1 - X0;
    public double Height => Y1 - Y0;
    public bool Empty => X1 <= X0 || Y1 <= Y0;

    public bool Contains(double x, double y) => x >= X0 && x < X1 && y >= Y0 && y < Y1;

    public UiRect Intersect(UiRect other) => new(Math.Max(X0, other.X0), Math.Max(Y0, other.Y0), Math.Min(X1, other.X1), Math.Min(Y1, other.Y1));
}

/// <summary>Where the game drew a node of a UI preview: its rectangle, the rectangle inside its padding, and its clip.</summary>
public readonly record struct UiBox(int Node, bool Shown, UiRect Rect, UiRect Content, UiRect Clip);

/// <summary>The UI editor's canvas's geometry (see docs/editor/ui-editor.md#the-canvas), apart from a window so tests reach it.</summary>
public static class UiCanvasGeometry
{
    /// <summary>
    /// The topmost node at a point: the last in the order that the game draws them, each before its children, that
    /// shows and whose rectangle, cut to its clip, holds the point. The root, the whole screen, is not picked.
    /// </summary>
    public static int? Pick(IReadOnlyList<UiBox> boxes, double x, double y)
    {
        for (var i = boxes.Count - 1; i >= 0; i--)
        {
            var b = boxes[i];
            if (b.Shown && b.Node != 0 && b.Rect.Intersect(b.Clip).Contains(x, y))
            {
                return b.Node;
            }
        }
        return null;
    }
}
