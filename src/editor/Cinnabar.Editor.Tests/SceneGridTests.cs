using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>Where the Scene document puts the scene views that are in it (see docs/editor/viewport.md#views).</summary>
public sealed class SceneGridTests
{
    // (view, row, column, row span, column span) of each cell, and (vertical, row, column, row span, column span) of each splitter.
    static (int, int, int, int, int)[] Cells(SceneGrid grid) => [.. grid.Cells.Select(c => (c.View, c.Row, c.Column, c.RowSpan, c.ColumnSpan))];

    static (bool, int, int, int, int)[] Splitters(SceneGrid grid) => [.. grid.Splitters.Select(s => (s.Vertical, s.Row, s.Column, s.RowSpan, s.ColumnSpan))];

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
}
