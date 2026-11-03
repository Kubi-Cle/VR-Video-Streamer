<#
.SYNOPSIS
  Streams your Windows desktop to a URL that VR video players (AVPro) can play,
  including games running standalone on a Steam Frame / Quest (via HLS).

.EXAMPLE
  .\Start-DesktopStream.ps1                      # primary monitor, 1080p, 30fps
  .\Start-DesktopStream.ps1 -Monitor 1           # second monitor
  .\Start-DesktopStream.ps1 -Encoder nvenc       # NVIDIA GPU encoding (much less CPU)
  .\Start-DesktopStream.ps1 -AudioDevice "Stereo Mix (Realtek(R) Audio)"
  .\Start-DesktopStream.ps1 -AudioPid 1234,5678 -AudioDevice "Stereo Mix (Realtek(R) Audio)"   # mix several
  .\Start-DesktopStream.ps1 -Window "Untitled - Notepad"   # one program's window (exact title)
  .\Start-DesktopStream.ps1 "C:\Videos\movie.mp4" -Loop    # play a file (or drop it on the shortcut)
  .\Start-DesktopStream.ps1 -ListMonitors
  .\Start-DesktopStream.ps1 -ListAudio
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [string]$File = "",                 # video/music file to play instead of capturing the screen
    [switch]$Loop,                      # repeat the file forever
    [string]$Window = "",               # capture one window by its title instead of a monitor
    [long]$WindowHwnd = 0,              # ...or by its window handle (StreamUI.ps1 passes this)
    [switch]$AppAudio,                  # with -Window: stream that program's own sound
    [string]$AudioPid = "",             # monitor or window: stream the sound of these processes, e.g. 1234,5678
    [int]$Monitor = -1,                 # -1 = primary monitor
    [int]$Height = 1080,                # output height (keep <=1080 for standalone headsets)
    [int]$Fps = 30,
    [string]$Bitrate = "4M",
    [string]$AudioBitrate = "128k",
    [ValidateSet("cpu", "nvenc", "amf", "qsv")]
    [string]$Encoder = "cpu",
    [string]$AudioDevice = "",          # DirectShow audio device name, see -ListAudio; several: "name 1|name 2"
    [string]$StreamName = "desktop",
    [switch]$ListMonitors,
    [switch]$ListAudio,
    [switch]$Pick,                      # ask which monitor to stream (used by the desktop shortcut)
    [switch]$Public,                    # also make a public https link via a free tunnel service
    [ValidateSet("auto", "cloudflare", "localhost.run", "pinggy", "permanent")]
    [string]$Tunnel = "auto",           # which service makes the public link; auto = try them in order
    [string]$PermanentHost = "",        # with -Tunnel permanent: your address, e.g. stream.example.com (token in $env:TUNNEL_TOKEN)
    [string]$PipeInput = "",            # used by StreamUI.ps1: read raw frames + PCM from \\.\pipe\<name>-v / -a
    [string]$PipeSize = "",             # frame size of -PipeInput, e.g. 1920x1080
    [string]$SubtitleText = "",         # used by StreamUI.ps1: text file holding the current subtitle (SubtitleOverlay.cs)
    [int]$SubtitleSize = 20,            # picture height / this = letter height, so smaller numbers are bigger
    [ValidateSet("bottom", "top")]
    [string]$SubtitlePlace = "bottom",
    [string]$SubtitleColor = "white",
    [string]$SubtitleFont = ""          # a font file; Arial if not given or not found
)

$ErrorActionPreference = "Stop"
# Files from a zip carry Windows' "downloaded from the internet" mark, and starting our tools then hangs
# on a prompt nobody can see when this runs hidden. The person chose to run this, so clear it.
Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File | ForEach-Object { try { Unblock-File -LiteralPath $_.FullName } catch { } }
# Everything started from here (ffmpeg, MediaMTX, tunnels, window capture) dies with this process,
# however it ends. Must come before any process is started.
Add-Type -Path (Join-Path $PSScriptRoot "KillOnClose.cs")
if (-not [KillOnClose]::Enable()) { Write-Host "Warning: couldn't set up auto-cleanup; close with Ctrl+C instead of X." -ForegroundColor Yellow }
$MediaMtxVersion = "v1.9.3"
$ToolsDir = Join-Path $PSScriptRoot "tools"
$MediaMtxExe = Join-Path $ToolsDir "mediamtx.exe"
$ConfigPath = Join-Path $ToolsDir "mediamtx-stream.yml"
$CloudflaredExe = Join-Path $ToolsDir "cloudflared.exe"

# Real pixel coordinates on high-DPI displays
Add-Type -Name Dpi -Namespace Win32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][Win32.Dpi]::SetProcessDPIAware()
Add-Type -AssemblyName System.Windows.Forms
$screens = [System.Windows.Forms.Screen]::AllScreens

if ($ListMonitors) {
    for ($i = 0; $i -lt $screens.Count; $i++) {
        $b = $screens[$i].Bounds
        $p = if ($screens[$i].Primary) { " (primary)" } else { "" }
        "[$i] $($b.Width)x$($b.Height) at $($b.X),$($b.Y)$p"
    }
    return
}

. (Join-Path $PSScriptRoot "FFmpegSetup.ps1")
$ffmpeg = Find-FFmpeg $ToolsDir
if (-not $ffmpeg) {
    throw "FFmpeg 8 or newer wasn't found. Run .\Install-FFmpeg.ps1, or install it with:  winget install Gyan.FFmpeg   (then open a new terminal)"
}

function Get-AudioDevices {
    $ErrorActionPreference = "Continue"   # ffmpeg prints the device list on stderr
    & $ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 |
        Where-Object { $_ -match '\(audio\)' } | ForEach-Object { ($_ -split '"')[1] }
}

if ($ListAudio) {
    Get-AudioDevices
    return
}

# --- MediaMTX (the stream server) ---
if (-not (Test-Path $MediaMtxExe)) {
    Write-Host "Downloading MediaMTX $MediaMtxVersion..."
    New-Item -ItemType Directory -Force $ToolsDir | Out-Null
    $zip = Join-Path $ToolsDir "mediamtx.zip"
    $url = "https://github.com/bluenviron/mediamtx/releases/download/$MediaMtxVersion/mediamtx_${MediaMtxVersion}_windows_amd64.zip"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath $ToolsDir -Force
    Remove-Item $zip
}

# HLS as plain MPEG-TS: the most compatible format for AVPro on Android/standalone headsets.
# Only HLS, which viewers can only watch, is reachable from other devices. The ports that accept a stream
# being sent in stay on this PC, so nobody on the network can replace what's showing.
@"
logLevel: warn
api: yes
apiAddress: 127.0.0.1:9997
metrics: no
pprof: no
playback: no
webrtc: no
srt: no
rtsp: yes
rtspAddress: 127.0.0.1:8554
protocols: [tcp]
rtmp: yes
rtmpAddress: 127.0.0.1:1935
hls: yes
hlsAddress: :8888
hlsAllowOrigin: '*'
hlsAlwaysRemux: yes
hlsVariant: mpegts
hlsSegmentCount: 3
hlsSegmentDuration: 1s
paths:
  all_others:
"@ | Set-Content -Path $ConfigPath -Encoding ascii

# --- What to stream ---
$Source = if ($PipeInput) { "pipe" } elseif ($File) { "file" } elseif ($Window -or $WindowHwnd) { "window" } else { "monitor" }
if ($Pick) {
    $Host.UI.RawUI.WindowTitle = "VR Video Streamer"
    if (-not $File -and -not $Window) {
        Write-Host "What do you want to stream?" -ForegroundColor Cyan
        Write-Host "  [1] A whole monitor"
        Write-Host "  [2] One program's window"
        Write-Host "  [3] A video or music file"
        $answer = Read-Host "Type a number and press Enter (just Enter = monitor)"
        $Source = switch ($answer.Trim()) { "2" { "window" } "3" { "file" } default { "monitor" } }
    }

    if ($Source -eq "monitor") {
        Write-Host "Which monitor?" -ForegroundColor Cyan
        for ($i = 0; $i -lt $screens.Count; $i++) {
            $sb = $screens[$i].Bounds
            $p = if ($screens[$i].Primary) { "  (main)" } else { "" }
            Write-Host "  [$($i + 1)] $($sb.Width) x $($sb.Height)$p"
        }
        do {
            $answer = Read-Host "Type a number and press Enter (just Enter = main monitor)"
            if ($answer -eq "") { $Monitor = -1; break }
            $n = 0
            if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $screens.Count) { $Monitor = $n - 1; break }
            Write-Host "  Not a valid choice." -ForegroundColor Red
        } while ($true)
    }
    elseif ($Source -eq "window" -and -not $Window) {
        $windows = @(Get-Process | Where-Object {
                $_.MainWindowTitle -and $_.Id -ne $PID -and $_.MainWindowTitle -ne "VR Video Streamer" } |
            Sort-Object ProcessName)
        Write-Host "Which program? (it has to stay open and not minimized)" -ForegroundColor Cyan
        for ($i = 0; $i -lt $windows.Count; $i++) {
            Write-Host "  [$($i + 1)] $($windows[$i].ProcessName) - $($windows[$i].MainWindowTitle)"
        }
        do {
            $n = 0
            if ([int]::TryParse((Read-Host "Type a number and press Enter"), [ref]$n) -and $n -ge 1 -and $n -le $windows.Count) {
                $Window = $windows[$n - 1].MainWindowTitle; break
            }
            Write-Host "  Not a valid choice." -ForegroundColor Red
        } while ($true)
    }
    elseif ($Source -eq "file" -and -not $File) {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = "Pick a video or music file to stream"
        $dialog.Filter = "Video and music|*.mp4;*.mkv;*.webm;*.mov;*.avi;*.wmv;*.flv;*.ts;*.m4v;*.mp3;*.wav;*.flac;*.ogg;*.m4a;*.aac;*.opus|All files|*.*"
        $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }   # keeps the dialog in front
        if ($dialog.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $File = $dialog.FileName
    }

    if ($Source -eq "file") {
        Write-Host "File: $File" -ForegroundColor DarkGray
        if (-not $Loop) { $Loop = (Read-Host "Loop it? (y/N)") -match '^\s*y' }
    }
    elseif ($Source -eq "window") {
        if (-not $AppAudio) { $AppAudio = (Read-Host "Stream that program's sound too? (Y/n)") -notmatch '^\s*n' }
    }
    elseif (-not $AudioDevice) {
        $answer = Read-Host "Stream your PC's sound too? (y/N)"
        if ($answer -match '^\s*y') {
            $devices = @(Get-AudioDevices)
            $AudioDevice = $devices | Where-Object { $_ -like "Stereo Mix*" } | Select-Object -First 1
            if (-not $AudioDevice) {
                Write-Host "  'Stereo Mix' not found (enable it in Control Panel > Sound > Recording). Pick another input:" -ForegroundColor Yellow
                for ($i = 0; $i -lt $devices.Count; $i++) { Write-Host "  [$($i + 1)] $($devices[$i])" }
                $n = 0
                if ([int]::TryParse((Read-Host "Number (Enter = no sound)"), [ref]$n) -and $n -ge 1 -and $n -le $devices.Count) {
                    $AudioDevice = $devices[$n - 1]
                }
            }
            if ($AudioDevice) { Write-Host "  Sound from: $AudioDevice" -ForegroundColor DarkGray }
        }
    }
    if (-not $Public) {
        $answer = Read-Host "Let other people view the video player (public link)? (Y/n)"
        $Public = $answer -notmatch '^\s*n'
    }
}
# --- Inputs ---
$ffArgs = @("-hide_banner", "-loglevel", "warning", "-stats")
$hasAudio = $false
switch ($Source) {
    "pipe" {
        # The window's player (PipePlayer.cs) paces frames and audio itself, with pause and seek
        $what = "video player"
        $ffArgs += @("-thread_queue_size", "64", "-probesize", "32", "-analyzeduration", "0",
                     "-f", "rawvideo", "-pix_fmt", "yuv420p", "-video_size", $PipeSize, "-framerate", $Fps,
                     "-i", "\\.\pipe\$PipeInput-v",
                     "-thread_queue_size", "1024", "-probesize", "32", "-analyzeduration", "0",
                     "-f", "s16le", "-ar", "48000", "-ch_layout", "stereo", "-i", "\\.\pipe\$PipeInput-a")
        $maps = @("-map", "0:v", "-map", "1:a")
        $hasAudio = $true
    }
    "monitor" {
        $screen = if ($Monitor -ge 0) { $screens[$Monitor] } else { [System.Windows.Forms.Screen]::PrimaryScreen }
        if (-not $screen) { throw "Monitor $Monitor not found. Use -ListMonitors." }
        $b = $screen.Bounds
        $what = "monitor $($b.Width)x$($b.Height)"
        $ffArgs += @("-f", "gdigrab", "-framerate", $Fps, "-draw_mouse", "1",
                     "-offset_x", $b.X, "-offset_y", $b.Y, "-video_size", "$($b.Width)x$($b.Height)", "-i", "desktop")
        $maps = @("-map", "0:v")
    }
    "window" {
        # Windows Graphics Capture: right size with display scaling, works while covered, and captures
        # GPU-drawn windows (browsers) that the older gdigrab shows zoomed in or black
        $proc = if ($WindowHwnd) { Get-Process | Where-Object { [long]$_.MainWindowHandle -eq $WindowHwnd } | Select-Object -First 1 }
                else { Get-Process | Where-Object { $_.MainWindowTitle -eq $Window } | Select-Object -First 1 }
        if (-not $proc) { throw "Window not found: '$Window$(if ($WindowHwnd) { " ($WindowHwnd)" })'. Is it still open?" }
        $WindowHwnd = [long]$proc.MainWindowHandle
        $what = "window '$($proc.MainWindowTitle)'"

        # Output size from the window's real size (physical pixels; this script is DPI-aware). A
        # minimized window reports a tiny rectangle, so use its restored size then.
        Add-Type -Name WinRect -Namespace VVS -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct PLACEMENT { public int length, flags, showCmd, minX, minY, maxX, maxY; public RECT normal; }
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
[DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref PLACEMENT p);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
'@
        $r = New-Object VVS.WinRect+RECT
        if ([VVS.WinRect]::IsIconic([IntPtr]$WindowHwnd)) {
            $wp = New-Object VVS.WinRect+PLACEMENT; $wp.length = 44
            [void][VVS.WinRect]::GetWindowPlacement([IntPtr]$WindowHwnd, [ref]$wp); $r = $wp.normal
            Write-Host "Note: that window is minimized. Viewers see black until you restore it (behind other windows is fine)." -ForegroundColor Yellow
        } else { [void][VVS.WinRect]::DwmGetWindowAttribute([IntPtr]$WindowHwnd, 9, [ref]$r, 16) }   # extended frame bounds
        $srcW = [Math]::Max(320, $r.Right - $r.Left); $srcH = [Math]::Max(180, $r.Bottom - $r.Top)
        $outH = [Math]::Min($Height, $srcH); $outW = $srcW * $outH / $srcH
        if ($outW -gt 3840) { $outW = 3840; $outH = $srcH * 3840 / $srcW }   # keep within what headsets decode
        $outH = [int]$outH - ([int]$outH % 2); $outW = [int][Math]::Round($outW / 2) * 2

        # Windows Graphics Capture delivers nothing while a window is minimized; FrameRelay keeps sending
        # 30 fps anyway (repeating the last picture) so the stream never stalls and video players keep playing
        Add-Type -Path (Join-Path $PSScriptRoot "FrameRelay.cs") -ReferencedAssemblies System.Core
        $videoPipe = "vvs-win-$PID"
        $relay = New-Object FrameRelay($ffmpeg,
            "-f lavfi -i `"gfxcapture=hwnd=${WindowHwnd}:max_framerate=${Fps}:resize_mode=scale_aspect,hwdownload,format=bgra`"",
            $videoPipe, $outW, $outH, $Fps)
        $relay.Start()
        $ffArgs += @("-thread_queue_size", "64", "-probesize", "32", "-analyzeduration", "0",
                     "-f", "rawvideo", "-pix_fmt", "yuv420p", "-video_size", "${outW}x${outH}", "-framerate", $Fps,
                     "-i", "\\.\pipe\$videoPipe-v")
        $maps = @("-map", "0:v")
        if ($AppAudio) { $AudioPid = "$($proc.Id),$AudioPid" }
    }
    "file" {
        if (-not (Test-Path -LiteralPath $File)) { throw "File not found: $File" }
        $File = (Resolve-Path -LiteralPath $File).Path
        $what = "file '$(Split-Path $File -Leaf)'" + $(if ($Loop) { " (looping)" } else { "" })
        # Cover art in music files shows up as a 1-frame "video" stream (attached_pic=1); ignore it
        $ffprobe = Join-Path (Split-Path $ffmpeg) "ffprobe.exe"
        $kinds = & $ffprobe -v error -show_entries stream=codec_type:stream_disposition=attached_pic -of csv=p=0 $File
        $hasVideo = [bool]($kinds | Where-Object { $_ -match '^video,0' })
        $hasAudio = [bool]($kinds | Where-Object { $_ -match '^audio' })
        $loopArgs = if ($Loop) { @("-stream_loop", "-1") } else { @() }
        if ($hasVideo) {
            $ffArgs += @("-re") + $loopArgs + @("-i", $File)
            $maps = @("-map", "0:v:0")
            if ($hasAudio) { $maps += @("-map", "0:a:0") }
        } else {
            # Music only: black picture so video players have something to show.
            # Only the music gets -re; it paces the whole output (-re on the picture too halves the speed).
            $ffArgs += @("-f", "lavfi", "-i", "color=c=black:s=1280x720:r=$Fps", "-re") + $loopArgs + @("-i", $File)
            $maps = @("-map", "0:v", "-map", "1:a:0", "-shortest")
        }
    }
}
# Sound sources, each its own ffmpeg input after the picture (input 0). Programs don't have to be the
# one in the picture. Delay = ms to hold the sound back so it matches the picture:
# - program capture: the picture reaches the stream ~100 ms after the sound (window capture + FrameRelay).
#   Measured: sound 90-150 ms early without this, +30 ms late with 120.
# - monitor with a program's sound: measured 46-113 ms early (average 67) without this.
$soundDelays = @()
if ($Source -in "monitor", "window") {
    $appCaptures = @()
    foreach ($soundId in @($AudioPid -split "[, ]+" | Where-Object { $_ } | Select-Object -Unique)) {
        $soundProc = Get-Process -Id $soundId -ErrorAction SilentlyContinue
        if (-not $soundProc) { Write-Host "Skipping sound from process $soundId, it has closed." -ForegroundColor Yellow; continue }
        Add-Type -Path (Join-Path $PSScriptRoot "ProcessAudio.cs")
        $audioPipe = "vvs-app-$PID-$($appCaptures.Count)"
        $capture = New-Object ProcessAudioCapture([int]$soundId, $audioPipe)
        $capture.Start()
        $appCaptures += $capture
        $ffArgs += @("-thread_queue_size", "1024", "-probesize", "32", "-analyzeduration", "0",
                     "-f", "s16le", "-ar", "48000", "-ch_layout", "stereo", "-i", "\\.\pipe\$audioPipe")
        $soundDelays += $(if ($relay) { 100 } else { 65 })
        $what += " + sound from $($soundProc.ProcessName)"
    }
    # A device opened by the main ffmpeg drops the picture to ~2 real fps with NVENC, so it's captured
    # by its own ffmpeg (see DeviceAudio.cs) and arrives through a steady pipe, just like a program's sound
    $deviceCaptures = @()
    foreach ($device in @($AudioDevice -split "\|" | Where-Object { $_ })) {
        Add-Type -Path (Join-Path $PSScriptRoot "DeviceAudio.cs")
        $audioPipe = "vvs-dev-$PID-$($deviceCaptures.Count)"
        $capture = New-Object DeviceAudioCapture($ffmpeg, $device, $audioPipe)
        $capture.Start()
        $deviceCaptures += $capture
        $ffArgs += @("-thread_queue_size", "1024", "-probesize", "32", "-analyzeduration", "0",
                     "-f", "s16le", "-ar", "48000", "-ch_layout", "stereo", "-i", "\\.\pipe\$audioPipe")
        $soundDelays += $(if ($relay) { 100 } else { 65 })
        $what += " + sound from $device"
    }
    if ($soundDelays.Count -eq 1) { $maps += @("-map", "1:a") }
    elseif ($soundDelays.Count -gt 1) {
        # Mix at full volume rather than amix's default of turning each source down; the limiter stops
        # loud moments from clipping. Each source starts at time 0 whatever order the inputs opened in.
        $chains = @(); $labels = ""
        for ($i = 0; $i -lt $soundDelays.Count; $i++) {
            $chains += "[$($i + 1):a]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo,adelay=delays=$($soundDelays[$i]):all=1[s$i]"
            $labels += "[s$i]"
        }
        $mix = ($chains -join ";") + ";${labels}amix=inputs=$($soundDelays.Count):duration=longest:normalize=0,alimiter=limit=0.95:level=0[mix]"
        $maps += @("-filter_complex", $mix, "-map", "[mix]")
    }
    if ($soundDelays.Count) { $hasAudio = $true }
}

# --- Encoder settings (H.264 main profile, 1 keyframe per second so HLS segments line up) ---
$gop = $Fps
$video = switch ($Encoder) {
    "nvenc" { @("-c:v", "h264_nvenc", "-preset", "p4", "-tune", "ll", "-profile:v", "main") }
    "amf"   { @("-c:v", "h264_amf", "-usage", "lowlatency", "-profile:v", "main") }
    "qsv"   { @("-c:v", "h264_qsv", "-preset", "veryfast", "-profile:v", "main") }
    # x264's sliced threads (from -tune zerolatency) drop capture to ~2 fps when there's an audio input
    default { @("-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-x264-params", "sliced-threads=0", "-profile:v", "main") }
}
# Shrink to $Height if bigger, never upscale; keep both sides even for H.264
$videoFilter = "scale=-2:'min($Height,trunc(ih/2)*2)'"
$subtitleFont = if ($SubtitleFont -and (Test-Path -LiteralPath $SubtitleFont)) { $SubtitleFont } else { Join-Path $env:WINDIR "Fonts\arial.ttf" }
if ($SubtitleText -and (Test-Path -LiteralPath $subtitleFont)) {
    # Subtitles are drawn after scaling so they're the same size at any quality. The text file is named
    # relative to its folder, since a user name with an apostrophe would break a full path in a filter.
    Set-Location -LiteralPath (Split-Path $SubtitleText)
    $fontForFilter = ($subtitleFont -replace '\\', '/') -replace ':', '\:'
    $videoFilter += ",drawtext=textfile=$(Split-Path $SubtitleText -Leaf):reload=1:expansion=none:fontfile='$fontForFilter'" +
        ":fontsize=h/${SubtitleSize}:fontcolor=${SubtitleColor}:borderw=2:bordercolor=black:line_spacing=6:text_align=C" +
        ":x=(w-text_w)/2:y=$(if ($SubtitlePlace -eq 'top') { 'h/14' } else { 'h-text_h-h/14' }):fix_bounds=1"
}
$video += @("-r", $Fps, "-b:v", $Bitrate, "-maxrate", $Bitrate, "-bufsize", $Bitrate, "-g", $gop, "-keyint_min", $gop,
            "-pix_fmt", "yuv420p", "-vf", $videoFilter)
$audio = if ($hasAudio) { @("-c:a", "aac", "-b:a", $AudioBitrate, "-ar", "48000", "-ac", "2") } else { @("-an") }
if ($soundDelays.Count -eq 1 -and $soundDelays[0]) { $audio += @("-af", "adelay=delays=$($soundDelays[0]):all=1") }
# Publish over RTMP: its sound and picture share one clock, which keeps the HLS links in sync
# (measured within one frame). Publishing over RTSP left HLS sound ~250 ms late.
$ffArgs += $maps + $video + $audio + @("-f", "flv", "rtmp://127.0.0.1:1935/$StreamName")

# --- Run ---
$lanIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.PrefixOrigin -in "Dhcp", "Manual" -and $_.IPAddress -notlike "169.254*" } |
    Select-Object -First 1).IPAddress

if ($Public -and -not (Test-Path $CloudflaredExe)) {
    Write-Host "Downloading cloudflared (for the public link)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" `
        -OutFile $CloudflaredExe -UseBasicParsing
}


# Backup: stop leftovers from an earlier run that would hold the ports
Get-Process mediamtx, cloudflared -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($ToolsDir, [StringComparison]::OrdinalIgnoreCase) } |
    Stop-Process -Force
# Old runs' tunnel logs (skips any still in use)
Get-ChildItem $ToolsDir -Include "cloudflared*.log", "tunnel-*.log*" -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { } }

$server = Start-Process $MediaMtxExe -ArgumentList "`"$ConfigPath`"" -WorkingDirectory $ToolsDir -PassThru -WindowStyle Hidden
$tunnelProc = $null
try {
    Start-Sleep -Milliseconds 800
    if ($server.HasExited) { throw "MediaMTX failed to start (is port 8554/8888 already in use?)" }

    $publicUrl = $null
    if ($Public) {
        # Free tunnels that need no account, tried in order. Each gives a random https address per run.
        # Cloudflare first (fastest, no time limit); localhost.run and Pinggy go over the SSH client
        # built into Windows, so they need nothing installed.
        $ssh = "$env:WINDIR\System32\OpenSSH\ssh.exe"
        # A throwaway key just for these tunnels: Pinggy otherwise waits at a password prompt nobody can
        # answer in a hidden window, and IdentitiesOnly stops ssh offering your own ~/.ssh keys to them.
        # Kept per PC, outside this folder, so sharing the folder never shares a private key.
        $tunnelKey = Join-Path $env:LOCALAPPDATA "VRVideoStreamer\tunnel_key"
        New-Item -ItemType Directory -Force (Split-Path $tunnelKey) | Out-Null
        if ((Test-Path $ssh) -and -not (Test-Path $tunnelKey)) {
            & "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe" -q -t ed25519 -N '""' -C "vr-video-streamer" -f $tunnelKey
        }
        $sshOpts = "-T -i `"$tunnelKey`" -o IdentitiesOnly=yes -o PasswordAuthentication=no" +
                   " -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=`"$ToolsDir\known_hosts`"" +
                   " -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes"
        $providers = @(
            @{ Id = "cloudflare"; Name = "Cloudflare"; Exe = $CloudflaredExe; Tries = 3; Pattern = 'https://[a-z0-9-]+\.trycloudflare\.com'
               Connected = 'Registered tunnel connection'; Args = "tunnel --no-autoupdate --url http://127.0.0.1:8888" },
            @{ Id = "localhost.run"; Name = "localhost.run"; Exe = $ssh; Tries = 2; Pattern = 'https://[a-z0-9]+\.lhr\.life'
               Args = "$sshOpts -R 80:127.0.0.1:8888 nokey@localhost.run" },
            # Last resort: Pinggy's free addresses contain your public IP, and stop after 60 minutes
            @{ Id = "pinggy"; Name = "Pinggy - stops after 60 min, link shows your IP"; Exe = $ssh; Tries = 2
               Pattern = 'https://(?!dashboard\.)[a-z0-9-]+\.[a-z0-9.-]*pinggy[a-z0-9.-]*'
               Args = "$sshOpts -p 443 -R0:127.0.0.1:8888 free.pinggy.io" },
            # Your own Cloudflare tunnel: the address never changes, so it isn't read from a log.
            # Only when asked for by name, since it needs setting up. cloudflared reads the token from TUNNEL_TOKEN.
            @{ Id = "permanent"; Name = "Your permanent link"; Exe = $CloudflaredExe; Tries = 2; Fixed = "https://$PermanentHost"
               Connected = 'Registered tunnel connection'; Args = "tunnel --no-autoupdate run" }
        ) | Where-Object { ($Tunnel -eq "auto" -and $_.Id -ne "permanent") -or $_.Id -eq $Tunnel }
        # The last error a tunnel program logged, for telling people why a service was skipped
        function Get-TunnelError($log) {
            $line = Select-String -Path $log, "$log.err" -Pattern ' ERR |denied|refused|timed out|failed|error' -ErrorAction SilentlyContinue | Select-Object -Last 1
            if ($line) { $text = ($line.Line -replace '^\S+Z\s+', '').Trim(); $text.Substring(0, [Math]::Min(140, $text.Length)) } else { "no details in its log" }
        }
        $n = 0
        foreach ($prov in $providers) {
            if ($publicUrl) { break }
            if (-not (Test-Path $prov.Exe)) { continue }
            for ($attempt = 1; $attempt -le $prov.Tries -and -not $publicUrl; $attempt++) {
                Write-Host "Opening public link via $($prov.Name)$(if ($attempt -gt 1) { " (try $attempt of $($prov.Tries))" })..."
                if ($tunnelProc -and -not $tunnelProc.HasExited) { Stop-Process -Id $tunnelProc.Id -Force; $tunnelProc.WaitForExit(3000) | Out-Null }
                $n++
                $TunnelLog = Join-Path $ToolsDir "tunnel-$PID-$n.log"
                $tunnelProc = Start-Process $prov.Exe -ArgumentList $prov.Args -PassThru -WindowStyle Hidden `
                    -RedirectStandardOutput $TunnelLog -RedirectStandardError "$TunnelLog.err"
                $candidate = $prov.Fixed
                for ($t = 0; $t -lt 40 -and -not $candidate -and -not $tunnelProc.HasExited; $t++) {
                    Start-Sleep -Milliseconds 500
                    $m = Select-String -Path $TunnelLog, "$TunnelLog.err" -Pattern $prov.Pattern -ErrorAction SilentlyContinue |
                        Select-Object -First 1
                    if ($m) { $candidate = $m.Matches[0].Value }
                }
                $why = if ($candidate) { "" } elseif ($tunnelProc.HasExited) { "it closed: $(Get-TunnelError $TunnelLog)" } else { "no link after 20 s: $(Get-TunnelError $TunnelLog)" }

                # A new Cloudflare address doesn't exist in DNS for the first few seconds. Asking this PC's DNS
                # during that time makes it remember "doesn't exist" for 60 s (measured), which used to fail the
                # check below even though the link was fine. So first wait for it to connect, and for the
                # address to exist on Cloudflare's own DNS, which doesn't get stuck like that.
                $connected = $false; $inPublicDns = $false
                if ($candidate -and $prov.Connected) {
                    for ($t = 0; $t -lt 60 -and -not $connected -and -not $tunnelProc.HasExited; $t++) {
                        $connected = [bool](Select-String -Path $TunnelLog, "$TunnelLog.err" -Pattern $prov.Connected -ErrorAction SilentlyContinue)
                        if (-not $connected) { Start-Sleep -Milliseconds 500 }
                    }
                    if (-not $connected) { $why = "it never connected to Cloudflare: $(Get-TunnelError $TunnelLog)" }
                    $deadline = (Get-Date).AddSeconds(25)
                    while ($connected -and -not $inPublicDns -and (Get-Date) -lt $deadline) {
                        try { Resolve-DnsName ([uri]$candidate).Host -Server 1.1.1.1 -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null; $inPublicDns = $true }
                        catch { Start-Sleep -Milliseconds 500 }
                    }
                }

                # Any HTTP answer (MediaMTX says 404 before the stream starts) proves the tunnel is through
                $checks = if ($candidate -and $prov.Connected -and -not $connected) { 0 } elseif ($inPublicDns) { 10 } else { 20 }
                $lookupError = ""
                for ($t = 0; $t -lt $checks -and -not $publicUrl -and -not $tunnelProc.HasExited; $t++) {
                    try { Invoke-WebRequest $candidate -UseBasicParsing -TimeoutSec 5 | Out-Null; $publicUrl = $candidate }
                    catch { if ($_.Exception.Response) { $publicUrl = $candidate } else { $lookupError = $_.Exception.Message; Start-Sleep 1 } }
                }
                # Connected, and the address exists: the link works. This PC just can't open it yet (slow DNS,
                # or a filter on this network), and viewers use their own DNS, so don't throw the link away.
                if (-not $publicUrl -and $connected -and $inPublicDns -and -not $tunnelProc.HasExited) {
                    $publicUrl = $candidate
                    Write-Host "Note: the link is working, but this PC can't open it yet ($lookupError). Viewers aren't affected."
                }
                if ($publicUrl) { $publicVia = $prov.Name }
                else {
                    if ($candidate -and -not $why) { $why = "the link didn't answer: $lookupError" }
                    Write-Host "$($prov.Name) didn't work: $why"
                }
            }
        }
        if (-not $publicUrl) {
            if ($tunnelProc -and -not $tunnelProc.HasExited) { Stop-Process -Id $tunnelProc.Id -Force }
            Write-Host "Could not open a public link with $(($providers | ForEach-Object { $_.Id }) -join ' / ') (logs: $ToolsDir\tunnel-$PID-*.log). Streaming locally only." -ForegroundColor Red
        }
    }

    Write-Host ""
    if ($publicUrl) {
        Write-Host "PUBLIC LINK (via $publicVia) - works for everyone, PC and Quest/Steam Frame:" -ForegroundColor Green
        Write-Host "     $publicUrl/$StreamName/index.m3u8" -ForegroundColor Green
        if (Copy-ToClipboard "$publicUrl/$StreamName/index.m3u8") {
            Write-Host "  (Copied to clipboard - paste it into the video player with Ctrl+V.)" -ForegroundColor Green
        }
        Write-Host "  Anyone with this link can watch your screen until you stop. Each viewer uses ~$Bitrate of your upload." -ForegroundColor DarkGray
        Write-Host ""
    }
    Write-Host "Streaming $what -> up to ${Height}p @ $Fps fps ($Encoder)" -ForegroundColor Cyan
    Write-Host "Paste one of these into a VR video player (AVPro / 'Stream' mode):" -ForegroundColor Cyan
    Write-Host "  Steam Frame / Quest / any headset on your Wi-Fi:" -ForegroundColor Yellow
    Write-Host "     http://${lanIp}:8888/$StreamName/index.m3u8"
    Write-Host "  Game Window on this PC:" -ForegroundColor Yellow
    Write-Host "     http://127.0.0.1:8888/$StreamName/index.m3u8"
    Write-Host "  Low delay, PC only (RTSP - sound may drift a little):" -ForegroundColor Yellow
    Write-Host "     rtspt://127.0.0.1:8554/$StreamName"
    if (-not $publicUrl) { Write-Host "  (To let other people see it, run with -Public or answer 'y' in the shortcut menu.)" }
    Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
    Write-Host ""

    & $ffmpeg @ffArgs
    if ($Pick -and $LASTEXITCODE -ne 0) { Read-Host "ffmpeg stopped with an error. Press Enter to close" }
    elseif ($Pick -and $Source -eq "file") { Read-Host "Finished playing. Press Enter to close" }
}
finally {
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    if ($tunnelProc -and -not $tunnelProc.HasExited) { Stop-Process -Id $tunnelProc.Id -Force }
}
