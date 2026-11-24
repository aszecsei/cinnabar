namespace Cinnabar.Editor.Shell;

public sealed partial class EditorShell
{
    /// <summary>
    /// The one place where the commands learn that what they read has changed (see
    /// docs/editor/shell-and-panels.md#commands): each owner raises only its own change event, and the registry refreshes
    /// the views once per dispatcher turn after any of them. An open editor's events are observed while it is open (see
    /// <see cref="ObserveCommandState"/>).
    /// </summary>
    void WireCommandRefresh()
    {
        var c = Commands;
        // The links and the processes.
        c.InvalidateOn(h => Host.StateChanged += _ => h());
        c.InvalidateOn(h => Cook.StateChanged += h);
        c.InvalidateOn(h => Builder.Started += h);
        c.InvalidateOn(h => Builder.Finished += (_, _) => h());
        c.InvalidateOn(h => GameWindowChanged += h);
        c.InvalidateOn(h => ProjectSettingsChanged += h);
        c.InvalidateOn(h => Captures.Changed += h);
        // The window: the panels, the workspaces, the ribbon, the editors' tabs and the content browser.
        c.InvalidateOn(h => Layout.Changed += h);
        c.InvalidateOn(h => Workspaces.Changed += h);
        c.InvalidateOn(h => RibbonChanged += h);
        c.InvalidateOn(h => GraphEditorsChanged += h);
        c.InvalidateOn(h => Content.Model.ContextChanged += h);
        // The scenes and what is selected, hidden and edited in them. Commands such as Delete act on the selection.
        c.InvalidateOn(h => Selection.Changed += (_, _) => h());
        c.InvalidateOn(h => SceneChanged += h);
        c.InvalidateOn(h => OpenEditChanged += h);
        c.InvalidateOn(h => UndoTargetChanged += h);
        c.InvalidateOn(h => Visibility.Changed += h);
        c.InvalidateOn(h => SublevelsChanged += h);
        c.InvalidateOn(h => WorldStateChanged += h);
        c.InvalidateOn(h => ModeChanged += h);
        c.InvalidateOn(h => ToolsChanged += h);
        c.InvalidateOn(h => Mesh.MeshModeChanged += h);
        c.InvalidateOn(h => Landscape.Changed += h);
        // The viewports.
        c.InvalidateOn(h => ActiveViewportChanged += h);
        c.InvalidateOn(h => ViewportsChanged += h);
        c.InvalidateOn(h => SceneViewsChanged += h);
        c.InvalidateOn(h => ViewportSettingsChanged += h);
        c.InvalidateOn(h => CameraProjectionChanged += h);
        c.InvalidateOn(h => GuidesChanged += _ => h());
        c.InvalidateOn(h => Looks.Changed += _ => h());
        foreach (var viewport in Viewports)
        {
            c.InvalidateOn(h => viewport.Session.ViewChanged += h);
        }
        // The cutscene preview, its keying and the timeline's clipboard.
        c.InvalidateOn(h => CutscenePreview.Changed += h);
        c.InvalidateOn(h => Keying.Changed += h);
        c.InvalidateOn(h => CutsceneClipboardChanged += h);
    }

    /// <summary>Observes an editor's own state while its tab is open: called once as it opens, and once as it closes.</summary>
    void ObserveCommandState(IGraphEditor editor, bool observe)
    {
        var refresh = (Action)Commands.RequestInvalidate;
        if (observe)
        {
            editor.Changed += refresh;
        }
        else
        {
            editor.Changed -= refresh;
        }
        // The cutscene's Key and Remove Key follow its playhead, and its commands follow the pane that has the keyboard.
        if (editor is CutsceneEditor cutscene)
        {
            if (observe)
            {
                cutscene.PlayheadChanged += refresh;
                cutscene.KeyboardPaneChanged += refresh;
            }
            else
            {
                cutscene.PlayheadChanged -= refresh;
                cutscene.KeyboardPaneChanged -= refresh;
            }
        }
    }
}
