using System;
using System.Linq;
using Microsoft.CodeAnalysis;

namespace Cinnabar.Editor.Link.Generator;

/// <summary>
/// Reads each link's schema from the project's additional files: <c>link-schema.json</c>, which <c>host
/// --emit-link-schema</c> writes, and <c>cook-schema.json</c>, which <c>cook --emit-link-schema</c> writes. It adds
/// each protocol's C# in a namespace of its own. Without a file, the build fails with a message that says how to make
/// it.
/// </summary>
[Generator(LanguageNames.CSharp)]
public sealed class LinkGenerator : IIncrementalGenerator
{
    /// <summary>The schema file of each link, the namespace of its C#, and the class that reads its messages.</summary>
    public static readonly (string File, string Namespace, string Messages, string Link)[] Schemas =
    [
        ("link-schema.json", SchemaCode.Namespace, "LinkMessages", "editor link"),
        ("cook-schema.json", "Cinnabar.Editor.Link.Cook", "CookMessages", "cook link"),
    ];

    static readonly DiagnosticDescriptor Missing = new(
        "CNL001", "A link's schema is missing",
        "The {0}'s schema is missing. Run 'just link-schema', which writes build/link/{1}.",
        "Cinnabar", DiagnosticSeverity.Error, isEnabledByDefault: true);

    static readonly DiagnosticDescriptor Invalid = new(
        "CNL002", "A link's schema cannot be read",
        "The {0}'s schema cannot be read: {1}",
        "Cinnabar", DiagnosticSeverity.Error, isEnabledByDefault: true);

    public void Initialize(IncrementalGeneratorInitializationContext context)
    {
        var schemas = context.AdditionalTextsProvider
            .Select((file, token) => (Name: System.IO.Path.GetFileName(file.Path), Text: file.GetText(token)?.ToString()))
            .Collect();
        context.RegisterSourceOutput(schemas, (output, files) =>
        {
            foreach (var schema in Schemas)
            {
                var text = files.FirstOrDefault(f => f.Text != null && string.Equals(f.Name, schema.File, StringComparison.OrdinalIgnoreCase)).Text;
                if (text == null)
                {
                    output.ReportDiagnostic(Diagnostic.Create(Missing, Location.None, schema.Link, schema.File));
                    continue;
                }
                try
                {
                    output.AddSource($"{schema.Messages}.g.cs", SchemaCode.Generate(text, schema.Namespace, schema.Messages));
                }
                catch (Exception e) when (e is FormatException or InvalidCastException or System.Collections.Generic.KeyNotFoundException)
                {
                    output.ReportDiagnostic(Diagnostic.Create(Invalid, Location.None, schema.Link, e.Message));
                }
            }
        });
    }
}
