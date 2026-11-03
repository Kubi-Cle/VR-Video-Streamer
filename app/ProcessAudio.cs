// Captures the sound of one program (and its child processes, e.g. a browser's audio process) with
// Windows' process loopback capture (Windows 10 2004+), and writes it as 48 kHz stereo s16le to a
// named pipe that ffmpeg reads. It doesn't matter which output device the program plays to.
// While the program is silent Windows sends nothing, so silence is filled in to keep the stream's
// sound timeline running in step with the picture.
using System;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Threading;

[ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPalActivateOperation
{
    void GetActivateResult([MarshalAs(UnmanagedType.Error)] out int hr, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
}

[ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPalActivateCompletionHandler
{
    void ActivateCompleted(IPalActivateOperation op);
}

// Marker: the completion callback may be called from any thread
[ComImport, Guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPalAgileObject { }

[ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPalAudioClient
{
    void Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
    void GetBufferSize(out uint frames);
    void GetStreamLatency(out long latency);
    void GetCurrentPadding(out uint padding);
    [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
    void GetMixFormat(out IntPtr format);
    void GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
    void Start();
    void Stop();
    void Reset();
    void SetEventHandle(IntPtr handle);
    void GetService([MarshalAs(UnmanagedType.LPStruct)] Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
}

[ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPalCaptureClient
{
    void GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
    void ReleaseBuffer(uint frames);
    void GetNextPacketSize(out uint frames);
}

[ClassInterface(ClassInterfaceType.None)]
public class PalCompletion : IPalActivateCompletionHandler, IPalAgileObject
{
    public readonly ManualResetEvent Done = new ManualResetEvent(false);
    public int Hr;
    public object Client;
    public void ActivateCompleted(IPalActivateOperation op)
    {
        try { op.GetActivateResult(out Hr, out Client); }
        catch (Exception e) { Hr = Marshal.GetHRForException(e); }
        Done.Set();
    }
}

public class ProcessAudioCapture
{
    [DllImport("Mmdevapi.dll", ExactSpelling = true, PreserveSig = false)]
    static extern void ActivateAudioInterfaceAsync([MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid, IntPtr activationParams,
        IPalActivateCompletionHandler completionHandler, out IPalActivateOperation operation);

    const int Rate = 48000, BytesPerFrame = 4;   // 48 kHz, stereo, 16-bit
    readonly int pid;
    readonly string pipeName;
    NamedPipeServerStream pipe;
    volatile bool stopping;
    public volatile string LastError = "";
    public long FramesCaptured;   // real (non-filler) audio frames received from the program

    public ProcessAudioCapture(int processId, string pipeName) { pid = processId; this.pipeName = pipeName; }

    public void Start()
    {
        pipe = new NamedPipeServerStream(pipeName, PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.None, 0, 1 << 20);
        var t = new Thread(Run) { IsBackground = true, Name = "ProcessAudioCapture" };
        t.SetApartmentState(ApartmentState.MTA);
        t.Start();
    }

    public void Stop() { stopping = true; try { pipe.Dispose(); } catch { } }

    IPalAudioClient Activate()
    {
        // AUDIOCLIENT_ACTIVATION_PARAMS { PROCESS_LOOPBACK, { pid, INCLUDE_TARGET_PROCESS_TREE } }
        IntPtr p = Marshal.AllocHGlobal(12);
        Marshal.WriteInt32(p, 0, 1);
        Marshal.WriteInt32(p, 4, pid);
        Marshal.WriteInt32(p, 8, 0);
        // PROPVARIANT { vt = VT_BLOB, blob = { 12, p } }
        IntPtr pv = Marshal.AllocHGlobal(24);
        for (int i = 0; i < 24; i += 4) Marshal.WriteInt32(pv, i, 0);
        Marshal.WriteInt16(pv, 0, 65);
        Marshal.WriteInt32(pv, 8, 12);
        Marshal.WriteIntPtr(pv, IntPtr.Size == 8 ? 16 : 12, p);
        try
        {
            var done = new PalCompletion();
            IPalActivateOperation op;
            ActivateAudioInterfaceAsync("VAD\\Process_Loopback", typeof(IPalAudioClient).GUID, pv, done, out op);
            if (!done.Done.WaitOne(10000)) throw new TimeoutException("Windows didn't start the program's audio capture.");
            if (done.Hr != 0) Marshal.ThrowExceptionForHR(done.Hr);
            return (IPalAudioClient)done.Client;
        }
        finally { Marshal.FreeHGlobal(pv); Marshal.FreeHGlobal(p); }
    }

    void Run()
    {
        IPalAudioClient client = null;
        try
        {
            client = Activate();
            // WAVEFORMATEX: PCM, 2 ch, 48000 Hz, 16-bit
            IntPtr fmt = Marshal.AllocHGlobal(18);
            Marshal.WriteInt16(fmt, 0, 1);
            Marshal.WriteInt16(fmt, 2, 2);
            Marshal.WriteInt32(fmt, 4, Rate);
            Marshal.WriteInt32(fmt, 8, Rate * BytesPerFrame);
            Marshal.WriteInt16(fmt, 12, BytesPerFrame);
            Marshal.WriteInt16(fmt, 14, 16);
            Marshal.WriteInt16(fmt, 16, 0);
            const int LOOPBACK = 0x00020000, SRC_DEFAULT_QUALITY = 0x08000000;
            const int AUTOCONVERTPCM = unchecked((int)0x80000000);
            client.Initialize(0, LOOPBACK | AUTOCONVERTPCM | SRC_DEFAULT_QUALITY, 2000000, 0, fmt, IntPtr.Zero);
            Marshal.FreeHGlobal(fmt);
            object o;
            client.GetService(typeof(IPalCaptureClient).GUID, out o);
            var capture = (IPalCaptureClient)o;

            WaitForFfmpeg();
            client.Start();
            while (!stopping)
            {
                uint packet;
                capture.GetNextPacketSize(out packet);
                while (packet > 0 && !stopping)
                {
                    IntPtr data; uint frames, flags; ulong devPos, qpc;
                    capture.GetBuffer(out data, out frames, out flags, out devPos, out qpc);
                    int bytes = (int)frames * BytesPerFrame;
                    if (bytes > buf.Length) buf = new byte[bytes];
                    long due = clock.ElapsedTicks * Rate / Stopwatch.Frequency;
                    // Skip audio that would run more than 100 ms ahead of real time (after filler was added)
                    if (written + frames <= due + Rate / 10)
                    {
                        if ((flags & 2) != 0) Array.Clear(buf, 0, bytes);   // AUDCLNT_BUFFERFLAGS_SILENT
                        else Marshal.Copy(data, buf, 0, bytes);
                        pipe.Write(buf, 0, bytes);
                        written += frames;
                        FramesCaptured += frames;
                    }
                    capture.ReleaseBuffer(frames);
                    capture.GetNextPacketSize(out packet);
                }
                FillSilence();
                Thread.Sleep(10);
            }
        }
        catch (Exception e) { if (!stopping) LastError = e.Message; }
        finally { try { if (client != null) client.Stop(); } catch { } }

        // If capture failed, keep feeding silence so ffmpeg (waiting on this pipe) keeps streaming the picture
        try
        {
            WaitForFfmpeg();
            while (!stopping) { FillSilence(); Thread.Sleep(10); }
        }
        catch { }
    }

    Stopwatch clock;
    long written;
    byte[] buf = new byte[Rate * BytesPerFrame];

    void WaitForFfmpeg()
    {
        if (clock != null) return;
        pipe.WaitForConnection();   // ffmpeg opened the pipe: sound time 0 starts now
        clock = Stopwatch.StartNew();
    }

    // Program silent: fill with silence once we're more than 50 ms behind real time
    void FillSilence()
    {
        long now = clock.ElapsedTicks * Rate / Stopwatch.Frequency;
        if (now - written <= Rate / 20) return;
        int fill = (int)(now - written - Rate / 50);   // keep 20 ms of slack for late packets
        int bytes = fill * BytesPerFrame;
        if (bytes > buf.Length) buf = new byte[bytes];
        Array.Clear(buf, 0, bytes);
        pipe.Write(buf, 0, bytes);
        written += fill;
    }
}
