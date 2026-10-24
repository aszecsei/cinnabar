using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace Cinnabar.Editor.Host;

/// <summary>
/// <c>host.exe</c> as a child process (see docs/editor.md#processes). The host runs in a Job Object that kills it when
/// the job's handle closes, so it exits with the editor even when the editor crashes.
/// </summary>
sealed partial class HostProcess : IDisposable
{
    readonly Process _process;
    readonly SafeFileHandle _job;
    // Set by Dispose. The process's events can still arrive afterwards, on a thread-pool thread.
    volatile bool _disposed;

    /// <summary>A line of the host's log, without terminal colors. Raised on a thread-pool thread.</summary>
    public event Action<string>? Output;

    /// <summary>The host's exit code. Raised on a thread-pool thread.</summary>
    public event Action<int>? Exited;

    HostProcess(Process process, SafeFileHandle job)
    {
        _process = process;
        _job = job;
        _process.OutputDataReceived += (_, e) => OnLine(e.Data);
        _process.ErrorDataReceived += (_, e) => OnLine(e.Data);
        _process.Exited += (_, _) => OnExited();
    }

    public static HostProcess Start(string hostPath, IEnumerable<string> args, string workingDirectory)
    {
        var job = CreateKillOnCloseJob();
        var info = new ProcessStartInfo(hostPath, args)
        {
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        var host = new HostProcess(process, job);
        process.Start();
        // The host starts no processes of its own, so nothing escapes the job before this.
        if (!AssignProcessToJobObject(job, process.SafeHandle))
        {
            process.Kill();
            throw new InvalidOperationException($"AssignProcessToJobObject failed: {Marshal.GetLastPInvokeErrorMessage()}");
        }
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return host;
    }

    void OnLine(string? line)
    {
        if (line != null && !_disposed)
        {
            Output?.Invoke(TerminalColor().Replace(line, ""));
        }
    }

    void OnExited()
    {
        int code;
        try
        {
            code = _process.ExitCode;
        }
        catch (InvalidOperationException)
        {
            // Disposed while this event was on its way: the editor stopped the host on purpose.
            return;
        }
        if (!_disposed)
        {
            Exited?.Invoke(code);
        }
    }

    public void Dispose()
    {
        _disposed = true;
        _job.Dispose();
        _process.Dispose();
    }

    static SafeFileHandle CreateKillOnCloseJob()
    {
        var job = CreateJobObjectW(0, null);
        if (job.IsInvalid)
        {
            throw new InvalidOperationException($"CreateJobObject failed: {Marshal.GetLastPInvokeErrorMessage()}");
        }
        var limits = new JobObjectExtendedLimitInformation
        {
            BasicLimitInformation = new JobObjectBasicLimitInformation { LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE },
        };
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformationClass, ref limits, (uint)Marshal.SizeOf<JobObjectExtendedLimitInformation>()))
        {
            job.Dispose();
            throw new InvalidOperationException($"SetInformationJobObject failed: {Marshal.GetLastPInvokeErrorMessage()}");
        }
        return job;
    }

    [GeneratedRegex(@"\x1b\[[0-9;]*m")]
    private static partial Regex TerminalColor();

    const int JobObjectExtendedLimitInformationClass = 9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public nuint MinimumWorkingSetSize;
        public nuint MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public nuint Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public nuint ProcessMemoryLimit;
        public nuint JobMemoryLimit;
        public nuint PeakProcessMemoryUsed;
        public nuint PeakJobMemoryUsed;
    }

    [LibraryImport("kernel32.dll", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial SafeFileHandle CreateJobObjectW(nint attributes, string? name);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetInformationJobObject(SafeFileHandle job, int infoClass, ref JobObjectExtendedLimitInformation info, uint length);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AssignProcessToJobObject(SafeFileHandle job, SafeProcessHandle process);
}
