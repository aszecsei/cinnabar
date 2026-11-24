using Avalonia;
using Avalonia.Input;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Materials;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>Material graphs in the editor: the file format, the document's undo, the catalog's pins, the canvas's geometry and the material editor.</summary>
public sealed class MaterialTests : IDisposable
{
    readonly TempDirectory _temp = new("material");

    const string Checker = """
        material 1
        # The box's material.
        shading = lit
        param tint color = [1, 1, 1, 1]
        	group = "Surface"
        param roughness float = 0.55
        param albedo texture = $6ae47342be33cfa451b9f6643231fd24
        switch shiny = false

        node 1 output
        	position = [360, -40]
        	base_color = @4.out
        	roughness = @5.value
        node 2 parameter
        	position = [-240, -160]
        	name = "tint"
        node 3 texture_sample
        	position = [-240, -40]
        	texture = @6.value
        node 4 multiply
        	position = [60, -100]
        	a = @2.value
        	b = @3.rgba
        node 5 parameter
        	position = [60, 60]
        	name = "roughness"
        node 6 parameter
        	position = [-480, -10]
        	name = "albedo"

        """;

    const string MaterialGuid = "f7eadea8bd278c0ae71b61b681352a82";
    const string FunctionGuid = "11112222333344445555666677778888";
    const string EffectGuid = "99998888777766665555444433332222";

    static string Text(string text) => text.Replace("\r\n", "\n");

    // The kinds of node and the shading model that the cook daemon would send, as much of them as the tests use.
    static readonly NodePin[] NoPins = [];
    static readonly NodeProperty[] NoProperties = [];

    static NodeInfo Kind(string kind, string category, NodePin[] inputs, NodePin[] outputs, NodeProperty[]? properties = null,
        NodePinsFrom from = NodePinsFrom.Kind, NodeScope scope = NodeScope.Both) =>
        new(kind, kind, category, "", inputs, outputs, properties ?? NoProperties, from, scope);

    static NodePin Pin(string name, PinType type, string label = "") => new(name, type, [0, 0, 0, 0], label);

    internal static readonly NodeInfo[] Nodes =
    [
        Kind("output", "Output", NoPins, NoPins, from: NodePinsFrom.ShadingModel, scope: NodeScope.Material),
        Kind("parameter", "Inputs", NoPins, [Pin("value", PinType.Any)], [new NodeProperty("name", PropertyKind.Parameter, [], "")], scope: NodeScope.Material),
        Kind("multiply", "Math", [Pin("a", PinType.Any), Pin("b", PinType.Any)], [Pin("out", PinType.Any)]),
        Kind("texture_sample", "Textures", [Pin("texture", PinType.Texture), Pin("uv", PinType.Float2, "UV0")],
            [Pin("rgba", PinType.Float4), Pin("rgb", PinType.Float3), Pin("r", PinType.Float)]),
        Kind("function", "Advanced", NoPins, NoPins, [new NodeProperty("function", PropertyKind.Function, [], "")], NodePinsFrom.Function),
        Kind("function_input", "Function", NoPins, [Pin("value", PinType.Any)],
            [new NodeProperty("name", PropertyKind.Text, [], "\"input\""), new NodeProperty("type", PropertyKind.Choice, ["float", "float3"], "float3")], scope: NodeScope.Function),
        Kind("function_output", "Function", [Pin("value", PinType.Any)], NoPins, [new NodeProperty("name", PropertyKind.Text, [], "\"output\"")], scope: NodeScope.Function),
    ];

    internal static readonly ShadingModelInfo[] Shading =
    [
        new("lit", "e8ede8e9c5df53b11ff7b663def5c540", [new NodePin("base_color", PinType.Float3, [0.8f, 0.8f, 0.8f, 0], ""), new NodePin("roughness", PinType.Float, [0.5f, 0, 0, 0], "")], false),
    ];

    const string Rim = """
        material_function 1

        node 1 function_input
        	position = [0, 0]
        	name = "power"
        	type = float
        node 2 function_output
        	position = [200, 0]
        	name = "rim"
        	value = @1.value

        """;

    [Fact]
    public void AMaterialFileReadsAndWritesBackAsItWas()
    {
        var (graph, problems) = MaterialFile.Parse(Text(Checker), MaterialFileKind.Material);
        Assert.Empty(problems);
        Assert.NotNull(graph);
        Assert.Equal(["# The box's material."], graph.Comments);
        Assert.Equal(new MaterialParam("tint", "color", "[1, 1, 1, 1]", "Surface"), graph.Params[0]);
        Assert.Equal(new MaterialSwitch("shiny", false), Assert.Single(graph.Switches));
        Assert.Equal(6, graph.Nodes.Count);
        Assert.Equal(new GraphLink(4, "out"), graph.Find(1)!.Get("base_color"));
        Assert.Equal((-240.0, -160.0), (graph.Find(2)!.X, graph.Find(2)!.Y));
        Assert.Equal(new GraphText("tint"), graph.Find(2)!.Get("name"));
        Assert.Equal(Text(Checker), MaterialFile.Write(graph));

        var (function, functionProblems) = MaterialFile.Parse(Text(Rim), MaterialFileKind.Function);
        Assert.Empty(functionProblems);
        Assert.Equal(Text(Rim), MaterialFile.Write(function!));
    }

    [Fact]
    public void TransparentMaterialsWriteTheirTransparencyAndNoCutoff()
    {
        const string glass = "material 1\nshading = lit\nblend = transparent\ntransparency = sorted\ntwo_sided = true\n---\nSurface evaluate(Material_Inputs inputs) { return default_surface(); }\n";
        var (graph, problems) = MaterialFile.Parse(glass, MaterialFileKind.Material);
        Assert.Empty(problems);
        Assert.Equal("sorted", graph!.Transparency);
        Assert.True(graph.IsTransparent);
        Assert.Equal(glass, MaterialFile.Write(graph));

        // Moments are the default, and only a masked material has a cutoff.
        graph.Transparency = "moments";
        Assert.DoesNotContain("transparency", MaterialFile.Write(graph));
        graph.Blend = "additive";
        Assert.DoesNotContain("transparency", MaterialFile.Write(graph));
        Assert.DoesNotContain("cutoff", MaterialFile.Write(graph));
        graph.Blend = "masked";
        Assert.Contains("cutoff = 0.5", MaterialFile.Write(graph));
    }

    [Fact]
    public void LinesThatDoNotParseAreProblemsWithTheirLines()
    {
        var (graph, problems) = MaterialFile.Parse("material 1\nshading = lit\nnode x output\nwobble = 3\n", MaterialFileKind.Material);
        Assert.Null(graph);
        Assert.Equal([3, 4], problems.Select(p => p.Line));
        Assert.True(MaterialFile.IsHlsl("material 1\nshading = lit\n---\nSurface evaluate(Material_Inputs inputs) { return default_surface(); }\n"));
        Assert.False(MaterialFile.IsHlsl(Text(Checker)));
        // Strings keep their escapes.
        Assert.Equal("\"a \\\"b\\\"\\n\"", new GraphText("a \"b\"\n").Write());
        Assert.Equal(new GraphText("a \"b\"\n"), GraphValue.Parse("\"a \\\"b\\\"\\n\""));
        Assert.Equal(new GraphNumbers(1, 0.5, 0), GraphValue.Parse("[1, 0.5, 0]"));
    }

    [Fact]
    public void TheDocumentUndoesEachEditAndADragIsOneEntry()
    {
        var graph = MaterialFile.Parse(Text(Checker), MaterialFileKind.Material).Graph!;
        var path = _temp.Combine("checker.material");
        Directory.CreateDirectory(_temp.Path);
        var document = MaterialDocument.Of(path, MaterialGuid, graph);
        Assert.False(document.IsDirty);

        document.Edit("Set Metallic", g => g.Find(1)!.Set("metallic", new GraphNumbers(1)));
        Assert.True(document.IsDirty);
        Assert.Contains("\tmetallic = 1\n", document.Text);
        // An edit that changes nothing leaves no entry.
        document.Edit("Nothing", _ => { });
        Assert.Equal(["Set Metallic"], document.History);

        document.Begin("Move Tint");
        for (var x = 0; x < 5; x++)
        {
            document.Step(g => g.Find(2)!.X = -240 + x * 10);
        }
        document.Commit();
        Assert.Equal(["Set Metallic", "Move Tint"], document.History);
        Assert.Equal(-200, document.Graph.Find(2)!.X);

        document.Undo();
        Assert.Equal(-240, document.Graph.Find(2)!.X);
        document.Undo();
        Assert.Null(document.Graph.Find(1)!.Get("metallic"));
        Assert.False(document.IsDirty);
        document.Redo();
        Assert.True(document.IsDirty);

        // A node's lines of the text find it, for the problems that the cook reports on them.
        var lines = document.Text.Split('\n').ToList();
        Assert.Equal(3, document.NodeAt(lines.IndexOf("node 3 texture_sample") + 2));
        Assert.Null(document.NodeAt(3));

        document.Save();
        Assert.False(document.IsDirty);
        Assert.Equal(document.Text, File.ReadAllText(path));
    }

    [Fact]
    public void ASaveDuringADragIsRefused()
    {
        var graph = MaterialFile.Parse(Text(Checker), MaterialFileKind.Material).Graph!;
        var path = _temp.Combine("checker.material");
        Directory.CreateDirectory(_temp.Path);
        var document = MaterialDocument.Of(path, MaterialGuid, graph);
        document.Save();
        var saved = File.ReadAllText(path);

        // A step needs an open entry.
        Assert.Throws<InvalidOperationException>(() => document.Step(g => g.Find(2)!.X = 0));

        document.Begin("Move Tint");
        document.Step(g => g.Find(2)!.X = 400);
        Assert.Throws<InvalidOperationException>(() => document.Save());
        document.Cancel();
        Assert.False(document.IsDirty);
        Assert.Equal(saved, File.ReadAllText(path));
        Assert.Equal(document.Text, File.ReadAllText(path));
    }

    [Fact]
    public void TheCatalogGivesEachNodeItsPinsAndTheCanvasFindsThem()
    {
        var graph = MaterialFile.Parse(Text(Checker), MaterialFileKind.Material).Graph!;
        var function = MaterialFile.Parse(Text(Rim), MaterialFileKind.Function).Graph!;
        var catalog = new MaterialCatalog(Nodes, Shading, guid => guid == FunctionGuid ? function : null);

        // The output node has the shading model's inputs, and a parameter node its parameter's type.
        var (inputs, _) = catalog.PinsOf(graph, graph.Find(1)!);
        Assert.Equal(["base_color", "roughness"], inputs.Select(p => p.Name));
        Assert.Equal(PinType.Float4, catalog.PinsOf(graph, graph.Find(2)!).Outputs[0].Type);
        Assert.Equal(PinType.Texture, catalog.PinsOf(graph, graph.Find(6)!).Outputs[0].Type);
        // A function node has its function's inputs and outputs.
        var call = new GraphNode(7, "function");
        call.Set("function", new GraphAsset(FunctionGuid));
        graph.Nodes.Add(call);
        var pins = catalog.PinsOf(graph, call);
        Assert.Equal(("power", PinType.Float), (pins.Inputs[0].Name, pins.Inputs[0].Type));
        Assert.Equal("rim", Assert.Single(pins.Outputs).Name);

        var geometry = GraphGeometry.Of(graph, catalog);
        Assert.Equal(5, geometry.Links.Count);
        var sample = geometry.Find(3)!;
        Assert.Equal(new GraphHit(GraphHitKind.Output, 3, "rgb"), geometry.HitTest(sample.OutputAt(1)));
        Assert.Equal(new GraphHit(GraphHitKind.Input, 3, "uv"), geometry.HitTest(sample.InputAt(1) + new Vec2(3, 2)));
        Assert.Equal(new GraphHit(GraphHitKind.Node, 3), geometry.HitTest(new Vec2(sample.Bounds.X + 90, sample.Bounds.Y + 10)));
        Assert.Equal(GraphHitKind.None, geometry.HitTest(new Vec2(-2000, 0)).Kind);
        Assert.Equal([2, 3], geometry.InBox(new Vec2(-250, -170), new Vec2(-200, -30)).Order());
        Assert.False(GraphGeometry.CanLink(PinType.Texture, PinType.Float3));
        Assert.True(GraphGeometry.CanLink(PinType.Float4, PinType.Any));
    }

    // Where a point of the graph is in the canvas's view, which is where a press there lands.
    static Point At(GraphCanvas canvas, Vec2 at)
    {
        var v = canvas.View.ToView(at);
        return new Point(v.X, v.Y);
    }

    [Fact]
    public void EscapeAndALostPointerCancelALinkDragOnTheCanvas()
    {
        using var shell = NewShell();
        var editor = shell.OpenMaterial(shell.Assets.Find(MaterialGuid)!)!;
        var canvas = new GraphCanvas(shell, editor);
        var text = editor.Document.Text;
        var geometry = editor.Geometry();
        var roughness = geometry.Find(5)!;
        var sample = geometry.Find(3)!;
        var output = At(canvas, roughness.OutputAt(roughness.OutputIndex("value")));
        var uv = At(canvas, sample.InputAt(sample.InputIndex("uv")));
        // Esc is Cancel, which the focused canvas takes.
        var cancel = shell.Commands.Get(EditorCommands.Cancel);
        shell.Commands.Focus(canvas);
        Assert.False(cancel.CanExecute);

        // Escape during the drag cancels it, and the release on the input that follows links nothing.
        Assert.True(canvas.Press(output, MouseButton.Left, KeyModifiers.None));
        canvas.MovePointer(uv);
        Assert.True(cancel.Execute());
        canvas.Release(uv, KeyModifiers.None);
        Assert.Equal(text, editor.Document.Text);
        Assert.Empty(editor.Document.History);

        // So does losing the pointer.
        Assert.True(canvas.Press(output, MouseButton.Left, KeyModifiers.None));
        canvas.MovePointer(uv);
        canvas.LoseCapture();
        canvas.Release(uv, KeyModifiers.None);
        Assert.Equal(text, editor.Document.Text);

        // The same drag, released, links the output to the input.
        Assert.True(canvas.Press(output, MouseButton.Left, KeyModifiers.None));
        canvas.MovePointer(uv);
        canvas.Release(uv, KeyModifiers.None);
        Assert.Equal(new GraphLink(5, "value"), editor.Document.Graph.Find(3)!.Get("uv"));
        Assert.Single(editor.Document.History);
    }

    [Fact]
    public void TheCanvasMovesSelectsAndDuplicatesNodesThroughTheSharedGestures()
    {
        using var shell = NewShell();
        var editor = shell.OpenMaterial(shell.Assets.Find(MaterialGuid)!)!;
        var canvas = new GraphCanvas(shell, editor);
        var tint = editor.Geometry().Find(2)!.Bounds;
        var body = At(canvas, new Vec2(tint.X + 90, tint.Y + 10));
        var away = new Point(body.X + 30, body.Y + 20);
        shell.Commands.Focus(canvas);

        // A press on a node selects it, and a drag moves it by as much, in one entry that Escape puts back.
        Assert.True(canvas.Press(body, MouseButton.Left, KeyModifiers.None));
        Assert.Equal([2], editor.Selection);
        canvas.MovePointer(away);
        canvas.MovePointer(away);
        Assert.True(editor.Document.InTransaction);
        Assert.NotEqual(tint.X, editor.Document.Graph.Find(2)!.X);
        Assert.True(shell.Commands.Get(EditorCommands.Cancel).Execute());
        canvas.Release(away, KeyModifiers.None);
        Assert.False(editor.Document.InTransaction);
        Assert.Empty(editor.Document.History);

        Assert.True(canvas.Press(body, MouseButton.Left, KeyModifiers.None));
        // The first move past the slop begins the drag, and each move after it steps it.
        canvas.MovePointer(away);
        canvas.MovePointer(away);
        canvas.Release(away, KeyModifiers.None);
        Assert.Equal(["Move tint"], editor.Document.History);
        Assert.Equal((tint.X + 30, tint.Y + 20), (editor.Document.Graph.Find(2)!.X, editor.Document.Graph.Find(2)!.Y));

        // The second press of a double click takes nothing: no drag follows it.
        Assert.False(canvas.Press(away, MouseButton.Left, KeyModifiers.None, clickCount: 2));

        // Ctrl+D duplicates the selection, as the canvas takes Duplicate while it has the keyboard, and a click on
        // nothing clears it.
        shell.Commands.Focus(canvas);
        Assert.True(shell.Commands.Get(EditorCommands.DuplicateEntity).Execute());
        Assert.Equal("Duplicate tint", editor.Document.History[^1]);
        Assert.DoesNotContain(2, editor.Selection);
        Assert.True(canvas.Press(At(canvas, new Vec2(-2000, 0)), MouseButton.Left, KeyModifiers.None));
        canvas.Release(At(canvas, new Vec2(-2000, 0)), KeyModifiers.None);
        Assert.Empty(editor.Selection);
    }

    // A scene of one entity, which the host reports, for the tests of the scene's commands beside a graph.
    const string DoorScene = "scene 1\n\nentity 0000000000000001\nname = \"Door\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";
    const ulong DoorHandle = 1UL << 32;

    [Fact]
    public void DeleteAndDuplicateWithTheCanvasFocusedActOnTheGraphAndNeverOnTheSelectedEntities()
    {
        using var shell = NewShell(DoorScene);
        shell.OnGameMessage(new Link.Protocol.EntitySnapshot([new Link.Protocol.EntityInfo(DoorHandle, "Door", 1, 1, 0, true, [1])]));
        var editor = shell.OpenMaterial(shell.Assets.Find(MaterialGuid)!)!;
        var canvas = new GraphCanvas(shell, editor);
        var delete = shell.Commands.Get(EditorCommands.DeleteEntity);
        var duplicate = shell.Commands.Get(EditorCommands.DuplicateEntity);
        shell.Selection.Set([DoorHandle]);
        Assert.True(delete.CanExecute);

        // The window's Delete and Ctrl+D run before the focused canvas sees the key, so they reach the graph as the
        // canvas's scope. With nothing selected in the graph they do nothing, and the entities stay.
        shell.Commands.Focus(canvas);
        editor.Select([]);
        Assert.False(delete.CanExecute);
        Assert.False(delete.Execute());
        Assert.False(duplicate.Execute());
        Assert.Single(shell.Scene!.Scene.Entities);
        Assert.Empty(editor.Document.History);

        // With a node selected, only the node goes.
        editor.Select([2]);
        Assert.True(delete.Execute());
        Assert.Null(editor.Document.Graph.Find(2));
        Assert.Single(shell.Scene.Scene.Entities);
        Assert.Empty(shell.Scene.History);

        // Once the canvas lets the keyboard go, Delete deletes the entities again.
        shell.Commands.Leave(canvas);
        Assert.True(delete.Execute());
        Assert.Empty(shell.Scene.Scene.Entities);
    }

    [Fact]
    public void FrameSelectedAndAddNodeWithTheCanvasFocusedActOnTheGraph()
    {
        using var shell = NewShell(DoorScene);
        var editor = shell.OpenMaterial(shell.Assets.Find(MaterialGuid)!)!;
        var canvas = new GraphCanvas(shell, editor);
        var frame = shell.Commands.Get(EditorCommands.FrameSelected);
        var addNode = shell.Commands.Get(EditorCommands.AddNode);

        // Without a focused canvas, Frame Selected is the scene's, which needs a selection, and Add Node has nothing to do.
        shell.Selection.Set([]);
        Assert.False(frame.CanExecute);
        Assert.False(addNode.CanExecute);

        // The canvas's F and Space are those commands, which it takes while it has the keyboard.
        Assert.Equal([ShortcutScopes.Viewport, ShortcutScopes.Canvas], shell.KeyBindings.ScopesOf(EditorCommands.FrameSelected));
        Assert.Contains((EditorCommands.FrameSelected, "F"), shell.KeyBindings.InScope(ShortcutScopes.Canvas));
        Assert.Contains((EditorCommands.AddNode, "Space"), shell.KeyBindings.InScope(ShortcutScopes.Canvas));
        shell.Commands.Focus(canvas);
        Assert.True(frame.CanExecute);
        Assert.True(addNode.CanExecute);
        // The scene's Frame Selected cannot run without a selection, so this ran the canvas's.
        Assert.True(frame.Execute());
        shell.Commands.Leave(canvas);
        Assert.False(addNode.CanExecute);
    }

    EditorShell NewShell(string? scene = null)
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("checker.material"), Text(Checker));
        File.WriteAllText(_temp.Combine("rim.material_function"), Text(Rim));
        File.WriteAllText(_temp.Combine("glow.material"), "material 1\nshading = lit\n---\nSurface evaluate(Material_Inputs inputs) { return default_surface(); }\n");
        File.WriteAllText(_temp.Combine("smoke.effect"), "effect 1\nemitter puffs\n");
        var shell = TestShell.Open(_temp, scene == null ? null : "door.scene", scene);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], Nodes, []));
        shell.Assets.Apply(new ShadingModels(Shading));
        shell.Assets.Apply(new AssetSnapshot(
        [
            TestAssets.Make(MaterialGuid, AssetKind.Material, "checker.material", permutations: 1),
            TestAssets.Make(FunctionGuid, AssetKind.MaterialFunction, "rim.material_function"),
            TestAssets.Make("22", AssetKind.Material, "glow.material", permutations: 1),
            TestAssets.Make(EffectGuid, AssetKind.Effect, "smoke.effect"),
        ], []));
        return shell;
    }

    [Fact]
    public void TheMaterialEditorEditsTheGraphAndTheShellRoutesUndoAndSave()
    {
        using var shell = NewShell();
        // An HLSL material is not a graph, so it does not open in the material editor.
        Assert.Null(shell.OpenMaterial(shell.Assets.Find("22")!));
        var editor = shell.OpenMaterial(shell.Assets.Find(MaterialGuid)!);
        Assert.NotNull(editor);
        Assert.Same(editor, shell.ActiveMaterial);
        Assert.Equal(0, editor.PreviewId);
        // Opening it again shows the same editor.
        Assert.Same(editor, shell.OpenMaterial(shell.Assets.Find(MaterialGuid)!));

        var scalar = editor.AddNode("multiply", 0, 200);
        Assert.Equal([scalar], editor.Selection);
        Assert.True(editor.Link(5, "value", scalar, "a"));
        Assert.True(editor.Link(scalar, "out", 1, "roughness"));
        // A link back into what feeds the node would loop.
        Assert.False(editor.Link(scalar, "out", 5, "nothing"));
        Assert.False(editor.Link(1, "out", 1, "roughness"));

        // The output node stays when the selection is deleted.
        editor.Select([1, scalar]);
        editor.DeleteSelected();
        Assert.NotNull(editor.Document.Graph.Find(1));
        Assert.Null(editor.Document.Graph.Find(scalar));
        Assert.Null(editor.Document.Graph.Find(1)!.Get("roughness"));

        // A duplicate keeps the links between the copies, and takes the others as they are.
        editor.Select([2, 4]);
        editor.DuplicateSelected();
        var copies = editor.Selection.Order().ToList();
        Assert.Equal(2, copies.Count);
        var multiply = editor.Document.Graph.Find(copies.Single(id => editor.Document.Graph.Find(id)!.Kind == "multiply"))!;
        Assert.Equal(new GraphLink(copies.Single(id => id != multiply.Id), "value"), multiply.Get("a"));
        Assert.Equal(new GraphLink(3, "rgba"), multiply.Get("b"));

        // Renaming a parameter renames it in the nodes that read it.
        editor.SetParam("tint", new MaterialParam("color", "color", "[1, 0, 0, 1]", "Surface"));
        Assert.Equal(new GraphText("color"), editor.Document.Graph.Find(2)!.Get("name"));

        // Undo, Redo and Save act on the active material editor.
        var undo = shell.Commands.Get("edit.undo");
        Assert.True(undo.CanExecute);
        undo.Execute();
        Assert.Equal(new GraphText("tint"), editor.Document.Graph.Find(2)!.Get("name"));
        shell.Commands.Get("file.save").Execute();
        Assert.False(editor.Document.IsDirty);
        Assert.Equal(editor.Document.Text, File.ReadAllText(_temp.Combine("checker.material")));

        // A function opens without a preview, and its editor is the active one.
        var function = shell.OpenMaterial(shell.Assets.Find(FunctionGuid)!);
        Assert.NotNull(function);
        Assert.Null(function.PreviewId);
        Assert.Same(function, shell.ActiveMaterial);
        shell.CloseGraph(function, discard: true);
        Assert.Single(shell.Materials);
    }

    [Fact]
    public void AnOpenMaterialFollowsItsFileAndSavesWhereItMoved()
    {
        using var shell = NewShell();
        var editor = shell.OpenMaterial(shell.Assets.Find(MaterialGuid)!)!;
        editor.AddNode("multiply", 0, 200);

        // The content browser renames the file, and the index gives the asset its new path.
        File.Move(_temp.Combine("checker.material"), _temp.Combine("tiles.material"));
        shell.Assets.Apply(new AssetDelta(
            [TestAssets.Make(MaterialGuid, AssetKind.Material, "tiles.material", permutations: 1)], [], [], []));
        Assert.Equal(Path.GetFullPath(_temp.Combine("tiles.material")), editor.Document.Path);
        Assert.Equal("tiles.material", editor.Document.Title);

        shell.Commands.Get("file.save").Execute();
        Assert.False(File.Exists(_temp.Combine("checker.material")));
        Assert.Equal(editor.Document.Text, File.ReadAllText(_temp.Combine("tiles.material")));
    }

    [Fact]
    public void EffectsOpenInPreviewsThatShareTheMaterialEditorsPreviews()
    {
        using var shell = NewShell();
        var material = shell.OpenMaterial(shell.Assets.Find(MaterialGuid)!);
        var effect = shell.OpenEffect(shell.Assets.Find(EffectGuid)!);
        Assert.NotNull(effect);
        // The effect takes the first preview that the material editor does not have, and picks no mesh.
        Assert.Equal(0, material!.PreviewId);
        Assert.Equal(1, effect.PreviewId);
        Assert.False(effect.PicksMesh);
        Assert.Equal(_temp.Combine("smoke.effect"), effect.Path);
        // Opening it again shows the same preview.
        Assert.Same(effect, shell.OpenEffect(shell.Assets.Find(EffectGuid)!));
        Assert.Equal("Open Preview", shell.OpenLabel(shell.Assets.Find(EffectGuid)!));

        // Closing its document frees its preview for the next one.
        shell.Layout.CloseDocument(effect);
        Assert.Empty(shell.Effects);
        shell.CloseGraph(material, discard: true);
        Assert.Equal(0, shell.OpenEffect(shell.Assets.Find(EffectGuid)!)!.PreviewId);
    }

    public void Dispose() => _temp.Dispose();
}
