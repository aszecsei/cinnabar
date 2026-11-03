using Avalonia;
using Avalonia.Controls;
using Avalonia.Input.TextInput;

namespace Cinnabar.Editor.Viewport;

/// <summary>The viewport as the IME's text field while the game has the input: what the IME composes goes to <paramref name="composing"/>, with the cursor in UTF-16 units. Avalonia never shows the system's composition window, so the viewport shows it.</summary>
sealed class GameTextClient(Control view, Rect cursor, Action<string, int> composing) : TextInputMethodClient
{
    public override Visual TextViewVisual => view;
    public override bool SupportsPreedit => true;
    public override bool SupportsSurroundingText => false;
    public override string SurroundingText => "";
    public override Rect CursorRectangle => cursor.WithY(view.Bounds.Height - cursor.Y);
    public override TextSelection Selection { get; set; }

    public override void SetPreeditText(string? preeditText, int? cursorPos) =>
        composing(preeditText ?? "", cursorPos ?? preeditText?.Length ?? 0);
}
