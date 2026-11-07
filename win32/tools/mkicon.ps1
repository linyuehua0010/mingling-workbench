param(
  [Parameter(Mandatory=$true)][string]$Source,
  [string]$OutDir = "win32\build\icons",
  [string]$Ico = "win32\res\app.ico",
  [int[]]$Sizes = @(256,128,64,48,32,16),
  [switch]$NoCrop
)
# Crop to the drawn content, export square frames (PNG for 256, 32bpp DIB for the rest),
# then pack them into one ICO. Small frames are DIB on purpose: the shell icon cache and
# the taskbar are happier with classic bitmaps than with PNG-compressed small frames.
Add-Type -AssemblyName System.Drawing

$srcPath = (Resolve-Path $Source).Path
$src = [System.Drawing.Bitmap]::FromFile($srcPath)
$W = $src.Width; $H = $src.Height

# Background colour is sampled at the corner; the art is a flat field.
$bg = $src.GetPixel(2, 2)

if (-not $NoCrop) {
  $minX = $W; $minY = $H; $maxX = 0; $maxY = 0
  for ($y = 0; $y -lt $H; $y += 4) {
    for ($x = 0; $x -lt $W; $x += 4) {
      $c = $src.GetPixel($x, $y)
      $d = [Math]::Abs($c.R - $bg.R) + [Math]::Abs($c.G - $bg.G) + [Math]::Abs($c.B - $bg.B)
      if ($d -gt 40) {
        if ($x -lt $minX) { $minX = $x }
        if ($y -lt $minY) { $minY = $y }
        if ($x -gt $maxX) { $maxX = $x }
        if ($y -gt $maxY) { $maxY = $y }
      }
    }
  }
  if ($maxX -gt $minX -and $maxY -gt $minY) {
    $side = [Math]::Max($maxX - $minX, $maxY - $minY)
    $side = [int]($side * 1.06)
    $cx = ($minX + $maxX) / 2; $cy = ($minY + $maxY) / 2
    $sx = [int]($cx - $side / 2); $sy = [int]($cy - $side / 2)
    if ($sx -lt 0) { $sx = 0 }
    if ($sy -lt 0) { $sy = 0 }
    if ($sx + $side -gt $W) { $side = $W - $sx }
    if ($sy + $side -gt $H) { $side = $H - $sy }
    Write-Output ("crop " + $sx + "," + $sy + " " + $side + "x" + $side + " of " + $W + "x" + $H)
    $cropped = New-Object System.Drawing.Bitmap $side, $side
    $gc = [System.Drawing.Graphics]::FromImage($cropped)
    $gc.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $side, $side),
                  (New-Object System.Drawing.Rectangle $sx, $sy, $side, $side),
                  [System.Drawing.GraphicsUnit]::Pixel)
    $gc.Dispose()
    $src.Dispose()
    $src = $cropped
    $W = $side; $H = $side
  }
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

function New-Dib32($bmp, [int]$s) {
  $rect = New-Object System.Drawing.Rectangle 0, 0, $s, $s
  $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stride = $data.Stride
  $buf = New-Object byte[] ($stride * $s)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
  $bmp.UnlockBits($data)
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter $ms
  $bw.Write([UInt32]40)
  $bw.Write([Int32]$s)
  $bw.Write([Int32]($s * 2))
  $bw.Write([UInt16]1)
  $bw.Write([UInt16]32)
  $bw.Write([UInt32]0)
  $bw.Write([UInt32]($s * $s * 4))
  $bw.Write([Int32]0)
  $bw.Write([Int32]0)
  $bw.Write([UInt32]0)
  $bw.Write([UInt32]0)
  for ($y = $s - 1; $y -ge 0; $y--) { $bw.Write($buf, $y * $stride, $s * 4) }
  $maskRow = [int]([Math]::Ceiling($s / 32.0) * 4)
  $mask = New-Object byte[] ($maskRow * $s)
  # AND mask: 1 = transparent, 0 = opaque. Derived from the alpha channel so that
  # shells that still consult the mask keep the knocked-out background transparent.
  for ($y = 0; $y -lt $s; $y++) {
    $rowBase = ($s - 1 - $y) * $stride
    $maskBase = $y * $maskRow
    for ($x = 0; $x -lt $s; $x++) {
      if ($buf[$rowBase + $x * 4 + 3] -lt 128) {
        $mask[$maskBase + [int]([Math]::Floor($x / 8))] = $mask[$maskBase + [int]([Math]::Floor($x / 8))] -bor (0x80 -shr ($x % 8))
      }
    }
  }
  $bw.Write($mask, 0, $mask.Length)
  $bw.Flush()
  return $ms.ToArray()
}

$frames = New-Object System.Collections.ArrayList
foreach ($s in $Sizes) {
  $bmp = New-Object System.Drawing.Bitmap $s, $s
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $s, $s))
  $g.Dispose()
  $p = Join-Path $OutDir ("icon-" + $s + ".png")
  $bmp.Save((Join-Path (Get-Location) $p), [System.Drawing.Imaging.ImageFormat]::Png)
  if ($s -ge 256) {
    [void]$frames.Add([System.IO.File]::ReadAllBytes((Join-Path (Get-Location) $p)))
  } else {
    [void]$frames.Add((New-Dib32 $bmp $s))
  }
  $bmp.Dispose()
  Write-Output ("frame " + $s + " -> " + $p)
}

# ICONDIR + ICONDIRENTRY list + payloads
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $ms
$bw.Write([UInt16]0)
$bw.Write([UInt16]1)
$bw.Write([UInt16]$Sizes.Count)
$offset = 6 + 16 * $Sizes.Count
for ($i = 0; $i -lt $Sizes.Count; $i++) {
  $s = $Sizes[$i]
  if ($s -ge 256) { $bw.Write([Byte]0) } else { $bw.Write([Byte]$s) }
  if ($s -ge 256) { $bw.Write([Byte]0) } else { $bw.Write([Byte]$s) }
  $bw.Write([Byte]0)
  $bw.Write([Byte]0)
  $bw.Write([UInt16]1)
  $bw.Write([UInt16]32)
  $bw.Write([UInt32]$frames[$i].Length)
  $bw.Write([UInt32]$offset)
  $offset += $frames[$i].Length
}
foreach ($f in $frames) { $bw.Write([byte[]]$f) }
$bw.Flush()
[System.IO.File]::WriteAllBytes((Join-Path (Get-Location) $Ico), $ms.ToArray())
$bw.Dispose(); $ms.Dispose(); $src.Dispose()
Write-Output ("ico " + $Ico + " " + (Get-Item $Ico).Length + " bytes")
