param([string]$Out = "win32\build\icon-check\desktop.png", [int]$X = 0, [int]$Y = 0, [int]$W = 0, [int]$H = 0)
# Capture the whole virtual screen (or a region) for icon inspection.
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DPIW { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
"@
[DPIW]::SetProcessDPIAware() | Out-Null
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
if ($W -le 0) { $W = $vs.Width }
if ($H -le 0) { $H = $vs.Height }
$bmp = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($vs.X + $X, $vs.Y + $Y, 0, 0, (New-Object System.Drawing.Size $W, $H))
$g.Dispose()
$bmp.Save((Join-Path (Get-Location) $Out), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output ("screen " + $W + "x" + $H + " -> " + $Out)
