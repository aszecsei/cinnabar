namespace Cinnabar.Editor.Document;

/// <summary>Where a node's value of an attribute comes from.</summary>
public enum UiSource
{
    /// <summary>The element sets it itself.</summary>
    Own,
    /// <summary>One of its styles, or a variant of one for a state that it shows.</summary>
    Style,
    /// <summary>An ancestor, for an attribute that children inherit.</summary>
    Inherited,
}

/// <summary>A node's value of an attribute, as its text has it, where it comes from, and from what: a style's name or an ancestor's label.</summary>
public sealed record UiValue(string Value, UiSource Source, string From);

/// <summary>
/// The cascade (see docs/ui/design.md#the-cascade) as far as the text says it: what a node inherits of its parent, its
/// styles' attributes in order, their variants for the states that it shows, and its own attributes. The element's
/// defaults are the runtime's, so an attribute that nothing sets is not here.
/// </summary>
public static class UiCascade
{
    /// <summary>The attributes that are not values: the element's id and styles, and a style's name.</summary>
    public static readonly IReadOnlySet<string> NotValues = new HashSet<string> { "id", "style", "name" };

    /// <param name="file">The document.</param>
    /// <param name="node">The node, by its index.</param>
    /// <param name="inherited">The attributes that children inherit.</param>
    /// <param name="states">The states that a node shows, by its index: none, or some of hover, focus, press and disabled.</param>
    public static IReadOnlyDictionary<string, UiValue> Resolve(UiFile file, int node, IReadOnlySet<string> inherited, Func<int, IReadOnlyCollection<string>> states)
    {
        var n = file.Nodes[node];
        var values = new Dictionary<string, UiValue>();
        if (n.Parent >= 0)
        {
            foreach (var (name, value) in Resolve(file, n.Parent, inherited, states))
            {
                if (inherited.Contains(name))
                {
                    values[name] = value.Source == UiSource.Inherited ? value : new UiValue(value.Value, UiSource.Inherited, Label(file.Nodes[n.Parent]));
                }
            }
        }
        var styles = file.StylesOf(n);
        foreach (var style in styles)
        {
            Apply(values, style.Element, UiSource.Style, style.Name);
        }
        var shown = states(node);
        foreach (var state in shown.Contains("disabled") ? ["disabled"] : UiFile.States.Where(shown.Contains))
        {
            foreach (var style in styles)
            {
                if (file.Style($"{style.Base}:{state}") is { } variant)
                {
                    Apply(values, variant.Element, UiSource.Style, variant.Name);
                }
            }
        }
        if (n.ButtonText)
        {
            values["text"] = new UiValue(n.Element.Text, UiSource.Own, "");
        }
        else
        {
            Apply(values, n.Element, UiSource.Own, "");
            if (n.Kind is "text" or "field" && n.Element.Text != "")
            {
                values["text"] = new UiValue(n.Element.Text, UiSource.Own, "");
            }
        }
        return values;
    }

    static void Apply(Dictionary<string, UiValue> values, UiElement e, UiSource source, string from)
    {
        foreach (var a in e.Attributes)
        {
            if (!NotValues.Contains(a.Name))
            {
                values[a.Name] = new UiValue(a.Value, source, from);
            }
        }
    }

    /// <summary>A node as the editor names it: its kind and its id, such as &lt;button#resume&gt;.</summary>
    public static string Label(UiNode n) => n.ButtonText ? "<text>" : n.Id == "" ? $"<{n.Kind}>" : $"<{n.Kind}#{n.Id}>";
}
