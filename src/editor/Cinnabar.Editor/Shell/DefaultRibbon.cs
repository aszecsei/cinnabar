using Cinnabar.Editor.Commands.Ribbon;
using Cinnabar.Editor.Docking;

namespace Cinnabar.Editor.Shell;

/// <summary>The editor's ribbon. It holds only commands that work today. Later phases add tabs as they add commands.</summary>
static class DefaultRibbon
{
    public static RibbonLayout Create(IEnumerable<PanelTool> panels)
    {
        var panelCommands = panels.Select(p => EditorCommands.Panel(p.Id)).ToList();
        return new RibbonLayout(
            Categories: [],
            Tabs:
            [
                new RibbonTab("home", "Home",
                [
                    new RibbonGroup("Scene",
                    [
                        new LargeButton(EditorCommands.OpenScene),
                        new LargeButton(EditorCommands.Save),
                        new SmallStack([EditorCommands.SaveAs]),
                    ]),
                    new RibbonGroup("Edit", [new SmallStack([EditorCommands.Undo, EditorCommands.Redo])]),
                    new RibbonGroup("Entity",
                    [
                        new LargeButton(EditorCommands.CreateEntity),
                        new SmallStack([EditorCommands.DuplicateEntity, EditorCommands.DeleteEntity]),
                    ]),
                    new RibbonGroup("Host", [new SplitButton(EditorCommands.RestartHost, [EditorCommands.RestartHost, EditorCommands.StopHost])]),
                    new RibbonGroup("Window",
                    [
                        new LargeButton(EditorCommands.Palette),
                        new Dropdown("Panels", "panels", panelCommands),
                    ]),
                ]),
                new RibbonTab("view", "View",
                [
                    new RibbonGroup("Panels", panelCommands.Chunk(SmallStack.MaxCommands).Select(c => (RibbonItem)new SmallStack(c)).ToList()),
                    new RibbonGroup("Viewport", [new LargeButton(EditorCommands.Stats), new ComboBox(EditorCommands.ViewportScale)]),
                    new RibbonGroup("Layout", [new LargeButton(EditorCommands.ResetLayout), new LargeButton(EditorCommands.CollapseRibbon)]),
                ]),
            ]);
    }
}
