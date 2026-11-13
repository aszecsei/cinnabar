using System.Globalization;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Tools;

/// <summary>A handle of a curve's graph, which a drag moves: what it changes, and for a table, which point.</summary>
public enum CurveHandleKind
{
    /// <summary>Where the curve's shape starts, at x_shift and y_shift.</summary>
    Origin,

    /// <summary>The curve's value at the right edge, which its slope sets.</summary>
    End,

    /// <summary>A point on the curve that its exponent bends.</summary>
    Bend,

    /// <summary>A point of a table.</summary>
    Point,
}

/// <summary>A handle of a curve's graph, at a place in the graph's units: x is the input from 0 to 1, y the score.</summary>
public readonly record struct CurveHandle(CurveHandleKind Kind, Vec2 At, int Index = 0);

/// <summary>
/// A utility consideration's response curve (see docs/content/kinds/decisions.md#utility), as its node's fields write
/// it, with their defaults: the editor draws it and moves its handles with the runtime's arithmetic
/// (lib/engine/ai/utility/utility.odin), so the graph shows what an agent scores.
/// </summary>
public sealed record ResponseCurve(string Kind, double Slope, double Exponent, double XShift, double YShift, IReadOnlyList<(double X, double Y)> Points)
{
    /// <summary>The curves, as the <c>curve</c> field names them.</summary>
    public static readonly IReadOnlyList<string> Kinds = ["linear", "polynomial", "logistic", "logit", "step", "table"];

    /// <summary>Most points that a table has, and the fewest.</summary>
    public const int MaxPoints = 32;

    public const int MinPoints = 2;

    // Keeps a logit's input inside (0, 1), where its logarithm is finite, as the runtime does.
    const double LogitEdge = 1e-6;

    // Where the origin handle is, from x_shift: the shape's start, or a logistic's or a logit's middle, which its shifts
    // move.
    double OriginAt => Kind is "logistic" or "logit" ? 0.5 : 0;

    // Where on the curve the bend handle is, by the curve: a logistic and a logit are 0.5 at 0.5 whatever their
    // exponent, so theirs is further along.
    static double BendAt(string kind) => kind == "polynomial" ? 0.5 : 0.75;

    /// <summary>The curve of a consideration's node. A field that does not read as a number has its default.</summary>
    public static ResponseCurve Of(DecisionNode node) => new(
        node.Get("curve") ?? "linear",
        Number(node.Get("slope")) ?? 1,
        Number(node.Get("exponent")) ?? 1,
        Number(node.Get("x_shift")) ?? 0,
        Number(node.Get("y_shift")) ?? 0,
        ParsePoints(node.Get("points") ?? "") ?? []);

    /// <summary>Whether the curve takes an exponent: linear and step do not.</summary>
    public bool HasExponent => Kind is "polynomial" or "logistic" or "logit" or "table";

    /// <summary>The curve's value at an input from 0 to 1: slope times its shape at the input less x_shift, plus y_shift, clamped to 0 to 1.</summary>
    public double Evaluate(double x)
    {
        var y = Raw(x);
        return double.IsNaN(y) ? 0 : Math.Clamp(y, 0, 1);
    }

    // The value before the clamp.
    double Raw(double x) => Slope * Shape(x - XShift) + YShift;

    double Shape(double u) => Kind switch
    {
        "linear" => u,
        "polynomial" => Math.Pow(u, Exponent),
        "logistic" => 1 / (1 + Math.Exp(-10 * Exponent * (u - 0.5))),
        "logit" => Logit(u),
        "step" => u >= 0.5 ? 1 : 0,
        "table" => Math.Pow(Table(Points, u), Exponent),
        _ => double.NaN,
    };

    double Logit(double u)
    {
        var z = Math.Clamp(u, LogitEdge, 1 - LogitEdge);
        return 0.5 + Math.Log(z / (1 - z)) / (10 * Exponent);
    }

    /// <summary>The line through a table's points at x, and the first or the last point's y beyond them. Where two points have one x, the later point's y.</summary>
    public static double Table(IReadOnlyList<(double X, double Y)> points, double x)
    {
        if (points.Count == 0)
        {
            return 0;
        }
        if (x < points[0].X)
        {
            return points[0].Y;
        }
        for (var i = 1; i < points.Count; i++)
        {
            var (a, b) = (points[i - 1], points[i]);
            if (x < b.X)
            {
                return a.Y + (x - a.X) / (b.X - a.X) * (b.Y - a.Y);
            }
        }
        return points[^1].Y;
    }

    /// <summary>A value over a range, from min at 0 to max at 1, clamped. A range may go down.</summary>
    public static double Normalize(double min, double max, double value)
    {
        var x = (value - min) / (max - min);
        return double.IsNaN(x) ? 0 : Math.Clamp(x, 0, 1);
    }

    /// <summary>A consideration's score made up for its option's count of considerations, as an option's score multiplies them.</summary>
    public static double Compensate(double score, int count) => count <= 1 ? score : score + (1 - score) * (1 - 1.0 / count) * score;

    /// <summary>A consideration's range, <c>[min, max]</c>, by default [0, 1].</summary>
    public static (double Min, double Max) RangeOf(DecisionNode node) =>
        GraphNumbers.TryParse(node.Get("range") ?? "") is { Values: [var min, var max] } ? (min, max) : (0, 1);

    // Handles.

    /// <summary>The handles that a drag moves: a table's points, or else the origin, the end and, with an exponent, the bend.</summary>
    public IReadOnlyList<CurveHandle> Handles()
    {
        if (Kind == "table")
        {
            return [.. Points.Select((p, i) => new CurveHandle(CurveHandleKind.Point, new Vec2(p.X + XShift, Raw(p.X + XShift)), i))];
        }
        var origin = XShift + OriginAt;
        var handles = new List<CurveHandle>
        {
            new(CurveHandleKind.Origin, new Vec2(origin, Raw(origin))),
            new(CurveHandleKind.End, new Vec2(1, Raw(1))),
        };
        if (HasExponent)
        {
            var at = XShift + BendAt(Kind);
            handles.Add(new CurveHandle(CurveHandleKind.Bend, new Vec2(at, Raw(at))));
        }
        return handles;
    }

    /// <summary>
    /// The fields that a drag of a handle to a place writes, as the file writes them, with null for a field back at its
    /// default. The origin moves the shifts, so the curve moves with it, and a logistic's or a logit's is its middle; the
    /// end sets the slope that reaches it; the bend sets the exponent whose curve passes it; and a table's point moves
    /// between its neighbours. A drag that no curve reaches changes nothing.
    /// </summary>
    public IReadOnlyDictionary<string, string?> Drag(CurveHandle handle, Vec2 to)
    {
        var x = Math.Clamp(to.X, 0, 1);
        var y = Math.Clamp(to.Y, 0, 1);
        var fields = new Dictionary<string, string?>();
        switch (handle.Kind)
        {
            case CurveHandleKind.Origin:
                // The shape is 0 at its origin, or 0.5 at a logistic's or a logit's middle.
                fields["x_shift"] = Field(x - OriginAt, 0);
                fields["y_shift"] = Field(y - Slope * Shape(OriginAt), 0);
                break;
            case CurveHandleKind.End:
                var shape = Shape(1 - XShift);
                if (Math.Abs(shape) < 1e-6 || double.IsNaN(shape))
                {
                    return fields;
                }
                fields["slope"] = Field((y - YShift) / shape, 1);
                break;
            case CurveHandleKind.Bend:
                if (BendExponent(y) is not { } exponent)
                {
                    return fields;
                }
                fields["exponent"] = Field(exponent, 1);
                break;
            case CurveHandleKind.Point:
                if (handle.Index < 0 || handle.Index >= Points.Count || Math.Abs(Slope) < 1e-6)
                {
                    return fields;
                }
                var points = Points.ToList();
                var lo = handle.Index > 0 ? points[handle.Index - 1].X : 0;
                var hi = handle.Index < points.Count - 1 ? points[handle.Index + 1].X : 1;
                // The point's own y, before the exponent, the slope and the shift.
                var raw = Math.Clamp((y - YShift) / Slope, 0, 1);
                points[handle.Index] = (Math.Clamp(x - XShift, lo, hi), Math.Pow(raw, 1 / Exponent));
                fields["points"] = WritePoints(points);
                break;
        }
        return fields;
    }

    // The exponent whose shape at the bend handle's place gives a score, or null where no exponent above 0 does.
    double? BendExponent(double y)
    {
        if (Math.Abs(Slope) < 1e-6)
        {
            return null;
        }
        var t = (y - YShift) / Slope;
        double k;
        switch (Kind)
        {
            case "polynomial":
                // 0.5^k = t
                if (t is <= 0 or >= 1)
                {
                    return null;
                }
                k = Math.Log(t) / Math.Log(0.5);
                break;
            case "logistic":
                // 1 / (1 + e^(-2.5k)) = t
                if (t is <= 0.5 or >= 1)
                {
                    return null;
                }
                k = -Math.Log(1 / t - 1) / 2.5;
                break;
            case "logit":
                // 0.5 + ln 3 / 10k = t
                if (t <= 0.5)
                {
                    return null;
                }
                k = Math.Log(3) / (10 * (t - 0.5));
                break;
            default:
                return null;
        }
        return k > 0 && double.IsFinite(k) ? k : null;
    }

    /// <summary>The points with one more, on the table's line at an input, keeping their order; null when the table is full.</summary>
    public string? AddPoint(double x)
    {
        if (Points.Count >= MaxPoints)
        {
            return null;
        }
        var u = Math.Clamp(x - XShift, 0, 1);
        var points = Points.ToList();
        var at = points.FindIndex(p => p.X > u);
        points.Insert(at < 0 ? points.Count : at, (u, Table(Points, u)));
        return WritePoints(points);
    }

    /// <summary>The points without one; null when the table would have too few.</summary>
    public string? RemovePoint(int index) =>
        Points.Count <= MinPoints || index < 0 || index >= Points.Count ? null : WritePoints([.. Points.Where((_, i) => i != index)]);

    // Text.

    /// <summary>A number as a curve's field writes it: up to three decimals.</summary>
    public static string Write(double value) => Math.Round(value, 3).ToString("0.###", CultureInfo.InvariantCulture);

    // A field's value, or null when it is back at its default.
    static string? Field(double value, double fallback) => Math.Round(value, 3) == fallback ? null : Write(value);

    static double? Number(string? text) =>
        text != null && double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;

    /// <summary>A table's points, <c>[x, y], [x, y], ...</c>, or null for text that is not.</summary>
    public static IReadOnlyList<(double X, double Y)>? ParsePoints(string text)
    {
        var points = new List<(double, double)>();
        var rest = text.Trim();
        while (rest.Length > 0)
        {
            var end = rest.IndexOf(']');
            if (!rest.StartsWith('[') || end < 0)
            {
                return null;
            }
            if (GraphNumbers.TryParse(rest[..(end + 1)]) is not { Values: [var x, var y] })
            {
                return null;
            }
            points.Add((x, y));
            rest = rest[(end + 1)..].TrimStart();
            if (rest.StartsWith(','))
            {
                rest = rest[1..].TrimStart();
                if (rest.Length == 0)
                {
                    return null;
                }
            }
            else if (rest.Length > 0)
            {
                return null;
            }
        }
        return points;
    }

    /// <summary>A table's points as the file writes them.</summary>
    public static string WritePoints(IEnumerable<(double X, double Y)> points) =>
        string.Join(", ", points.Select(p => $"[{Write(p.X)}, {Write(p.Y)}]"));
}
