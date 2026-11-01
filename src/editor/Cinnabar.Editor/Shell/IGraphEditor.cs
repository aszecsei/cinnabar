using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Shell;

/// <summary>An open graph in a document beside the viewport: what the shell's commands and the window ask of it.</summary>
public interface IGraphEditor : IDisposable
{
    /// <summary>The asset's GUID, which stays when its file moves.</summary>
    string Guid { get; }

    IGraphDocument Document { get; }

    /// <summary>What the console calls it, such as <c>material</c>.</summary>
    string Noun { get; }

    /// <summary>Sends the unsaved text to the cook daemon now, and shows the answer's problems.</summary>
    Task CookNow();
}
