<#
.SYNOPSIS
  Gets what AI subtitles need, checking each against its publisher's checksum: a Whisper speech recognition model,
  and if this PC's FFmpeg can't run one (the small one this program downloads can't), a larger FFmpeg just for this
  in tools\whisper. Run by the window on first use (Dialogs.ps1), or by hand.
#>
param(
    [string]$ToolsDir = (Join-Path $PSScriptRoot "tools"),
    [string]$ErrorFile = "",
    [string]$Model = "",        # e.g. ggml-small-q5_1.bin
    [string]$ModelFolder = "",
    [switch]$NeedTool,
    [switch]$ForceSevenZip      # for testing what older Windows versions get
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # the progress display makes downloads many times slower
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# From Hugging Face's published file list. Kept here so a changed file can't slip through.
$modelChecksums = @{
    "ggml-small-q5_1.bin"          = "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
    "ggml-large-v3-turbo-q5_0.bin" = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
}
$target = Join-Path $ToolsDir "whisper"
$archiveFile = Join-Path $ToolsDir "whisper-download.7z"
$unpack = Join-Path $ToolsDir "whisper-unpack"

# gyan.dev's full build is the one with Whisper, and it only comes as a .7z. Windows' own tar reads that on current
# versions; on older ones the official standalone 7-Zip does it (a fixed version, checked against its published checksum).
function Expand-FFmpeg {
    New-Item -ItemType Directory -Force $unpack | Out-Null
    $ErrorActionPreference = "Continue"
    if (-not $ForceSevenZip) {
        & "$env:WINDIR\System32\tar.exe" -xf $archiveFile -C $unpack 2>$null
    }
    $found = Get-ChildItem -LiteralPath $unpack -Recurse -Filter "ffmpeg.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) {
        $ErrorActionPreference = "Stop"
        $sevenZip = Join-Path $ToolsDir "7zr.exe"
        Invoke-WebRequest "https://github.com/ip7z/7zip/releases/download/26.05/7zr.exe" -UseBasicParsing -OutFile $sevenZip
        if ((Get-FileHash -LiteralPath $sevenZip -Algorithm SHA256).Hash -ne "9BF582B894DFA665F852D7E9112B02290A1C303C2D95A21FCDC41FFCB03143B7") { throw "The download of 7-Zip was damaged or changed (its checksum doesn't match). Please try again." }
        $ErrorActionPreference = "Continue"
        & $sevenZip x $archiveFile "-o$unpack" -y *>$null
        Remove-Item -LiteralPath $sevenZip -Force -ErrorAction SilentlyContinue
        $found = Get-ChildItem -LiteralPath $unpack -Recurse -Filter "ffmpeg.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    $ErrorActionPreference = "Stop"
    if (-not $found) { throw "Couldn't unpack the FFmpeg download." }
    New-Item -ItemType Directory -Force $target | Out-Null
    Move-Item -LiteralPath $found.FullName -Destination (Join-Path $target "ffmpeg.exe") -Force
}

try {
    if ($NeedTool) {
        $url = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-full.7z"
        $sums = (Invoke-WebRequest "$url.sha256" -UseBasicParsing).Content
        if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
        if ($sums -notmatch '[0-9a-fA-F]{64}') { throw "Couldn't read the checksum for FFmpeg." }
        $expected = $Matches[0]
        New-Item -ItemType Directory -Force $ToolsDir | Out-Null
        Invoke-WebRequest $url -UseBasicParsing -OutFile $archiveFile
        if ((Get-FileHash -LiteralPath $archiveFile -Algorithm SHA256).Hash -ne $expected) { throw "The FFmpeg download was damaged or changed (its checksum doesn't match). Please try again." }
        Expand-FFmpeg
        $ErrorActionPreference = "Continue"
        $canRun = & (Join-Path $target "ffmpeg.exe") -hide_banner -filters 2>$null | Select-String -Pattern '\bwhisper\b' -Quiet
        $ErrorActionPreference = "Stop"
        if (-not $canRun) { throw "The downloaded FFmpeg can't run Whisper." }
    }
    if ($Model) {
        New-Item -ItemType Directory -Force $ModelFolder | Out-Null
        $path = Join-Path $ModelFolder $Model
        $part = "$path.part"
        Invoke-WebRequest "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$Model" -UseBasicParsing -OutFile $part
        if ((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne $modelChecksums[$Model]) {
            Remove-Item -LiteralPath $part -Force
            throw "The download of $Model was damaged or changed (its checksum doesn't match). Please try again."
        }
        Move-Item -LiteralPath $part -Destination $path -Force
    }
    "Ready."
}
catch {
    if ($ErrorFile) { Set-Content -LiteralPath $ErrorFile -Value $_.Exception.Message }
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
finally {
    foreach ($leftover in $archiveFile, $unpack) {
        if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
