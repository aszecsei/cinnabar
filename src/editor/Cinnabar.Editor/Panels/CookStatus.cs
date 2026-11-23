using Avalonia.Controls;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Panels;

/// <summary>The status line of an asset editor: its cook checks' state, with the parts that its view adds.</summary>
static class CookStatus
{
    /// <summary>What the cook checks say: no daemon yet, no answer yet, a clean cook, or the count of errors.</summary>
    public static string Describe(CheckState state, int errors, bool linked) => state switch
    {
        _ when !linked => "waiting for the cook daemon",
        CheckState.Clean => "cooks",
        CheckState.Failed when errors == 0 => "does not cook",
        CheckState.Failed => errors == 1 ? "1 error" : $"{errors} errors",
        _ => "cooking",
    };

    /// <summary>
    /// Shows the parts that are not null, joined, in a status line. A failed state marks the line as a warning, with the
    /// error as its tooltip.
    /// </summary>
    public static void Show(TextBlock status, CheckState state, params string?[] parts)
    {
        status.Text = string.Join("  ·  ", parts.OfType<string>());
        status.Classes.Set("warning", state is CheckState.Failed);
        ToolTip.SetTip(status, state is CheckState.Failed { Error: var error } ? error : null);
    }
}
