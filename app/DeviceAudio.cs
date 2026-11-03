// Captures a sound device (Stereo Mix, a microphone) in its own ffmpeg and passes it to the stream
// ffmpeg through a named pipe as 48 kHz stereo s16le.
//
//   helper ffmpeg (dshow)  --PCM-->  DeviceAudioCapture  --PCM, real-time-->  stream ffmpeg
//
// When the stream ffmpeg opens a device itself, the picture drops to ~2 real fps with NVENC. Sound that
// arrives through a pipe doesn't do that. Silence is filled in if the helper falls behind or stops, so
// the stream's sound timeline keeps running in step with the picture.
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO.Pipes;
using System.Threading;

public class DeviceAudioCapture
{
    const int Rate = 48000, BytesPerFrame = 4;   // 48 kHz, stereo, 16-bit
    readonly string ffmpeg, device, pipeName;
    readonly ConcurrentQueue<byte[]> chunks = new ConcurrentQueue<byte[]>();
    NamedPipeServerStream pipe, helperPipe;
    Process helper;
    volatile bool connected, stopping;
    public volatile string LastError = "";

    public DeviceAudioCapture(string ffmpeg, string device, string pipeName)
    {
        this.ffmpeg = ffmpeg; this.device = device; this.pipeName = pipeName;
    }

    public void Start()
    {
        pipe = new NamedPipeServerStream(pipeName, PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.None, 0, 1 << 20);
        helperPipe = new NamedPipeServerStream(pipeName + "-in", PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.None, 1 << 20, 0);
        new Thread(ReadHelper) { IsBackground = true, Name = "DeviceAudio reader" }.Start();
        new Thread(WriteStream) { IsBackground = true, Name = "DeviceAudio writer" }.Start();
    }

    public void Stop()
    {
        stopping = true;
        try { if (helper != null && !helper.HasExited) helper.Kill(); } catch { }
        try { helperPipe.Dispose(); } catch { }
        try { pipe.Dispose(); } catch { }
    }

    void ReadHelper()
    {
        try
        {
            string args = "-nostdin -hide_banner -loglevel error -f dshow -audio_buffer_size 50 -i \"audio=" + device +
                "\" -f s16le -ar " + Rate + " -ac 2 -y \\\\.\\pipe\\" + pipeName + "-in";
            var psi = new ProcessStartInfo(ffmpeg, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
            helper = new Process { StartInfo = psi };
            helper.ErrorDataReceived += (s, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) LastError = e.Data; };
            helper.Start();
            helper.BeginErrorReadLine();
            helperPipe.WaitForConnection();
            while (!stopping)
            {
                byte[] buf = new byte[Rate / 100 * BytesPerFrame];   // up to 10 ms at a time
                int n = helperPipe.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                if (!connected) continue;   // nobody listening yet: only sound from time 0 onward counts
                if (n != buf.Length) Array.Resize(ref buf, n);
                chunks.Enqueue(buf);
            }
        }
        catch (Exception e) { if (!stopping) LastError = e.Message; }
    }

    void WriteStream()
    {
        try
        {
            pipe.WaitForConnection();   // stream ffmpeg opened the pipe: sound time 0 starts now
            connected = true;
            var clock = Stopwatch.StartNew();
            long written = 0;
            byte[] partial = null;   // bytes of an odd-sized chunk carried over, so whole sample frames go out
            byte[] silence = new byte[Rate * BytesPerFrame];
            while (!stopping)
            {
                long now = clock.ElapsedTicks * Rate / Stopwatch.Frequency;
                byte[] chunk;
                while (chunks.TryDequeue(out chunk))
                {
                    if (partial != null)
                    {
                        byte[] joined = new byte[partial.Length + chunk.Length];
                        Buffer.BlockCopy(partial, 0, joined, 0, partial.Length);
                        Buffer.BlockCopy(chunk, 0, joined, partial.Length, chunk.Length);
                        chunk = joined; partial = null;
                    }
                    int whole = chunk.Length - chunk.Length % BytesPerFrame;
                    if (whole != chunk.Length)
                    {
                        partial = new byte[chunk.Length - whole];
                        Buffer.BlockCopy(chunk, whole, partial, 0, partial.Length);
                    }
                    long frames = whole / BytesPerFrame;
                    // Skip sound that would run more than 100 ms ahead of real time (after filler was added)
                    if (written + frames <= now + Rate / 10)
                    {
                        pipe.Write(chunk, 0, whole);
                        written += frames;
                    }
                }
                // Device late or gone: fill with silence once we're more than 100 ms behind real time
                if (now - written > Rate / 10)
                {
                    int fill = (int)Math.Min(now - written - Rate / 50, silence.Length / BytesPerFrame);   // keep 20 ms of slack
                    pipe.Write(silence, 0, fill * BytesPerFrame);
                    written += fill;
                }
                Thread.Sleep(10);
            }
        }
        catch (Exception e) { if (!stopping) LastError = e.Message; }
    }
}
