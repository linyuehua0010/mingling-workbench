param([string]$Source = "win32\build\icon-cand\c1.png", [string]$Out = "art\avatar.png", [int]$Size = 832,
      [double]$CX = 0.17, [double]$CY = 0.14, [double]$CW = 0.66)
# Reuse the icon art as the sidebar avatar: crop a square around the face, then downscale.
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Bitmap]::FromFile((Resolve-Path $Source).Path)
$side = [int]([Math]::Min($src.Width * $CW, $src.Height * $CW))
$x = [int]($src.Width * $CX)
$y = [int]($src.Height * $CY)
if ($x + $side -gt $src.Width)  { $x = $src.Width - $side }
if ($y + $side -gt $src.Height) { $y = $src.Height - $side }
if ($x -lt 0) { $x = 0 }
if ($y -lt 0) { $y = 0 }
$bmp = New-Object System.Drawing.Bitmap $Size, $Size
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $Size, $Size),
             (New-Object System.Drawing.Rectangle $x, $y, $side, $side),
             [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$bmp.Save((Join-Path (Get-Location) $Out), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose(); $src.Dispose()
Write-Output ("avatar " + $Out + " " + (Get-Item $Out).Length + " bytes")
