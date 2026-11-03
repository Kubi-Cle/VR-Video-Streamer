# Getting subtitles, for StreamUI.ps1 (dot-sourced, and also in background tasks, so nothing here touches the
# window). Sources: YouTube's captions, tracks inside a file, and OpenSubtitles.org, which needs no account or key.

$script:OpenSubtitlesApi = "https://rest.opensubtitles.org"
$script:OpenSubtitlesAgent = "VR Video Streamer v1.1"
$script:AppData = Join-Path $env:LOCALAPPDATA "VRVideoStreamer"
# Short = how files usually label them (ISO 639-2)
$script:SubtitleLanguages = @(
    @{ Name = "English"; Code = "en"; Short = "eng" }, @{ Name = "Spanish"; Code = "es"; Short = "spa" },
    @{ Name = "French"; Code = "fr"; Short = "fre|fra" }, @{ Name = "German"; Code = "de"; Short = "ger|deu" },
    @{ Name = "Portuguese"; Code = "pt"; Short = "por" }, @{ Name = "Italian"; Code = "it"; Short = "ita" },
    @{ Name = "Dutch"; Code = "nl"; Short = "dut|nld" }, @{ Name = "Polish"; Code = "pl"; Short = "pol" },
    @{ Name = "Russian"; Code = "ru"; Short = "rus" }, @{ Name = "Turkish"; Code = "tr"; Short = "tur" },
    @{ Name = "Chinese"; Code = "zh"; Short = "chi|zho"; Font = "msyh.ttc" }, @{ Name = "Japanese"; Code = "ja"; Short = "jpn"; Font = "YuGothM.ttc" },
    @{ Name = "Korean"; Code = "ko"; Short = "kor"; Font = "malgun.ttf" })

# The file to draw subtitles with. Arial has no Chinese, Japanese or Korean, and FFmpeg can't borrow from another font.
function Get-SubtitleFontPath($settings) {
    $name = if ($settings.SubsFont -ne "auto") { $settings.SubsFont } else { ($script:SubtitleLanguages | Where-Object { $_.Code -eq $settings.SubsLanguage }).Font }
    if (-not $name) { $name = "arial.ttf" }
    Join-Path $env:WINDIR "Fonts\$name"
}

function Get-SubtitleCacheFolder {
    $folder = Join-Path $script:AppData "subtitles"
    New-Item -ItemType Directory -Force $folder | Out-Null
    $folder
}

# A file name that stays the same for the same source, for reusing what's already been fetched
function Get-SubtitleCachePath($prefix, $text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace("-", "").Substring(0, 24)
    $sha.Dispose()
    Join-Path (Get-SubtitleCacheFolder) "$prefix-$hash.srt"
}

function Format-SrtTime([long]$ms) {
    $t = [TimeSpan]::FromMilliseconds($ms)
    "{0:00}:{1:00}:{2:00},{3:000}" -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds, $t.Milliseconds
}

# YouTube's captions (its "json3" format) saved as an .srt. The direct address is instant, but YouTube often
# refuses it with "429" for machine-translated captions, while yt-dlp's slower way (a few seconds) still works.
function Save-YouTubeCaption($url, $path, $ytDlp, $videoUrl, $language) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $body = $null
    try { $body = (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 20).Content }
    catch {
        $base = "$path.download"
        $ErrorActionPreference = "Continue"
        & $ytDlp --ignore-config --js-runtimes "deno:$(Join-Path (Split-Path $ytDlp) 'deno.exe')" --no-warnings --skip-download --write-subs --write-auto-subs `
            --sub-langs $language --sub-format json3 -o "$base.%(ext)s" -- $videoUrl 2>$null | Out-Null
        $ErrorActionPreference = "Stop"
        $saved = Get-ChildItem -LiteralPath (Split-Path $path) -File | Where-Object { $_.Name.StartsWith((Split-Path $base -Leaf)) -and $_.Extension -eq ".json3" } | Select-Object -First 1
        if (-not $saved) { throw "YouTube wouldn't send those captions right now. Try again in a minute." }
        $body = [IO.File]::ReadAllText($saved.FullName, [Text.Encoding]::UTF8)
        Remove-Item -LiteralPath $saved.FullName -Force
    }
    if ($body -is [byte[]]) { $body = [Text.Encoding]::UTF8.GetString($body) }
    $lines = New-Object Collections.ArrayList
    foreach ($e in (ConvertFrom-Json $body).events) {
        if (-not $e.segs) { continue }
        $text = (($e.segs | ForEach-Object { $_.utf8 }) -join "").Replace("`n", " ").Trim()
        if ($text) { [void]$lines.Add(@{ Start = [long]$e.tStartMs; End = [long]$e.tStartMs + [long]$e.dDurationMs; Text = $text }) }
    }
    if (-not $lines.Count) { throw "Those captions turned out to be empty." }
    $srt = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # Automatic captions overlap: each is shown until well after the next begins
        $end = $lines[$i].End
        if ($i + 1 -lt $lines.Count -and $end -gt $lines[$i + 1].Start) { $end = $lines[$i + 1].Start }
        [void]$srt.Append("$($i + 1)`n$(Format-SrtTime $lines[$i].Start) --> $(Format-SrtTime $end)`n$($lines[$i].Text)`n`n")
    }
    [IO.File]::WriteAllText($path, $srt.ToString(), (New-Object Text.UTF8Encoding($false)))
    $path
}

# A subtitle track from inside a video file saved as an .srt. Can take a while, as the track runs through the whole file.
function Save-EmbeddedSubtitle($ffmpeg, $file, $streamIndex, $path) {
    $part = "$path.part.srt"
    $ErrorActionPreference = "Continue"
    & $ffmpeg -nostdin -hide_banner -loglevel error -y -i $file -map "0:$streamIndex" -c:s srt $part 2>$null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $part) -or (Get-Item -LiteralPath $part).Length -eq 0) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        throw "Couldn't read that subtitle track from the file."
    }
    Move-Item -LiteralPath $part -Destination $path -Force
    $path
}

# Keys and tokens: stored per PC, encrypted for this Windows user, and outside this folder
function Get-Secret($name) {
    $file = Join-Path $script:AppData $name
    if (-not (Test-Path -LiteralPath $file)) { return }
    try {
        $secure = (Get-Content -LiteralPath $file -Raw).Trim() | ConvertTo-SecureString
        (New-Object System.Net.NetworkCredential("", $secure)).Password
    } catch { }   # made by another Windows user or PC: same as having none
}

function Set-Secret($name, $value) {
    New-Item -ItemType Directory -Force $script:AppData | Out-Null
    $value.Trim() | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString |
        Set-Content -LiteralPath (Join-Path $script:AppData $name) -Encoding ascii
}

# Upload speed in Mbit/s, sending random data to Cloudflare's public speed test. Takes a few seconds.
function Measure-UploadSpeed {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $block = New-Object byte[] (1MB)
    (New-Object Random).NextBytes($block)
    $best = 0.0
    foreach ($megabytes in 4, 16) {
        $request = [Net.HttpWebRequest]::Create("https://speed.cloudflare.com/__up")
        $request.Method = "POST"
        $request.ContentType = "application/octet-stream"
        $request.ContentLength = $megabytes * 1MB
        $request.AllowWriteStreamBuffering = $false
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 30000
        $request.UserAgent = "VR Video Streamer"
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $body = $request.GetRequestStream()
        for ($i = 0; $i -lt $megabytes -and $clock.Elapsed.TotalSeconds -lt 12; $i++) { $body.Write($block, 0, $block.Length) }
        if ($i -lt $megabytes) { $request.Abort(); $sent = $i; $seconds = $clock.Elapsed.TotalSeconds }
        else { $body.Close(); $request.GetResponse().Close(); $sent = $megabytes; $seconds = $clock.Elapsed.TotalSeconds }
        $speed = $sent * 8 * 1.048576 / $seconds
        if ($speed -gt $best) { $best = $speed }
        if ($seconds -gt 4) { break }   # a slow connection has given a fair reading already
    }
    $best
}

function Invoke-OpenSubtitles($path) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try { Invoke-RestMethod "$script:OpenSubtitlesApi$path" -TimeoutSec 20 -UserAgent $script:OpenSubtitlesAgent -Headers @{ "X-User-Agent" = $script:OpenSubtitlesAgent; Accept = "application/json" } }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($status -eq 429 -or $status -eq 407) { throw "OpenSubtitles says that's too many requests for now. Try again later." }
        if ($status) { throw "OpenSubtitles answered with an error ($status). Try again in a moment." }
        throw "Couldn't reach OpenSubtitles: $($_.Exception.Message)"
    }
}

# Rows with what's worth showing: ones made for this exact file first (if $file is given), then most downloaded.
# The site expects the settings in the address in alphabetical order.
function Search-OpenSubtitles($query, $language, $file) {
    $id = (($script:SubtitleLanguages | Where-Object { $_.Code -eq $language }).Short -split '\|')[0]
    if (-not $id) { $id = "eng" }
    $found = @()
    if ($file) {
        $info = Get-Item -LiteralPath $file
        $found += @(Invoke-OpenSubtitles "/search/moviebytesize-$($info.Length)/moviehash-$([SubtitleOverlay]::FileHash($file))/sublanguageid-$id")
    }
    if ("$query".Trim()) {
        $found += @(Invoke-OpenSubtitles "/search/query-$([uri]::EscapeDataString($query.Trim().ToLowerInvariant()))/sublanguageid-$id")
    }
    # Only .srt can be shown. The same file can come back from both searches: the exact match is the one to keep.
    $rows = @($found | ForEach-Object { $_ } | Where-Object { $_.SubFormat -eq "srt" -and $_.SubDownloadLink } | ForEach-Object {
            [pscustomobject]@{
                FileId    = $_.IDSubtitleFile
                Link      = $_.SubDownloadLink
                Title     = "$($_.MovieName)$(if ($_.MovieYear) { " ($($_.MovieYear))" })"
                Release   = "$($_.MovieReleaseName)"
                Downloads = [int]$_.SubDownloadsCnt
                Hearing   = $_.SubHearingImpaired -eq "1"
                Exact     = $_.MatchedBy -eq "moviehash"
            }
        } | Sort-Object @{ Expression = "Exact"; Descending = $true }, @{ Expression = "Downloads"; Descending = $true })
    $seen = @{}
    @($rows | Where-Object { if ($seen[$_.FileId]) { $false } else { $seen[$_.FileId] = $true; $true } } | Select-Object -First 60)
}

# Saves the .srt and returns its path. One already fetched is reused rather than asked for again.
function Get-OpenSubtitlesFile($link, $fileId) {
    $path = Join-Path (Get-SubtitleCacheFolder) "opensubtitles-$([long]$fileId).srt"
    if (Test-Path -LiteralPath $path) { return $path }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try { $packed = (Invoke-WebRequest $link -UseBasicParsing -TimeoutSec 30 -UserAgent $script:OpenSubtitlesAgent -Headers @{ "X-User-Agent" = $script:OpenSubtitlesAgent }).Content }
    catch { throw "OpenSubtitles wouldn't send that one right now. Try again later, or pick another." }
    if ($packed -isnot [byte[]]) { throw "OpenSubtitles sent a message instead of the subtitles, which usually means too many downloads today. Try again later." }
    $plain = New-Object IO.MemoryStream
    try {
        Add-Type -AssemblyName System.IO.Compression
        $unzip = New-Object IO.Compression.GZipStream((New-Object IO.MemoryStream(, $packed)), [IO.Compression.CompressionMode]::Decompress)
        $unzip.CopyTo($plain); $unzip.Dispose()
    } catch { throw "OpenSubtitles sent a message instead of the subtitles, which usually means too many downloads today. Try again later." }
    $bytes = $plain.ToArray()
    if ([Text.Encoding]::ASCII.GetString($bytes) -notmatch '-->') { throw "That download doesn't contain subtitles. Pick another." }
    [IO.File]::WriteAllBytes($path, $bytes)
    [void][SubtitleOverlay]::RemoveAds($path)
    $path
}

# For turning subtitles on automatically: only a version OpenSubtitles knows was made for this exact file. A
# search by name could put the wrong movie's subtitles on screen. Returns its path and name, or nothing.
function Find-ExactOpenSubtitles($file, $language) {
    $rows = @(Search-OpenSubtitles "" $language $file | Where-Object { $_.Exact })
    if (-not $rows.Count) { return }
    @{ Path = (Get-OpenSubtitlesFile $rows[0].Link $rows[0].FileId); Name = $rows[0].Release }
}

# A file name's title without the release details, as a starting point for searching
function Get-SubtitleSearchText($name) {
    if ($name -notmatch '\.[a-z0-9]{2,4}$') { return $name.Trim() }   # a YouTube title, not a file name
    $text = [IO.Path]::GetFileNameWithoutExtension($name) -replace '[._]', ' '
    $text = $text -replace '(?i)\b(1080p|720p|2160p|480p|4k|x264|x265|h ?264|h ?265|hevc|bluray|brrip|web-?dl|webrip|hdtv|dvdrip|aac|ac3|dts)\b.*$', ''
    $text.Trim()
}

function Get-Settings {
    $settings = @{ SubsAuto = $true; SubsLanguage = "en"; SubsSize = 20; SubsPlace = "bottom"; SubsColor = "white"; SubsFont = "auto"
                   Volume = 100; EvenOut = $false; Card = $true; PermanentHost = ""; Preview = $true; AudioBitrate = "128k" }
    try {
        $saved = Get-Content -LiteralPath (Join-Path $script:AppData "settings.json") -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($name in @($settings.Keys)) { if ($null -ne $saved.$name) { $settings[$name] = $saved.$name } }
    } catch { }   # none saved yet
    $settings
}

function Save-Settings($settings) {
    New-Item -ItemType Directory -Force $script:AppData | Out-Null
    $settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:AppData "settings.json") -Encoding utf8
}
