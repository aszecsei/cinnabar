using System.Collections;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Graphs;

/// <summary>
/// The selected things of a graph editor, by their IDs, which the material, animation graph and decision editors each
/// keep one of. A select tells <see cref="Changed"/> each time; a prune tells it only when it took something.
/// </summary>
public sealed class NodeSelection : IReadOnlyCollection<int>
{
    readonly HashSet<int> _ids = [];

    /// <summary>The selection was set, or a prune took something from it.</summary>
    public event Action? Changed;

    public int Count => _ids.Count;

    public bool Contains(int id) => _ids.Contains(id);

    /// <summary>The one selected ID, or null when none or several are selected.</summary>
    public int? One => _ids.Count == 1 ? _ids.First() : null;

    /// <summary>Selects some IDs: in place of the selection, beside it, or each in or out of it.</summary>
    public void Select(IEnumerable<int> ids, SelectMode mode = SelectMode.Replace)
    {
        if (mode == SelectMode.Replace)
        {
            _ids.Clear();
        }
        foreach (var id in ids)
        {
            if (mode == SelectMode.Toggle && !_ids.Add(id))
            {
                _ids.Remove(id);
            }
            else
            {
                _ids.Add(id);
            }
        }
        Changed?.Invoke();
    }

    /// <summary>Drops the IDs that the graph no longer has, as after an undo or a delete. Returns whether it dropped any.</summary>
    public bool Prune(Func<int, bool> exists)
    {
        if (_ids.RemoveWhere(id => !exists(id)) == 0)
        {
            return false;
        }
        Changed?.Invoke();
        return true;
    }

    /// <summary>Opens the undo entry of a drag of the selection, named for the one thing that it moves or for how many.</summary>
    public void BeginMove<TGraph>(GraphDocument<TGraph> document, Func<int, string> label) =>
        document.Begin(One is { } one ? $"Move {label(one)}" : $"Move {Count} Nodes");

    /// <summary>A step of a drag: puts each thing that it moves at its start plus the drag's offset.</summary>
    public static void MoveSelected<TGraph>(GraphDocument<TGraph> document, IReadOnlyDictionary<int, Vec2> starts, Vec2 offset,
        Action<TGraph, int, Vec2> place) =>
        document.Step(graph =>
        {
            foreach (var (id, start) in starts)
            {
                place(graph, id, start + offset);
            }
        });

    /// <summary>Ends a drag: commits its entry, or with cancel, puts the graph back as it was before it.</summary>
    public static void EndMove<TGraph>(GraphDocument<TGraph> document, bool cancel)
    {
        if (cancel)
        {
            document.Cancel();
        }
        else if (document.InTransaction)
        {
            document.Commit();
        }
    }

    public IEnumerator<int> GetEnumerator() => _ids.GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
}
