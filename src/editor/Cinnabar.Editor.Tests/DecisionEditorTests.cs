using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>The decision editor and the blackboard editor, driven without a window.</summary>
public sealed class DecisionEditorTests : IDisposable
{
    const string Guard = "0123456789abcdef0123456789abcdef";
    const string Sniper = "11111111111111111111111111111111";
    const string Other = "22222222222222222222222222222222";
    const string Board = "33333333333333333333333333333333";
    const string OtherBoard = "44444444444444444444444444444444";

    static string Tree(string board = Board) => $"""
        decision 1
        technique = behavior_tree
        blackboard = ${board}

        node 1 selector
        	position = [0, 0]
        	children = 2
        node 2 action
        	position = [0, 150]
        	when = target != none
        	action = attack(at = target)

        """.ReplaceLineEndings("\n");

    const string Blackboard = "blackboard 1\nfloat health = 100\nentity target\nposition last_seen\nenum mood (calm, alert) = calm\n";

    readonly TempDirectory _temp = new("decision-editor");

    public void Dispose() => _temp.Dispose();

    // A shell whose index has the guard's decision and blackboard, a sniper's decision of the same blackboard, and a
    // decision of another blackboard that reads a key of the same name.
    (EditorShell Shell, Asset Guard, Asset Board) Setup()
    {
        var shell = TestShell.Open(_temp, null, null);
        File.WriteAllText(_temp.Combine("guard.decision"), Tree());
        File.WriteAllText(_temp.Combine("sniper.decision"), Tree());
        File.WriteAllText(_temp.Combine("other.decision"), Tree(OtherBoard));
        File.WriteAllText(_temp.Combine("guard.blackboard"), Blackboard);
        File.WriteAllText(_temp.Combine("other.blackboard"), Blackboard);
        Asset[] assets =
        [
            TestAssets.Make(Guard, AssetKind.Decision, "guard.decision"),
            TestAssets.Make(Sniper, AssetKind.Decision, "sniper.decision"),
            TestAssets.Make(Other, AssetKind.Decision, "other.decision"),
            TestAssets.Make(Board, AssetKind.Blackboard, "guard.blackboard"),
            TestAssets.Make(OtherBoard, AssetKind.Blackboard, "other.blackboard"),
            TestAssets.Make("55555555555555555555555555555555", AssetKind.Script, "bark.luau", action: "bark",
                @params: [new ActionParam("at", ActionParamKind.Entity), new ActionParam("line", ActionParamKind.String)]),
        ];
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        shell.Assets.Apply(new AssetSnapshot(assets, []));
        return (shell, assets[0], assets[3]);
    }

    DecisionEditor OpenGuard(EditorShell shell, Asset guard)
    {
        shell.OpenAsset(guard);
        return Assert.Single(shell.Decisions);
    }

    [Fact]
    public void ADecisionOpensInItsEditorWithoutChanging()
    {
        var (shell, guard, board) = Setup();
        using var _ = shell;
        Assert.Equal("Open in Decision Editor", shell.OpenLabel(guard));
        var editor = OpenGuard(shell, guard);
        Assert.Same(editor, shell.ActiveDecision);
        Assert.Contains(editor, shell.GraphEditors);
        Assert.False(editor.Document.IsDirty);
        Assert.Equal(Tree(), editor.Document.Text);
        // Opening it again shows the same editor.
        shell.OpenAsset(guard);
        Assert.Single(shell.Decisions);
        Assert.Equal(["health", "target", "last_seen", "mood"], editor.Keys.Select(k => k.Name));
        Assert.Equal(["guard.blackboard", "other.blackboard"], editor.Blackboards.Select(Cinnabar.Editor.Content.AssetIndex.DisplayName));

        // A blackboard opens in its own editor, and the decision reads its keys as the editor has them.
        shell.OpenAsset(board);
        var blackboard = Assert.Single(shell.Blackboards);
        blackboard.AddKey("bool");
        Assert.Contains("bool1", editor.Keys.Select(k => k.Name));
    }

    [Fact]
    public void ATreeIsMadeFromTheAddMenuAndAFootsDragAndEachStepUndoes()
    {
        var (shell, guard, _) = Setup();
        using var _ = shell;
        var editor = OpenGuard(shell, guard);
        // Undo reads the text again, so the file is the document's at each step.
        DecisionFile file() => editor.Document.Graph;

        // A new node is selected, and a drag from a foot to an empty place makes it that composite's child.
        var wait = editor.AddPicked("wait", new Vec2(200, 150), parent: 1);
        Assert.Equal(3, wait);
        Assert.Equal([3], editor.Selection);
        Assert.Equal([2, 3], file().Find(1)!.Ids("children"));
        Assert.Equal("1", file().Find(3)!.Get("seconds"));

        // A sequence of its own is a second root until a drag from the selector's foot makes it a child, among its
        // siblings by its place from left to right.
        var sequence = editor.AddPicked("sequence", new Vec2(-200, 150));
        Assert.Null(editor.ParentOf(sequence));
        Assert.True(editor.AddChild(1, sequence));
        Assert.Equal([4, 2, 3], file().Find(1)!.Ids("children"));
        // The wait moves to the sequence: it leaves the selector, in the same entry.
        Assert.True(editor.AddChild(sequence, wait));
        Assert.Equal([4, 2], file().Find(1)!.Ids("children"));
        Assert.Equal([3], file().Find(4)!.Ids("children"));
        // A leaf has no children, and a node is not a child of one below it.
        Assert.False(editor.AddChild(2, 1));
        Assert.False(editor.AddChild(sequence, 1));
        Assert.False(editor.AddChild(sequence, sequence));

        editor.Document.Undo();
        Assert.Equal([4, 2, 3], file().Find(1)!.Ids("children"));
        editor.Document.Undo();
        Assert.Equal([2, 3], file().Find(1)!.Ids("children"));
        editor.Document.Undo();
        Assert.Null(file().Find(4));
        editor.Document.Undo();
        Assert.Equal(Tree(), editor.Document.Text);
        Assert.False(editor.Document.IsDirty);
    }

    [Fact]
    public void DraggingANodeAmongItsSiblingsReordersThemInOneEntry()
    {
        var (shell, guard, _) = Setup();
        using var _ = shell;
        var editor = OpenGuard(shell, guard);
        DecisionFile file() => editor.Document.Graph;
        editor.AddPicked("wait", new Vec2(200, 150), parent: 1);
        var before = editor.Document.Text;

        editor.Select([3]);
        var starts = editor.MoveStarts();
        editor.BeginMove();
        editor.MoveSelected(starts, new Vec2(-150, 0));
        editor.MoveSelected(starts, new Vec2(-400, 10));
        editor.EndMove();
        Assert.Equal([3, 2], file().Find(1)!.Ids("children"));
        Assert.Equal((-200.0, 160.0), file().Find(3)!.Position);

        editor.Document.Undo();
        Assert.Equal(before, editor.Document.Text);
        // A cancelled drag changes nothing.
        starts = editor.MoveStarts();
        editor.BeginMove();
        editor.MoveSelected(starts, new Vec2(-400, 0));
        editor.EndMove(cancel: true);
        Assert.Equal(before, editor.Document.Text);
    }

    [Fact]
    public void DeletingANodeTakesItOutOfItsParentsChildren()
    {
        var (shell, guard, _) = Setup();
        using var _ = shell;
        var editor = OpenGuard(shell, guard);
        editor.Select([2]);
        editor.DeleteSelected();
        Assert.Null(editor.Document.Graph.Find(2));
        Assert.Null(editor.Document.Graph.Find(1)!.Get("children"));
        Assert.Empty(editor.Selection);
        editor.Document.Undo();
        Assert.Equal(Tree(), editor.Document.Text);
    }

    [Fact]
    public void RenamingAKeyRenamesItInTheDecisionsThatReadItWithAnEntryInEach()
    {
        var (shell, guard, board) = Setup();
        using var _ = shell;
        var open = OpenGuard(shell, guard);
        var blackboard = shell.OpenBlackboard(board)!;
        // The other decision names another blackboard, so it is not among them.
        Assert.Equal(["guard.decision", "sniper.decision"], blackboard.DecisionsReading("target").Select(a => a.Path));
        Assert.Empty(blackboard.DecisionsReading("health"));
        Assert.False(blackboard.CanRename("target", "mood"));
        Assert.False(blackboard.RenameKey("target", "2nd"));

        Assert.True(blackboard.RenameKey("target", "enemy"));
        Assert.Contains("entity enemy\n", blackboard.Document.Text);
        // The closed decision opens, and both stay unsaved, with one entry each.
        Assert.Equal(2, shell.Decisions.Count);
        foreach (var editor in shell.Decisions)
        {
            Assert.True(editor.Document.IsDirty);
            Assert.Equal(Tree().Replace("target", "enemy"), editor.Document.Text);
            editor.Document.Undo();
            Assert.Equal(Tree(), editor.Document.Text);
            Assert.False(editor.Document.CanUndo);
        }
        Assert.Equal(Tree(OtherBoard), File.ReadAllText(_temp.Combine("other.decision")));
        Assert.Equal(Tree(), File.ReadAllText(_temp.Combine("sniper.decision")));
        blackboard.Document.Undo();
        Assert.Equal(Blackboard, blackboard.Document.Text);
        Assert.Same(open, shell.Decisions[0]);
    }

    [Fact]
    public void TheBlackboardEditorsKeysAreEditedAndEachStepUndoes()
    {
        var (shell, _, board) = Setup();
        using var _ = shell;
        var editor = shell.OpenBlackboard(board)!;
        Assert.Equal("float1", editor.AddKey("float"));
        editor.SetKey("mood", "enum", ["calm", "alert", "angry"], "angry");
        editor.MoveKey("float1", -1);
        editor.RemoveKey("last_seen");
        Assert.Equal("blackboard 1\nfloat health = 100\nentity target\nfloat float1\nenum mood (calm, alert, angry) = angry\n", editor.Document.Text);
        for (var i = 0; i < 4; i++)
        {
            editor.Document.Undo();
        }
        Assert.Equal(Blackboard, editor.Document.Text);

        // A problem goes on its key's row.
        editor.ShowProblems(editor.Document.Text, new PreviewResult("bad", [new Problem(editor.Document.Path, 5, 0, true, "the enum mood has the value calm twice")], []));
        Assert.Single(editor.ProblemsOf(editor.Find("mood")!));
        Assert.Empty(editor.ProblemsOf(editor.Find("health")!));
    }

    [Fact]
    public void TheCheckersProblemsGoOnTheirNodes()
    {
        var (shell, guard, _) = Setup();
        using var _ = shell;
        var editor = OpenGuard(shell, guard);
        var path = editor.Document.Path;
        editor.ShowProblems(editor.Document.Text, new PreviewResult("bad",
        [
            new Problem(path, 9, 0, true, "the blackboard has no key named target"),
            new Problem(path, 3, 0, true, "no asset has the GUID"),
        ], []));
        Assert.Equal(new int?[] { 2, null }, editor.Problems.Select(p => p.Node));
        Assert.Equal("bad", editor.CookError);
        // An answer about a text that has changed since is dropped.
        editor.SetField(2, "cooldown", "1");
        editor.ShowProblems(Tree(), new PreviewResult("", [], []));
        Assert.Equal(2, editor.Problems.Count);
    }

    [Fact]
    public void TheAddMenuHasTheGamesAndTheScriptsActions()
    {
        var (shell, guard, _) = Setup();
        using var _ = shell;
        var editor = OpenGuard(shell, guard);
        shell.OnGameMessage(new AgentActions([new AgentActionInfo("move_to", [new AgentActionParam("key", AgentKind.String)]), new AgentActionInfo("stop", [])]));
        Assert.Equal(["bark", "move_to", "stop"], editor.Actions.Select(a => a.Name));
        Assert.Equal([("at", "entity"), ("line", "string")], editor.Actions[0].Params);
        Assert.True(editor.Actions[0].Script);
        var picks = editor.Picks().ToList();
        Assert.Equal(["sequence", "selector", "parallel", "action", "wait", "set", "condition"], picks.Take(7).Select(p => p.Kind));
        Assert.Contains(picks, p => p.Kind == "action:move_to" && p.Category == "Native action");

        var id = editor.AddPicked("action:bark", new Vec2(0, 300), parent: 1);
        Assert.Equal("bark", editor.Document.Graph.Find(id)!.Get("action"));
        Assert.Equal("bark", editor.Label(id));
        // An argument is a constant or a key of a type that fits the parameter.
        Assert.True(DecisionEditor.Fits("entity", "entity"));
        Assert.True(DecisionEditor.Fits("number", "int"));
        Assert.False(DecisionEditor.Fits("position", "vector"));
        Assert.True(DecisionEditor.Fits("string", "enum"));
    }

    [Fact]
    public void AConditionsBoxCompletesTheKeyAtItsEnd()
    {
        Assert.True(DecisionEditor.Completes("health < 3 and tar", "target"));
        Assert.False(DecisionEditor.Completes("health < 3 and ", "target"));
        Assert.False(DecisionEditor.Completes("target", "target"));
        Assert.Equal("health < 3 and target", DecisionEditor.Complete("health < 3 and tar", "target"));
    }

    static AgentView View(ulong entity, string decision = Guard, bool running = true) =>
        new(entity, Convert.FromHexString(decision),
            [new AgentNode(1, running, AgentResult.None), new AgentNode(2, running, AgentResult.Failed)],
            [new AgentValue("health", AgentKind.Float, "100"), new AgentValue("target", AgentKind.Entity, "#3:1")], [], []);

    [Fact]
    public void WhileTheGamePlaysTheSelectedEntitysAgentIsLive()
    {
        var (shell, guard, _) = Setup();
        using var _ = shell;
        var editor = OpenGuard(shell, guard);
        var changes = 0;
        editor.LiveChanged += () => changes++;
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(1, "Guard", 1, 0, true, []), new EntityInfo(2, "Crate", 2, 0, true, [])]));
        shell.OnGameMessage(View(1));
        Assert.Null(editor.Live);
        Assert.Null(editor.LiveWaiting);

        shell.Play();
        Assert.Contains("Select an entity", editor.LiveWaiting);
        shell.Selection.Select(2);
        Assert.Contains("Crate has no Agent", editor.LiveWaiting);
        changes = 0;
        shell.Selection.Select(1);
        Assert.Equal(1, changes);
        Assert.Equal([1u, 2u], editor.Live!.Nodes.Where(n => n.Running).Select(n => n.Id));
        Assert.Equal("#3:1", editor.Live.Values[1].Text);

        shell.OnGameMessage(View(1, Sniper));
        Assert.Null(editor.Live);
        Assert.Contains("Guard runs sniper", editor.LiveWaiting);
        // An empty view says that the agent has gone.
        shell.OnGameMessage(new AgentView(1, new byte[16], [], [], [], []));
        Assert.Null(shell.World.Agent(1));
        shell.Stop();
        Assert.Null(editor.LiveWaiting);
    }

    [Fact]
    public void ATreeIsLaidOutFromTheTopDownWhereItHasNoPositions()
    {
        var (file, _) = DecisionFile.Parse("decision 1\nnode 1 selector\n\tchildren = 2, 3\nnode 2 sequence\n\tchildren = 4, 5\nnode 3 wait\n\twhen = a\n\tseconds = 1\nnode 4 action\nnode 5 action\nnode 6 condition\n");
        var geometry = BehaviorTreeGeometry.Of(file!);
        var x = geometry.Nodes.ToDictionary(n => n.Node.Id, n => (n.Bounds.X, n.Bounds.Y));
        // Leaves in their order, each composite over its children's middle, and a second root after the first tree.
        Assert.Equal((0.0, 2 * BehaviorTreeGeometry.Down), x[4]);
        Assert.Equal((BehaviorTreeGeometry.Across, 2 * BehaviorTreeGeometry.Down), x[5]);
        Assert.Equal((BehaviorTreeGeometry.Across / 2, BehaviorTreeGeometry.Down), x[2]);
        Assert.Equal((2 * BehaviorTreeGeometry.Across, BehaviorTreeGeometry.Down), x[3]);
        Assert.Equal(((BehaviorTreeGeometry.Across / 2 + 2 * BehaviorTreeGeometry.Across) / 2, 0.0), x[1]);
        Assert.Equal((3 * BehaviorTreeGeometry.Across, 0.0), x[6]);
        Assert.Equal([(1, 2, 1), (1, 3, 2), (2, 4, 1), (2, 5, 2)], geometry.Edges.Select(e => (e.Parent, e.Child, e.Order)));
        // Decorators are bands, and a composite's foot is what a press takes under it.
        var wait = geometry.Find(3)!;
        Assert.Equal(["when a"], wait.Bands);
        Assert.Equal(["1 s"], wait.Rows);
        var foot = geometry.Find(1)!.Foot;
        Assert.Equal(new TreeHit(TreeHitKind.Foot, 1), geometry.HitTest(new Vec2(foot.X + 1, foot.Y + 1)));
        Assert.Equal(new TreeHit(TreeHitKind.Node, 3), geometry.HitTest(new Vec2(wait.Bounds.X + 1, wait.Bounds.Y + 1)));
        Assert.Equal(new TreeHit(TreeHitKind.None), geometry.HitTest(new Vec2(-500, -500)));
        Assert.Equal([4, 5], geometry.InBox(new Vec2(-10, 2 * BehaviorTreeGeometry.Down - 10), new Vec2(400, 2 * BehaviorTreeGeometry.Down + 5)));
    }
}
