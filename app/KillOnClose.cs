// Puts the current process in a Windows job object that kills every process started from it
// (ffmpeg, MediaMTX, cloudflared, the stream script...) as soon as this process ends, however it
// ends: the X button, Task Manager, or a crash. Closing a console with X can kill PowerShell before
// any 'finally' cleanup runs, so cleanup code alone isn't enough.
using System;
using System.Runtime.InteropServices;

public static class KillOnClose
{
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits
    {
        public BasicLimits Basic;
        public ulong IoReadOps, IoWriteOps, IoOtherOps, IoReadBytes, IoWriteBytes, IoOtherBytes;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll")] static extern IntPtr CreateJobObject(IntPtr attrs, string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, int size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    static IntPtr job;

    public static bool Enable()
    {
        if (job != IntPtr.Zero) return true;
        job = CreateJobObject(IntPtr.Zero, null);
        var info = new ExtendedLimits();
        info.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        return SetInformationJobObject(job, 9, ref info, Marshal.SizeOf(typeof(ExtendedLimits)))
            && AssignProcessToJobObject(job, GetCurrentProcess());
    }
}
