using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace Cinnabar.Editor.Content;

/// <summary>
/// A child process of the editor, such as <c>host.exe</c> or the cook daemon (see docs/editor.md#processes). It runs in
/// a Job Object that kills it when the job's handle closes, so it exits with the editor even when the editor crashes.
/// </summary>
public sealed partial class ChildProcess : IDisposable
{
    readonly Process _process;
    readonly SafeFileHandle _job;
    // Set by Dispose. The process's events can still arrive afterwards, on a thread-pool thread.
    volatile bool _disposed;

    /// <summary>A line of the process's output, without terminal colors. Raised on a thread-pool thread.</summary>
    public event Action<string>? Output;

    /// <summary>The process's exit code. Raised on a thread-pool thread.</summary>
    public event Action<int>? Exited;

    ChildProcess(Process process, SafeFileHandle job)
    {
        _process = process;
        _job = job;
        _process.OutputDataReceived += (_, e) => OnLine(e.Data);
        _process.ErrorDataReceived += (_, e) => OnLine(e.Data);
        _process.Exited += (_, _) => OnExited();
    }

    public static ChildProcess Start(string path, IEnumerable<string> args, string workingDirectory)
    {
        var job = CreateKillOnCloseJob();
        var info = new ProcessStartInfo(path, args)
        {
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        var child = new ChildProcess(process, job);
        process.Start();
        // The editor's children start no processes of their own, so nothing escapes the job before this.
        if (!AssignProcessToJobObject(job, process.SafeHandle))
        {
            process.Kill();
            throw new InvalidOperationException($"AssignProcessToJobObject failed: {Marshal.GetLastPInvokeErrorMessage()}");
        }
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return child;
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
            // Disposed while this event was on its way: the editor stopped the process on purpose.
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
