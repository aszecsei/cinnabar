using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;

namespace Cinnabar.Editor.Projects;

/// <summary>What a new project is: its name, the folder that it goes in, its folder's name and its template.</summary>
public sealed record NewProjectAnswer(string Name, string Location, string Folder, string Template);

/// <summary>Asks for a new project's name, where it goes and its template (see docs/overview/getting-started.md#a-new-project).</summary>
static class NewProjectDialog
{
    /// <summary>
    /// A folder's name for a game's name: the characters that Windows refuses in a name are left out, and so are the
    /// dots and spaces at its end.
    /// </summary>
    public static string FolderName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        return new string([.. name.Where(c => !invalid.Contains(c))]).Trim().TrimEnd('.', ' ');
    }

    public static async Task<NewProjectAnswer?> Ask(Window owner, string location, IReadOnlyList<string> templates)
    {
        NewProjectAnswer? answer = null;
        var dialog = new Window
        {
            Title = "New Project",
            SizeToContent = SizeToContent.WidthAndHeight,
            CanResize = false,
            ShowInTaskbar = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = new SolidColorBrush(Color.Parse("#232326")),
        };
        var name = new TextBox { Text = "My Game", MinWidth = 360 };
        var where = new TextBox { Text = location, MinWidth = 360 };
        var browse = new Button { Content = "Browse…" };
        var template = new ComboBox { ItemsSource = templates.Count > 0 ? templates : ["basic"], SelectedIndex = 0, MinWidth = 160 };
        var folder = new TextBlock { Foreground = new SolidColorBrush(Color.Parse("#A0A0A8")), TextWrapping = TextWrapping.Wrap, MaxWidth = 460 };
        var create = new Button { Content = "Create", MinWidth = 88, HorizontalContentAlignment = HorizontalAlignment.Center, IsDefault = true, Classes = { "accent" } };
        var cancel = new Button { Content = "Cancel", MinWidth = 88, HorizontalContentAlignment = HorizontalAlignment.Center, IsCancel = true };
        void Update()
        {
            var dir = FolderName(name.Text ?? "");
            create.IsEnabled = dir.Length > 0 && !string.IsNullOrWhiteSpace(where.Text);
            folder.Text = create.IsEnabled ? $"The project goes in {Path.Combine(where.Text!.Trim(), dir)}." : "";
        }
        name.TextChanged += (_, _) => Update();
        where.TextChanged += (_, _) => Update();
        browse.Click += async (_, _) =>
        {
            var picked = await dialog.StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = "Where the project goes", AllowMultiple = false });
            if (picked.Count == 1 && picked[0].TryGetLocalPath() is { } path)
            {
                where.Text = path;
            }
        };
        create.Click += (_, _) =>
        {
            answer = new NewProjectAnswer(name.Text!.Trim(), where.Text!.Trim(), FolderName(name.Text!), template.SelectedItem as string ?? "basic");
            dialog.Close();
        };
        cancel.Click += (_, _) => dialog.Close();
        dialog.Opened += (_, _) =>
        {
            name.Focus();
            name.SelectAll();
        };
        static TextBlock Label(string text) => new() { Text = text, Margin = new Thickness(0, 6, 0, 2) };
        dialog.Content = new StackPanel
        {
            Margin = new Thickness(20),
            Spacing = 4,
            Children =
            {
                Label("Name"),
                name,
                Label("Location"),
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { where, browse } },
                Label("Template: basic is content and scripts; odin adds a game folder of Odin hooks"),
                template,
                folder,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0), Children = { create, cancel } },
            },
        };
        Update();
        await dialog.ShowDialog(owner);
        return answer;
    }
}
