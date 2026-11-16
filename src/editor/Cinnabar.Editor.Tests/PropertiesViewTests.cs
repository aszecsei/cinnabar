using System.Collections.Specialized;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.LogicalTree;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>The properties panel's controls over a scene's entity (see docs/editor/shell-and-panels.md#properties).</summary>
public sealed class PropertiesViewTests : IDisposable
{
    readonly TempDirectory _temp = new("properties-view");

    const string SceneText = "scene 2\n\n" +
        "entity 0000000000000001\nname = \"Door\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    const ulong Door = 1UL << 32;

    // The one component, with a field whose editor needs no window: a number's and a vector's make a cursor for their drags.
    static readonly ComponentType Transform = new(1, "Transform", "Transform", 56,
    [
        new FieldInfo("frozen", 52, FieldKind.Bool, FieldKind.Bool, [], false, false, 0, 0, false, false, 0, ""),
    ]);

    // The panel over the scene's one entity, selected, and listening as it does while it shows.
    (EditorShell Shell, PropertiesView View, StackPanel Content) Open()
    {
        var shell = TestShell.Open(_temp, "door.scene", SceneText);
        shell.OnGameMessage(new ComponentTypes([Transform]));
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(Door, "Door", 1, 0, true, [1])]));
        shell.Selection.Select(Door);
        var view = new PropertiesView(shell);
        view.Subscriptions.Attach();
        return (shell, view, (StackPanel)view.Content!);
    }

    static TextBox NameBox(StackPanel content) =>
        content.GetLogicalDescendants().OfType<TextBox>().Single(b => b.Classes.Contains("title-edit"));

    // Avalonia takes the focus from a focused control that leaves the tree, which raises LostFocus on it while the panel
    // is in the middle of clearing its rows. The tests have no window, so they raise it as the rows go.
    static void LoseFocusWhenRemoved(StackPanel content, Control focused) =>
        content.Children.CollectionChanged += (_, e) =>
        {
            if (e.Action is NotifyCollectionChangedAction.Reset or NotifyCollectionChangedAction.Remove && !content.GetLogicalDescendants().Contains(focused))
            {
                focused.RaiseEvent(new FocusChangedEventArgs(InputElement.LostFocusEvent));
            }
        };

    static int Headers(StackPanel content) => content.Children.OfType<StackPanel>().Count(c => c.Classes.Contains("properties-header"));

    [Fact]
    public void ARenameShowsTheEntityOnceAndIsOneUndoEntry() => Ui.Run(() =>
    {
        var (shell, _, content) = Open();
        using var _ = shell;
        Assert.Equal(1, Headers(content));
        var rows = content.Children.Count;
        var name = NameBox(content);
        LoseFocusWhenRemoved(content, name);

        // Enter commits, and the box keeps the focus.
        name.Text = "Gate";
        name.RaiseEvent(new KeyEventArgs { RoutedEvent = InputElement.KeyDownEvent, Key = Key.Enter });
        Assert.Equal("Gate", shell.Scene!.Expanded.Flat.Find(1)!.Name);
        // The game reports the new name, which builds the panel again, and takes the focused box out of it.
        shell.OnGameMessage(new EntityDelta([new EntityInfo(Door, "Gate", 1, 0, true, [1])], []));

        Assert.Equal(1, Headers(content));
        Assert.Equal(rows, content.Children.Count);
        Assert.Equal("Gate", NameBox(content).Text);
        Assert.Equal(["Rename"], shell.Scene.History.Select(t => t.Label));
    });

    [Fact]
    public void ANameTypedAndNotCommittedIsKeptWhenTheSelectionLeaves() => Ui.Run(() =>
    {
        var (shell, _, content) = Open();
        using var _ = shell;
        var name = NameBox(content);
        LoseFocusWhenRemoved(content, name);

        // The selection goes while the box has the focus and text that it has not committed.
        name.Text = "Gate";
        shell.Selection.Clear();

        Assert.Equal("Gate", shell.Scene!.Expanded.Flat.Find(1)!.Name);
        Assert.Equal(["Rename"], shell.Scene.History.Select(t => t.Label));
        Assert.Equal(0, Headers(content));
        // The panel says that nothing is selected, once.
        Assert.Single(content.Children);
    });

    public void Dispose() => _temp.Dispose();
}
