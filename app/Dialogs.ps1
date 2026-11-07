# Every window other than the main one, for StreamUI.ps1 (dot-sourced), plus what they all share.
# Their buttons use $script: variables because a click runs after the function that made the button has moved on.

Add-Type -Name Dwm -Namespace UI -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
'@

# Dark title bar: 20 asks for dark mode (Windows 10 2004 and later), 35 sets its colour to the page's (Windows 11)
function Set-DarkTitleBar($window) {
    $window.Add_SourceInitialized({
            param($s)
            $handle = (New-Object System.Windows.Interop.WindowInteropHelper($s)).Handle
            $dark = 1; [void][UI.Dwm]::DwmSetWindowAttribute($handle, 20, [ref]$dark, 4)
            $colour = 0x001A1810; [void][UI.Dwm]::DwmSetWindowAttribute($handle, 35, [ref]$colour, 4)
        })
}

function New-AppWindow($xaml, $owner) {
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
    try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([uri](Join-Path $PSScriptRoot "app.ico")) } catch { }   # only cosmetic
    Set-DarkTitleBar $window
    if ($owner -and $owner.IsLoaded) { $window.Owner = $owner; $window.WindowStartupLocation = "CenterOwner" }
    else { $window.WindowStartupLocation = "CenterScreen" }
    $window
}

# Every x:Name in the XAML, as a hashtable of controls
function Get-NamedControls($window, $xaml) {
    $named = @{}
    foreach ($m in [regex]::Matches($xaml, 'x:Name="(\w+)"')) { $named[$m.Groups[1].Value] = $window.FindName($m.Groups[1].Value) }
    $named
}

$script:WindowHead = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'

# A message with buttons. Returns the label of the one pressed, or nothing if closed.
function Show-Message($owner, $text, [string[]]$buttons = @("OK")) {
    $xaml = @"
<Window $script:WindowHead Title="VR Video Streamer" Width="460" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False">
  <StackPanel Margin="16">
    <TextBlock x:Name="lblText" TextWrapping="Wrap" Margin="0,0,0,14"/>
    <StackPanel x:Name="pnlButtons" Orientation="Horizontal" HorizontalAlignment="Right"/>
  </StackPanel>
</Window>
"@
    $message = New-AppWindow $xaml $owner
    if (-not $owner -or -not $owner.IsLoaded) { $message.ShowInTaskbar = $true }
    $c = Get-NamedControls $message $xaml
    $c.lblText.Text = $text
    $script:msgAnswer = $null
    $first = $true
    foreach ($label in $buttons) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $label
        $b.Tag = $label
        $b.MinWidth = 76
        $b.Margin = "6,0,0,0"
        $b.HorizontalContentAlignment = "Center"
        if ($first) { $b.Style = $message.FindResource("AccentButton"); $first = $false }
        # Its own window, not "the latest": a second message can open on top while this one is showing
        $b.Add_Click({ param($s) $script:msgAnswer = $s.Tag; [System.Windows.Window]::GetWindow($s).Close() })
        [void]$c.pnlButtons.Children.Add($b)
    }
    [void]$message.ShowDialog()
    $script:msgAnswer
}

# A link as a QR code, for opening it on a phone by pointing the camera at the screen
function Show-QrCode($owner, $title, $link) {
    $xaml = @"
<Window $script:WindowHead Title="$([Security.SecurityElement]::Escape($title))" Width="400" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False">
  <StackPanel Margin="16">
    <Border Background="White" CornerRadius="6" Padding="6" HorizontalAlignment="Center">
      <Image x:Name="imgCode" Width="300" Height="300" RenderOptions.BitmapScalingMode="NearestNeighbor"/>
    </Border>
    <TextBlock x:Name="lblLink" TextWrapping="Wrap" Margin="0,12,0,4" Style="{StaticResource MutedText}" TextAlignment="Center"/>
    <TextBlock Text="Point a phone's camera at the code to open the link." TextWrapping="Wrap" TextAlignment="Center" Margin="0,0,0,12"/>
    <Button x:Name="btnClose" Content="Close" HorizontalAlignment="Right" MinWidth="76" HorizontalContentAlignment="Center" Style="{StaticResource AccentButton}"/>
  </StackPanel>
</Window>
"@
    $qr = New-AppWindow $xaml $owner
    $c = Get-NamedControls $qr $xaml
    $c.imgCode.Source = [QrCode]::ToBitmap([QrCode]::Encode($link), 8)
    $c.lblLink.Text = $link
    $c.btnClose.Add_Click({ param($s) [System.Windows.Window]::GetWindow($s).Close() })
    [void]$qr.ShowDialog()
}

# A progress window around an installer script, which does the work in its own process so Cancel can simply stop it.
# $progress is run a few times a second and returns what to say. Returns whether it was cancelled.
function Show-InstallProgress($owner, $text, $installer, $toolsDir, $errorFile, [scriptblock]$progress, $extraArguments = "") {
    $xaml = @"
<Window $script:WindowHead Title="VR Video Streamer" Width="440" SizeToContent="Height" ResizeMode="NoResize">
  <StackPanel Margin="16">
    <TextBlock x:Name="lblText"/>
    <ProgressBar IsIndeterminate="True" Height="6" Margin="0,10,0,14"/>
    <Button x:Name="btnCancel" Content="Cancel" HorizontalAlignment="Right" MinWidth="76" HorizontalContentAlignment="Center"/>
  </StackPanel>
</Window>
"@
    $script:installWindow = New-AppWindow $xaml $owner
    $script:installControls = Get-NamedControls $script:installWindow $xaml
    $script:installControls.lblText.Text = $text
    $script:installProgress = $progress
    $script:installCancelled = $false
    $script:installChild = Start-Process "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -PassThru -WindowStyle Hidden -ArgumentList `
        "-NoProfile -ExecutionPolicy Bypass -File `"$installer`" -ToolsDir `"$toolsDir`" -ErrorFile `"$errorFile`" $extraArguments"
    $script:installControls.btnCancel.Add_Click({ $script:installCancelled = $true; $script:installWindow.Close() })
    $script:installWindow.Add_Closing({ if (-not $script:installChild.HasExited) { $script:installCancelled = $true; Stop-Process -Id $script:installChild.Id -Force -ErrorAction SilentlyContinue } })
    $script:installTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:installTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:installTimer.Add_Tick({
            if ($script:installChild.HasExited) { $script:installWindow.Close(); return }
            if ($script:installProgress) { $said = & $script:installProgress; if ($said) { $script:installControls.lblText.Text = $said } }
        })
    $script:installTimer.Start()
    [void]$script:installWindow.ShowDialog()
    $script:installTimer.Stop()
    $script:installCancelled
}

# First run: ask, then download. Returns ffmpeg's path, or nothing.
function Install-FFmpegWithDialog($toolsDir) {
    $answer = Show-Message $null "This program needs FFmpeg, the free video tool that does the capturing and encoding. It isn't on this PC yet.`n`nDownload it now from gyan.dev? It's about 110 MB and only happens once." @("Download", "Not now")
    if ($answer -ne "Download") {
        [void](Show-Message $null "The program can't run without FFmpeg, so it will close now. Open it again any time to download FFmpeg.")
        return
    }
    $zip = Join-Path $toolsDir "ffmpeg-download.zip"
    $unpack = Join-Path $toolsDir "ffmpeg-unpack"
    $errorFile = Join-Path $env:TEMP "VRVideoStreamer-ffmpeg-error-$PID.log"
    $script:ffmpegZip = $zip; $script:ffmpegUnpack = $unpack
    $cancelled = Show-InstallProgress $null "Downloading FFmpeg..." (Join-Path $PSScriptRoot "Install-FFmpeg.ps1") $toolsDir $errorFile {
        if (Test-Path -LiteralPath $script:ffmpegUnpack) { "Unpacking FFmpeg..." }
        elseif (Test-Path -LiteralPath $script:ffmpegZip) { "Downloading FFmpeg: {0:0} MB of about 110 MB" -f ((Get-Item -LiteralPath $script:ffmpegZip).Length / 1MB) }
    }
    if ($cancelled) {
        foreach ($leftover in $zip, "$zip.sha256", $unpack) { if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Recurse -Force -ErrorAction SilentlyContinue } }
        [void](Show-Message $null "Download cancelled. The program can't run without FFmpeg, so it will close now.")
        return
    }
    $exe = Find-FFmpeg $toolsDir
    if (-not $exe) {
        $why = if (Test-Path -LiteralPath $errorFile) { (Get-Content -LiteralPath $errorFile -Raw).Trim() } else { "Unknown error." }
        [void](Show-Message $null "Couldn't set up FFmpeg:`n$why`n`nCheck your internet connection and open the program again, or install it yourself by running this in PowerShell:`n    winget install Gyan.FFmpeg")
    }
    Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    $exe
}

# First use of YouTube: ask, then download. A running stream keeps going. Returns yt-dlp's path, or nothing.
function Install-YouTubeWithDialog($toolsDir, $owner) {
    $answer = Show-Message $owner "Playing YouTube needs two free tools that aren't on this PC yet: yt-dlp, which reads YouTube, and Deno, which yt-dlp uses to do it.`n`nDownload them now from their official GitHub pages? It's about 70 MB and only happens once. A stream that's running keeps going." @("Download", "Not now")
    if ($answer -ne "Download") { return }
    $errorFile = Join-Path $env:TEMP "VRVideoStreamer-youtube-error-$PID.log"
    [void](Show-InstallProgress $owner "Downloading yt-dlp and Deno..." (Join-Path $PSScriptRoot "Install-YouTube.ps1") $toolsDir $errorFile $null)
    $exe = Find-YtDlp $toolsDir
    if (-not $exe -and (Test-Path -LiteralPath $errorFile)) {
        [void](Show-Message $owner "Couldn't set up YouTube:`n$((Get-Content -LiteralPath $errorFile -Raw).Trim())")
    }
    Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    $exe
}

# First use of AI subtitles: say what's needed, then download it. Returns whether everything's ready.
function Install-WhisperWithDialog($toolsDir, $owner, $model, $modelFolder, $needTool) {
    $sizes = @{ "ggml-small-q5_1.bin" = 181; "ggml-large-v3-turbo-q5_0.bin" = 547 }
    $total = $sizes[$model] + $(if ($needTool) { 161 } else { 0 })
    $script:whisperPart = Join-Path $modelFolder "$model.part"
    $script:whisperZip = Join-Path $toolsDir "whisper-download.7z"
    $script:whisperModelMB = $sizes[$model]
    $answer = Show-Message $owner "AI subtitles listen to the video's speech and run entirely on this PC, so nothing is uploaded. They need a speech recognition model (Whisper)$(if ($needTool) { ' and a larger version of FFmpeg' }) that this PC doesn't have yet.`n`nDownload them now? It's about $total MB and only happens once. A stream that's running keeps going." @("Download", "Not now")
    if ($answer -ne "Download") { return $false }
    $errorFile = Join-Path $env:TEMP "VRVideoStreamer-whisper-error-$PID.log"
    $extra = "-Model `"$model`" -ModelFolder `"$modelFolder`"" + $(if ($needTool) { " -NeedTool" } else { "" })
    $cancelled = Show-InstallProgress $owner "Downloading..." (Join-Path $PSScriptRoot "Install-Whisper.ps1") $toolsDir $errorFile {
        if (Test-Path -LiteralPath $script:whisperPart) { "Downloading the speech model: {0:0} MB of about $($script:whisperModelMB) MB" -f ((Get-Item -LiteralPath $script:whisperPart).Length / 1MB) }
        elseif (Test-Path -LiteralPath $script:whisperZip) { "Downloading FFmpeg: {0:0} MB of about 161 MB" -f ((Get-Item -LiteralPath $script:whisperZip).Length / 1MB) }
    } $extra
    foreach ($leftover in $script:whisperPart, $script:whisperZip) { Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue }
    $ok = -not $cancelled -and (Test-Path -LiteralPath (Join-Path $modelFolder $model))
    if (-not $ok -and -not $cancelled) {
        $why = if (Test-Path -LiteralPath $errorFile) { (Get-Content -LiteralPath $errorFile -Raw).Trim() } else { "Unknown error." }
        [void](Show-Message $owner "Couldn't set up AI subtitles:`n$why")
    }
    Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    $ok
}

# A list row: optional thumbnail (an internet address, loaded in the background), a title, and a smaller line below it
function New-VideoRow($title, $detail, $thumbnail) {
    $title = ("$title" -replace '\s+', ' ').Trim()   # some YouTube titles contain line breaks
    $row = New-Object System.Windows.Controls.DockPanel
    $row.ToolTip = $title
    if ($thumbnail) {
        $frame = New-Object System.Windows.Controls.Border
        $frame.Width = 64; $frame.Height = 36; $frame.CornerRadius = 4; $frame.Margin = "0,0,8,0"
        $frame.Background = $window.FindResource("Line")
        $frame.ClipToBounds = $true
        try {
            $image = New-Object System.Windows.Media.Imaging.BitmapImage
            $image.BeginInit(); $image.UriSource = [uri]$thumbnail; $image.DecodePixelWidth = 128; $image.EndInit()
            $picture = New-Object System.Windows.Controls.Image
            $picture.Source = $image; $picture.Stretch = "UniformToFill"
            $frame.Child = $picture
        } catch { }   # only cosmetic
        [System.Windows.Controls.DockPanel]::SetDock($frame, "Left")
        [void]$row.Children.Add($frame)
    }
    $text = New-Object System.Windows.Controls.StackPanel
    $line = New-Object System.Windows.Controls.TextBlock
    $line.Text = $title; $line.TextTrimming = "CharacterEllipsis"
    [void]$text.Children.Add($line)
    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.Text = $detail; $sub.TextTrimming = "CharacterEllipsis"; $sub.FontSize = 12
    $sub.Foreground = $window.FindResource("Muted")
    [void]$text.Children.Add($sub)
    [void]$row.Children.Add($text)
    $row
}

# Pick subtitles from OpenSubtitles. Returns the .srt's path and a name for it, or nothing.
function Show-OpenSubtitlesDialog($owner, $searchText, $file) {
    $xaml = @"
<Window $script:WindowHead Title="Find subtitles" Width="680" Height="480" MinWidth="520" MinHeight="320" ShowInTaskbar="False">
  <Grid Margin="12">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <DockPanel>
      <Button x:Name="btnFind" DockPanel.Dock="Right" Content="Search" Margin="6,0,0,0"/>
      <ComboBox x:Name="cbLanguage" DockPanel.Dock="Right" Width="130" Margin="6,0,0,0"/>
      <TextBox x:Name="tbQuery"/>
    </DockPanel>
    <Border Grid.Row="1" Style="{StaticResource CardBox}" Margin="0,8,0,0" Padding="5"><ListBox x:Name="lbRows"/></Border>
    <TextBlock x:Name="lblInfo" Grid.Row="2" Style="{StaticResource MutedText}" Margin="2,8,2,8" TextWrapping="Wrap"/>
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="btnUse" Content="Use selected" Style="{StaticResource AccentButton}" Margin="0,0,6,0"/>
      <Button x:Name="btnClose" Content="Cancel"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $script:osWindow = New-AppWindow $xaml $owner
    $script:os = Get-NamedControls $script:osWindow $xaml
    $script:osPicked = $null
    $script:osRows = @()
    $script:osFile = $file
    $script:os.tbQuery.Text = $searchText
    foreach ($l in $script:SubtitleLanguages) { [void]$script:os.cbLanguage.Items.Add($l.Name) }
    $script:os.cbLanguage.SelectedIndex = [Math]::Max(0, [array]::IndexOf(@($script:SubtitleLanguages | ForEach-Object { $_.Code }), $script:settings.SubsLanguage))
    $script:os.lblInfo.Text = "Searches OpenSubtitles.org. It's free and needs no account."
    $script:os.btnFind.Add_Click({ Start-OpenSubtitlesSearch })
    $script:os.tbQuery.Add_KeyDown({ param($s, $e) if ($e.Key -eq "Return") { $e.Handled = $true; Start-OpenSubtitlesSearch } })
    $script:os.btnUse.Add_Click({ Use-OpenSubtitlesRow })
    $script:os.lbRows.Add_MouseDoubleClick({ Use-OpenSubtitlesRow })
    $script:os.btnClose.Add_Click({ $script:osWindow.Close() })
    $script:osWindow.Add_ContentRendered({ if ($script:os.tbQuery.Text.Trim()) { Start-OpenSubtitlesSearch } })
    [void]$script:osWindow.ShowDialog()
    $script:osPicked
}

function Start-OpenSubtitlesSearch {
    $query = $script:os.tbQuery.Text
    if (-not $query.Trim()) { $script:os.lblInfo.Text = "Type what to search for."; return }
    $script:os.lblInfo.Text = "Searching..."
    $language = $script:SubtitleLanguages[$script:os.cbLanguage.SelectedIndex].Code
    Start-SubtitleTask {
        param($query, $language, $file)
        Search-OpenSubtitles $query $language $file
    } @($query, $language, $script:osFile) {
        param($rows, $why)
        if (-not $script:osWindow.IsVisible) { return }
        if ($why) { $script:os.lblInfo.Text = $why; return }
        $script:osRows = @($rows)
        $script:os.lbRows.Items.Clear()
        foreach ($r in $script:osRows) {
            $details = @("$($r.Downloads) downloads")
            if ($r.Exact) { $details = @("Exact match for your file") + $details }
            if ($r.Hearing) { $details += "hearing impaired" }
            [void]$script:os.lbRows.Items.Add((New-VideoRow $(if ($r.Release) { $r.Release } else { $r.Title }) "$($r.Title)  -  $($details -join ', ')" $null))
        }
        if ($script:osRows.Count) { $script:os.lbRows.SelectedIndex = 0 }
        $script:os.lblInfo.Text = if ($script:osRows.Count) { "Pick the release that matches your video best, since timing differs between releases." } else { "Nothing found. Try fewer words." }
    }
}

function Use-OpenSubtitlesRow {
    if ($script:os.lbRows.SelectedIndex -lt 0) { $script:os.lblInfo.Text = "Select a row first."; return }
    $row = $script:osRows[$script:os.lbRows.SelectedIndex]
    $script:osChosen = $row
    $script:os.lblInfo.Text = "Downloading..."
    Start-SubtitleTask {
        param($link, $fileId)
        Get-OpenSubtitlesFile $link $fileId
    } @($row.Link, $row.FileId) {
        param($path, $why)
        if (-not $script:osWindow.IsVisible) { return }
        if ($why) { $script:os.lblInfo.Text = $why; return }
        $script:osPicked = @{ Path = "$path"; Name = $(if ($script:osChosen.Release) { $script:osChosen.Release } else { $script:osChosen.Title }) }
        $script:osWindow.Close()
    }
}

# Measures the upload, and suggests the best quality that fits how many people are expected. Returns the quality's number, or nothing.
function Show-UploadTest($owner, $qualities) {
    $xaml = @"
<Window $script:WindowHead Title="Test my upload" Width="480" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False">
  <StackPanel Margin="16">
    <TextBlock TextWrapping="Wrap" Text="Each viewer gets the whole stream from your upload, so this finds what fits. It sends a little random data to Cloudflare's speed test."/>
    <DockPanel Margin="0,12,0,12">
      <TextBlock Text="Viewers you expect" Style="{StaticResource MutedText}" Margin="0,0,10,0"/>
      <ComboBox x:Name="cbViewers" Width="90" HorizontalAlignment="Left"/>
    </DockPanel>
    <TextBlock x:Name="lblResult" TextWrapping="Wrap" MinHeight="44" Text="Press Test to measure."/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="btnGo" Content="Test" Style="{StaticResource AccentButton}" MinWidth="76" Margin="0,0,6,0" HorizontalContentAlignment="Center"/>
      <Button x:Name="btnUse" Content="Use this quality" Margin="0,0,6,0" IsEnabled="False"/>
      <Button x:Name="btnDone" Content="Close" MinWidth="76" HorizontalContentAlignment="Center"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $script:upWindow = New-AppWindow $xaml $owner
    $script:up = Get-NamedControls $script:upWindow $xaml
    $script:upQualities = $qualities
    $script:upSpeed = 0.0
    $script:upPick = -1
    $script:upChosen = $null
    foreach ($n in 1, 2, 3, 5, 8, 10, 15, 20, 30) { [void]$script:up.cbViewers.Items.Add("$n") }
    $script:up.cbViewers.SelectedIndex = 2
    $script:up.btnGo.Add_Click({
            $script:up.btnGo.IsEnabled = $false
            $script:up.lblResult.Text = "Measuring, which takes a few seconds..."
            Start-SubtitleTask { Measure-UploadSpeed } @() {
                param($speed, $why)
                if (-not $script:upWindow.IsVisible) { return }
                $script:up.btnGo.IsEnabled = $true
                if ($why -or -not $speed) { $script:up.lblResult.Text = "Couldn't measure it: $why"; return }
                $script:upSpeed = [double]$speed
                Update-UploadAdvice
            }
        })
    $script:up.cbViewers.Add_SelectionChanged({ if ($script:upSpeed -gt 0) { Update-UploadAdvice } })
    $script:up.btnUse.Add_Click({ $script:upChosen = $script:upPick; $script:upWindow.Close() })
    $script:up.btnDone.Add_Click({ $script:upWindow.Close() })
    [void]$script:upWindow.ShowDialog()
    $script:upChosen
}

function Update-UploadAdvice {
    $viewers = [int]$script:up.cbViewers.SelectedItem
    # Leaves about a third of the upload spare: speeds vary, and other things on the PC use it too
    $each = $script:upSpeed * 0.66 / $viewers
    $script:upPick = -1
    for ($i = 0; $i -lt $script:upQualities.Count; $i++) {
        if ($each -ge $script:upQualities[$i].Mbps) { $script:upPick = $i; break }
    }
    $line = "Your upload is about {0:0} Mbit/s, so about {1:0.0} Mbit/s for each of {2} viewers." -f $script:upSpeed, $each, $viewers
    if ($script:upPick -ge 0) {
        $script:up.lblResult.Text = "$line Suggested: $($script:upQualities[$script:upPick].Name)."
        $script:up.btnUse.IsEnabled = $true
    } else {
        $script:up.lblResult.Text = "$line That's less than the lightest quality needs, so some viewers would stutter. Try fewer viewers."
        $script:up.btnUse.IsEnabled = $false
    }
}

# Your own Cloudflare tunnel, set up on their website. Returns whether one is saved.
function Show-PermanentLinkDialog($owner) {
    $xaml = @"
<Window $script:WindowHead Title="Permanent link" Width="560" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False">
  <StackPanel Margin="16">
    <TextBlock TextWrapping="Wrap" Text="Keeps the same public link every stream. It needs a free Cloudflare account and a domain name of your own on that account."/>
    <TextBlock TextWrapping="Wrap" Margin="0,10,0,0" Text="1. In Cloudflare's Zero Trust dashboard, go to Networks, Tunnels, and create a Cloudflared tunnel."/>
    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="2. Add a public hostname, such as stream.yourdomain.com, with service type HTTP and URL 127.0.0.1:8890. (8888 also works, but without the remote control link.)"/>
    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="3. Copy the tunnel's token, the long text in its install command, and paste it here with the hostname."/>
    <Button x:Name="btnSite" Content="Open Cloudflare's dashboard" HorizontalAlignment="Left" Margin="0,12,0,12"/>
    <TextBlock Text="Hostname" Style="{StaticResource MutedText}"/>
    <TextBox x:Name="tbHost" Margin="0,3,0,10"/>
    <TextBlock Text="Tunnel token (stays on this PC, encrypted, and isn't included if you send this folder to someone)" Style="{StaticResource MutedText}" TextWrapping="Wrap"/>
    <PasswordBox x:Name="tbToken" Margin="0,3,0,0"/>
    <TextBlock x:Name="lblProblem" Foreground="#F09595" TextWrapping="Wrap" Margin="0,8,0,0"/>
    <DockPanel Margin="0,10,0,0">
      <Button x:Name="btnForget" Content="Remove it"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="btnSave" Content="Save" Style="{StaticResource AccentButton}" MinWidth="76" Margin="0,0,6,0" HorizontalContentAlignment="Center"/>
        <Button x:Name="btnCancel" Content="Cancel" MinWidth="76" HorizontalContentAlignment="Center"/>
      </StackPanel>
    </DockPanel>
  </StackPanel>
</Window>
"@
    $script:plWindow = New-AppWindow $xaml $owner
    $script:pl = Get-NamedControls $script:plWindow $xaml
    $script:pl.tbHost.Text = $script:settings.PermanentHost
    $script:pl.btnSite.Add_Click({ Start-Process "https://one.dash.cloudflare.com/" })
    $script:pl.btnSave.Add_Click({
            $hostName = ($script:pl.tbHost.Text.Trim() -replace '^https?://', '').TrimEnd('/')
            $token = $script:pl.tbToken.Password.Trim()
            if ($hostName -notmatch '^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$') { $script:pl.lblProblem.Text = "Enter the hostname like stream.yourdomain.com."; return }
            if (-not $token -and -not (Get-Secret "tunnel.token")) { $script:pl.lblProblem.Text = "Paste the tunnel's token."; return }
            if ($token) { Set-Secret "tunnel.token" $token }
            $script:settings.PermanentHost = $hostName
            Save-Settings $script:settings
            $script:plWindow.Close()
        })
    $script:pl.btnForget.Add_Click({
            Remove-Item -LiteralPath (Join-Path $script:AppData "tunnel.token") -Force -ErrorAction SilentlyContinue
            $script:settings.PermanentHost = ""
            Save-Settings $script:settings
            $script:plWindow.Close()
        })
    $script:pl.btnCancel.Add_Click({ $script:plWindow.Close() })
    [void]$script:plWindow.ShowDialog()
    [bool]($script:settings.PermanentHost -and (Get-Secret "tunnel.token"))
}

# Results stay open beside the main window, so the video controls still work while you browse
function Show-YouTubeSearch($query) {
    if ($script:ytWindow -and $script:ytWindow.IsVisible) { [void]$script:ytWindow.Activate() }
    else {
        $xaml = @"
<Window $script:WindowHead Title="Search YouTube" Width="660" Height="560" MinWidth="480" MinHeight="320">
  <Grid Margin="12">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <DockPanel>
      <Button x:Name="btnGo" DockPanel.Dock="Right" Content="Search" Margin="6,0,0,0"/>
      <TextBox x:Name="tbQuery"/>
    </DockPanel>
    <Border Grid.Row="1" Style="{StaticResource CardBox}" Margin="0,8,0,0" Padding="5"><ListBox x:Name="lbResults" SelectionMode="Extended"/></Border>
    <TextBlock x:Name="lblInfo" Grid.Row="2" Style="{StaticResource MutedText}" Margin="2,8,2,8"/>
    <DockPanel Grid.Row="3">
      <Button x:Name="btnAddSel" Content="Add to queue" Style="{StaticResource AccentButton}" Margin="0,0,6,0"/>
      <Button x:Name="btnPlaySel" Content="Play now"/>
      <Button x:Name="btnCloseSel" Content="Close" HorizontalAlignment="Right"/>
    </DockPanel>
  </Grid>
</Window>
"@
        $script:ytWindow = New-AppWindow $xaml $window
        $script:yt = Get-NamedControls $script:ytWindow $xaml
        $script:yt.btnGo.Add_Click({ Start-YouTubeSearch })
        $script:yt.tbQuery.Add_KeyDown({ param($s, $e) if ($e.Key -eq "Return") { $e.Handled = $true; Start-YouTubeSearch } })
        $script:yt.btnAddSel.Add_Click({ Add-SearchSelection })
        $script:yt.lbResults.Add_MouseDoubleClick({ Add-SearchSelection })
        $script:yt.btnPlaySel.Add_Click({ Add-SearchSelection -PlayNow })
        $script:yt.btnCloseSel.Add_Click({ $script:ytWindow.Close() })
        $script:ytWindow.Show()
    }
    $script:yt.tbQuery.Text = $query
    Start-YouTubeSearch
}

function Start-YouTubeSearch {
    $query = $script:yt.tbQuery.Text.Trim()
    if (-not $query) { return }
    $script:yt.lblInfo.Text = "Searching..."
    Search-YouTube $query {
        param($info, $why)
        if (-not $script:ytWindow -or -not $script:ytWindow.IsVisible) { return }
        $script:yt.lbResults.Items.Clear()
        $script:ytResults = @($info.entries | Where-Object { $_.id })
        foreach ($r in $script:ytResults) {
            $channel = if ($r.channel) { $r.channel } else { $r.uploader }
            $length = if ($r.duration) { Format-Time $r.duration } else { "live" }
            [void]$script:yt.lbResults.Items.Add((New-VideoRow "$($r.title)" "$channel  -  $length" "https://i.ytimg.com/vi/$($r.id)/mqdefault.jpg"))
        }
        $script:yt.lblInfo.Text = if (-not $info) { "Search failed: $why" }
                                  elseif ($script:ytResults.Count) { "Double-click to add one, or select several with Ctrl and press Add to queue." }
                                  else { "Nothing found." }
    }
}

function Add-SearchSelection([switch]$PlayNow) {
    $picked = @($script:yt.lbResults.SelectedItems | ForEach-Object { $script:yt.lbResults.Items.IndexOf($_) } | Sort-Object |
            ForEach-Object { $r = $script:ytResults[$_]; New-YouTubeItem $r.id $r.title $r.duration })
    if (-not $picked) { $script:yt.lblInfo.Text = "Select a video first."; return }
    if ($PlayNow -and $script:player) {
        $script:queue.Insert(0, $picked[0])
        Add-YouTubeItems @($picked | Select-Object -Skip 1)
        Start-QueueItem 0
        $script:yt.lblInfo.Text = "Getting that video..."
    } else {
        Add-YouTubeItems $picked
        $script:yt.lblInfo.Text = "Added. It's in Up next in the main window."
    }
}
