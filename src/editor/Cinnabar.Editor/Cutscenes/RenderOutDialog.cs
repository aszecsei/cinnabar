using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// Render Out… (see docs/editor/cutscene-editor.md#render-out): the range, the size, the rate, the format, where the
/// frames go and their names, the camera, the warm-up and whether to write the sound and a video. It gives the settings,
/// or null when cancelled.
/// </summary>
static class RenderOutDialog
{
    public static async Task<RenderOutSettings?> Ask(Window owner, EditorShell shell, CutsceneEditor editor)
    {
        var ffmpeg = shell.Settings.Ffmpeg();
        var start = editor.DefaultRenderOut(shell.ProjectDirectory, ffmpeg != null);
        RenderOutSettings? answer = null;
        var dialog = new Window
        {
            Title = $"Render Out {editor.CutsceneName}",
            SizeToContent = SizeToContent.WidthAndHeight,
            CanResize = false,
            ShowInTaskbar = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = new SolidColorBrush(Color.Parse("#232326")),
        };
        // Each range that the tab has: the whole range, the in and out points, and the selected shot.
        List<(string Label, RenderOutRange Range)> ranges = [("Whole range", RenderOutRange.Whole)];
        if (editor.RenderOutSpan(RenderOutRange.InOut) != null)
        {
            ranges.Add(("In to out", RenderOutRange.InOut));
        }
        if (editor.RenderOutSpan(RenderOutRange.Shot) != null)
        {
            ranges.Add(("Selected shot", RenderOutRange.Shot));
        }
        var range = new ComboBox { ItemsSource = ranges.Select(r => r.Label).ToList(), SelectedIndex = 0, MinWidth = 160 };
        var size = new TextBox { Text = $"{start.Width}x{start.Height}", MinWidth = 120 };
        var rate = new TextBox { Text = start.Rate.ToString(), MinWidth = 60 };
        var format = new ComboBox { ItemsSource = new[] { "PNG", "EXR (needs an HDR target, not built yet)" }, SelectedIndex = 0, MinWidth = 160 };
        var folder = new TextBox { Text = start.Folder, MinWidth = 360 };
        var browse = new Button { Content = "Browse…" };
        var pattern = new TextBox { Text = start.Pattern, MinWidth = 240 };
        List<(string Label, uint Binding)> cameras = [("Cut track", 0u), .. editor.RenderOutCameras().Select(c => (c.Name, c.Binding))];
        var camera = new ComboBox { ItemsSource = cameras.Select(c => c.Label).ToList(), SelectedIndex = 0, MinWidth = 160 };
        var warmup = new TextBox { Text = start.Warmup.ToString(), MinWidth = 60 };
        var audio = new CheckBox { Content = "Sound, as a WAV", IsChecked = true };
        var video = new CheckBox { Content = "Video, as an MP4 of the frames and the sound", IsChecked = ffmpeg != null, IsEnabled = ffmpeg != null };
        if (RenderOutModel.VideoRefusal(ffmpeg) is { } off)
        {
            ToolTip.SetTip(video, off);
        }
        var problem = new TextBlock { Foreground = new SolidColorBrush(Color.Parse("#E08A7A")), TextWrapping = TextWrapping.Wrap, MaxWidth = 460 };
        var summary = new TextBlock { Foreground = new SolidColorBrush(Color.Parse("#A0A0A8")), TextWrapping = TextWrapping.Wrap, MaxWidth = 460 };
        var render = new Button { Content = "Render", MinWidth = 88, HorizontalContentAlignment = HorizontalAlignment.Center, IsDefault = true, Classes = { "accent" } };
        var cancel = new Button { Content = "Cancel", MinWidth = 88, HorizontalContentAlignment = HorizontalAlignment.Center, IsCancel = true };

        RenderOutSettings? Read(out string? reason)
        {
            reason = null;
            if (!EditorShell.TryParseFixedSize(size.Text ?? "", out var pixels, out var sizeReason) || pixels is not { } fixedSize)
            {
                reason = sizeReason != "" ? sizeReason : "the size takes <width>x<height>";
                return null;
            }
            if (!uint.TryParse(rate.Text, out var fps))
            {
                reason = "the rate is a whole number of frames a second";
                return null;
            }
            if (!uint.TryParse(warmup.Text, out var warm) || warm > 64)
            {
                reason = "the warm-up is 0 to 64 frames";
                return null;
            }
            var (from, to) = editor.RenderOutSpan(ranges[Math.Max(range.SelectedIndex, 0)].Range) ?? (start.RangeStart, start.RangeEnd);
            var settings = start with
            {
                RangeStart = from,
                RangeEnd = to,
                Rate = fps,
                Width = (uint)fixedSize.Width,
                Height = (uint)fixedSize.Height,
                Format = format.SelectedIndex == 1 ? RenderOutFormat.Exr : RenderOutFormat.Png,
                CameraBinding = cameras[Math.Max(camera.SelectedIndex, 0)].Binding,
                Warmup = warm,
                Folder = (folder.Text ?? "").Trim(),
                Pattern = (pattern.Text ?? "").Trim(),
                Audio = audio.IsChecked == true,
                Video = video.IsChecked == true,
            };
            reason = settings.Refusal ?? shell.RenderOutRefusal(editor);
            return settings;
        }
        void Update()
        {
            var settings = Read(out var reason);
            render.IsEnabled = settings != null && reason == null;
            problem.Text = reason ?? "";
            summary.Text = settings == null ? "" : $"{settings.FrameCount} frames, from {settings.Pattern.Replace("{name}", settings.Name).Replace("{frame}", settings.FirstFrame.ToString("D6"))}.";
        }
        foreach (var box in new[] { size, rate, folder, pattern, warmup })
        {
            box.TextChanged += (_, _) => Update();
        }
        foreach (var combo in new[] { range, format, camera })
        {
            combo.SelectionChanged += (_, _) => Update();
        }
        audio.IsCheckedChanged += (_, _) => Update();
        video.IsCheckedChanged += (_, _) => Update();
        browse.Click += async (_, _) =>
        {
            var picked = await dialog.StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = "Where the frames go", AllowMultiple = false });
            if (picked.Count == 1 && picked[0].TryGetLocalPath() is { } path)
            {
                folder.Text = path;
            }
        };
        render.Click += (_, _) =>
        {
            answer = Read(out var reason);
            if (reason == null)
            {
                dialog.Close();
            }
        };
        cancel.Click += (_, _) =>
        {
            answer = null;
            dialog.Close();
        };
        static TextBlock Label(string text) => new() { Text = text, Margin = new Thickness(0, 6, 0, 2) };
        static StackPanel Row(params Control[] controls)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            row.Children.AddRange(controls);
            return row;
        }
        dialog.Content = new StackPanel
        {
            Margin = new Thickness(20),
            Spacing = 4,
            Children =
            {
                Label("Range"), range,
                Label("Size in pixels, and frames a second"), Row(size, rate),
                Label("Format"), format,
                Label("Folder"), Row(folder, browse),
                Label("File names: {name} is the cutscene's, {frame} the frame's number"), pattern,
                Label("Camera"), camera,
                Label("Warm-up frames, drawn and not written"), warmup,
                audio, video,
                summary, problem,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0), Children = { render, cancel } },
            },
        };
        Update();
        await dialog.ShowDialog(owner);
        return answer;
    }
}
