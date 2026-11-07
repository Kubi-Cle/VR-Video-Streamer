// Makes chosen programs silent on this PC while viewers still hear them, so you don't hear them twice.
//
// Windows offers no way to do that directly: its per-program mute silences the stream's capture too (measured). But
// a program's volume reaches the capture as a plain multiplication, so turning it down to 0.01% is inaudible here,
// and SoundMixer boosts it back by the same amount. Captured as floats, that loses nothing (measured: 79 dB clean,
// against 8 dB or worse for 16-bit audio at 0.1%).
//
// Windows remembers a program's volume after it closes, so each original volume is written to a file before it's
// changed. The stream's own process does the turning down, but it's stopped without warning, so the window calls
// RestoreFromFile whenever a stream ends and when it opens. A line stays in the file until its program's been seen.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISqDeviceEnumerator
{
    void EnumAudioEndpoints(int dataFlow, int stateMask, out ISqDeviceCollection devices);
}

[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISqDeviceCollection
{
    void GetCount(out int count);
    void Item(int index, out ISqDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISqDevice
{
    void Activate([MarshalAs(UnmanagedType.LPStruct)] Guid iid, int context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object service);
}

[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISqSessionManager
{
    void GetAudioSessionControl(IntPtr guid, int flags, [MarshalAs(UnmanagedType.IUnknown)] out object control);
    void GetSimpleAudioVolume(IntPtr guid, int flags, [MarshalAs(UnmanagedType.IUnknown)] out object volume);
    void GetSessionEnumerator(out ISqSessionEnumerator sessions);
}

[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISqSessionEnumerator
{
    void GetCount(out int count);
    void GetSession(int index, out ISqSessionControl session);
}

[ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISqSessionControl
{
    void GetState(out int state);
    void GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
    void SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr context);
    void GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
    void SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr context);
    void GetGroupingParam(out Guid group);
    void SetGroupingParam(ref Guid group, IntPtr context);
    void RegisterAudioSessionNotification(IntPtr notifications);
    void UnregisterAudioSessionNotification(IntPtr notifications);
    void GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
    void GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
    void GetProcessId(out int processId);
}

[ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISqAudioClient
{
    void Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
    void GetBufferSize(out uint frames);
    void GetStreamLatency(out long latency);
    void GetCurrentPadding(out uint padding);
    [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
    void GetMixFormat(out IntPtr format);
}

[ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISqSimpleVolume
{
    void SetMasterVolume(float level, IntPtr context);
    void GetMasterVolume(out float level);
}

public class SessionQuiet
{
    public const float Boost = 10000f;   // what SoundMixer multiplies a quieted program by
    // Windows remembers a volume per program file, so another session of the same program can start out turned down
    // too (measured). Nobody really plays anything this low, so at or under this it's taken to be inherited from here.
    const float Inherited = 0.001f;
    const int Render = 0, ActiveOnly = 1, AllContexts = 23;

    class Saved { public string Instance, Identifier; public float Volume; }

    readonly string memoryFile;
    readonly Dictionary<string, Saved> saved = new Dictionary<string, Saved>();   // by session instance
    readonly Dictionary<string, float> known = new Dictionary<string, float>();   // true volumes, by program

    public SessionQuiet(string memoryFile)
    {
        this.memoryFile = memoryFile;
        Directory.CreateDirectory(Path.GetDirectoryName(memoryFile));   // not there yet on a new install
        if (File.Exists(memoryFile))
            foreach (string line in File.ReadAllLines(memoryFile))
            {
                string[] parts = line.Split('\t');
                float level;
                if (parts.Length == 3 && float.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out level) && level > Inherited) known[parts[2]] = level;
            }
    }

    delegate void SessionAction(ISqSessionControl control);

    static void ForEachSession(SessionAction action)
    {
        var enumerator = (ISqDeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")));
        ISqDeviceCollection devices;
        enumerator.EnumAudioEndpoints(Render, ActiveOnly, out devices);
        int deviceCount;
        devices.GetCount(out deviceCount);
        for (int d = 0; d < deviceCount; d++)
        {
            try
            {
                ISqDevice device;
                devices.Item(d, out device);
                object service;
                device.Activate(typeof(ISqSessionManager).GUID, AllContexts, IntPtr.Zero, out service);
                ISqSessionEnumerator sessions;
                ((ISqSessionManager)service).GetSessionEnumerator(out sessions);
                int count;
                sessions.GetCount(out count);
                for (int i = 0; i < count; i++)
                {
                    try
                    {
                        ISqSessionControl control;
                        sessions.GetSession(i, out control);
                        action(control);
                    }
                    catch (COMException) { }           // that session just closed
                    catch (InvalidCastException) { }
                }
            }
            catch (COMException) { }                   // that device just went away
        }
    }

    // How much a program's captured sound has to be raised to make up for the device it plays on, or 0 if it isn't
    // playing anything yet. Capture asks for stereo, and Windows lowers sound when folding a surround device down to
    // that. Measured on a 6-channel device: 10.6 dB lower than on a stereo one, whatever the level. Other layouts
    // haven't been measured, so they're left as they are rather than guessed at.
    public static float DeviceGain(int processId)
    {
        const int Active = 1;
        var wanted = WithChildren(new[] { processId });
        var enumerator = (ISqDeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")));
        ISqDeviceCollection devices;
        enumerator.EnumAudioEndpoints(Render, ActiveOnly, out devices);
        int deviceCount;
        devices.GetCount(out deviceCount);
        float idle = 0f;
        for (int d = 0; d < deviceCount; d++)
        {
            try
            {
                ISqDevice device;
                devices.Item(d, out device);
                object service;
                device.Activate(typeof(ISqSessionManager).GUID, AllContexts, IntPtr.Zero, out service);
                ISqSessionEnumerator sessions;
                ((ISqSessionManager)service).GetSessionEnumerator(out sessions);
                int count;
                sessions.GetCount(out count);
                bool found = false, playing = false;
                for (int i = 0; i < count; i++)
                {
                    try
                    {
                        ISqSessionControl control;
                        sessions.GetSession(i, out control);
                        int id, state;
                        control.GetProcessId(out id);
                        if (!wanted.Contains(id)) continue;
                        found = true;
                        control.GetState(out state);
                        if (state == Active) playing = true;
                    }
                    catch (COMException) { }
                }
                if (!found) continue;
                object client;
                device.Activate(typeof(ISqAudioClient).GUID, AllContexts, IntPtr.Zero, out client);
                IntPtr format;
                ((ISqAudioClient)client).GetMixFormat(out format);
                int channels = Marshal.ReadInt16(format, 2);
                Marshal.FreeCoTaskMem(format);
                float gain = channels == 6 ? 3.388f : 1f;
                if (playing) return gain;   // a program can have old sessions on other devices, so this one counts
                idle = gain;
            }
            catch (COMException) { }
        }
        return idle;
    }

    // Turns these programs (and the processes they started, which is often what actually plays) down, and any
    // others this turned down back up. Called repeatedly, as a program's sound can start at any moment.
    public void Update(int[] processIds)
    {
        var wanted = WithChildren(processIds);
        bool changed = false;
        ForEachSession(control =>
        {
            int id;
            control.GetProcessId(out id);
            string instance, identifier;
            control.GetSessionInstanceIdentifier(out instance);
            control.GetSessionIdentifier(out identifier);
            var volume = (ISqSimpleVolume)control;
            if (wanted.Contains(id))
            {
                if (saved.ContainsKey(instance)) return;
                float level;
                volume.GetMasterVolume(out level);
                float truth;
                if (level <= Inherited && known.TryGetValue(identifier, out truth)) level = truth;
                else known[identifier] = level;
                saved[instance] = new Saved { Instance = instance, Identifier = identifier, Volume = level };
                // Before changing it, so a crash just after this can't lose the original. If that can't be done
                // it stays as it is, and it's tried again next time.
                try { Save(); }
                catch { saved.Remove(instance); throw; }
                changed = true;
                volume.SetMasterVolume(level / Boost, IntPtr.Zero);
            }
            else if (saved.ContainsKey(instance))
            {
                volume.SetMasterVolume(saved[instance].Volume, IntPtr.Zero);
                saved.Remove(instance);
                changed = true;
            }
            else
            {
                // A session this program never turned down itself, but which started out low because of one that was
                float truth, level;
                if (!known.TryGetValue(identifier, out truth)) return;
                volume.GetMasterVolume(out level);
                if (level <= Inherited) volume.SetMasterVolume(truth, IntPtr.Zero);
            }
        });
        // A program that's closed: Windows will bring back the low volume next time, so its line has to stay
        if (changed) Save();
    }

    void Save()
    {
        var lines = new List<string>();
        foreach (var s in saved.Values) lines.Add(s.Volume.ToString("R", CultureInfo.InvariantCulture) + "\t" + s.Instance + "\t" + s.Identifier);
        // Lines from an earlier stream, for programs not seen since, are kept too
        if (File.Exists(memoryFile))
            foreach (string old in File.ReadAllLines(memoryFile))
            {
                string[] parts = old.Split('\t');
                if (parts.Length != 3) continue;
                bool ours = false;
                foreach (var s in saved.Values) if (s.Identifier == parts[2]) ours = true;
                if (!ours && !IsRunning(parts[2])) lines.Add(old);
            }
        if (lines.Count == 0) { try { File.Delete(memoryFile); } catch (IOException) { } return; }
        File.WriteAllLines(memoryFile, lines.ToArray());
    }

    static bool IsRunning(string identifier)
    {
        bool found = false;
        ForEachSession(control =>
        {
            string id;
            control.GetSessionIdentifier(out id);
            if (id == identifier) found = true;
        });
        return found;
    }

    // Puts back every volume in the file whose program has a session now; the others wait for next time. The same
    // running session gets exactly its own volume back. Two windows of one program share an identifier, so going by
    // that is only for sessions still turned right down, which can't be told apart any better.
    public static void RestoreFromFile(string memoryFile)
    {
        if (!File.Exists(memoryFile)) return;
        var entries = new List<string[]>();
        foreach (string line in File.ReadAllLines(memoryFile))
        {
            string[] parts = line.Split('\t');
            float ignored;
            if (parts.Length == 3 && float.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out ignored)) entries.Add(parts);
        }
        var used = new HashSet<string[]>();
        var sessions = new List<KeyValuePair<string, ISqSessionControl>>();
        ForEachSession(control =>
        {
            string instance;
            control.GetSessionInstanceIdentifier(out instance);
            foreach (var e in entries)
                if (e[1] == instance)
                {
                    ((ISqSimpleVolume)control).SetMasterVolume(float.Parse(e[0], CultureInfo.InvariantCulture), IntPtr.Zero);
                    used.Add(e);
                    return;
                }
            sessions.Add(new KeyValuePair<string, ISqSessionControl>(instance, control));
        });
        // Anything else of the same program that's still turned down, whether reopened or a second copy
        foreach (var pair in sessions)
        {
            try
            {
                string identifier;
                float current;
                pair.Value.GetSessionIdentifier(out identifier);
                ((ISqSimpleVolume)pair.Value).GetMasterVolume(out current);
                if (current > Inherited) continue;
                foreach (var e in entries)
                    if (e[2] == identifier)
                    {
                        ((ISqSimpleVolume)pair.Value).SetMasterVolume(float.Parse(e[0], CultureInfo.InvariantCulture), IntPtr.Zero);
                        used.Add(e);
                        break;
                    }
            }
            catch (COMException) { }
        }
        var remaining = new List<string>();
        foreach (var e in entries) if (!used.Contains(e)) remaining.Add(string.Join("\t", e));
        if (remaining.Count == 0) { try { File.Delete(memoryFile); } catch (IOException) { } }
        else File.WriteAllLines(memoryFile, remaining.ToArray());
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct ProcessEntry
    {
        public int Size, Usage, ProcessId;
        public IntPtr DefaultHeap;
        public int ModuleId, Threads, ParentProcessId, BasePriority, Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string ExeFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(int flags, int processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

    static HashSet<int> WithChildren(int[] roots)
    {
        var all = new HashSet<int>(roots);
        if (roots.Length == 0) return all;
        var pairs = new List<KeyValuePair<int, int>>();
        IntPtr snapshot = CreateToolhelp32Snapshot(2, 0);
        if (snapshot == new IntPtr(-1)) return all;
        try
        {
            var entry = new ProcessEntry { Size = Marshal.SizeOf(typeof(ProcessEntry)) };
            if (Process32FirstW(snapshot, ref entry))
                do { pairs.Add(new KeyValuePair<int, int>(entry.ProcessId, entry.ParentProcessId)); }
                while (Process32NextW(snapshot, ref entry));
        }
        finally { CloseHandle(snapshot); }
        bool grew = true;
        while (grew)
        {
            grew = false;
            foreach (var p in pairs) if (all.Contains(p.Value) && all.Add(p.Key)) grew = true;
        }
        return all;
    }
}
