// Gives ffmpeg a local address for a YouTube video and fetches it from YouTube in pieces.
//
//   decoder ffmpeg  --one long request-->  SegmentProxy  --many 10 MB requests-->  YouTube
//
// YouTube holds one long request to about 8 Mbit/s, close enough to a video's own bitrate that busy scenes
// stall. Requests for a piece at a time measured about 350 Mbit/s. ffmpeg has no way to ask for pieces itself.
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public class SegmentProxy
{
    const int PieceBytes = 10 * 1024 * 1024;
    const int PiecesAhead = 2;

    readonly TcpListener listener;
    readonly int port;
    readonly ConcurrentDictionary<string, string> addresses = new ConcurrentDictionary<string, string>();
    int lastId;

    public SegmentProxy()
    {
        ServicePointManager.DefaultConnectionLimit = 16;
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        listener = new TcpListener(IPAddress.Loopback, 0);   // this PC only, on any free port
        listener.Start();
        port = ((IPEndPoint)listener.LocalEndpoint).Port;
        new Thread(Accept) { IsBackground = true, Name = "SegmentProxy" }.Start();
    }

    // The local address to give ffmpeg instead of this one
    public string Add(string address)
    {
        string id = Interlocked.Increment(ref lastId).ToString();
        addresses[id] = address;
        return "http://127.0.0.1:" + port + "/" + id;
    }

    void Accept()
    {
        while (true)
        {
            try
            {
                TcpClient client = listener.AcceptTcpClient();
                new Thread(() => Serve(client)) { IsBackground = true, Name = "SegmentProxy client" }.Start();
            }
            catch (Exception) { Thread.Sleep(200); }   // an error on this thread would close the whole program
        }
    }

    void Serve(TcpClient client)
    {
        var stop = new CancellationTokenSource();
        var pieces = new BlockingCollection<Piece>(PiecesAhead);
        try
        {
            client.NoDelay = true;
            NetworkStream net = client.GetStream();
            string request = ReadRequest(net);
            Match line = Regex.Match(request, @"^GET /(\d+) ");
            string address;
            if (!line.Success || !addresses.TryGetValue(line.Groups[1].Value, out address)) { Reply(net, "404 Not Found"); return; }
            Match range = Regex.Match(request, @"(?im)^Range:\s*bytes=(\d+)-(\d*)");
            long start = range.Success ? long.Parse(range.Groups[1].Value) : 0;

            new Thread(() => Fetch(address, start, pieces, stop.Token)) { IsBackground = true, Name = "SegmentProxy fetch" }.Start();

            Piece piece;
            if (!pieces.TryTake(out piece, 30000) || piece.Bytes == null) { Reply(net, "502 Bad Gateway"); return; }
            long total = piece.Total;
            long last = total - 1;
            if (range.Success && range.Groups[2].Length > 0) last = Math.Min(last, long.Parse(range.Groups[2].Value));
            string head = (range.Success ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes " + start + "-" + last + "/" + total + "\r\n" : "HTTP/1.1 200 OK\r\n")
                + "Accept-Ranges: bytes\r\nContent-Type: application/octet-stream\r\nContent-Length: " + (last - start + 1) + "\r\nConnection: close\r\n\r\n";
            byte[] headBytes = Encoding.ASCII.GetBytes(head);
            net.Write(headBytes, 0, headBytes.Length);

            long left = last - start + 1;
            while (left > 0 && piece != null && piece.Bytes != null)
            {
                int n = (int)Math.Min(left, piece.Length);
                net.Write(piece.Bytes, 0, n);
                left -= n;
                if (left <= 0) break;
                if (!pieces.TryTake(out piece, 60000)) break;
            }
        }
        catch (Exception) { }           // usually ffmpeg hanging up: it seeked, or moved on to another video.
                                        // Anything else on this thread would close the whole program.
        finally
        {
            stop.Cancel();
            client.Close();
        }
    }

    class Piece { public byte[] Bytes; public int Length; public long Total; }

    static void Fetch(string address, long position, BlockingCollection<Piece> pieces, CancellationToken stop)
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                Piece piece = FetchPiece(address, position, stop);
                if (piece == null) { pieces.TryAdd(new Piece()); return; }
                while (!pieces.TryAdd(piece, 500, stop)) { }
                position += piece.Length;
                if (position >= piece.Total) return;
            }
        }
        catch (Exception) { }           // cancelled, or the reader has gone. An error here would close the whole program.
    }

    static Piece FetchPiece(string address, long position, CancellationToken stop)
    {
        for (int attempt = 0; attempt < 4 && !stop.IsCancellationRequested; attempt++)
        {
            if (attempt > 0) Thread.Sleep(1000);
            try
            {
                var request = (HttpWebRequest)WebRequest.Create(address);
                request.Proxy = null;
                request.Timeout = 15000;
                request.ReadWriteTimeout = 15000;
                request.AddRange(position, position + PieceBytes - 1);
                using (var response = (HttpWebResponse)request.GetResponse())
                using (Stream body = response.GetResponseStream())
                {
                    Match total = Regex.Match(response.Headers["Content-Range"] ?? "", @"/(\d+)$");
                    if (!total.Success || response.ContentLength <= 0) continue;
                    var bytes = new byte[Math.Min(PieceBytes, response.ContentLength)];
                    int got = 0;
                    while (got < bytes.Length)
                    {
                        int n = body.Read(bytes, got, bytes.Length - got);
                        if (n <= 0) break;
                        got += n;
                    }
                    if (got > 0) return new Piece { Bytes = bytes, Length = got, Total = long.Parse(total.Groups[1].Value) };
                }
            }
            catch (WebException) { }    // includes the few seconds' 403 before a new address starts working
            catch (IOException) { }
        }
        return null;
    }

    static string ReadRequest(NetworkStream net)
    {
        var text = new StringBuilder();
        var one = new byte[1];
        while (text.Length < 8192 && net.Read(one, 0, 1) == 1)
        {
            text.Append((char)one[0]);
            if (text.Length >= 4 && text.ToString(text.Length - 4, 4) == "\r\n\r\n") break;
        }
        return text.ToString();
    }

    static void Reply(NetworkStream net, string status)
    {
        byte[] b = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        net.Write(b, 0, b.Length);
    }
}
