using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>Where the Scene document puts the scene views that are in it (see docs/editor/viewport.md#views).</summary>
public sealed class SceneGridTests
{
    const SceneViewSet P = SceneViewSet.Perspective;
    const SceneViewSet T = SceneViewSet.Top;
    const SceneViewSet F = SceneViewSet.Front;
    const SceneViewSet S = SceneViewSet.Side;

    // (view, row, column, row span, column span) of each cell, and (vertical, row, column, row span, column span) of each splitter.
    static (int, int, int, int, int)[] Cells(SceneGrid grid) => [.. grid.Cells.Select(c => (c.View, c.Row, c.Column, c.RowSpan, c.ColumnSpan))];

    static (bool, int, int, int, int)[] Splitters(SceneGrid grid) => [.. grid.Splitters.Select(s => (s.Vertical, s.Row, s.Column, s.RowSpan, s.ColumnSpan))];

    [Theory]
    [InlineData(SceneViewSet.Perspective, 0)]
    [InlineData(SceneViewSet.Top, 1)]
    [InlineData(SceneViewSet.Front, 2)]
    [InlineData(SceneViewSet.Side, 3)]
    public void OneViewFillsTheDocument(SceneViewSet views, int view)
    {
        var grid = SceneGrid.Arrange(views);

        Assert.Equal((1, 1), (grid.Rows, grid.Columns));
        Assert.Equal([(view, 0, 0, 1, 1)], Cells(grid));
        Assert.Empty(grid.Splitters);
    }

    [Theory]
    [InlineData(SceneViewSet.Perspective | SceneViewSet.Top, 0, 1)]
    [InlineData(SceneViewSet.Front | SceneViewSet.Side, 2, 3)]
    [InlineData(SceneViewSet.Perspective | SceneViewSet.Side, 0, 3)]
    public void TwoViewsOutsideOneColumnSitSideBySideTheLeftColumnsFirst(SceneViewSet views, int left, int right)
    {
        var grid = SceneGrid.Arrange(views);

        Assert.Equal((1, 3), (grid.Rows, grid.Columns));
        Assert.Equal([(left, 0, 0, 1, 1), (right, 0, 2, 1, 1)], Cells(grid));
        Assert.Equal([(true, 0, 1, 1, 1)], Splitters(grid));
    }

    [Fact]
    public void TopAndFrontAreADiagonalPairThatSitsSideBySideWithFrontOnTheLeft()
    {
        var grid = SceneGrid.Arrange(T | F);

        Assert.Equal([(2, 0, 0, 1, 1), (1, 0, 2, 1, 1)], Cells(grid));
    }

    [Theory]
    [InlineData(SceneViewSet.Perspective | SceneViewSet.Front, 0, 2)]
    [InlineData(SceneViewSet.Top | SceneViewSet.Side, 1, 3)]
    public void TwoViewsInOneColumnAreStackedTheTopRowsFirst(SceneViewSet views, int above, int below)
    {
        var grid = SceneGrid.Arrange(views);

        Assert.Equal((3, 1), (grid.Rows, grid.Columns));
        Assert.Equal([(above, 0, 0, 1, 1), (below, 2, 0, 1, 1)], Cells(grid));
        Assert.Equal([(false, 1, 0, 1, 1)], Splitters(grid));
    }

    [Fact]
    public void ThreeViewsMakeASplitRowAndARowThatSpansTheWidth()
    {
        // Perspective and Top on the top row, Front across the bottom.
        var topSplit = SceneGrid.Arrange(P | T | F);
        Assert.Equal((3, 3), (topSplit.Rows, topSplit.Columns));
        Assert.Equal([(0, 0, 0, 1, 1), (1, 0, 2, 1, 1), (2, 2, 0, 1, 3)], Cells(topSplit));
        Assert.Equal([(false, 1, 0, 1, 3), (true, 0, 1, 1, 1)], Splitters(topSplit));

        // Perspective across the top, Front and Side below.
        var bottomSplit = SceneGrid.Arrange(P | F | S);
        Assert.Equal([(0, 0, 0, 1, 3), (2, 2, 0, 1, 1), (3, 2, 2, 1, 1)], Cells(bottomSplit));
        Assert.Equal([(false, 1, 0, 1, 3), (true, 2, 1, 1, 1)], Splitters(bottomSplit));

        // Top across the top, Front and Side below, and Perspective and Top above Side.
        Assert.Equal([(1, 0, 0, 1, 3), (2, 2, 0, 1, 1), (3, 2, 2, 1, 1)], Cells(SceneGrid.Arrange(T | F | S)));
        Assert.Equal([(0, 0, 0, 1, 1), (1, 0, 2, 1, 1), (3, 2, 0, 1, 3)], Cells(SceneGrid.Arrange(P | T | S)));
    }

    [Fact]
    public void FourViewsAreTheQuadWithOneSplitterAcrossBothRows()
    {
        var grid = SceneGrid.Arrange(SceneViewSet.All);

        Assert.Equal([(0, 0, 0, 1, 1), (1, 0, 2, 1, 1), (2, 2, 0, 1, 1), (3, 2, 2, 1, 1)], Cells(grid));
        Assert.Equal([(false, 1, 0, 1, 3), (true, 0, 1, 3, 1)], Splitters(grid));
    }

    [Fact]
    public void EverySubsetPlacesEachViewOnceInsideTheGridWithoutOverlap()
    {
        for (var bits = 1; bits <= 15; bits++)
        {
            var views = (SceneViewSet)bits;
            var grid = SceneGrid.Arrange(views);
            Assert.Equal(Enumerable.Range(0, 4).Where(i => (bits & (1 << i)) != 0), grid.Cells.Select(c => c.View).Order());
            Assert.True(grid.Rows is 1 or 3 && grid.Columns is 1 or 3, $"{views}: {grid.Rows} by {grid.Columns}");
            var taken = new HashSet<(int, int)>();
            foreach (var cell in grid.Cells)
            {
                Assert.True(cell.Row >= 0 && cell.Row + cell.RowSpan <= grid.Rows && cell.Column >= 0 && cell.Column + cell.ColumnSpan <= grid.Columns, $"{views}: {cell}");
                foreach (var row in Enumerable.Range(cell.Row, cell.RowSpan))
                {
                    foreach (var column in Enumerable.Range(cell.Column, cell.ColumnSpan))
                    {
                        Assert.True(taken.Add((row, column)), $"{views}: two views in track {row}, {column}");
                    }
                }
            }
            foreach (var splitter in grid.Splitters)
            {
                Assert.True(splitter.Row + splitter.RowSpan <= grid.Rows && splitter.Column + splitter.ColumnSpan <= grid.Columns, $"{views}: {splitter}");
                // A splitter lies on the thin track between views, and covers no view.
                Assert.True(splitter.Vertical ? splitter.Column == 1 : splitter.Row == 1, $"{views}: {splitter}");
                foreach (var row in Enumerable.Range(splitter.Row, splitter.RowSpan))
                {
                    foreach (var column in Enumerable.Range(splitter.Column, splitter.ColumnSpan))
                    {
                        Assert.DoesNotContain((row, column), taken);
                    }
                }
            }
        }
    }

    [Fact]
    public void AViewThatStaysKeepsItsViewWhateverTheCellsAre()
    {
        // Perspective is in every set that has it, and the arrangement names it by its number alone.
        foreach (var views in new[] { P, P | T, P | F, P | S, P | T | F, P | F | S, SceneViewSet.All })
        {
            Assert.Single(SceneGrid.Arrange(views).Cells, c => c.View == 0);
        }
    }
}
