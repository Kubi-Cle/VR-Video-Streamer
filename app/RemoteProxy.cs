// Sits in front of the stream server for the public link, so the same link can also carry the remote control page.
//
//   link service  -->  RemoteProxy (127.0.0.1:8890)  --everything else-->  MediaMTX (127.0.0.1:8888)
//                           |
//                           +-- /remote/<secret>/...  the remote control page, its state and its commands
//
// The secret changes with every stream, so an old remote link stops working. Commands wait in a queue for the
// window to carry out on its own thread; the window also writes the state the page shows. Each request is passed
// on with "Connection: close" and then the connection ends, which keeps this simple: there's never a second
// request on a connection to look at. The link services keep their own connections to viewers open regardless.
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public class RemoteProxy
{
    readonly TcpListener listener;
    readonly int target;
    readonly string pageFile;
    public readonly int Port;
    public volatile string Secret;            // null = no remote just now
    public volatile string State = "{}";      // JSON, written by the window
    public readonly ConcurrentQueue<string> Commands = new ConcurrentQueue<string>();
    public int Requests;                       // remote requests answered, for tests

    public RemoteProxy(int port, int target, string pageFile)
    {
        this.target = target;
        this.pageFile = pageFile;
        listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        new Thread(Accept) { IsBackground = true, Name = "RemoteProxy" }.Start();
    }

    public void Stop() { try { listener.Stop(); } catch { } }

    void Accept()
    {
        while (true)
        {
            TcpClient client;
            try { client = listener.AcceptTcpClient(); }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) { if (!listener.Server.IsBound) return; Thread.Sleep(200); continue; }
            catch (Exception) { Thread.Sleep(200); continue; }   // an error on this thread would close the whole program
            new Thread(() => Serve(client)) { IsBackground = true, Name = "RemoteProxy client" }.Start();
        }
    }

    void Serve(TcpClient client)
    {
        try
        {
            client.NoDelay = true;
            client.ReceiveTimeout = 30000;
            client.SendTimeout = 30000;
            NetworkStream net = client.GetStream();
            string head = ReadHead(net);
            Match line = Regex.Match(head, @"^([A-Z]+) (\S+) HTTP/1\.[01]\r\n");
            if (!line.Success) { Reply(net, "400 Bad Request", "text/plain", ""); return; }
            string method = line.Groups[1].Value, path = line.Groups[2].Value;
            if (path.StartsWith("/remote", StringComparison.OrdinalIgnoreCase)) { ServeRemote(net, head, method, path); return; }
            Forward(net, head);
        }
        catch (Exception) { }   // the viewer or player went away; anything else on this thread would close the program
        finally { client.Close(); }
    }

    void ServeRemote(NetworkStream net, string head, string method, string path)
    {
        Interlocked.Increment(ref Requests);
        string secret = Secret;
        string prefix = "/remote/" + secret;
        int query = path.IndexOf('?');
        if (query >= 0) path = path.Substring(0, query);
        if (string.IsNullOrEmpty(secret) || !(path == prefix || path.StartsWith(prefix + "/", StringComparison.Ordinal)))
        {
            Thread.Sleep(300);   // makes guessing slow, on top of the secret being long
            Reply(net, "404 Not Found", "text/plain; charset=utf-8", "This remote link has expired. Ask for the new one.");
            return;
        }
        string rest = path.Substring(prefix.Length);
        if (rest == "")
        {
            byte[] b = Encoding.ASCII.GetBytes("HTTP/1.1 302 Found\r\nLocation: " + prefix + "/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            net.Write(b, 0, b.Length);
        }
        else if (rest == "/" && method == "GET")
            Reply(net, "200 OK", "text/html; charset=utf-8", File.ReadAllText(pageFile, Encoding.UTF8));
        else if (rest == "/state" && method == "GET")
            Reply(net, "200 OK", "application/json; charset=utf-8", State);
        else if (rest == "/command" && method == "POST")
        {
            Match length = Regex.Match(head, @"(?im)^Content-Length:\s*(\d+)");
            int n = length.Success ? int.Parse(length.Groups[1].Value) : 0;
            if (n <= 0 || n > 4096) { Reply(net, "400 Bad Request", "text/plain", ""); return; }
            var body = new byte[n];
            int got = 0;
            while (got < n) { int r = net.Read(body, got, n - got); if (r <= 0) break; got += r; }
            if (Commands.Count < 50) Commands.Enqueue(Encoding.UTF8.GetString(body, 0, got));
            Reply(net, "204 No Content", null, null);
        }
        else Reply(net, "404 Not Found", "text/plain", "");
    }

    // A shorter link for the same stream, easier to type in a headset: "/v.m3u8" is the stream's playlist, and the
    // files that playlist names (relative, so they arrive here as "/main_stream.m3u8" and so on) are the stream's too.
    // Link shortening services all refuse these free tunnel addresses as an abuse risk, so this is the short link.
    public const string ShortPath = "/v.m3u8";
    static string Rewrite(string path)
    {
        if (path == ShortPath || path == "/") return "/desktop/index.m3u8";
        if (path.StartsWith("/desktop/", StringComparison.Ordinal)) return path;
        if (Regex.IsMatch(path, @"^/[\w.-]+$")) return "/desktop" + path;
        return path;
    }

    // Hands the request to MediaMTX with "Connection: close", then copies the answer back until it's done
    void Forward(NetworkStream net, string head)
    {
        head = Regex.Replace(head, @"^([A-Z]+) (\S+)", m => m.Groups[1].Value + " " + Rewrite(m.Groups[2].Value));
        using (var server = new TcpClient())
        {
            server.NoDelay = true;
            server.Connect(IPAddress.Loopback, target);
            server.ReceiveTimeout = 60000;
            NetworkStream up = server.GetStream();
            string cleaned = Regex.Replace(head, @"(?im)^(Connection|Keep-Alive|Proxy-Connection):[^\r\n]*\r\n", "");
            cleaned = cleaned.Substring(0, cleaned.Length - 2) + "Connection: close\r\n\r\n";
            byte[] h = Encoding.ASCII.GetBytes(cleaned);
            up.Write(h, 0, h.Length);
            Match length = Regex.Match(head, @"(?im)^Content-Length:\s*(\d+)");
            long body = length.Success ? long.Parse(length.Groups[1].Value) : 0;
            var buffer = new byte[65536];
            while (body > 0)
            {
                int r = net.Read(buffer, 0, (int)Math.Min(buffer.Length, body));
                if (r <= 0) break;
                up.Write(buffer, 0, r);
                body -= r;
            }
            int n;
            while ((n = up.Read(buffer, 0, buffer.Length)) > 0) net.Write(buffer, 0, n);
        }
    }

    // Header names and values are ASCII, so a byte at a time is fine for these few hundred bytes
    static string ReadHead(NetworkStream net)
    {
        var text = new StringBuilder();
        var one = new byte[1];
        while (text.Length < 16384 && net.Read(one, 0, 1) == 1)
        {
            text.Append((char)one[0]);
            if (text.Length >= 4 && text[text.Length - 1] == '\n' && text.ToString(text.Length - 4, 4) == "\r\n\r\n") break;
        }
        return text.ToString();
    }

    static void Reply(NetworkStream net, string status, string type, string body)
    {
        byte[] content = Encoding.UTF8.GetBytes(body ?? "");
        string head = "HTTP/1.1 " + status + "\r\n" + (type != null ? "Content-Type: " + type + "\r\n" : "") +
            "Content-Length: " + content.Length + "\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n" +
            "Referrer-Policy: no-referrer\r\nConnection: close\r\n\r\n";
        byte[] h = Encoding.ASCII.GetBytes(head);
        net.Write(h, 0, h.Length);
        if (content.Length > 0) net.Write(content, 0, content.Length);
    }
}
