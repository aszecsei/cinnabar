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

    // Applies a batch to the document, or refuses it: without a scene, outside Edit, or for a scene that the game no
    // longer has. An operation that does not fit puts the batch back.
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
        if (OpenEdit is { } open)
        {
            foreach (var wire in batch.Operations)
            {
                Operation[] ops;
                try
                {
                    ops = ExpandBehaviourOperation(wire);
                }
                catch (InvalidOperationException e)
                {
                    Console.Add(LogLevel.Error, $"edit: {label} cannot edit the scene: {e.Message}");
                    return false;
                }
                if (!open.Preview(ops))
                {
                    return false;
                }
            }
            return true;
        }
        Scene.Begin(label, follows: true);
        try
        {
            foreach (var wire in batch.Operations)
            {
                Scene.Preview(ExpandBehaviourOperation(wire));
            }
        }
        catch (InvalidOperationException e)
        {
            Scene.Cancel();
            Console.Add(LogLevel.Error, $"edit: {label} cannot edit the scene: {e.Message}");
            return false;
        }
        Scene.Commit();
        return true;
    }

    // A wire operation as the document's operations, against the document as it is now, as the editor's own commands
    // make them: a destroy takes the descendants, a new parent keeps the pose in the world, and an instance is a block.
    Operation[] ExpandBehaviourOperation(Wire.Operation wire)
    {
        var scene = Scene!;
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
