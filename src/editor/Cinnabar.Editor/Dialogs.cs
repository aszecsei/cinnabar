using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Cinnabar.Editor;

/// <summary>Small modal questions, such as whether to save. Avalonia has no message box of its own.</summary>
static class Dialogs
{
    /// <summary>Asks a question with a button for each answer, and returns the answer, or null if the user closed it.</summary>
    public static async Task<string?> Ask(Window owner, string title, string message, params string[] answers)
    {
        string? answer = null;
        var dialog = new Window
        {
            Title = title,
            SizeToContent = SizeToContent.WidthAndHeight,
            CanResize = false,
            ShowInTaskbar = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = new SolidColorBrush(Color.Parse("#232326")),
        };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var a in answers)
        {
            var button = new Button { Content = a, MinWidth = 88, HorizontalContentAlignment = HorizontalAlignment.Center };
            button.Click += (_, _) =>
            {
                answer = a;
                dialog.Close();
            };
            buttons.Children.Add(button);
        }
        if (buttons.Children.FirstOrDefault() is Button first)
        {
            first.Classes.Add("accent");
            first.IsDefault = true;
        }
        dialog.Content = new StackPanel
        {
            Margin = new Thickness(20),
            Spacing = 16,
            MaxWidth = 460,
            Children = { new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap }, buttons },
        };
        await dialog.ShowDialog(owner);
        return answer;
    }
}
