# Builds "VR Video Streamer.exe" (from Launcher.cs) with its icon (app.ico), and the files in branding\.
# The logo is drawn here. Only needed again if you change Launcher.cs or want to redraw the logo.
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot   # this script lives in build\
Add-Type -AssemblyName System.Drawing, System.Windows.Forms

# --- Logo: the "Double V", a stacked V like a signal coming down. Coordinates are on a 64 x 64 grid. ---
$tileColor = [System.Drawing.ColorTranslator]::FromHtml("#04342C")
$outerColor = [System.Drawing.ColorTranslator]::FromHtml("#5DCAA5")
$paleColor = [System.Drawing.ColorTranslator]::FromHtml("#9FE1CB")

function New-Canvas($width, $height) {
    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $canvas = [System.Drawing.Graphics]::FromImage($bitmap)
    $canvas.SmoothingMode = "AntiAlias"
    $canvas.PixelOffsetMode = "Half"   # without this everything lands half a pixel off-centre, which shows at small sizes
    $canvas.TextRenderingHint = "AntiAliasGridFit"
    $canvas.Clear([System.Drawing.Color]::Transparent)
    @{ Bitmap = $bitmap; Canvas = $canvas }
}
function RoundRect([float]$x, [float]$y, [float]$width, [float]$height, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, 2 * $r, 2 * $r, 180, 90); $p.AddArc($x + $width - 2 * $r, $y, 2 * $r, 2 * $r, 270, 90)
    $p.AddArc($x + $width - 2 * $r, $y + $height - 2 * $r, 2 * $r, 2 * $r, 0, 90); $p.AddArc($x, $y + $height - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $p.CloseFigure(); $p
}
function Draw-Vee($canvas, $x, $y, $size, $color, [float[]]$points) {
    $scale = $size / 64
    $pen = New-Object System.Drawing.Pen($color, (7 * $scale))
    $pen.StartCap = "Round"; $pen.EndCap = "Round"; $pen.LineJoin = "Round"
    $pixels = for ($i = 0; $i -lt $points.Count; $i += 2) { New-Object System.Drawing.PointF(($x + $points[$i] * $scale), ($y + $points[$i + 1] * $scale)) }
    $canvas.DrawLines($pen, [System.Drawing.PointF[]]$pixels)
    $pen.Dispose()
}
function Draw-DoubleV($canvas, $x, $y, $size) {
    Draw-Vee $canvas $x $y $size $outerColor @(12, 16, 32, 50, 52, 16)
    Draw-Vee $canvas $x $y $size ([System.Drawing.Color]::White) @(24, 16, 32, 30, 40, 16)
}
function New-Logo($size) {
    $image = New-Canvas $size $size
    $brush = New-Object System.Drawing.SolidBrush($tileColor)
    $image.Canvas.FillPath($brush, (RoundRect 0 0 $size $size ($size * 14 / 64)))
    Draw-DoubleV $image.Canvas 0 0 $size
    $brush.Dispose(); $image.Canvas.Dispose()
    $image.Bitmap
}
function Get-PngBytes($bitmap) {
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $stream.ToArray()
}

# --- app.ico: one drawing per size, so small sizes stay sharp instead of being shrunk from a big one ---
$ico = Join-Path $root "app\app.ico"
$sizes = 16, 24, 32, 48, 64, 256
# The classic bitmap format below 256 px (PNG there breaks .NET's icon loading), PNG at 256 as is standard
function Get-IconBitmapBytes($bitmap) {
    $size = $bitmap.Width
    $stream = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($stream)
    $bw.Write([UInt32]40); $bw.Write([Int32]$size); $bw.Write([Int32]($size * 2))   # height covers picture + mask
    $bw.Write([UInt16]1); $bw.Write([UInt16]32); foreach ($unused in 1..6) { $bw.Write([UInt32]0) }
    for ($y = $size - 1; $y -ge 0; $y--) {                                          # rows run bottom to top
        for ($x = 0; $x -lt $size; $x++) {
            $pixel = $bitmap.GetPixel($x, $y)
            $bw.Write([byte]$pixel.B); $bw.Write([byte]$pixel.G); $bw.Write([byte]$pixel.R); $bw.Write([byte]$pixel.A)
        }
    }
    $maskRow = [int][Math]::Ceiling($size / 32) * 4                                 # empty mask: alpha does the work
    $bw.Write((New-Object byte[] ($maskRow * $size)))
    $bw.Flush()
    $stream.ToArray()
}
$frames = foreach ($size in $sizes) {
    $logo = New-Logo $size
    if ($size -eq 256) { , (Get-PngBytes $logo) } else { , (Get-IconBitmapBytes $logo) }
    $logo.Dispose()
}
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)      # ICONDIR
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }                  # 0 means 256 here
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([UInt16]1); $w.Write([UInt16]32); $w.Write([UInt32]$frames[$i].Length); $w.Write([UInt32]$offset)
    $offset += $frames[$i].Length
}
foreach ($frame in $frames) { $w.Write([byte[]]$frame) }
$w.Flush()
[System.IO.File]::WriteAllBytes($ico, $out.ToArray())

# --- branding\: the logo and ready-made images for sharing ---
$branding = Join-Path $root "branding"
New-Item -ItemType Directory -Force $branding | Out-Null
foreach ($size in 512, 1024) {
    $logo = New-Logo $size
    $logo.Save((Join-Path $branding "logo-$size.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $logo.Dispose()
}
@'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img"><title>VR Video Streamer</title>
<rect width="64" height="64" rx="14" fill="#04342C"/>
<path d="M12 16 L32 50 L52 16" fill="none" stroke="#5DCAA5" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M24 16 L32 30 L40 16" fill="none" stroke="#fff" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
'@ | Set-Content (Join-Path $branding "logo.svg") -Encoding ascii

$image = New-Canvas 1280 400
$image.Canvas.Clear($tileColor)
Draw-DoubleV $image.Canvas 70 60 280
$nameFont = New-Object System.Drawing.Font("Segoe UI Semibold", 62, [System.Drawing.GraphicsUnit]::Pixel)
$tagFont = New-Object System.Drawing.Font("Segoe UI", 30, [System.Drawing.GraphicsUnit]::Pixel)
$image.Canvas.DrawString("VR Video Streamer", $nameFont, [System.Drawing.Brushes]::White, 390, 118)
$paleBrush = New-Object System.Drawing.SolidBrush($paleColor)
$image.Canvas.DrawString("Your screen, on any video player in the world", $tagFont, $paleBrush, 394, 208)
$image.Canvas.Dispose()
$image.Bitmap.Save((Join-Path $branding "banner.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$image.Bitmap.Dispose()

$image = New-Canvas 620 120
$brush = New-Object System.Drawing.SolidBrush($tileColor)
$image.Canvas.FillPath($brush, (RoundRect 0 0 620 120 26))
Draw-DoubleV $image.Canvas 16 14 92
$liveFont = New-Object System.Drawing.Font("Segoe UI Semibold", 38, [System.Drawing.GraphicsUnit]::Pixel)
$withFont = New-Object System.Drawing.Font("Segoe UI", 34, [System.Drawing.GraphicsUnit]::Pixel)
$image.Canvas.DrawString("Live", $liveFont, [System.Drawing.Brushes]::White, 120, 32)
$image.Canvas.DrawString("with VR Video Streamer", $withFont, $paleBrush, 206, 35)
$image.Canvas.Dispose()
$image.Bitmap.Save((Join-Path $branding "live-badge.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$image.Bitmap.Dispose()
$brush.Dispose(); $paleBrush.Dispose()

# --- Compile ---
$exe = Join-Path $root "VR Video Streamer.exe"
$cp = New-Object System.CodeDom.Compiler.CompilerParameters
$cp.GenerateExecutable = $true
$cp.OutputAssembly = $exe
$cp.CompilerOptions = "/target:winexe /win32icon:`"$ico`" /optimize"
[void]$cp.ReferencedAssemblies.AddRange(@("System.dll", "System.Windows.Forms.dll"))
Add-Type -TypeDefinition (Get-Content (Join-Path $PSScriptRoot "Launcher.cs") -Raw) -CompilerParameters $cp
"Built: $exe"
