using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using DebugView = Cinnabar.Editor.Link.Protocol.DebugView;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// A viewport's toolbar, at its top left (see docs/editor/viewport.md#toolbar): a menu for each part of what is the
/// viewport's own. A scene view has View, which names how its camera looks and turns it, and what it looks through;
/// every viewport has Shading, which names what it shows in place of the lit scene, Show, the features and helpers that
/// it draws, Guides, which the editor draws over its frame, and Quality, which draws it at a quality in place of the
/// game's; and a scene view has Layout, the views that the Scene shows.
/// Each menu reads the viewport's state as it opens, and changes this viewport and no other. The Game view has no
/// camera of the editor's, so it has no View and no Layout.
/// </summary>
public sealed class ViewportToolbar : StackPanel
{
    readonly EditorShell _shell;
    readonly EditorViewport _viewport;
    readonly TextBlock _viewText = new();
    readonly TextBlock _shadingText = new();

    public ViewportToolbar(EditorShell shell, EditorViewport viewport)
    {
        _shell = shell;
        _viewport = viewport;
        Orientation = Orientation.Horizontal;
        Spacing = 2;
        HorizontalAlignment = HorizontalAlignment.Left;
        VerticalAlignment = VerticalAlignment.Top;
        Margin = new Thickness(8);
        if (viewport.HasCamera)
        {
            Children.Add(Button(_viewText, "Which way this view looks, and its projection.", ViewMenu()));
        }
        Children.Add(Button(_shadingText, "What this viewport shows: the lit scene, or a debug view of what makes it.", ShadingMenu()));
        Children.Add(Button(new TextBlock { Text = "Show" }, "What this viewport draws: the renderer's features, the icons and shapes of lights, volumes and cameras, and its exposure.", ShowMenu()));
        Children.Add(Button(new TextBlock { Text = "Guides" }, "Guides over this viewport's frame: an aspect mask, the safe areas, a rule-of-thirds grid and the camera's name and lens.", GuidesMenu()));
        Children.Add(Button(new TextBlock { Text = "Quality" }, "Draw this viewport at a quality in place of the game's, and choose how its frame fits.", QualityMenu()));
        if (viewport.HasCamera)
        {
            Children.Add(Button(CommandViews.Icon("layout", 13) ?? (Control)new TextBlock { Text = "Layout" }, "Which views the Scene shows: one, two side by side, or the four.", LayoutMenu()));
        }
        AttachedToVisualTree += (_, _) =>
        {
            if (_viewport.HasCamera)
            {
                _viewport.Camera.Changed += ShowView;
                ShowView();
            }
            _shell.ViewportSettingsChanged += ShowShading;
            ShowShading();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            if (_viewport.HasCamera)
            {
                _viewport.Camera.Changed -= ShowView;
            }
            _shell.ViewportSettingsChanged -= ShowShading;
        };
        ShowShading();
    }

    void ShowView() => _viewText.Text = ViewGizmo.Label(_viewport.Camera);

    void ShowShading() => _shadingText.Text = EditorShell.DebugViewName(_viewport.Settings.DebugView);

    Link.Protocol.ViewportSettings Settings
    {
        get => _viewport.Settings;
        set => _shell.ApplyViewportSettings(_viewport, value);
    }

    // A button that opens a menu. It never takes the focus, so the viewport keeps its keys.
    static Button Button(Control content, string tip, LiveMenu menu)
    {
        content.VerticalAlignment = VerticalAlignment.Center;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, Children = { content } };
        if (CommandViews.Icon("chevron-down", 8) is { } chevron)
        {
            chevron.Opacity = 0.7;
            row.Children.Add(chevron);
        }
        var button = new Button { Content = row, Classes = { "viewport-menu" }, Focusable = false, Flyout = menu.Flyout };
        ToolTip.SetTip(button, tip);
        return button;
    }

    // A menu whose commands act in this viewport: the editor's commands act in the viewport that was last used, so the
    // menu makes this one that viewport as it opens, before its commands read their state, and again before one runs.
    LiveMenu ViewportMenu()
    {
        var menu = new LiveMenu();
        menu.OnOpening(Activate);
        return menu;
    }

    void Activate() => _shell.ActivateViewport(_viewport);

    // Commands of the editor's, with their own labels and state, which act in this viewport.
    void Commands(LiveMenu menu, ItemCollection items, params MenuEntry[] entries) =>
        MenuBuilder.Build(items, entries, _shell.Commands, _shell.KeyBindings, menu, Activate);

    LiveMenu ViewMenu()
    {
        var menu = ViewportMenu();
        foreach (var axis in Enum.GetValues<ViewAxis>())
        {
            menu.Radio(menu.Items, axis.ToString(), () => ViewGizmo.Aligned(_viewport.Camera) == axis, () =>
            {
                _shell.ActivateViewport(_viewport);
                _shell.LookAlong(_viewport, axis);
            });
        }
        Commands(menu, menu.Items, new MenuSeparator(), EditorCommands.ViewProjection, EditorCommands.View2D, new MenuSeparator());
        LookThroughMenu(menu);
        Commands(menu, menu.Items, new MenuSeparator(), EditorCommands.FrameSelected, EditorCommands.FrameScene, EditorCommands.OrbitSelection);
        return menu;
    }

    // What the view draws from (see docs/editor/cutscene-editor.md#look-through): its own camera, the cutscene's cuts, or
    // one of its camera bindings, of the active cutscene or the one that holds the preview. It is built as it opens, as
    // the bindings change.
    void LookThroughMenu(LiveMenu menu)
    {
        var index = _viewport.Index;
        var look = menu.Submenu(menu.Items, () => _shell.Looks[index] switch
        {
            ViewLook.Cuts => "Look Through: Cuts",
            ViewLook.Camera camera => $"Look Through: {camera.Owner.File.Bindings.FirstOrDefault(b => b.Id == camera.Binding)?.Name ?? "Camera"}",
            _ => "Look Through",
        }, "Draw this view from a camera of the cutscene that holds the preview, in place of its own.");
        menu.OnOpening(() =>
        {
            look.Items.Clear();
            var cutscene = _shell.ActiveCutscene ?? _shell.CutscenePreview.Owner;
            var current = _shell.Looks[index];
            look.Items.Add(Choice("Editor Camera", current is ViewLook.Editor, "Draw this view from its own camera.",
                () => _shell.Looks.LookThroughEditor(index)));
            if (cutscene == null || !_shell.IsEditing)
            {
                return;
            }
            look.Items.Add(Choice("Cuts", current is ViewLook.Cuts, "Draw this view from the camera of the camera cut at the playhead.", () =>
            {
                _shell.ActivateViewport(_viewport);
                cutscene.LookThroughCuts();
            }));
            var cameras = cutscene.CameraBindings();
            if (cameras.Count > 0)
            {
                look.Items.Add(new Separator());
            }
            foreach (var (id, name) in cameras)
            {
                var on = current is ViewLook.Camera c && c.Owner == cutscene && c.Binding == id;
                look.Items.Add(Choice(name, on, "Draw this view from the camera, and move it with the view's fly, orbit and pan.", () =>
                {
                    _shell.ActivateViewport(_viewport);
                    if (!cutscene.LooksThrough(id))
                    {
                        cutscene.ToggleLookThrough(id);
                    }
                }));
            }
        });
    }

    // A radio item of a menu that is built as it opens, so it reads its state then.
    static MenuItem Choice(string header, bool on, string tip, Action click)
    {
        var item = new MenuItem { Header = header, ToggleType = MenuItemToggleType.Radio, IsChecked = on };
        item.Click += (_, _) => click();
        ToolTip.SetTip(item, tip);
        return item;
    }

    LiveMenu ShadingMenu()
    {
        var menu = new LiveMenu();
        void View(ItemCollection items, DebugView view) =>
            menu.Radio(items, EditorShell.DebugViewName(view), () => Settings.DebugView == view, () => Settings = Settings with { DebugView = view });
        View(menu.Items, DebugView.Lit);
        menu.Items.Add(new Separator());
        foreach (var (label, views) in ViewportOptions.DebugViewGroups)
        {
            var group = new MenuItem { Header = label };
            foreach (var view in views)
            {
                View(group.Items, view);
            }
            // The group that has the view that shows is marked, so the view is found again.
            menu.OnOpening(() => group.Icon = views.Contains(Settings.DebugView) ? CommandViews.Icon("visible", 14) : null);
            menu.Items.Add(group);
        }
        return menu;
    }

    LiveMenu ShowMenu()
    {
        var menu = ViewportMenu();
        void Toggle(ViewportToggle toggle) =>
            menu.Check(menu.Items, toggle.Label, () => toggle.IsOn(Settings), () => Settings = toggle.Set(Settings, !toggle.IsOn(Settings)), toggle.Description);
        foreach (var feature in ViewportOptions.Features)
        {
            Toggle(feature);
        }
        menu.Items.Add(new Separator());
        Toggle(ViewportOptions.Icons);
        Choice(menu, ViewportOptions.Shapes);
        menu.Items.Add(new Separator());
        var exposure = menu.Submenu(menu.Items, () => Settings.ExposureOffset == 0 ? "Exposure" : $"Exposure ({Settings.ExposureOffset:+0.#;-0.#} stops)");
        Commands(menu, exposure.Items, EditorCommands.ExposureUp, EditorCommands.ExposureDown, EditorCommands.ExposureReset);
        menu.Items.Add(new Separator());
        menu.Check(menu.Items, "Frame Statistics", () => _viewport.Session.ShowStats, () =>
        {
            _viewport.Session.ShowStats = !_viewport.Session.ShowStats;
            _shell.Commands.InvalidateAll();
        }, "Show the frame rates and the adapter over this viewport.");
        Toggle(ViewportOptions.ShadingStats);
        return menu;
    }

    // A choice as a menu under its label and its value, with the option that the viewport has marked.
    void Choice(LiveMenu menu, ViewportChoice choice)
    {
        var parent = menu.Submenu(menu.Items, () => $"{choice.Label}: {choice.Get(Settings)}", choice.Description);
        foreach (var option in choice.Options)
        {
            menu.Radio(parent.Items, option, () => choice.Get(Settings) == option, () => Settings = choice.Set(Settings, option));
        }
    }

    // The frame guides (see docs/editor/cutscene-editor.md#frame-guides), which only the editor draws, over this viewport.
    LiveMenu GuidesMenu()
    {
        var menu = new LiveMenu();
        FrameGuideSettings Guides() => _viewport.Guides;
        void Set(FrameGuideSettings guides) => _shell.SetGuides(_viewport, guides);
        foreach (var guide in ViewportOptions.Guides)
        {
            menu.Check(menu.Items, guide.Label, () => guide.IsOn(Guides()), () => Set(guide.Set(Guides(), !guide.IsOn(Guides()))), guide.Description);
        }
        menu.Items.Add(new Separator());
        var aspect = menu.Submenu(menu.Items, () => $"Aspect: {(Guides().Aspect == GuideAspect.Custom ? $"{Guides().Custom:0.##}:1" : FrameGuides.Label(Guides().Aspect))}",
            "The aspect that the mask and the guides frame.");
        foreach (var choice in Enum.GetValues<GuideAspect>())
        {
            menu.Radio(aspect.Items, FrameGuides.Label(choice), () => Guides().Aspect == choice, () => Set(Guides() with { Aspect = choice, Mask = true }));
        }
        var custom = new NumericUpDown
        {
            Minimum = (decimal)FrameGuides.MinAspect,
            Maximum = (decimal)FrameGuides.MaxAspect,
            Increment = 0.01m,
            FormatString = "0.00",
            Width = 110,
        };
        ToolTip.SetTip(custom, "The custom aspect, as width over height.");
        custom.ValueChanged += (_, e) =>
        {
            if (e.NewValue is { } value && (double)value != Guides().Custom)
            {
                Set(Guides() with { Custom = (double)value, Aspect = GuideAspect.Custom, Mask = true });
            }
        };
        aspect.Items.Add(new MenuItem { Header = custom, StaysOpenOnClick = true });
        menu.OnOpening(() => custom.Value = (decimal)Guides().Custom);
        return menu;
    }

    LiveMenu QualityMenu()
    {
        var menu = new LiveMenu();
        foreach (var choice in ViewportOptions.QualityChoices)
        {
            Choice(menu, choice);
        }
        menu.Items.Add(new Separator());
        var frame = menu.Submenu(menu.Items, () => $"Frame Size: {(_viewport.Session.Scale == ViewportScale.Fit ? "Fit" : "100%")}",
            "Fit the frame to the viewport, or show one frame pixel per screen pixel.");
        menu.Radio(frame.Items, "Fit", () => _viewport.Session.Scale == ViewportScale.Fit, () => _viewport.Session.Scale = ViewportScale.Fit);
        menu.Radio(frame.Items, "100%", () => _viewport.Session.Scale == ViewportScale.Actual, () => _viewport.Session.Scale = ViewportScale.Actual);
        return menu;
    }

    LiveMenu LayoutMenu()
    {
        // The Scene's views are not one viewport's, so these commands need no viewport of their own.
        var menu = new LiveMenu();
        MenuBuilder.Build(menu.Items,
            [EditorCommands.SceneLayout, new MenuSeparator(), .. Enumerable.Range(0, EditorViewport.SceneViews).Select(i => (MenuEntry)EditorCommands.SceneViewToggle(i))],
            _shell.Commands, _shell.KeyBindings, menu);
        return menu;
    }
}
