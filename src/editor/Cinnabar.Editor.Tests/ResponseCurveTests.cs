using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>A consideration's curve, with the runtime's arithmetic, and the handles that a drag of its graph moves.</summary>
public sealed class ResponseCurveTests
{
    static ResponseCurve Curve(string kind, double slope = 1, double exponent = 1, double xShift = 0, double yShift = 0, params (double, double)[] points) =>
        new(kind, slope, exponent, xShift, yShift, points);

    static readonly (double, double)[] Table = [(0, 0), (0.5, 1), (1, 0.5)];

    // The cases of the runtime's curves_have_their_shapes (lib/engine/ai/utility/utility_test.odin).
    public static TheoryData<string, double, double, double, double, double, double> RuntimeCases => new()
    {
        { "linear", 1, 1, 0, 0, 0.3, 0.3 },
        { "linear", -1, 1, 0, 1, 0.3, 0.7 },
        { "linear", 1, 1, 0.2, 0, 0.3, 0.1 },
        { "linear", 2, 1, 0, 0, 0.8, 1 },
        { "linear", 1, 1, 0.5, 0, 0.3, 0 },
        { "polynomial", 1, 2, 0, 0, 0.5, 0.25 },
        { "polynomial", 1, 3, 0, 0, 0.5, 0.125 },
        { "polynomial", -1, 2, 0, 1, 0.5, 0.75 },
        { "polynomial", 1, 0.5, 0.2, 0, 0.1, 0 },
        { "logistic", 1, 1, 0, 0, 0.5, 0.5 },
        { "logistic", 1, 1, 0, 0, 0.6, 1 / (1 + Math.Exp(-1.0)) },
        { "logistic", 1, 1, 0.1, 0, 0.6, 0.5 },
        { "logistic", 1, 2, 0, 0, 0.6, 1 / (1 + Math.Exp(-2.0)) },
        { "logit", 1, 1, 0, 0, 0.5, 0.5 },
        { "logit", 1, 1, 0, 0, 1 / (1 + Math.Exp(-1.0)), 0.6 },
        { "logit", 1, 2, 0, 0, 1 / (1 + Math.Exp(-1.0)), 0.55 },
        { "logit", 1, 1, 0, 0, 0, 0 },
        { "logit", 1, 1, 0, 0, 1, 1 },
        { "step", 1, 1, 0, 0, 0.49, 0 },
        { "step", 1, 1, 0, 0, 0.5, 1 },
        { "step", 1, 1, 0.2, 0, 0.71, 1 },
        { "step", -1, 1, 0, 1, 0.7, 0 },
    };

    [Theory]
    [MemberData(nameof(RuntimeCases))]
    public void ACurveHasTheRuntimesShape(string kind, double slope, double exponent, double xShift, double yShift, double x, double y) =>
        Assert.Equal(y, Curve(kind, slope, exponent, xShift, yShift).Evaluate(x), 6);

    [Fact]
    public void ATableIsALineThroughItsPoints()
    {
        Assert.Equal(0.5, Curve("table", points: Table).Evaluate(0.25), 6);
        Assert.Equal(0.75, Curve("table", points: Table).Evaluate(0.75), 6);
        Assert.Equal(0.5, Curve("table", points: Table).Evaluate(2), 6);
        Assert.Equal(0.25, Curve("table", exponent: 2, points: Table).Evaluate(0.25), 6);
        Assert.Equal(0.6, Curve("table", slope: 0.5, yShift: 0.1, points: Table).Evaluate(0.5), 6);
        // Two points at one x are a step to the later.
        Assert.Equal(1, ResponseCurve.Table([(0, 0), (0.5, 0), (0.5, 1), (1, 1)], 0.5));
        Assert.Equal(0.5, ResponseCurve.Normalize(0, 100, 50));
        Assert.Equal(0.75, ResponseCurve.Normalize(100, 0, 25));
        Assert.Equal(0.625, ResponseCurve.Compensate(0.5, 2));
    }

    [Theory]
    [InlineData("linear")]
    [InlineData("polynomial")]
    [InlineData("logistic")]
    [InlineData("logit")]
    [InlineData("step")]
    [InlineData("table")]
    public void AHandleDraggedToWhereItIsChangesNoField(string kind)
    {
        // The table's last point is at the graph's right edge after the shift, where a handle can be.
        var curve = Curve(kind, slope: 0.8, exponent: 2, xShift: 0.1, yShift: 0.1, points: [(0, 0), (0.5, 1), (0.9, 0.5)]);
        foreach (var handle in curve.Handles())
        {
            var fields = curve.Drag(handle, handle.At);
            var moved = curve with
            {
                Slope = Read(fields, "slope", curve.Slope, 1),
                Exponent = Read(fields, "exponent", curve.Exponent, 1),
                XShift = Read(fields, "x_shift", curve.XShift, 0),
                YShift = Read(fields, "y_shift", curve.YShift, 0),
                Points = fields.TryGetValue("points", out var p) ? ResponseCurve.ParsePoints(p!)! : curve.Points,
            };
            for (var x = 0.0; x <= 1; x += 0.125)
            {
                Assert.Equal(curve.Evaluate(x), moved.Evaluate(x), 2);
            }
        }
    }

    static double Read(IReadOnlyDictionary<string, string?> fields, string key, double value, double fallback) =>
        fields.TryGetValue(key, out var text) ? (text == null ? fallback : double.Parse(text, System.Globalization.CultureInfo.InvariantCulture)) : value;

    [Fact]
    public void AHandlesDragSetsItsFields()
    {
        var polynomial = Curve("polynomial");
        var handles = polynomial.Handles();
        Assert.Equal([CurveHandleKind.Origin, CurveHandleKind.End, CurveHandleKind.Bend], handles.Select(h => h.Kind));
        // The bend's place gives the exponent whose curve passes it, and a field back at its default is removed.
        Assert.Equal("3", polynomial.Drag(handles[2], new Vec2(0.5, 0.125))["exponent"]);
        Assert.Null(polynomial.Drag(handles[2], new Vec2(0.5, 0.5))["exponent"]);
        // A bend that no exponent above 0 reaches changes nothing.
        Assert.Empty(polynomial.Drag(handles[2], new Vec2(0.5, 1)));
        // The origin moves the shifts, a logistic's from its middle.
        Assert.Equal(("0.3", "0.2"), (polynomial.Drag(handles[0], new Vec2(0.3, 0.2))["x_shift"], polynomial.Drag(handles[0], new Vec2(0.3, 0.2))["y_shift"]));
        var logistic = Curve("logistic");
        Assert.Equal(new Vec2(0.5, 0.5), logistic.Handles()[0].At);
        var moved = logistic.Drag(logistic.Handles()[0], new Vec2(0.6, 0.5));
        Assert.Equal("0.1", moved["x_shift"]);
        Assert.Null(moved["y_shift"]);
        // The end sets the slope that reaches it; linear and step have no bend.
        Assert.Equal("0.5", Curve("linear").Drag(Curve("linear").Handles()[1], new Vec2(1, 0.5))["slope"]);
        Assert.Equal(2, Curve("step").Handles().Count);
        // A table's point stays between its neighbours.
        var table = Curve("table", points: Table);
        var middle = table.Handles()[1];
        Assert.Equal("[0, 0], [1, 0.25], [1, 0.5]", table.Drag(middle, new Vec2(1.5, 0.25))["points"]);
    }

    [Fact]
    public void PointsReadAndWriteAsTheFileWritesThem()
    {
        Assert.Equal([(0.0, 1.0), (0.3, 0.9), (1.0, 0.0)], ResponseCurve.ParsePoints("[0, 1], [0.3, 0.9], [1, 0]"));
        Assert.Equal("[0, 1], [0.3, 0.9], [1, 0]", ResponseCurve.WritePoints([(0, 1), (0.3, 0.9), (1, 0)]));
        Assert.Empty(ResponseCurve.ParsePoints("")!);
        Assert.Null(ResponseCurve.ParsePoints("[0, 1] [1, 0]"));
        Assert.Null(ResponseCurve.ParsePoints("[0, 1],"));
        Assert.Null(ResponseCurve.ParsePoints("[0, 1, 2]"));
        Assert.Equal("0.333", ResponseCurve.Write(1 / 3.0));
    }
}
