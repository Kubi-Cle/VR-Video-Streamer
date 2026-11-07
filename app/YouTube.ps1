# YouTube for StreamUI.ps1 (dot-sourced): asking yt-dlp things without freezing the window.
# Each question runs yt-dlp as its own process; Update-YouTubeJobs (on a timer) hands over the answer.

$script:ytJobs = New-Object System.Collections.ArrayList
$script:ytUpdated = $false

# Any web address counts: yt-dlp reads YouTube, Twitch, Vimeo and many more, and says so if it can't
function Test-OnlineLink($text) { $text -match '^\s*https?://\S+\s*$' }

function Find-YtDlp($toolsDir) {
    $exe = Join-Path $toolsDir "youtube\yt-dlp.exe"
    if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath (Join-Path $toolsDir "youtube\deno.exe"))) { $exe }
}

# Runs yt-dlp and later calls $done with its parsed JSON answer (or $null) and its last error line
function Start-YouTubeJob($ytArgs, [scriptblock]$done, $tag) {
    $folder = Split-Path $script:ytDlpExe
    # yt-dlp replacing itself (Update-YtDlpOnce) leaves a moment with no program there
    for ($try = 0; $try -lt 10 -and -not (Test-Path -LiteralPath $script:ytDlpExe); $try++) { Start-Sleep -Milliseconds 200 }
    $id = [guid]::NewGuid().ToString("N")
    $out = Join-Path $env:TEMP "VRVideoStreamer-yt-$id.json"
    $err = Join-Path $env:TEMP "VRVideoStreamer-yt-$id.err"
    $common = @("--ignore-config", "--js-runtimes", (Quote "deno:$(Join-Path $folder 'deno.exe')"))
    $proc = Start-Process $script:ytDlpExe -ArgumentList (($common + $ytArgs) -join " ") -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $out -RedirectStandardError $err
    [void]$script:ytJobs.Add(@{ Proc = $proc; Out = $out; Err = $err; Done = $done; Tag = $tag; Read = $false; ReadyAt = 0 })
}

function Update-YouTubeJobs {
    foreach ($job in @($script:ytJobs)) {
        if (-not $job.Proc.HasExited) { continue }
        if (-not $job.Read) {
            $job.Read = $true
            try { $job.Answer = (Get-Content -LiteralPath $job.Out -Raw -Encoding UTF8) | ConvertFrom-Json } catch { }
            $job.Why = "yt-dlp gave no answer."
            try {
                $last = Get-Content -LiteralPath $job.Err -Encoding UTF8 | Where-Object { $_ -match 'ERROR' } | Select-Object -Last 1
                if ($last) { $job.Why = ($last -replace '^ERROR:\s*', '') }
            } catch { }
            foreach ($f in $job.Out, $job.Err) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
            # A new address is refused until YouTube's stated moment, often a few seconds away
            foreach ($format in @($job.Answer.requested_formats)) {
                if ($format.available_at -gt $job.ReadyAt) { $job.ReadyAt = $format.available_at }
            }
        }
        if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt $job.ReadyAt) { continue }
        $script:ytJobs.Remove($job)
        & $job.Done $job.Answer $job.Why $job.Tag
    }
}

# yt-dlp breaks when YouTube changes things and fixes it within days, so stay current. Once per window.
function Update-YtDlpOnce {
    if ($script:ytUpdated) { return }
    $script:ytUpdated = $true
    Start-Process $script:ytDlpExe -ArgumentList "--ignore-config -U" -WindowStyle Hidden | Out-Null
}

function New-YouTubeItem($id, $title, $duration) {
    $seconds = 0.0
    [void][double]::TryParse([string]$duration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)
    @{ Path = "https://www.youtube.com/watch?v=$id"; Name = ("$title" -replace '\s+', ' ').Trim(); IsOnline = $true; Site = "YouTube"; Subs = $null
       Thumb = "https://i.ytimg.com/vi/$id/mqdefault.jpg"; Media = @{ Duration = $seconds; HasVideo = $true; HasAudio = $true } }
}

# One entry of yt-dlp's answer about a link, from any site
function New-OnlineItem($entry, $link) {
    $site = "$($entry.ie_key)$($entry.extractor_key)" -replace 'Tab$', '' -replace '^Generic$', 'Online'
    if ($site -match '^Youtube' -or $link -match 'youtu\.?be') { if ($entry.id) { return New-YouTubeItem $entry.id $entry.title $entry.duration } }
    $seconds = 0.0
    [void][double]::TryParse([string]$entry.duration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)
    $address = if ($entry.webpage_url) { $entry.webpage_url } elseif ($entry.url -and -not $entry.formats) { $entry.url } else { $link }
    $thumb = if ($entry.thumbnail) { $entry.thumbnail } elseif ($entry.thumbnails) { @($entry.thumbnails)[-1].url }
    $title = if ($entry.title) { $entry.title } else { $address }
    @{ Path = $address; Name = ("$title" -replace '\s+', ' ').Trim(); IsOnline = $true; Site = $(if ($site) { $site } else { "Online" }); Subs = $null
       Thumb = $thumb; Media = @{ Duration = $seconds; HasVideo = $true; HasAudio = $true } }
}

# Search results, or $done gets nothing plus why
function Search-YouTube($query, [scriptblock]$done) {
    Start-YouTubeJob @("--flat-playlist", "-J", "--no-warnings", (Quote "ytsearch15:$query")) $done
}

# A link's title and length, or every video if it's a playlist. Not yet anything playable (see Get-YouTubeStream).
function Get-YouTubeLinkInfo($url, [scriptblock]$done, $tag) {
    Start-YouTubeJob @("--flat-playlist", "--no-playlist", "--playlist-end", "200", "-J", "--no-warnings", "--", (Quote $url.Trim())) $done $tag
}

# The video's actual addresses. They expire after some hours, so this is only asked for when it's about to play.
# Picks the best up to the stream's height, H.264 where offered as it takes the least CPU to decode. Sound is
# stereo without YouTube's "-drc" variants: the 5.1 track it would otherwise pick measured 5 dB quieter once mixed down.
function Get-YouTubeStream($url, $height, [scriptblock]$done, $tag) {
    $format = "bv*+ba[audio_channels<=2][format_id!*=drc]/bv*+ba/b"
    Start-YouTubeJob @("-J", "--no-playlist", "--no-warnings", "-f", (Quote $format), "-S", (Quote "res:$height,vcodec:h264"), "--", (Quote $url)) $done $tag
}

# Live videos come as a playlist of short segments (not "https"), which has nothing to gain from this
function Get-PlayableAddress($format) {
    # Only YouTube has that limit, and other sites may not hand out pieces at all
    if ($format.protocol -ne "https" -or $format.url -notmatch 'googlevideo\.com') { return $format.url }
    if (-not $script:segmentProxy) { $script:segmentProxy = New-Object SegmentProxy }
    $script:segmentProxy.Add($format.url)
}

# Every caption track in that same answer: made by the uploader, or automatic
function Read-YouTubeCaptions($info) {
    foreach ($kind in @(@{ Field = "subtitles"; Auto = $false }, @{ Field = "automatic_captions"; Auto = $true })) {
        $tracks = $info.($kind.Field)
        if (-not $tracks) { continue }
        $codes = @($tracks.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($track in $tracks.PSObject.Properties) {
            if ($track.Name -eq "live_chat") { continue }
            # "en-orig" is what was actually said, so a plain "en" beside it is the same words listed twice
            if ($kind.Auto -and $codes -contains "$($track.Name)-orig") { continue }
            $json = @($track.Value) | Where-Object { $_.ext -eq "json3" } | Select-Object -First 1
            $name = if ($json.name) { $json.name -replace '\s*\(Original\)$', '' } else { $track.Name }
            if ($json) { @{ Code = $track.Name; Name = $name; Auto = $kind.Auto; Url = $json.url } }
        }
    }
}

# Turn that answer into what the player needs, or nothing if it holds no address
function Read-YouTubeStream($info) {
    $picked = @($info.requested_formats)
    $video = $picked | Where-Object { $_.vcodec -and $_.vcodec -ne "none" } | Select-Object -First 1
    # Not by its audio codec: on live videos YouTube leaves that blank
    $audio = $picked | Where-Object { $_.vcodec -eq "none" } | Select-Object -First 1
    $main = if ($video) { $video } else { $info }
    if (-not $main.url) { return }
    $hasAudio = [bool]$audio -or $main.acodec -ne "none"
    $hasVideo = $main.vcodec -ne "none"   # sound-only sites, such as SoundCloud, get a black picture like a music file
    # What this site expects to see from whoever fetches the video. YouTube's go through SegmentProxy, which doesn't need them.
    $options = ""
    if ($main.url -notmatch 'googlevideo\.com') {
        $headers = $main.http_headers
        if ($headers.'User-Agent') { $options = "-user_agent `"$($headers.'User-Agent')`"" }
        if ($headers.Referer) { $options += " -referer `"$($headers.Referer)`"" }
    }
    $duration = 0.0
    [void][double]::TryParse([string]$info.duration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration)
    @{ File = (Get-PlayableAddress $main); AudioFile = $(if ($video -and $audio) { Get-PlayableAddress $audio }); Duration = $duration; Title = $info.title; HasAudio = $hasAudio; HasVideo = $hasVideo; Options = $options
       Captions = @(Read-YouTubeCaptions $info)
       Chapters = @($info.chapters | Where-Object { $_ } | ForEach-Object { @{ Start = [double]$_.start_time; Title = "$($_.title)" } }) }
}
