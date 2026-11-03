// The live picture in the window: what viewers get, at the stream's own frame rate.
//
//   MediaMTX  --RTSP-->  a small ffmpeg (decodes and shrinks)  --raw frames-->  this  --newest frame-->  the window
//
// It's a separate process reading the finished stream, so it shows the subtitles too, and if it ever fails the
// stream isn't touched. If the window falls behind, older frames are dropped so the picture never lags further.
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

public class PreviewFeed
{
    const int W = 640, H = 360, Bytes = W * H * 4;

    readonly string ffmpeg, url;
    readonly Image target;
    readonly WriteableBitmap bitmap;
    readonly object swap = new object();
    byte[] newest = new byte[Bytes];
    bool hasNew;
    int drawQueued;
    Process process;
    volatile bool stopping;

    public volatile int FramesShown;
    public bool Running { get { var p = process; return p != null && !stopping && !p.HasExited; } }

    // Call from the window's thread
    public PreviewFeed(string ffmpeg, string url, Image target)
    {
        this.ffmpeg = ffmpeg; this.url = url; this.target = target;
        bitmap = new WriteableBitmap(W, H, 96, 96, PixelFormats.Bgr32, null);
        target.Source = bitmap;
    }

    public void Start()
    {
        // Don't wait to gather data before showing anything, and shrink to a fixed size whatever the stream's shape
        string args = "-hide_banner -loglevel quiet -nostdin -fflags nobuffer -flags low_delay -probesize 500000 -analyzeduration 0 " +
            "-rtsp_transport tcp -i " + url + " -an -sn -threads 2 " +
            "-vf \"scale=" + W + ":" + H + ":flags=fast_bilinear:force_original_aspect_ratio=decrease,pad=" + W + ":" + H +
            ":(ow-iw)/2:(oh-ih)/2:color=0x04342C,format=bgr0\" -fps_mode passthrough -f rawvideo -";
        var psi = new ProcessStartInfo(ffmpeg, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        process = Process.Start(psi);
        // The stream matters more: on a slower PC this should be what gives way
        try { process.PriorityClass = ProcessPriorityClass.BelowNormal; } catch (Exception) { }
        var output = process.StandardOutput.BaseStream;
        new Thread(() => Read(output)) { IsBackground = true, Name = "PreviewFeed" }.Start();
    }

    public void Stop()
    {
        stopping = true;
        try { if (process != null && !process.HasExited) process.Kill(); } catch (Exception) { }
    }

    void Read(Stream output)
    {
        // An error on this thread would close the whole program
        try
        {
            var spare = new byte[Bytes];
            while (!stopping)
            {
                int got = 0, n;
                while (got < Bytes && (n = output.Read(spare, got, Bytes - got)) > 0) got += n;
                if (got < Bytes) return;
                lock (swap) { var old = newest; newest = spare; spare = old; hasNew = true; }
                // One draw waiting at a time: it takes whatever's newest when it runs
                if (Interlocked.CompareExchange(ref drawQueued, 1, 0) == 0)
                    target.Dispatcher.BeginInvoke(DispatcherPriority.Render, new Action(Draw));
            }
        }
        catch (Exception) { }
    }

    void Draw()
    {
        Interlocked.Exchange(ref drawQueued, 0);
        if (stopping) return;
        try
        {
            lock (swap)
            {
                if (!hasNew) return;
                hasNew = false;
                bitmap.WritePixels(new Int32Rect(0, 0, W, H), newest, W * 4, 0);
            }
            FramesShown++;
        }
        catch (Exception) { }
    }
}
