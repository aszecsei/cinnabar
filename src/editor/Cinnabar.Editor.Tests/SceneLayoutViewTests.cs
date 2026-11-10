using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Viewport;

namespace Cinnabar.Editor.Tests;

/// <summary>The Scene document's view keeps the views that stay in it when the views change (see docs/editor/viewport.md#views).</summary>
public sealed class SceneLayoutViewTests : IDisposable
{
    readonly TempDirectory _temp = new("scene-layout");

    [Fact]
    public void EveryViewThatStaysIsTheSameControlAfterAChange()
    {
        using var shell = TestShell.Open(_temp, null, null);
        var view = new PlainLayoutView(shell);
        ViewportView[] Views() => [.. view.Children.OfType<ViewportView>()];
        var perspective = Assert.Single(Views());

        shell.SetSceneViews(SceneViewSet.All);
        view.Arrange();
        var quad = Views();
        Assert.Equal(4, quad.Length);
        Assert.Contains(perspective, quad);

        // Perspective, Front and Side stay while Top leaves, and the three are the controls they were.
        shell.SetSceneViews(SceneViewSet.Perspective | SceneViewSet.Front | SceneViewSet.Side);
        view.Arrange();
        var three = Views();
        Assert.Equal(3, three.Length);
        Assert.All(three, v => Assert.Contains(v, quad));

        shell.SetSceneViews(SceneViewSet.Front);
        view.Arrange();
        var front = Assert.Single(Views());
        Assert.Contains(front, three);
    }

    sealed class PlainLayoutView(EditorShell shell) : SceneLayoutView(shell)
    {
        protected override Avalonia.Controls.Control CreateSplitter(bool vertical) => new Avalonia.Controls.Border();
    }

    public void Dispose() => _temp.Dispose();
}
