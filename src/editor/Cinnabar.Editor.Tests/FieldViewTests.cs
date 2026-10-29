using Avalonia.Input;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Xunit;

namespace Cinnabar.Editor.Tests;

public class FieldViewTests
{
    // Records what a view asks of its field's editor.
    sealed class Recorder : IFieldEditor
    {
        public List<double[]> Numbers { get; } = [];
        public bool Commit(int axis, string text) => true;
        public void SetFlag(bool value) { }
        public void SetEntity(ulong handle) { }
        public void SetAsset(string guid) { }
        public IReadOnlyList<string> Options => [];
        public void Choose(string option) { }
        public void BeginScrub(int axis) { }
        public void Scrub(int axis, double pixels, KeyModifiers modifiers) { }
        public void EndScrub() { }
        public void SetNumbers(double[] values) => Numbers.Add(values);
    }

    static FieldDisplay Number(string text) => new(DisplayKind.Number, text, [], false, 0, null);

    [Fact]
    public void ShowingAValueOutsideTheSlidersRangeEditsNothing()
    {
        // A camera's vertical_fov is 0 for the default, below its slider's range, 0.1 to 3.
        var editor = new Recorder();
        var view = new BoxView(numeric: true, editor, (0.1, 3));
        view.Show(Number("0"));
        view.Show(Number("1.2"));
        view.Show(Number("0"));
        Assert.Empty(editor.Numbers);
    }

    [Fact]
    public void ASliderThatMovesWithoutTheUserEditsNothing()
    {
        // Avalonia moves a slider's value itself when it coerces it into the range, as when the properties panel's new
        // views are laid out after Stop. The field keeps its own value, such as a camera's 0 for the default field of
        // view, instead of taking the range's minimum.
        var editor = new Recorder();
        var view = new BoxView(numeric: true, editor, (0.1, 3));
        view.Show(Number("0"));
        var slider = ((Avalonia.Controls.DockPanel)view.Control).Children.OfType<Avalonia.Controls.Slider>().Single();
        slider.Value = 0.1;
        slider.Value = 2;
        Assert.Empty(editor.Numbers);
    }
}
