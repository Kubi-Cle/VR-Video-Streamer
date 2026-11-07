<#
.SYNOPSIS
  Puts a downloaded update in place. The window starts this (from a copy in the update folder) after it has downloaded
  the new version and checked it against its published checksum, then closes. This waits for it to close, copies the
  new files over the program folder and opens the program again. Files that aren't in the release (FFmpeg, AI subtitle
  tools, anything else downloaded later) are left alone, and so is yt-dlp, which keeps itself up to date.
#>
param([int]$WaitFor, [string]$From, [string]$To)
$ErrorActionPreference = "Stop"
$updateFolder = Split-Path (Split-Path $From)     # $From is <update folder>\new\VR Video Streamer
$log = Join-Path $updateFolder "install.log"
$exe = Join-Path $To "VR Video Streamer.exe"
try {
    if (-not (Test-Path -LiteralPath (Join-Path $From "VR Video Streamer.exe")) -or -not (Test-Path -LiteralPath (Join-Path $To "app"))) { throw "The update or the program folder is missing." }
    # The window, then the tools it started, which can take a moment longer to let go of their files
    try { Wait-Process -Id $WaitFor -Timeout 120 -ErrorAction Stop } catch { }
    Start-Sleep -Seconds 1
    $keep = @()
    if (Test-Path -LiteralPath (Join-Path $To "app\tools\youtube\yt-dlp.exe")) { $keep = @("/XF", (Join-Path $From "app\tools\youtube\yt-dlp.exe")) }
    $output = & robocopy.exe $From $To /E /R:30 /W:1 /NP /NJH /NJS @keep
    $code = $LASTEXITCODE
    Set-Content -LiteralPath $log -Value $output -Encoding UTF8
    if ($code -ge 8) { throw "Copying the new files failed (robocopy error $code). Some files may be in use." }
    Start-Process -FilePath $exe -WorkingDirectory $To
    # Out of the update folder first: Windows won't remove a folder that's in use as the current one
    Set-Location -LiteralPath $env:TEMP
    [Environment]::CurrentDirectory = $env:TEMP
    Start-Sleep -Seconds 2
    Remove-Item -LiteralPath $updateFolder -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    Add-Content -LiteralPath $log -Value "FAILED: $($_.Exception.Message)" -ErrorAction SilentlyContinue
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show("The update couldn't be installed:`n$($_.Exception.Message)`n`nYou can download the new version from GitHub instead. Details are in:`n$log", "VR Video Streamer")
    if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe -WorkingDirectory $To }
}
