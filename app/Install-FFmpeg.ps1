<#
.SYNOPSIS
  Downloads FFmpeg into tools\ffmpeg, checking it against the checksum its publisher posts. Run by the
  window on first use (Dialogs.ps1), or by hand: .\Install-FFmpeg.ps1
#>
param(
    [string]$ToolsDir = (Join-Path $PSScriptRoot "tools"),
    [string]$Url = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip",
    [string]$ErrorFile = ""
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # the progress display makes downloads many times slower
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $PSScriptRoot "FFmpegSetup.ps1")

$zip = Join-Path $ToolsDir "ffmpeg-download.zip"
$unpack = Join-Path $ToolsDir "ffmpeg-unpack"
$target = Join-Path $ToolsDir "ffmpeg"
try {
    New-Item -ItemType Directory -Force $ToolsDir | Out-Null
    Invoke-WebRequest "$Url.sha256" -UseBasicParsing -OutFile "$zip.sha256"
    $expected = (Get-Content -LiteralPath "$zip.sha256" -Raw).Trim().Split()[0]
    Invoke-WebRequest $Url -UseBasicParsing -OutFile $zip
    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "The download was damaged or changed (its checksum doesn't match). Please try again." }

    New-Item -ItemType Directory -Force $unpack | Out-Null   # tells the progress window we've moved on to unpacking
    New-Item -ItemType Directory -Force $target | Out-Null
    # Only the two files needed, straight into tools\ffmpeg: recreating the zip's own folders
    # (Expand-Archive) fails when the program is in a long path
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($name in "ffmpeg.exe", "ffprobe.exe") {
            $entry = $archive.Entries | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if (-not $entry) { throw "$name wasn't in the download." }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $target $name), $true)
        }
    } finally { $archive.Dispose() }
    if (-not (Test-FFmpeg (Join-Path $target "ffmpeg.exe"))) { throw "The downloaded FFmpeg didn't run, or is too old for program capture." }
    "FFmpeg is ready: $target"
}
catch {
    if ($ErrorFile) { Set-Content -LiteralPath $ErrorFile -Value $_.Exception.Message }
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
finally {
    foreach ($leftover in $zip, "$zip.sha256", $unpack) {
        if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
