using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The profiler (see docs/editor/shell-and-panels.md#profiler): the host's summaries, and the frames that the editor
/// asks it to capture. Each capture shows the Profiler panel.
/// </summary>
public sealed partial class EditorShell
{
    /// <summary>How many recent frames Capture Worst Frame looks at: two seconds at 60 frames per second.</summary>
    public const uint WorstOfFrames = 120;

    public ProfilerModel Profiler { get; } = new();

    /// <summary>Captures a frame by its number, such as a worst frame from the Resource Monitor's graph.</summary>
    public void CaptureFrame(ulong frame) => Capture(ProfileCaptureMode.Frame, frame, 0);

    public void CaptureNextFrame() => Capture(ProfileCaptureMode.Next, 0, 0);

    public void CaptureWorstFrame(uint count = WorstOfFrames) => Capture(ProfileCaptureMode.WorstRecent, 0, count);

    void Capture(ProfileCaptureMode mode, ulong frame, uint count)
    {
        if (!Host.Linked)
        {
            return;
        }
        Host.Send(Profiler.Request(mode, frame, count));
        Layout.Show("profiler");
    }

    /// <summary>Starts or stops the host's recording of zones. The next summary says which it does.</summary>
    public void ToggleProfilerRecording()
    {
        if (Host.Linked)
        {
            Host.Send(new ProfileRecording(!Profiler.Recording));
        }
    }
}
