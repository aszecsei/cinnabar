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

    /// <summary>Asks for a name, with a text that starts selected, and returns it, or null if the user cancelled.</summary>
    public static async Task<string?> AskName(Window owner, string title, string message, string initial, string accept)
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
        var box = new TextBox { Text = initial, MinWidth = 320 };
        var ok = new Button { Content = accept, MinWidth = 88, HorizontalContentAlignment = HorizontalAlignment.Center, IsDefault = true, Classes = { "accent" } };
        var cancel = new Button { Content = "Cancel", MinWidth = 88, HorizontalContentAlignment = HorizontalAlignment.Center, IsCancel = true };
        ok.Click += (_, _) =>
        {
            answer = box.Text?.Trim();
            dialog.Close();
        };
        cancel.Click += (_, _) => dialog.Close();
        box.TextChanged += (_, _) => ok.IsEnabled = !string.IsNullOrWhiteSpace(box.Text);
        dialog.Opened += (_, _) =>
        {
            box.Focus();
            box.SelectAll();
        };
        dialog.Content = new StackPanel
        {
            Margin = new Thickness(20),
            Spacing = 12,
            MaxWidth = 460,
            Children =
            {
                new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
                box,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Children = { ok, cancel } },
            },
        };
        await dialog.ShowDialog(owner);
        return string.IsNullOrEmpty(answer) ? null : answer;
    }
}
