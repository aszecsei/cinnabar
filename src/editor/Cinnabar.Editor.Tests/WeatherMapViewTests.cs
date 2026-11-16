using Cinnabar.Editor.Panels;

namespace Cinnabar.Editor.Tests;

/// <summary>How the Weather Map panel shares its height (see docs/editor/shell-and-panels.md#weather-map).</summary>
public sealed class WeatherMapViewTests
{
    [Fact]
    public void WithoutAMapTheControlsHaveThePanel()
    {
        // There is nothing to paint, so no height is kept for a canvas.
        Assert.Equal(double.PositiveInfinity, WeatherMapView.ControlsMaxHeight(hasMap: false, panelHeight: 700));
        Assert.Equal(double.PositiveInfinity, WeatherMapView.ControlsMaxHeight(hasMap: false, panelHeight: 0));
    }

    [Fact]
    public void WithAMapTheMapKeepsAtLeastHalfThePanel()
    {
        Assert.Equal(350, WeatherMapView.ControlsMaxHeight(hasMap: true, panelHeight: 700));
        Assert.Equal(500, WeatherMapView.ControlsMaxHeight(hasMap: true, panelHeight: 1000));
        // In a panel that is docked short, the controls still show a few rows.
        Assert.Equal(120, WeatherMapView.ControlsMaxHeight(hasMap: true, panelHeight: 150));
        // Before the panel has a size, nothing is held back.
        Assert.Equal(double.PositiveInfinity, WeatherMapView.ControlsMaxHeight(hasMap: true, panelHeight: 0));
    }
}
