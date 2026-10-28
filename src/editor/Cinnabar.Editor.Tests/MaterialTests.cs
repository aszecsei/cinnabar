using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>Material graphs in the editor: the file format, the document's undo, the catalog's pins, the canvas's geometry and the material editor.</summary>
public sealed class MaterialTests : IDisposable
{
    readonly string _directory = Path.Combine(Path.GetTempPath(), $"cinnabar-material-tests-{Guid.NewGuid():N}");

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
        var path = Path.Combine(_directory, "checker.material");
        Directory.CreateDirectory(_directory);
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

    EditorShell NewShell()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(Path.Combine(_directory, "checker.material"), Text(Checker));
        File.WriteAllText(Path.Combine(_directory, "rim.material_function"), Text(Rim));
        File.WriteAllText(Path.Combine(_directory, "glow.material"), "material 1\nshading = lit\n---\nSurface evaluate(Material_Inputs inputs) { return default_surface(); }\n");
        File.WriteAllText(Path.Combine(_directory, "smoke.effect"), "effect 1\nemitter puffs\n");
        var shell = new EditorShell(new EditorOptions("host.exe", "game.dll", null) { AutosaveDirectory = Path.Combine(_directory, "autosave") },
            new EditorSettings(Path.Combine(_directory, "settings")));
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _directory)], [], Nodes));
        shell.Assets.Apply(new ShadingModels(Shading));
        shell.Assets.Apply(new AssetSnapshot(
        [
            new Asset(MaterialGuid, AssetKind.Material, "game", "checker.material", AssetStatus.Current, 0, 0, "", [], [], "", "", 1, [0, 0], "", []),
            new Asset(FunctionGuid, AssetKind.MaterialFunction, "game", "rim.material_function", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", []),
            new Asset("22", AssetKind.Material, "game", "glow.material", AssetStatus.Current, 0, 0, "", [], [], "", "", 1, [0, 0], "", []),
            new Asset(EffectGuid, AssetKind.Effect, "game", "smoke.effect", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", []),
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
        Assert.Equal(editor.Document.Text, File.ReadAllText(Path.Combine(_directory, "checker.material")));

        // A function opens without a preview, and its editor is the active one.
        var function = shell.OpenMaterial(shell.Assets.Find(FunctionGuid)!);
        Assert.NotNull(function);
        Assert.Null(function.PreviewId);
        Assert.Same(function, shell.ActiveMaterial);
        shell.CloseMaterial(function, discard: true);
        Assert.Single(shell.Materials);
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
        Assert.Equal(Path.Combine(_directory, "smoke.effect"), effect.Path);
        // Opening it again shows the same preview.
        Assert.Same(effect, shell.OpenEffect(shell.Assets.Find(EffectGuid)!));
        Assert.Equal("Open Preview", shell.OpenLabel(shell.Assets.Find(EffectGuid)!));

        // Closing its document frees its preview for the next one.
        shell.Layout.CloseDocument(effect);
        Assert.Empty(shell.Effects);
        shell.CloseMaterial(material, discard: true);
        Assert.Equal(0, shell.OpenEffect(shell.Assets.Find(EffectGuid)!)!.PreviewId);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, true);
        }
    }
}
