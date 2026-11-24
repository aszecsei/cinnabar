using Avalonia.Controls;
using Avalonia.Interactivity;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The one walker of every menu of commands (see docs/editor/shell-and-panels.md#commands): what an item shows, how it
/// keeps its command's state, and the focus that runs before its command.
/// </summary>
public sealed class MenuBuilderTests : IDisposable
{
    readonly TempDirectory _temp = new("menus");

    public void Dispose() => _temp.Dispose();

    sealed class Registry
    {
        public readonly CommandRegistry Commands = new();
        public bool CanRun = true;
        public bool On;
        public string Picked = "One";
        public readonly List<string> Log = [];

        public Registry()
        {
            Commands.Register(new Command("run", "Run", () => Log.Add("run"))
            {
                Description = "Run it.",
                Shortcut = "Ctrl+R",
                CanExecuteWhen = () => CanRun,
            });
            Commands.Register(Command.Toggle("toggle", "Toggle", () => On, on => On = on));
            Commands.Register(new ChoiceCommand("pick", "Pick", ["One", "Two"], () => Picked, option => Picked = option));
        }

        public KeyBindings Keys => new(Commands, new Dictionary<string, string>());
    }

    static void Click(MenuItem item) => item.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));

    [Fact]
    public void ACommandShowsWithItsStateAndAChoiceAsItsOptions() => Ui.Run(() =>
    {
        var r = new Registry();
        var menu = new MenuFlyout();
        MenuBuilder.Build(menu.Items,
            ["run", new MenuCommand("toggle", Label: "Flip"), new MenuSeparator(), "pick", "gone", new Submenu("More", null, ["run"])],
            r.Commands, r.Keys, MenuBinding.Snapshot);

        var items = menu.Items.ToList();
        Assert.Equal(6, items.Count);
        var run = Assert.IsType<MenuItem>(items[0]);
        Assert.Equal("Run", run.Header);
        Assert.Equal("Ctrl+R", run.InputGesture?.ToString());
        Assert.Equal("Run it.", ToolTip.GetTip(run));
        var toggle = Assert.IsType<MenuItem>(items[1]);
        Assert.Equal("Flip", toggle.Header);
        Assert.Equal(MenuItemToggleType.CheckBox, toggle.ToggleType);
        Assert.IsType<Separator>(items[2]);
        // A choice is a radio item for each option, and a command that the registry lacks is left out.
        var one = Assert.IsType<MenuItem>(items[3]);
        var two = Assert.IsType<MenuItem>(items[4]);
        Assert.Equal(["One", "Two"], new[] { one.Header, two.Header });
        Assert.True(one.IsChecked);
        Assert.False(two.IsChecked);
        var more = Assert.IsType<MenuItem>(items[5]);
        Assert.Equal("Run", Assert.IsType<MenuItem>(Assert.Single(more.Items)).Header);

        Click(two);
        Assert.Equal("Two", r.Picked);
    });

    [Fact]
    public void EachBindingReadsTheStateWhenItSays() => Ui.Run(() =>
    {
        var r = new Registry();
        var unsubscribe = new List<Action>();
        var subscribed = new MenuFlyout();
        MenuBuilder.Build(subscribed.Items, ["run", "toggle"], r.Commands, r.Keys, MenuBinding.Subscribed(unsubscribe));
        var snapshot = new MenuFlyout();
        MenuBuilder.Build(snapshot.Items, ["run", "toggle"], r.Commands, r.Keys, MenuBinding.Snapshot);
        var live = new LiveMenu();
        MenuBuilder.Build(live.Items, ["run", "toggle"], r.Commands, r.Keys, live);
        static MenuItem Item(MenuFlyout menu, int i) => (MenuItem)menu.Items[i]!;

        r.CanRun = false;
        r.On = true;
        r.Commands.Get("run").Invalidate();
        r.Commands.Get("toggle").Invalidate();
        // A subscribed item follows its command; a snapshot keeps what it read; a live menu reads as it opens.
        Assert.False(Item(subscribed, 0).IsEnabled);
        Assert.True(Item(subscribed, 1).IsChecked);
        Assert.True(Item(snapshot, 0).IsEnabled);
        Assert.False(Item(snapshot, 1).IsChecked);
        Assert.True(Item(live.Flyout, 0).IsEnabled);
        live.Refresh();
        Assert.False(Item(live.Flyout, 0).IsEnabled);
        Assert.True(Item(live.Flyout, 1).IsChecked);

        foreach (var stop in unsubscribe)
        {
            stop();
        }
        r.CanRun = true;
        r.Commands.Get("run").Invalidate();
        Assert.False(Item(subscribed, 0).IsEnabled);
    });

    [Fact]
    public void AnEntrysFocusRunsBeforeItsCommandInPlaceOfTheMenus() => Ui.Run(() =>
    {
        var r = new Registry();
        var menu = new MenuFlyout();
        MenuBuilder.Build(menu.Items, ["run", new MenuCommand("run", () => r.Log.Add("own"))], r.Commands, r.Keys, MenuBinding.Snapshot,
            () => r.Log.Add("menu"));

        Click((MenuItem)menu.Items[0]!);
        Click((MenuItem)menu.Items[1]!);
        Assert.Equal(["menu", "run", "own", "run"], r.Log);
    });

    [Fact]
    public void TheFolderMenuNamesEveryNewAssetCommand()
    {
        using var shell = new EditorShell(new EditorOptions("host.exe", "game.dll") { AutosaveDirectory = _temp.Combine("autosave") },
            new EditorSettings(_temp.Combine("settings")));
        var menu = DefaultRibbon.NewAssetMenu();

        Assert.Empty(MenuEntry.Validate(shell.Commands, menu));
        var named = MenuEntry.Commands(menu).ToHashSet();
        string[] all =
        [
            EditorCommands.NewScript, EditorCommands.NewBehaviour, EditorCommands.NewSceneAsset, EditorCommands.NewMaterial,
            EditorCommands.NewMaterialFunction, EditorCommands.NewMesh, EditorCommands.NewPrefab, EditorCommands.NewEffect,
            EditorCommands.NewAnimationGraph, EditorCommands.NewUiDocument, EditorCommands.NewSpriteSheet, EditorCommands.NewBlackboard,
            EditorCommands.NewCutscene, EditorCommands.NewDecision, EditorCommands.NewUtilityDecision, EditorCommands.NewGoapDecision,
            EditorCommands.NewHtnDecision, EditorCommands.NewFolder,
        ];
        Assert.All(all, id => Assert.Contains(id, named));
    }
}
