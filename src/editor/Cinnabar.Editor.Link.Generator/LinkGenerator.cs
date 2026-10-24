using System;
using System.Linq;
using Microsoft.CodeAnalysis;

namespace Cinnabar.Editor.Link.Generator;

/// <summary>
/// Reads <c>link-schema.json</c>, which <c>host --emit-link-schema</c> writes, from the project's additional files,
/// and adds the protocol's C#. Without the file, the build fails with a message that says how to make it.
/// </summary>
[Generator(LanguageNames.CSharp)]
public sealed class LinkGenerator : IIncrementalGenerator
{
    public const string SchemaFileName = "link-schema.json";

    static readonly DiagnosticDescriptor Missing = new(
        "CNL001", "The editor link's schema is missing",
        "The editor link's schema is missing. Run 'just link-schema', which writes build/link/link-schema.json.",
        "Cinnabar", DiagnosticSeverity.Error, isEnabledByDefault: true);

    static readonly DiagnosticDescriptor Invalid = new(
        "CNL002", "The editor link's schema cannot be read",
        "The editor link's schema cannot be read: {0}",
        "Cinnabar", DiagnosticSeverity.Error, isEnabledByDefault: true);

    public void Initialize(IncrementalGeneratorInitializationContext context)
    {
        var schemas = context.AdditionalTextsProvider
            .Where(file => string.Equals(System.IO.Path.GetFileName(file.Path), SchemaFileName, StringComparison.OrdinalIgnoreCase))
            .Select((file, token) => file.GetText(token)?.ToString())
            .Collect();
        context.RegisterSourceOutput(schemas, (output, texts) =>
        {
            var text = texts.FirstOrDefault(t => t != null);
            if (text == null)
            {
                output.ReportDiagnostic(Diagnostic.Create(Missing, Location.None));
                return;
            }
            try
            {
                output.AddSource("LinkProtocol.g.cs", SchemaCode.Generate(text));
            }
            catch (Exception e) when (e is FormatException or InvalidCastException or System.Collections.Generic.KeyNotFoundException)
            {
                output.ReportDiagnostic(Diagnostic.Create(Invalid, Location.None, e.Message));
            }
        });
    }
}
