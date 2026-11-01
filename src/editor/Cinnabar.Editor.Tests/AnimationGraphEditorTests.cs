using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>The animation graph editor, driven without a window.</summary>
public sealed class AnimationGraphEditorTests : IDisposable
{
    const string Guid = "0123456789abcdef0123456789abcdef";
    const string Survey = "00112233445566778899aabbccddeeff";
    const string Walk = "ffeeddccbbaa99887766554433221100";

    static string Graph => $"""
        animation_graph 1
        entry = idle

        param speed float 0
        param grounded bool true # set by the character
        param look trigger

        clip survey = ${Survey}
        clip walk = ${Walk}
        	event 0.5 footstep "left"

        node 1 state
        	position = [0, 0]
        	name = idle
        	motion = survey
        node 2 state
        	position = [320, 0]
        	name = move
        	motion = @10.pose
        node 3 state
        	position = [320, 200]
        	name = look
        	motion = survey

        node 10 blend_1d
        	position = [80, 120]
        	parameter = speed
        	input.0 = survey
        	at.0 = 1
        	input.1 = walk
        	at.1 = 3

        node 20 transition
        	from = idle
        	to = move
        	when = speed > 0.1 and !grounded
        node 21 transition
        	from = move
        	to = idle
        	when = speed < 0.05
        node 22 transition
        	from = move
        	to = look
        	when = look
        node 23 transition
        	from = any
        	to = look
        	when = grounded

        """.ReplaceLineEndings("\n");

    readonly TempDirectory _temp = new("animation-graph-editor");

    public void Dispose() => _temp.Dispose();

    (EditorShell Shell, AnimationGraphEditor Editor) Open(string? text = null)
    {
        var shell = TestShell.Open(_temp, null, null);
        var path = _temp.Combine("fox.animation_graph");
        File.WriteAllText(path, text ?? Graph);
        return (shell, new AnimationGraphEditor(shell, AnimationGraphDocument.Open(path, Guid).Document!));
    }

    // A shell whose index has the sample's graph, in the test's directory.
    (EditorShell Shell, Asset Asset, string Text) Fox()
    {
        var text = File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "models", "fox", "fox.animation_graph"));
        var shell = TestShell.Open(_temp, null, null);
        File.WriteAllText(_temp.Combine("fox.animation_graph"), text);
        var asset = new Asset(Guid, AssetKind.AnimationGraph, "game", "fox.animation_graph", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", [], "");
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], []));
        shell.Assets.Apply(new AssetSnapshot([asset], []));
        return (shell, asset, text);
    }

    [Fact]
    public void TheSamplesGraphOpensOnACanvasAndAnEditChangesOnlyItsLines()
    {
        var (shell, asset, text) = Fox();
        using var _ = shell;
        Assert.True(EditorShell.CanOpen(asset));
        Assert.Equal("Open in Animation Graph Editor", shell.OpenLabel(asset));
        shell.OpenAsset(asset);
        var editor = Assert.Single(shell.AnimationGraphs);
        Assert.Same(editor, shell.ActiveGraphEditor);
        Assert.Null(shell.ActiveMaterial);
        Assert.Contains(editor, shell.GraphEditors);
        Assert.False(editor.Document.IsDirty);
        Assert.Equal(text, editor.Document.Text);
        // Opening it again shows the same editor.
        Assert.Same(editor, shell.OpenAnimationGraph(asset));

        var geometry = editor.Geometry();
        Assert.Equal([1, 2, 3, 10], geometry.Nodes.Select(n => n.Node.Id));
        Assert.Equal([20, 21, 22, 23], geometry.Transitions.Select(t => t.Node.Id));
        Assert.Equal((10, 2), (geometry.Links[0].Blend, geometry.Links[0].State));

        // A drag writes the one line, and the file is the same but for it.
        editor.Select([1]);
        var starts = editor.MoveStarts();
        editor.BeginMove();
        editor.MoveSelected(starts, new Vec2(40, 80));
        editor.EndMove();
        Assert.True(editor.Document.IsDirty);
        var expected = text.Replace("position = [0, 0]", "position = [40, 80]");
        Assert.Equal(expected, editor.Document.Text);

        // Undo, Redo and Save act on the active graph.
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(text, editor.Document.Text);
        shell.Commands.Get("edit.redo").Execute();
        shell.Commands.Get("file.save").Execute();
        Assert.False(editor.Document.IsDirty);
        Assert.Equal(expected, File.ReadAllText(_temp.Combine("fox.animation_graph")));

        shell.CloseGraph(editor, discard: true);
        Assert.Empty(shell.AnimationGraphs);
        Assert.Null(shell.ActiveGraphEditor);
    }

    [Fact]
    public void ASaveDoesNotReplaceWhatAnotherProgramWroteWithoutAsking()
    {
        var (shell, asset, _) = Fox();
        using var __ = shell;
        var editor = shell.OpenAnimationGraph(asset)!;
        IGraphEditor? asked = null;
        shell.GraphOverwriteRequested += e => asked = e;
        editor.AddState(0, 0);
        File.AppendAllText(_temp.Combine("fox.animation_graph"), "# Someone's note.\n");

        Assert.False(shell.SaveGraph(editor));
        Assert.Same(editor, asked);
        Assert.True(editor.Document.IsDirty);
        Assert.Contains("Someone's note", File.ReadAllText(_temp.Combine("fox.animation_graph")));

        Assert.True(shell.SaveGraph(editor, overwrite: true));
        Assert.DoesNotContain("Someone's note", File.ReadAllText(_temp.Combine("fox.animation_graph")));
        // Now the file is the one that the document wrote.
        Assert.False(editor.Document.ChangedOnDisk);
        editor.AddState(0, 0);
        asked = null;
        Assert.True(shell.SaveGraph(editor));
        Assert.Null(asked);
    }

    [Fact]
    public void AnOpenGraphFollowsItsFile()
    {
        var (shell, asset, _) = Fox();
        using var __ = shell;
        var editor = shell.OpenAnimationGraph(asset)!;
        File.Move(_temp.Combine("fox.animation_graph"), _temp.Combine("vixen.animation_graph"));
        shell.Assets.Apply(new AssetDelta([asset with { Path = "vixen.animation_graph" }], [], [], []));
        Assert.Equal("vixen.animation_graph", editor.Document.Title);
        // The move is no change to the file.
        Assert.False(editor.Document.ChangedOnDisk);
    }

    [Fact]
    public void TheCanvasFindsStatesPinsAndTransitions()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        var geometry = editor.Geometry();

        Assert.Equal([1, 2, 3, 10], geometry.Nodes.Select(n => n.Node.Id));
        Assert.Equal([20, 21, 22, 23], geometry.Transitions.Select(t => t.Node.Id));
        var move = geometry.Find(2)!;
        Assert.Equal(320, move.Bounds.X);
        Assert.Equal(new AnimationGraphHit(AnimationGraphHitKind.Node, 2), geometry.HitTest(new Vec2(400, 6)));
        Assert.Equal(new AnimationGraphHit(AnimationGraphHitKind.StateHandle, 2), geometry.HitTest(move.Handle));
        Assert.Equal(new AnimationGraphHit(AnimationGraphHitKind.MotionInput, 2), geometry.HitTest(move.MotionInput));
        Assert.Equal(new AnimationGraphHit(AnimationGraphHitKind.BlendOutput, 10), geometry.HitTest(geometry.Find(10)!.BlendOutput));
        Assert.Equal(AnimationGraphHitKind.None, geometry.HitTest(new Vec2(-2000, 0)).Kind);

        // A blend's output links to the state that plays it.
        var link = Assert.Single(geometry.Links);
        Assert.Equal((10, 2, geometry.Find(10)!.BlendOutput, move.MotionInput), (link.Blend, link.State, link.Start, link.End));

        // A transition's glyph and its arrow both find it.
        var there = geometry.FindTransition(20)!;
        Assert.Equal(new AnimationGraphHit(AnimationGraphHitKind.Transition, 20), geometry.HitTest(there.Middle));
        var onArrow = there.Start!.Value + (there.Middle - there.Start.Value) * 0.1;
        Assert.Equal(new AnimationGraphHit(AnimationGraphHitKind.Transition, 20), geometry.HitTest(onArrow));

        // An arrow and the one back are apart, and each starts at its from state and ends at its to state.
        var back = geometry.FindTransition(21)!;
        Assert.True((there.Middle - back.Middle).Length > 10);
        Assert.Equal(180, there.Start!.Value.X, 3);
        Assert.Equal(320, there.End!.Value.X, 3);
        Assert.Equal(320, back.Start!.Value.X, 3);
        Assert.Equal(180, back.End!.Value.X, 3);

        // From any state, there is an arrow only to its state.
        var any = geometry.FindTransition(23)!;
        Assert.Null(any.Start);
        Assert.NotNull(any.End);

        Assert.Contains(20, geometry.InBox(there.Middle - new Vec2(1, 1), there.Middle + new Vec2(1, 1)));
        Assert.Contains(1, geometry.InBox(new Vec2(10, 10), new Vec2(20, 20)));
        Assert.NotNull(geometry.Extent());
    }

    [Fact]
    public void NodesWithoutAPositionGetAPlaceThatIsNotWritten()
    {
        var text = "animation_graph 1\nentry = a\nnode 1 state\n\tname = a\nnode 2 state\n\tname = b\nnode 3 transition\n\tfrom = a\n\tto = nowhere\nnode 4 transition\n";
        var (shell, editor) = Open(text);
        using var _ = shell;
        var geometry = editor.Geometry();
        Assert.NotEqual(geometry.Find(1)!.Bounds.X, geometry.Find(2)!.Bounds.X);
        // A transition that names no state still has a glyph to select it by.
        Assert.Null(geometry.FindTransition(3)!.End);
        Assert.NotNull(geometry.FindTransition(3)!.Start);
        var lost = geometry.FindTransition(4)!;
        Assert.Null(lost.Start);
        Assert.Equal(new AnimationGraphHit(AnimationGraphHitKind.Transition, 4), geometry.HitTest(lost.Middle));
        Assert.False(editor.Document.IsDirty);
        Assert.Equal(text, editor.Document.Text);
    }

    [Fact]
    public void DraggingATransitionGivesItAPositionInOneUndoEntry()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        editor.Select([1, 20]);
        var starts = editor.MoveStarts();
        var middle = editor.Geometry().FindTransition(20)!.Middle;
        editor.BeginMove();
        editor.MoveSelected(starts, new Vec2(10, 20));
        editor.MoveSelected(starts, new Vec2(40, 60));
        editor.EndMove();

        Assert.Equal(["Move 2 Nodes"], editor.Document.History);
        Assert.Equal((40, 60), editor.Document.Graph.Find(1)!.Position);
        var moved = editor.Geometry().FindTransition(20)!;
        Assert.Equal(Math.Round(middle.X + 40), moved.Middle.X);
        Assert.Contains("node 20 transition\n\tposition = [", editor.Document.Text);

        editor.Document.Undo();
        Assert.Equal(Graph, editor.Document.Text);

        // Escape's cancel leaves nothing.
        editor.BeginMove();
        editor.MoveSelected(starts, new Vec2(5, 5));
        editor.EndMove(cancel: true);
        Assert.Equal(Graph, editor.Document.Text);
        Assert.Equal(0, editor.Document.Position);
        Assert.Single(editor.Document.History);
    }

    [Fact]
    public void NewNodesAreSelectedAndUndoOneEntryEach()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        var state = editor.AddState(40, 50);
        Assert.Equal([state], editor.Selection);
        Assert.Equal("state1", editor.Document.Graph.Find(state)!.Get("name"));
        Assert.Equal("survey", editor.Document.Graph.Find(state)!.Get("motion"));
        Assert.Equal((40, 50), editor.Document.Graph.Find(state)!.Position);
        Assert.Equal("state2", editor.Document.Graph.Find(editor.AddState(0, 0))!.Get("name"));

        var blend = editor.AddBlend(0, 0);
        Assert.Equal("speed", editor.Document.Graph.Find(blend)!.Get("parameter"));

        var transition = editor.AddTransition(1, state)!.Value;
        var added = editor.Document.Graph.Find(transition)!;
        Assert.Equal(("idle", "state1", "1", "0.25"), (added.Get("from"), added.Get("to"), added.Get("exit_time"), added.Get("duration")));
        Assert.Null(editor.AddTransition(1, 1));

        editor.LinkBlend(blend, state);
        Assert.Equal($"@{blend}.pose", editor.Document.Graph.Find(state)!.Get("motion"));
        Assert.Equal(5, editor.Document.History.Count);

        // A link dragged from one state to another moves in one entry, and one dropped on nothing is gone.
        editor.MoveBlendLink(blend, state, 1);
        Assert.Null(editor.Document.Graph.Find(state)!.Get("motion"));
        Assert.Equal($"@{blend}.pose", editor.Document.Graph.Find(1)!.Get("motion"));
        editor.MoveBlendLink(blend, 1, null);
        Assert.Null(editor.Document.Graph.Find(1)!.Get("motion"));
        // A drag that ends where it began, or that began on no state and ended on none, changes nothing.
        editor.MoveBlendLink(blend, null, null);
        Assert.Equal(7, editor.Document.History.Count);
        for (var i = 0; i < 7; i++)
        {
            editor.Document.Undo();
        }
        Assert.Equal(Graph, editor.Document.Text);
    }

    [Fact]
    public void DeletingAStateTakesItsTransitionsAndABlendLeavesItsStatesWithoutAMotion()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        editor.Select([3]);
        editor.DeleteSelected();
        var graph = editor.Document.Graph;
        Assert.Null(graph.Find(3));
        // Those to it go, from any state too, and the others stay.
        Assert.Equal([20, 21], graph.Nodes.Where(n => n.Kind == AnimationGraphNodeKind.Transition).Select(n => n.Id));
        Assert.Empty(editor.Selection);
        Assert.Single(editor.Document.History);

        editor.Select([10]);
        editor.DeleteSelected();
        Assert.Null(editor.Document.Graph.Find(2)!.Get("motion"));

        editor.Document.Undo();
        editor.Document.Undo();
        Assert.Equal(Graph, editor.Document.Text);
    }

    [Fact]
    public void RenamesReachWhatReadsTheName()
    {
        var (shell, editor) = Open();
        using var _ = shell;

        Assert.True(editor.RenameState(1, "stand"));
        var graph = editor.Document.Graph;
        Assert.Equal("stand", graph.Entry);
        Assert.Equal("stand", graph.Find(20)!.Get("from"));
        Assert.Equal("stand", graph.Find(21)!.Get("to"));
        Assert.Single(editor.Document.History);
        Assert.False(editor.RenameState(1, "any"));
        Assert.False(editor.RenameState(1, "move"));
        Assert.False(editor.RenameState(1, "not a name"));
        Assert.Single(editor.Document.History);

        // A parameter's name is the first word of a term, with a ! or not, and another word is not it.
        Assert.True(editor.SetParam("grounded", "landed", "bool", "true"));
        Assert.Equal("speed > 0.1 and !landed", editor.Document.Graph.Find(20)!.Get("when"));
        Assert.Equal("landed", editor.Document.Graph.Find(23)!.Get("when"));
        Assert.Equal("a > 1 and speed", AnimationGraphEditor.RenameInCondition("a > 1 and b", "b", "speed"));
        Assert.Equal("1 > b  and  c", AnimationGraphEditor.RenameInCondition("1 > b  and  c", "b", "speed"));
        Assert.True(editor.SetParam("speed", "pace", "float", "1"));
        Assert.Equal("pace", editor.Document.Graph.Find(10)!.Get("parameter"));
        Assert.False(editor.SetParam("pace", "look", "float", "1"));
        Assert.Contains("param landed bool true # set by the character\n", editor.Document.Text);

        // A clip's name is in the states and the blends that play it.
        Assert.True(editor.SetClip("survey", "scan", Survey));
        Assert.Equal("scan", editor.Document.Graph.Find(3)!.Get("motion"));
        Assert.Equal("scan", editor.Document.Graph.Find(10)!.Get("input.0"));
        Assert.False(editor.SetClip("scan", "walk", Survey));
        Assert.Contains("\tevent 0.5 footstep \"left\"\n", editor.Document.Text);
    }

    [Fact]
    public void ATransitionsOrderIsAmongThoseWithItsFrom()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        Assert.Equal([21, 22], editor.Siblings(22).Select(n => n.Id));
        editor.MoveTransition(22, -1);
        Assert.Equal([22, 21], editor.Siblings(22).Select(n => n.Id));
        // The first cannot go earlier.
        editor.MoveTransition(22, -1);
        Assert.Single(editor.Document.History);
        editor.Document.Undo();
        Assert.Equal(Graph, editor.Document.Text);

        // From any state, a transition has no exit time.
        editor.SetField(21, "exit_time", "0.5");
        editor.SetTransitionFrom(21, "any");
        Assert.Null(editor.Document.Graph.Find(21)!.Get("exit_time"));
        Assert.Equal("any", editor.Document.Graph.Find(21)!.Get("from"));
    }

    [Fact]
    public void ABlendsInputsStayNumberedWithoutAGap()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        editor.AddBlendInput(10);
        var blend = editor.Document.Graph.Find(10)!;
        Assert.Equal([(0, "survey", "1"), (1, "walk", "3"), (2, "survey", "4")], AnimationGraphEditor.InputsOf(blend));

        editor.RemoveBlendInput(10, 0);
        blend = editor.Document.Graph.Find(10)!;
        Assert.Equal([(0, "walk", "3"), (1, "survey", "4")], AnimationGraphEditor.InputsOf(blend));
        Assert.Contains("\tinput.0 = walk\n\tat.0 = 3\n\tinput.1 = survey\n\tat.1 = 4\n", editor.Document.Text);
    }

    static byte[] Bytes(string guid) => Convert.FromHexString(guid);

    static AnimatorView View(ulong entity, string graph = Guid, uint state = 2, uint source = 1, uint transition = 20, float fade = 0.1f, float duration = 0.4f) =>
        new(entity, Bytes(graph), state, source, transition, fade, duration, 1.25f,
            [new AnimatorParameter("speed", AnimatorParameterKind.Float, 2), new AnimatorParameter("look", AnimatorParameterKind.Trigger, 0)]);

    [Fact]
    public void WhileTheGamePlaysTheSelectedEntitysAnimatorIsLive()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        var changes = 0;
        editor.LiveChanged += () => changes++;
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(1, "Fox", 1, 0, true, []), new EntityInfo(2, "Other", 2, 0, true, [])]));
        shell.OnGameMessage(View(1));

        // In Edit, there is nothing to show or to wait for.
        Assert.Null(editor.Live);
        Assert.Null(editor.LiveWaiting);

        shell.Play();
        Assert.Null(editor.Live);
        Assert.Contains("Select an entity", editor.LiveWaiting);

        shell.Selection.Select(2);
        Assert.Contains("Other has no Animator", editor.LiveWaiting);

        changes = 0;
        shell.Selection.Select(1);
        Assert.Equal(1, changes);
        var live = editor.Live;
        Assert.NotNull(live);
        Assert.Equal((2u, 1u, 20u), (live.State, live.Source, live.Transition));
        Assert.Null(editor.LiveWaiting);
        Assert.Equal(0.25, AnimationGraphEditor.FadeOf(live), 3);
        Assert.Equal(1, AnimationGraphEditor.FadeOf(View(1, fade: 0.4f)));
        Assert.Equal(1, AnimationGraphEditor.FadeOf(View(1, fade: 0, duration: 0)));

        // Only the selected entity's view changes it.
        changes = 0;
        shell.OnGameMessage(View(2));
        Assert.Equal(0, changes);
        shell.OnGameMessage(View(1, state: 3, source: 2, transition: 22));
        Assert.Equal(1, changes);
        Assert.Equal(3u, editor.Live!.State);

        // Another graph's Animator is not this graph's to show, and the panel says what it plays.
        shell.OnGameMessage(View(1, graph: Survey));
        Assert.Null(editor.Live);
        Assert.Contains($"Fox plays {Survey}", editor.LiveWaiting);

        // An empty view says that the Animator has gone.
        shell.OnGameMessage(new AnimatorView(1, new byte[16], 0, 0, 0, 0, 0, 0, []));
        Assert.Null(shell.World.Animator(1));
        Assert.Contains("Fox has no Animator", editor.LiveWaiting);

        // A view of an entity that has gone stays gone, and so does one that it had.
        shell.OnGameMessage(View(1));
        Assert.NotNull(shell.World.Animator(1));
        shell.OnGameMessage(new EntityDelta([], [1]));
        Assert.Null(shell.World.Animator(1));
        shell.OnGameMessage(View(1));
        Assert.Null(shell.World.Animator(1));

        // Sending with no host is nothing, and so is a parameter with no live view.
        editor.SetLiveParameter("speed", 1);

        shell.Stop();
        Assert.Null(editor.LiveWaiting);
    }

    [Fact]
    public void AParametersSliderCoversWhatTheGraphComparesItWith()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        // The blend's inputs are at 1 and 3, the conditions read 0.1 and 0.05, and 0 to 1 is the least.
        Assert.Equal((0, 3), editor.RangeOf("speed", 0));
        // What it holds now is in the range too.
        Assert.Equal((0, 5), editor.RangeOf("speed", 5));
        Assert.Equal((-2, 3), editor.RangeOf("speed", -2));
        Assert.Equal((0, 1), editor.RangeOf("grounded", 1));
    }

    static PreviewResult Answer(string file, params (uint Line, string Text)[] problems) =>
        new(problems.Length == 0 ? "" : problems[0].Text, [.. problems.Select(p => new Problem(file, p.Line, 0, true, p.Text))]);

    [Fact]
    public void TheCheckersProblemsGoOnTheirNodes()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        var path = editor.Document.Path.Replace('\\', '/');
        var lines = Graph.Split('\n').ToList();
        var move = lines.IndexOf("node 21 transition") + 1;
        var param = lines.IndexOf("param look trigger") + 1;
        var raised = 0;
        editor.ProblemsChanged += () => raised++;

        editor.ShowProblems(editor.Document.Text, Answer(path, ((uint)move + 2, "there is no state named x"), ((uint)param, "another parameter is named look"), (1, "an animation graph has a state at least")));
        Assert.Equal(1, raised);
        Assert.Equal(21, editor.Problems[0].Node);
        // A line of a parameter is on no node, and keeps its line for the panel's row.
        Assert.Null(editor.Problems[1].Node);
        Assert.Same(editor.Document.Graph.Params.Last(), editor.Document.Graph.BlockAt(editor.Problems[1].Line));
        Assert.Null(editor.Problems[2].Node);
        Assert.Equal("there is no state named x", editor.CookError);

        // A problem in another file says where, and is on no node.
        editor.ShowProblems(editor.Document.Text, Answer("C:/elsewhere/other.animation_graph", (9, "broken")));
        Assert.Equal("other.animation_graph:9: broken", Assert.Single(editor.Problems).Text);
        Assert.Null(editor.Problems[0].Node);

        // An answer about a text that has changed since names the wrong lines, so it waits for the next.
        var old = editor.Document.Text;
        editor.AddState(0, 0);
        editor.ShowProblems(old, Answer(path, (3, "stale")));
        Assert.DoesNotContain(editor.Problems, p => p.Text.Contains("stale"));

        // The next answer clears them.
        editor.ShowProblems(editor.Document.Text, Answer(path));
        Assert.Empty(editor.Problems);
        Assert.Null(editor.CookError);
    }

    [Fact]
    public void AClipThatNamesNoAnimationIsAWarningOnItsLine()
    {
        var (shell, editor) = Open();
        using var _ = shell;
        // Before the index comes, no clip can be looked up.
        Assert.Empty(editor.Problems);

        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], []));
        shell.Assets.Apply(new AssetSnapshot(
        [
            new Asset(Survey, AssetKind.Animation, "game", "fox.gltf", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", [], ""),
            new Asset(Walk, AssetKind.Texture, "game", "walk.png", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", [], ""),
        ], []));
        var problem = Assert.Single(editor.Problems);
        Assert.False(problem.Error);
        Assert.Contains("walk", problem.Text);
        Assert.Same(editor.Document.Graph.Clips.Last(), editor.Document.Graph.BlockAt(problem.Line));

        var added = editor.AddClip();
        Assert.Contains(editor.Problems, p => p.Text == $"the clip {added} has no animation");
        Assert.Contains($"clip {added} = $00000000000000000000000000000000\n", editor.Document.Text);
    }
}
