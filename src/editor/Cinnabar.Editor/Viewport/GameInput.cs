using Avalonia.Input;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Viewport;

/// <summary>The viewport's keyboard and mouse as the game's input events (see docs/editor/document-and-scenes.md#modes).</summary>
static class GameInput
{
    public static InputEvent Down(InputKey key) => new(InputEventKind.KeyDown, key, [0, 0], 0);
    public static InputEvent Up(InputKey key) => new(InputEventKind.KeyUp, key, [0, 0], 0);
    public static InputEvent Move(Vec2 pixel) => new(InputEventKind.MouseMove, InputKey.None, [(float)pixel.X, (float)pixel.Y], 0);
    public static InputEvent Scroll(double notches) => new(InputEventKind.Scroll, InputKey.None, [0, 0], (float)notches);
    public static InputEvent ReleaseAll() => new(InputEventKind.ReleaseAll, InputKey.None, [0, 0], 0);

    /// <summary>The game's key for a key, or null for one that the game does not have.</summary>
    public static InputKey? Key(Key key) => key switch
    {
        >= Avalonia.Input.Key.A and <= Avalonia.Input.Key.Z => (InputKey)((int)InputKey.A + (key - Avalonia.Input.Key.A)),
        >= Avalonia.Input.Key.D0 and <= Avalonia.Input.Key.D9 => (InputKey)((int)InputKey.Num0 + (key - Avalonia.Input.Key.D0)),
        >= Avalonia.Input.Key.F1 and <= Avalonia.Input.Key.F12 => (InputKey)((int)InputKey.F1 + (key - Avalonia.Input.Key.F1)),
        Avalonia.Input.Key.Space => InputKey.Space,
        Avalonia.Input.Key.Enter => InputKey.Enter,
        Avalonia.Input.Key.Escape => InputKey.Escape,
        Avalonia.Input.Key.Tab => InputKey.Tab,
        Avalonia.Input.Key.Back => InputKey.Backspace,
        Avalonia.Input.Key.Delete => InputKey.Delete,
        Avalonia.Input.Key.Insert => InputKey.Insert,
        Avalonia.Input.Key.Home => InputKey.Home,
        Avalonia.Input.Key.End => InputKey.End,
        Avalonia.Input.Key.PageUp => InputKey.PageUp,
        Avalonia.Input.Key.PageDown => InputKey.PageDown,
        Avalonia.Input.Key.Left => InputKey.Left,
        Avalonia.Input.Key.Right => InputKey.Right,
        Avalonia.Input.Key.Up => InputKey.Up,
        Avalonia.Input.Key.Down => InputKey.Down,
        Avalonia.Input.Key.LeftShift => InputKey.LeftShift,
        Avalonia.Input.Key.RightShift => InputKey.RightShift,
        Avalonia.Input.Key.LeftCtrl => InputKey.LeftControl,
        Avalonia.Input.Key.RightCtrl => InputKey.RightControl,
        Avalonia.Input.Key.LeftAlt => InputKey.LeftAlt,
        Avalonia.Input.Key.RightAlt => InputKey.RightAlt,
        _ => null,
    };

    /// <summary>The button that a press or a release changed.</summary>
    public static InputKey? Button(PointerUpdateKind kind) => kind switch
    {
        PointerUpdateKind.LeftButtonPressed or PointerUpdateKind.LeftButtonReleased => InputKey.MouseLeft,
        PointerUpdateKind.RightButtonPressed or PointerUpdateKind.RightButtonReleased => InputKey.MouseRight,
        PointerUpdateKind.MiddleButtonPressed or PointerUpdateKind.MiddleButtonReleased => InputKey.MouseMiddle,
        PointerUpdateKind.XButton1Pressed or PointerUpdateKind.XButton1Released => InputKey.Mouse4,
        PointerUpdateKind.XButton2Pressed or PointerUpdateKind.XButton2Released => InputKey.Mouse5,
        _ => null,
    };
}
