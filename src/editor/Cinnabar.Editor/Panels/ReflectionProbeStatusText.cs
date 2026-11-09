using System.Globalization;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// A reflection probe's state in words, which the Properties panel shows under its component (see
/// docs/editor/shell-and-panels.md#properties): whether it holds a slot, and when it was last captured, by the clock.
/// </summary>
public static class ReflectionProbeStatusText
{
    /// <summary>
    /// The state of a probe from its last view and the time that the view came, or null without one: the game is not
    /// linked, has not drawn the probe yet, or has its reflections off.
    /// </summary>
    public static string Describe((ReflectionProbeView View, DateTime Received)? state, bool linked)
    {
        if (!linked)
        {
            return "Run the game to see this probe's capture.";
        }
        if (state is not var (view, received))
        {
            return "No capture: the game's reflections are off, or it has not drawn this probe yet.";
        }
        var capturing = view.Capturing ? " Capturing now." : "";
        switch (view.Status)
        {
            case ReflectionProbeStatus.NoSlot:
                return "No slot: probes of a higher priority or nearer the camera hold them all.";
            case ReflectionProbeStatus.Waiting:
                return "A slot, waiting for its first capture." + capturing;
            default:
                var at = (received - TimeSpan.FromSeconds(view.Age)).ToLocalTime().ToString("HH:mm:ss", CultureInfo.InvariantCulture);
                var provisional = view.Complete ? "" : ", provisional: the level was still loading, so it captures again once it is in";
                return $"A slot, captured at {at}{provisional}.{capturing}";
        }
    }
}
