using Avalonia;

namespace Cinnabar.Editor;

static class Program
{
    [STAThread]
    public static int Main(string[] args) => BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            // The viewport hands its frames to ANGLE's D3D11 device (see docs/editor.md#viewport).
            .With(new Win32PlatformOptions { RenderingMode = [Win32RenderingMode.AngleEgl] })
            .WithInterFont()
            .LogToTrace();
}
