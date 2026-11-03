<#
.SYNOPSIS
  Downloads yt-dlp (reads YouTube) and Deno (which yt-dlp needs for YouTube) into tools\youtube, checking
  each against the checksum its publisher posts. Run by the window on first use (YouTube.ps1), or by hand.
#>
param(
    [string]$ToolsDir = (Join-Path $PSScriptRoot "tools"),
    [string]$ErrorFile = ""
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # the progress display makes downloads many times slower
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$target = Join-Path $ToolsDir "youtube"
$unpack = Join-Path $ToolsDir "youtube-download"

function Get-Verified($url, $checksumUrl, $file) {
    $listed = Invoke-WebRequest $checksumUrl -UseBasicParsing
    $text = if ($listed.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($listed.Content) } else { $listed.Content }
    # yt-dlp lists every release file on its own line; Deno's holds only its own, with the name on another line
    $line = $text -split "`r?`n" | Where-Object { $_ -match [regex]::Escape((Split-Path $file -Leaf)) -and $_ -match '[0-9a-fA-F]{64}' } | Select-Object -First 1
    if (-not $line) { $line = $text }
    if ($line -notmatch '[0-9a-fA-F]{64}') { throw "Couldn't read the checksum for $(Split-Path $file -Leaf)." }
    $expected = $Matches[0]
    Invoke-WebRequest $url -UseBasicParsing -OutFile $file
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $expected) {
        throw "The download of $(Split-Path $file -Leaf) was damaged or changed (its checksum doesn't match). Please try again."
    }
}

try {
    New-Item -ItemType Directory -Force $unpack, $target | Out-Null
    $ytdlp = Join-Path $unpack "yt-dlp.exe"
    $yt = "https://github.com/yt-dlp/yt-dlp/releases/latest/download"
    Get-Verified "$yt/yt-dlp.exe" "$yt/SHA2-256SUMS" $ytdlp

    $zip = Join-Path $unpack "deno-x86_64-pc-windows-msvc.zip"
    $deno = "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip"
    Get-Verified $deno "$deno.sha256sum" $zip
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entry = $archive.Entries | Where-Object { $_.Name -eq "deno.exe" } | Select-Object -First 1
        if (-not $entry) { throw "deno.exe wasn't in the download." }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $target "deno.exe"), $true)
    } finally { $archive.Dispose() }
    Move-Item -LiteralPath $ytdlp -Destination (Join-Path $target "yt-dlp.exe") -Force
    "YouTube tools are ready: $target"
}
catch {
    if ($ErrorFile) { Set-Content -LiteralPath $ErrorFile -Value $_.Exception.Message }
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
finally {
    if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force -ErrorAction SilentlyContinue }
}
