using Cinnabar.Editor.Decisions;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>The decision editor's utility, GOAP and HTN views, driven without a window, on the cooker's test decisions.</summary>
public sealed class DecisionViewsTests : IDisposable
{
    // The blackboard that the cooker's test decisions name.
    const string Board = "0123456789abcdef0123456789abcdef";
    const string Utility = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1";
    const string Goap = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2";
    const string Htn = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3";

    readonly TempDirectory _temp = new("decision-views");

    public void Dispose() => _temp.Dispose();

    static string Corpus(string file) =>
        File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "tools", "cook", "testdata", "decisions", file)).ReplaceLineEndings("\n");

    EditorShell Setup()
    {
        var shell = TestShell.Open(_temp, null, null);
        foreach (var name in new[] { "utility", "goap", "htn" })
        {
            File.WriteAllText(_temp.Combine(name + ".decision"), Corpus(name + ".decision"));
        }
        File.WriteAllText(_temp.Combine("guard.blackboard"), Corpus("guard.blackboard"));
        Asset[] assets =
        [
            TestAssets.Make(Utility, AssetKind.Decision, "utility.decision"),
            TestAssets.Make(Goap, AssetKind.Decision, "goap.decision"),
            TestAssets.Make(Htn, AssetKind.Decision, "htn.decision"),
            TestAssets.Make(Board, AssetKind.Blackboard, "guard.blackboard"),
        ];
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        shell.Assets.Apply(new AssetSnapshot(assets, []));
        return shell;
    }

    static DecisionEditor Open(EditorShell shell, string guid)
    {
        shell.OpenAsset(shell.Assets.Find(guid)!);
        return shell.Decisions.Single(d => d.Guid == guid);
    }

    [Theory]
    [InlineData(Utility, "utility")]
    [InlineData(Goap, "goap")]
    [InlineData(Htn, "htn")]
    public void EachTechniqueOpensInItsViewWithoutChanging(string guid, string name)
    {
        using var shell = Setup();
        var editor = Open(shell, guid);
        Assert.Equal(name, editor.Technique);
        // What the views read of the file: the geometry, what the cards show, and the plan preview's query and keys.
        var geometry = editor.Geometry();
        _ = UtilityView.Shown(editor.Document.Graph);
        _ = editor.PlanningKeys;
        _ = editor.PlanQuery();
        foreach (var node in editor.Document.Graph.Nodes)
        {
            _ = DecisionNodeDetails.FieldsOf(editor.Technique, node.Kind);
            if (node.Kind == "consideration")
            {
                _ = ResponseCurve.Of(node).Handles();
            }
        }
        Assert.Equal(Corpus(name + ".decision"), editor.Document.Text);
        Assert.False(editor.Document.IsDirty);
        Assert.Equal(name == "htn", geometry.Edges.Count > 0);
    }

    [Fact]
    public void AConsiderationsCurveIsMadeDraggedTypedAndUndone()
    {
        using var shell = Setup();
        var editor = Open(shell, Utility);
        DecisionFile file() => editor.Document.Graph;
        string? field(int id, string key) => file().Find(id)!.Get(key);

        // Patrol, option 3, has no considerations; a new one is linear, and listed by it.
        var id = editor.AddConsideration(3);
        Assert.Equal(7, id);
        Assert.Equal([7], file().Find(3)!.Ids("considerations"));
        Assert.Equal("linear", field(id, "curve"));
        editor.SetField(id, "input", "health");
        editor.SetField(id, "range", "[0, 100]");

        // A polynomial bends by its exponent: a drag of its bend handle is one entry, however many steps it takes.
        editor.SetCurveKind(id, "polynomial");
        var curve = ResponseCurve.Of(file().Find(id)!);
        var bend = curve.Handles().Single(h => h.Kind == CurveHandleKind.Bend);
        Assert.Equal(new Vec2(0.5, 0.5), bend.At);
        var before = editor.Document.Text;
        editor.BeginFieldDrag("Drag Bend");
        editor.DragFields(id, curve.Drag(bend, new Vec2(0.5, 0.4)));
        editor.DragFields(id, curve.Drag(bend, new Vec2(0.5, 0.25)));
        editor.EndFieldDrag();
        Assert.Equal("2", field(id, "exponent"));
        Assert.Equal(0.25, ResponseCurve.Of(file().Find(id)!).Evaluate(0.5), 6);
        editor.Document.Undo();
        Assert.Equal(before, editor.Document.Text);
        editor.Document.Redo();
        Assert.Equal("2", field(id, "exponent"));

        // The origin moves the shifts, the end sets the slope, and Escape puts a drag back.
        curve = ResponseCurve.Of(file().Find(id)!);
        editor.BeginFieldDrag("Drag Origin");
        editor.DragFields(id, curve.Drag(curve.Handles().Single(h => h.Kind == CurveHandleKind.Origin), new Vec2(0.2, 0.1)));
        editor.EndFieldDrag();
        Assert.Equal(("0.2", "0.1"), (field(id, "x_shift"), field(id, "y_shift")));
        curve = ResponseCurve.Of(file().Find(id)!);
        editor.BeginFieldDrag("Drag End");
        editor.DragFields(id, curve.Drag(curve.Handles().Single(h => h.Kind == CurveHandleKind.End), new Vec2(1, 0.5)));
        editor.EndFieldDrag(cancel: true);
        Assert.Null(field(id, "slope"));
        editor.BeginFieldDrag("Drag End");
        editor.DragFields(id, curve.Drag(curve.Handles().Single(h => h.Kind == CurveHandleKind.End), new Vec2(1, 0.5)));
        editor.EndFieldDrag();
        Assert.Equal(0.5, ResponseCurve.Of(file().Find(id)!).Evaluate(1), 3);

        // A typed field is an entry of its own.
        editor.SetField(id, "slope", "-1");
        Assert.Equal("-1", field(id, "slope"));
        editor.Document.Undo();
        Assert.NotEqual("-1", field(id, "slope"));

        // A table starts as a line, gains a point by a double click and loses one by a right click, and a linear curve
        // drops the exponent and the points that it does not take.
        editor.SetCurveKind(id, "table");
        Assert.Equal("[0, 0], [1, 1]", field(id, "points"));
        editor.SetField(id, "points", ResponseCurve.Of(file().Find(id)!).AddPoint(0.7));
        Assert.Equal(3, ResponseCurve.Of(file().Find(id)!).Points.Count);
        editor.SetField(id, "points", ResponseCurve.Of(file().Find(id)!).RemovePoint(1));
        Assert.Equal(2, ResponseCurve.Of(file().Find(id)!).Points.Count);
        Assert.Null(ResponseCurve.Of(file().Find(id)!).RemovePoint(0));
        editor.SetCurveKind(id, "linear");
        Assert.Null(field(id, "points"));
        Assert.Null(field(id, "exponent"));

        // Taking it out of the option and deleting it are entries too.
        editor.Delete(id);
        Assert.Null(file().Find(id));
        Assert.Empty(file().Find(3)!.Ids("considerations"));
        editor.Document.Undo();
        Assert.Equal([7], file().Find(3)!.Ids("considerations"));
        editor.RemoveFromList(3, "considerations", 7);
        Assert.NotNull(file().Find(7));
        Assert.Empty(file().Find(3)!.Ids("considerations"));
    }

    [Fact]
    public void AGoapActionAndGoalAreMadeEditedAndUndone()
    {
        using var shell = Setup();
        var editor = Open(shell, Goap);
        DecisionFile file() => editor.Document.Graph;
        var start = editor.Document.Text;

        var action = editor.AddPicked("action:reload", new Vec2(0, 0));
        Assert.Equal(21, action);
        Assert.Equal("reload", file().Find(action)!.Get("action"));
        editor.SetField(action, "preconditions", "armed and ammo < 5");
        editor.SetField(action, "effects", "ammo += 6");
        editor.SetField(action, "cost", "travel_cost");
        Assert.Equal("ammo += 6", file().Find(action)!.Get("effects"));

        var goal = editor.AddNode("goal", 0, 0);
        editor.SetField(goal, "desired", "armed");
        editor.SetField(goal, "priority", "3");
        var consideration = editor.AddConsideration(goal);
        Assert.Equal([consideration], file().Find(goal)!.Ids("considerations"));
        Assert.Equal("3", file().Find(goal)!.Get("priority"));

        // Each edit is an entry.
        editor.Document.Undo();
        Assert.Empty(file().Find(goal)!.Ids("considerations"));
        editor.Document.Undo();
        Assert.Null(file().Find(goal)!.Get("priority"));
        for (var i = 0; i < 6; i++)
        {
            editor.Document.Undo();
        }
        Assert.Equal(start, editor.Document.Text);

        // A delete takes a consideration out of the goal that lists it.
        editor.Delete(20);
        Assert.Empty(file().Find(1)!.Ids("considerations"));
    }

    [Fact]
    public void AnHtnMethodIsMadeLinkedReorderedDeletedAndUndone()
    {
        using var shell = Setup();
        var editor = Open(shell, Htn);
        DecisionFile file() => editor.Document.Graph;
        var start = editor.Document.Text;

        // The domain is a tree from the root: task 1's methods, in order, and method 7's subtasks.
        var geometry = editor.Geometry();
        Assert.Equal([(1, 2, 1), (1, 3, 2), (1, 4, 3)], geometry.Edges.Where(e => e.Parent == 1).Select(e => (e.Parent, e.Child, e.Order)));
        Assert.Equal([14, 13], geometry.Edges.Where(e => e.Parent == 7).Select(e => e.Child));
        Assert.True(geometry.Find(1)!.HasFoot);
        Assert.False(geometry.Find(10)!.HasFoot);
        Assert.Equal(TreeHitKind.Foot, geometry.HitTest(geometry.Find(1)!.Bottom - new Vec2(0, 2)).Kind);

        // A drag from the root's foot to an empty place adds a method, the task's last.
        var method = editor.AddPicked("method", new Vec2(2000, 150), parent: 1);
        Assert.Equal([2, 3, 4, method], file().Find(1)!.Ids("methods"));
        // A task lists methods, and a method lists tasks and actions.
        Assert.False(editor.AddChild(1, 10));
        Assert.False(editor.AddChild(method, 2));
        Assert.False(editor.AddChild(10, 13));
        // A subtask may be several methods': aim stays in methods 6 and 7.
        Assert.True(editor.AddChild(method, 13));
        Assert.Equal([13], file().Find(method)!.Ids("subtasks"));
        Assert.Contains(13, file().Find(6)!.Ids("subtasks"));
        Assert.Contains(13, file().Find(7)!.Ids("subtasks"));
        // A task may recur.
        Assert.True(editor.AddChild(method, 1));
        Assert.Equal(new HashSet<int> { 13, 1 }, file().Find(method)!.Ids("subtasks").ToHashSet());
        // A method has one task, so it leaves task 1 for task 5.
        Assert.True(editor.AddChild(5, method));
        Assert.DoesNotContain(method, file().Find(1)!.Ids("methods"));
        Assert.Contains(method, file().Find(5)!.Ids("methods"));
        editor.Document.Undo();
        Assert.Contains(method, file().Find(1)!.Ids("methods"));

        // A move past a sibling reorders the methods, in the move's entry.
        editor.Select([method]);
        var starts = editor.MoveStarts();
        editor.BeginMove();
        editor.MoveSelected(starts, new Vec2(-5000, 0));
        editor.EndMove();
        Assert.Equal([method, 2, 3, 4], file().Find(1)!.Ids("methods"));
        editor.Document.Undo();
        Assert.Equal([2, 3, 4, method], file().Find(1)!.Ids("methods"));

        // A delete takes an action out of every method that lists it.
        editor.Delete(13);
        Assert.DoesNotContain(13, file().Find(6)!.Ids("subtasks"));
        Assert.DoesNotContain(13, file().Find(7)!.Ids("subtasks"));
        Assert.DoesNotContain(13, file().Find(method)!.Ids("subtasks"));
        editor.Document.Undo();
        Assert.Contains(13, file().Find(6)!.Ids("subtasks"));
        for (var i = 0; i < 20 && editor.Document.Text != start; i++)
        {
            editor.Document.Undo();
        }
        Assert.Equal(start, editor.Document.Text);
    }

    [Fact]
    public async Task APlanPreviewAsksForItsGoalAndStateAndShowsOnlyItsOwnAnswer()
    {
        using var shell = Setup();
        var cooker = new PreviewCookTests.FakePreviewCooker();
        shell.PreviewCooker = cooker;
        var editor = Open(shell, Goap);
        Assert.Null(editor.PlanQuery());
        Assert.Equal(["armed", "ammo", "near", "down"], editor.PlanningKeys.Select(k => k.Name));
        // The start state is the blackboard's defaults until the user sets a value.
        Assert.Equal(30, editor.PlanValue("ammo"));
        Assert.Equal(0, editor.PlanValue("armed"));

        editor.SetPlanGoal(1);
        editor.SetPlanValue("armed", 1);
        editor.SetPlanValue("health", 5);
        var query = editor.PlanQuery()!;
        Assert.Equal(1u, query.Goal);
        // The query has every planning key's value, set or the default, and only the planning keys.
        Assert.Equal([("armed", 1), ("ammo", 30), ("near", 0), ("down", 0)], query.State.Select(v => (v.Key, v.Value)));
        Assert.Equal(PlanPreviewStatus.Pending, editor.PlanStatus);

        var cook = await Next(cooker, c => c.Plan != null);
        Assert.Equal(1u, cook.Plan!.Goal);
        PlanAnswer answer = new(PlanOutcome.Found, [new PlanAnswerStep(12, "move_to"), new PlanAnswerStep(11, "attack")], 4, []);
        cook.Answer(new PreviewResult("", [], [answer]));
        await Until(() => editor.Plan != null);
        Assert.Equal([12u, 11u], editor.Plan!.Steps.Select(s => s.Id));
        Assert.Equal(PlanPreviewStatus.Answered, editor.PlanStatus);

        // A change of the setup hides the answer, and an answer to the old setup does not show.
        var count = cooker.Requests.Count;
        editor.SetPlanValue("near", 1);
        Assert.Null(editor.Plan);
        var next = await Next(cooker, c => c.Plan != null, count);
        Assert.Equal([("armed", 1), ("ammo", 30), ("near", 1), ("down", 0)], next.Plan!.State.Select(v => (v.Key, v.Value)));
        count = cooker.Requests.Count;
        editor.SetPlanValue("near", null);
        next.Answer(new PreviewResult("", [], [answer]));
        var last = await Next(cooker, c => c.Plan != null, count);
        Assert.Null(editor.Plan);
        PlanAnswer closest = new(PlanOutcome.Closest, [new PlanAnswerStep(11, "attack")], 9, ["near"]);
        last.Answer(new PreviewResult("", [], [closest]));
        await Until(() => editor.Plan != null);
        Assert.Equal(PlanOutcome.Closest, editor.Plan!.Outcome);

        // A blackboard's default is in the start state, so a change of one asks again, and hides the answer until then.
        count = cooker.Requests.Count;
        shell.OpenAsset(shell.Assets.Find(Board)!);
        var board = Assert.Single(shell.Blackboards);
        board.SetKey("ammo", "int", [], "12");
        Assert.Equal(12, editor.PlanValue("ammo"));
        Assert.Null(editor.Plan);
        var again = await Next(cooker, c => c.Plan != null, count);
        Assert.Contains(again.Plan!.State, v => v.Key == "ammo" && v.Value == 12);
        // An answer without a plan, as for a decision with problems, is refused.
        again.Answer(new PreviewResult("the decision did not cook", [], []));
        await Until(() => editor.PlanStatus == PlanPreviewStatus.Refused);

        // A goal that is deleted asks for no plan.
        editor.Delete(1);
        Assert.Null(editor.PlanGoal);
        Assert.Null(editor.PlanQuery());
    }

    // The next cook after a count of them that matches and waits for its answer. One cook runs at a time, so each other
    // that waits is answered with no problems, and the next can go.
    static async Task<PreviewCookTests.Cook> Next(PreviewCookTests.FakePreviewCooker cooker, Func<PreviewCookTests.Cook, bool> match, int after = 0)
    {
        PreviewCookTests.Cook? found = null;
        await Until(() =>
        {
            var waiting = cooker.Requests.Skip(after).Where(c => !c.Result.Task.IsCompleted).ToList();
            foreach (var other in waiting.Where(c => !match(c)))
            {
                other.Answer(new PreviewResult("", [], []));
            }
            found = waiting.LastOrDefault(match);
            return found != null;
        });
        return found!;
    }

    static async Task Until(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "the condition did not hold within 10 s");
            await Task.Delay(20, TestContext.Current.CancellationToken);
        }
    }

    static AgentView View(string decision, AgentOption[] options, AgentPlan[] plan) =>
        new(1, Convert.FromHexString(decision), [], [new AgentValue("health", AgentKind.Float, "100")], options, plan);

    [Fact]
    public void TheLiveViewShowsScoresGoalsPlansAndAnHtnPath()
    {
        using var shell = Setup();
        var utility = Open(shell, Utility);
        var goap = Open(shell, Goap);
        var htn = Open(shell, Htn);
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(1, "Guard", 1, 0, true, [])]));
        shell.Play();
        shell.Selection.Select(1);

        shell.OnGameMessage(View(Utility,
            [new AgentOption(1, 0.75f, true, [new AgentConsideration(4, 0.5f, 0.5f), new AgentConsideration(5, 0.2f, 0.95f)]), new AgentOption(3, 0.2f, false, [])], []));
        Assert.Equal(1u, utility.Live!.Options.Single(o => o.Chosen).Id);
        Assert.Equal(0.95f, utility.Live.Options[0].Considerations[1].Score);
        Assert.Null(utility.LivePlan);

        shell.OnGameMessage(View(Goap, [], [new AgentPlan(1, [new AgentGoal(1, 10), new AgentGoal(2, 1)], [10, 12, 11], 1, [], false)]));
        Assert.Null(utility.Live);
        Assert.Equal(1u, goap.LivePlan!.Goal);
        var (path, running) = goap.LivePath();
        Assert.Equal(12, running);

        shell.OnGameMessage(View(Htn, [], [new AgentPlan(0, [], [14, 13, 10], 2, [new AgentMethod(1, 2), new AgentMethod(5, 7)], false)]));
        (path, running) = htn.LivePath();
        Assert.Equal(10, running);
        Assert.Equal(new HashSet<int> { 1, 2, 5, 7, 14, 13, 10 }, path);
        // Edges on the path are those of each task to its method, and of the methods to their subtasks.
        var lit = htn.Geometry().Edges.Where(e => path.Contains(e.Parent) && path.Contains(e.Child)).Select(e => (e.Parent, e.Child)).ToHashSet();
        Assert.Contains((1, 2), lit);
        Assert.Contains((7, 14), lit);
        Assert.DoesNotContain((1, 3), lit);
        shell.Stop();
        Assert.Null(htn.Live);
    }
}
