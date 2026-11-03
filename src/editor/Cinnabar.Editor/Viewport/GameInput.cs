using System.Text;
using Avalonia.Input;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Viewport;

/// <summary>The viewport's keyboard, mouse, gamepads and text as the game's input events (see docs/editor/document-and-scenes.md#modes).</summary>
static class GameInput
{
    static InputEvent Event(
        InputEventKind kind, InputKey key = InputKey.None, float[]? position = null, float scroll = 0,
        int pad = 0, bool connected = false, ushort buttons = 0, float[]? axes = null, string text = "", int cursor = 0) =>
        new(kind, key, position ?? [0, 0], scroll, (byte)pad, connected, buttons, axes ?? [0, 0, 0, 0, 0, 0], text, cursor);

    public static InputEvent Down(InputKey key) => Event(InputEventKind.KeyDown, key);
    public static InputEvent Up(InputKey key) => Event(InputEventKind.KeyUp, key);
    public static InputEvent Move(Vec2 pixel) => Event(InputEventKind.MouseMove, position: [(float)pixel.X, (float)pixel.Y]);
    public static InputEvent Scroll(double notches) => Event(InputEventKind.Scroll, scroll: (float)notches);
    public static InputEvent ReleaseAll() => Event(InputEventKind.ReleaseAll);

    /// <summary>What a slot's pad reports now, or that it has none.</summary>
    public static InputEvent Pad(int slot, GamepadReading? reading) => reading is { } r
        ? Event(InputEventKind.Gamepad, pad: slot, connected: true, buttons: r.Buttons, axes: [r.LeftX, r.LeftY, r.RightX, r.RightY, r.LeftTrigger, r.RightTrigger])
        : Event(InputEventKind.Gamepad, pad: slot);

    public static InputEvent Text(string text) => Event(InputEventKind.Text, text: text);

    /// <summary>What an IME composes, with its cursor in UTF-16 units. The game counts the cursor in bytes of UTF-8.</summary>
    public static InputEvent Composition(string text, int cursor) =>
        Event(InputEventKind.Composition, text: text, cursor: Encoding.UTF8.GetByteCount(text.AsSpan(0, Math.Clamp(cursor, 0, text.Length))));

    /// <summary>Whether a key with this symbol and modifiers may type a character. Avalonia drops the character of a key that was handled, so such a key must stay unhandled. Ctrl and Alt together are AltGr.</summary>
    public static bool TypesCharacter(string? symbol, KeyModifiers modifiers) =>
        !string.IsNullOrEmpty(symbol) && !char.IsControl(symbol[0])
        && !modifiers.HasFlag(KeyModifiers.Meta)
        && modifiers.HasFlag(KeyModifiers.Control) == modifiers.HasFlag(KeyModifiers.Alt);

    /// <summary>Joins characters that arrive in two halves: Avalonia gives a typed character one UTF-16 unit at a time, and half of one is not text.</summary>
    public sealed class Characters
    {
        string _high = "";

        public string Join(string text)
        {
            text = _high + text;
            _high = "";
            if (text.Length > 0 && char.IsHighSurrogate(text[^1]))
            {
                _high = text[^1..];
                text = text[..^1];
            }
            return text;
        }
    }

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
