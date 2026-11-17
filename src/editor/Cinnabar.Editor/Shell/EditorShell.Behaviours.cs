using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using BehaviourOperations = Cinnabar.Editor.Link.Protocol.BehaviourOperations;
using BehaviourOperationsAnswer = Cinnabar.Editor.Link.Protocol.BehaviourOperationsAnswer;
using Operation = Cinnabar.Editor.Document.Operation;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// What the edit-mode behaviours do to the scene in Edit (see docs/editor/document-and-scenes.md#behaviours-edits). The
/// game sends their writes as operations, which the editor applies to its document: into the entry that a drag has
/// open, or as an entry that follows the one before it, so undo takes both. Applying them sends them back to the game,
/// and then the editor answers, so the game runs the behaviours again only on a world that has their edits.
/// </summary>
public sealed partial class EditorShell
{
    // The number of the last scene that went to the game, which the behaviours' edits name.
    ulong _sceneTicket;

    void OnBehaviourOperations(BehaviourOperations batch)
    {
        var applied = false;
        try
        {
            applied = ApplyBehaviourOperations(batch);
        }
        finally
        {
            // After the Apply_Operations that the edit sent, on the same stream.
            Host.Send(new BehaviourOperationsAnswer(batch.Ticket, applied));
        }
    }

    // Applies a batch to the documents that its operations name, or refuses it: without a scene, outside Edit, for a
    // world that the game no longer has, or for a scene that is not open. An operation that does not fit puts the batch
    // back. Each scene that it edits gets an entry of its own, which follows the entry before it in that scene.
    bool ApplyBehaviourOperations(BehaviourOperations batch)
    {
        if (Scene == null || !IsEditing || batch.Scene != _sceneTicket)
        {
            return false;
        }
        if (batch.Operations.Length == 0)
        {
            return true;
        }
        var label = batch.Label.Length > 0 ? FieldValues.Humanize(batch.Label) : "Behaviours";
        var targets = new List<(SceneDocument Document, Wire.Operation Wire)>();
        foreach (var wire in batch.Operations)
        {
            // A scene of 0 is the active one, as for an entity that a behaviour creates at the root.
            if ((wire.Scene == 0 ? Scene : SceneByNumber(wire.Scene)) is not { } document)
            {
                Console.Add(LogLevel.Error, $"edit: {label} cannot edit the scene: the scene {wire.Scene} is not open");
                return false;
            }
            targets.Add((document, wire));
        }
        var open = OpenEdit;
        var begun = new List<SceneDocument>();
        try
        {
            foreach (var (document, wire) in targets)
            {
                var ops = ExpandBehaviourOperation(document, wire);
                if (open != null && open.Document == document)
                {
                    if (!open.Preview(ops))
                    {
                        CancelAll(begun);
                        return false;
                    }
                    continue;
                }
                if (!begun.Contains(document))
                {
                    document.Begin(label, follows: true);
                    begun.Add(document);
                }
                document.Preview(ops);
            }
        }
        catch (InvalidOperationException e)
        {
            CancelAll(begun);
            Console.Add(LogLevel.Error, $"edit: {label} cannot edit the scene: {e.Message}");
            return false;
        }
        foreach (var document in begun)
        {
            document.Commit();
        }
        return true;

        static void CancelAll(List<SceneDocument> begun)
        {
            foreach (var document in begun)
            {
                document.Cancel();
            }
        }
    }

    // A wire operation as the document's operations, against the document as it is now, as the editor's own commands
    // make them: a destroy takes the descendants, a new parent keeps the pose in the world, and an instance is a block.
    Operation[] ExpandBehaviourOperation(SceneDocument scene, Wire.Operation wire)
    {
        switch (wire.Kind)
        {
            case Wire.OperationKind.DestroyEntity:
                return scene.Expanded.Flat.Find(wire.Entity) == null ? [] : PrefabEdits.DestroyTree(scene, wire.Entity);
            case Wire.OperationKind.SetParent:
                return SceneEdits.Reparent(scene.Expanded.Flat, wire.Entity, wire.Parent);
            case Wire.OperationKind.CreateInstance:
                if (wire.Components.Length != 1)
                {
                    throw new InvalidOperationException($"the instance {wire.Entity:x16} has no pose");
                }
                var create = PrefabEdits.CreateInstance(scene, Convert.ToHexStringLower(wire.Prefab), wire.Parent,
                    SceneSnapshot.FromWire(wire.Components[0]), id: wire.Entity);
                return wire.Active ? [create] : [create, new SetActive(create.Id, false)];
            case Wire.OperationKind.CreateEntity:
                return [Operation.FromWire(wire) is CreateEntity created ? UnderPrefabRoot(created) : Operation.FromWire(wire)];
            default:
                return [Operation.FromWire(wire)];
        }
    }
}
