# Helpers shared by StreamUI.ps1 and Start-DesktopStream.ps1 (dot-sourced): finding ffmpeg and copying to
# the clipboard. Getting ffmpeg on a PC that doesn't have it is in Dialogs.ps1 and Install-FFmpeg.ps1.

# Only one program can use the clipboard at a time, so it's often briefly busy (the window and the stream
# script both copy the public link). Never worth failing over. Returns whether it worked.
function Copy-ToClipboard($text) {
    for ($try = 0; $try -lt 10; $try++) {
        try { Set-Clipboard -Value $text -ErrorAction Stop; return $true } catch { Start-Sleep -Milliseconds 150 }
    }
    $false
}

# Usable = has ffprobe beside it and is new enough for program capture (gfxcapture arrived in ffmpeg 8)
function Test-FFmpeg($exe) {
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $exe) "ffprobe.exe"))) { return $false }
    $ErrorActionPreference = "Continue"
    try { [bool](& $exe -hide_banner -filters 2>$null | Select-String -SimpleMatch "gfxcapture" -Quiet) } catch { $false }
}

# One already installed on this PC, otherwise the copy this program downloaded into tools\ffmpeg
function Find-FFmpeg($toolsDir) {
    foreach ($exe in (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source, (Join-Path $toolsDir "ffmpeg\ffmpeg.exe")) {
        if (Test-FFmpeg $exe) { return $exe }
    }
}
