<#
.SYNOPSIS
  Builds the zip to send to people: release\VR-Video-Streamer-<version>.zip, with its checksum beside it.
  It's built from a list of approved files, so anything else in the folder (logs, downloads, test files) can't
  slip in, and it stops if it finds anything private. Run: powershell -ExecutionPolicy Bypass -File build\Make-Release.ps1
#>
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$root = Split-Path $PSScriptRoot
# One place for the version, Launcher.cs, and the build stops if the .exe or README don't match it
if ((Get-Content -LiteralPath "$PSScriptRoot\Launcher.cs" -Raw) -notmatch 'AssemblyVersion\("(\d+\.\d+\.\d+)\.0"\)') { throw "Couldn't read the version from Launcher.cs." }
$version = $Matches[1]
if ((Get-Item -LiteralPath "$root\VR Video Streamer.exe").VersionInfo.FileVersion -ne "$version.0") { throw "VR Video Streamer.exe isn't version $version. Run Build-Launcher.ps1 first." }
if ((Get-Content -LiteralPath "$root\README.txt" -Raw) -notmatch "Version $([regex]::Escape($version))\b") { throw "README.txt doesn't say version $version." }
$name = "VR-Video-Streamer-$version"
"--- version $version"

# Checked by hand against what each publisher released. A changed copy stops the build rather than being sent to people.
# yt-dlp updates itself, so it's checked against its publisher's list online. Deno and cloudflared carry their publishers' signatures.
$pinned = @{ "app\tools\mediamtx.exe" = "EB10FF6C28EBFA96C6C60509D9DBD8250F1A71381A9CFDD5A98311B062234155" }

if (Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq "VR Video Streamer" }) { throw "Close VR Video Streamer first." }

$files = @("VR Video Streamer.exe", "README.txt", "LICENSE", "THIRD-PARTY-NOTICES.txt", "app\app.ico",
           "app\tools\cloudflared.exe", "app\tools\mediamtx.exe", "app\tools\youtube\yt-dlp.exe", "app\tools\youtube\deno.exe")
$files += Get-ChildItem "$root\app" -File | Where-Object { $_.Extension -in ".ps1", ".cs", ".xaml" } | ForEach-Object { "app\$($_.Name)" }
$files += Get-ChildItem "$root\app\tools\licenses" -File | ForEach-Object { "app\tools\licenses\$($_.Name)" }

"--- tools"
foreach ($file in $pinned.Keys) {
    if ((Get-FileHash -LiteralPath "$root\$file" -Algorithm SHA256).Hash -ne $pinned[$file]) { throw "$file isn't the copy that was checked." }
    "  $file matches the checked copy"
}
foreach ($file in "app\tools\cloudflared.exe", "app\tools\youtube\deno.exe") {
    $signature = Get-AuthenticodeSignature -LiteralPath "$root\$file"
    if ($signature.Status -ne "Valid") { throw "$file has no valid signature ($($signature.Status))." }
    "  $file signed by $($signature.SignerCertificate.Subject -replace ',.*', '')"
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "Continue"
$ytVersion = (& "$root\app\tools\youtube\yt-dlp.exe" --version).Trim()
$ErrorActionPreference = "Stop"
$sums = (Invoke-WebRequest "https://github.com/yt-dlp/yt-dlp/releases/download/$ytVersion/SHA2-256SUMS" -UseBasicParsing).Content
if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
$expected = (($sums -split "`n") | Where-Object { $_ -match 'yt-dlp\.exe\s*$' } | Select-Object -First 1).Split()[0]
if ((Get-FileHash -LiteralPath "$root\app\tools\youtube\yt-dlp.exe" -Algorithm SHA256).Hash -ne $expected) { throw "yt-dlp doesn't match what its publisher released." }
"  yt-dlp $ytVersion matches its publisher's checksum"

$output = Join-Path $root "release"
$stage = Join-Path $env:TEMP "vvs-release-$PID"
try {
    New-Item -ItemType Directory -Force "$stage\VR Video Streamer", $output | Out-Null
    foreach ($file in $files) {
        $target = Join-Path "$stage\VR Video Streamer" $file
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item -LiteralPath "$root\$file" -Destination $target
    }

    "--- privacy check"
    $private = @(Get-ChildItem "$stage\VR Video Streamer" -Recurse -File | Where-Object { $_.Name -match '\.(key|token|log|err|json|srt|part|vvslist|pem)$|tunnel_key|known_hosts|settings' })
    if ($private) { throw "Private-looking files: $($private.Name -join ', ')" }
    $text = Get-ChildItem "$stage\VR Video Streamer" -Recurse -File | Where-Object { $_.Extension -in ".ps1", ".cs", ".xaml" -or $_.Name -eq "README.txt" }
    # This PC's names as whole words, email addresses, private keys, tokens, and home network addresses
    # (the profile folder's name can differ from the account's, so both are checked)
    $profileName = Split-Path $env:USERPROFILE -Leaf
    $checks = @("\b$([regex]::Escape($env:USERNAME))\b", "\b$([regex]::Escape($profileName))\b", "\b$([regex]::Escape($env:COMPUTERNAME))\b", '(?i)[a-z]:\\Users\\[a-z0-9]', '(?<![\w.+-])(?!nokey@localhost\.run)[\w.+-]+@[\w-]+\.[a-z]{2,}', 'BEGIN [A-Z ]*PRIVATE KEY', 'eyJ[A-Za-z0-9_-]{20,}',
                '\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b')
    foreach ($check in $checks) {
        $hits = $text | Select-String -Pattern $check
        if ($hits) { throw "Found something private: $(($hits | Select-Object -First 3 | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ')" }
    }
    $launcher = [IO.File]::ReadAllBytes("$stage\VR Video Streamer\VR Video Streamer.exe")
    foreach ($encoding in [Text.Encoding]::ASCII, [Text.Encoding]::Unicode) { if ($encoding.GetString($launcher) -match "Users\\($([regex]::Escape($env:USERNAME))|$([regex]::Escape($profileName)))") { throw "The launcher contains this PC's user path." } }
    "  nothing private in $($files.Count) files"

    # So anyone can confirm nothing changed on the way to them
    Push-Location "$stage\VR Video Streamer"
    $list = Get-ChildItem -Recurse -File | ForEach-Object { "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)  $($_.FullName.Substring((Get-Location).Path.Length + 1))" }
    Pop-Location
    Set-Content -LiteralPath "$stage\VR Video Streamer\CHECKSUMS.txt" $list -Encoding ascii

    "--- virus scan (Windows Defender)"
    $defender = Join-Path $env:ProgramFiles "Windows Defender\MpCmdRun.exe"
    if (Test-Path -LiteralPath $defender) {
        $ErrorActionPreference = "Continue"
        $scan = & $defender -Scan -ScanType 3 -File "$stage\VR Video Streamer" -DisableRemediation 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
        if ($code -eq 2) { throw "Windows Defender found a threat: $($scan -join ' ')" }
        "  exit code $code; $(($scan | Where-Object { $_ -match 'found|finished' }) -join ' ')"
    } else { "  Windows Defender isn't available here, so this wasn't scanned." }

    "--- zip"
    $zip = Join-Path $output "$name.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory("$stage\VR Video Streamer", $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    Set-Content -LiteralPath "$zip.sha256.txt" "$hash  $name.zip" -Encoding ascii
    "  $zip"
    "  {0:0} MB, SHA-256 {1}" -f ((Get-Item -LiteralPath $zip).Length / 1MB), $hash
}
finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue } }
