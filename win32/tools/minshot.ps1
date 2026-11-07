param([string]$OutDir = "win32\build\ui-min", [int]$W = 1500, [int]$H = 1050)
# Capture the workbench at its minimum outer size for layout checks.
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MW {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  public struct RECT { public int L, T, R, B; }
}
"@
[MW]::SetProcessDPIAware() | Out-Null
$script:wnd = [IntPtr]::Zero
$cb = [MW+EnumProc]{
  param($h, $p)
  $sb = New-Object System.Text.StringBuilder 256
  [MW]::GetClassName($h, $sb, 256) | Out-Null
  if ($sb.ToString() -eq "MinglingWorkbench") { $script:wnd = $h; return $false }
  return $true
}
[MW]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
if ($script:wnd -eq [IntPtr]::Zero) { Write-Output "window not found"; exit 1 }
$wnd = $script:wnd
[MW]::ShowWindow($wnd, 9) | Out-Null
[MW]::MoveWindow($wnd, 40, 40, $W, $H, $true) | Out-Null
Start-Sleep -Milliseconds 900
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$r = New-Object MW+RECT
[MW]::GetWindowRect($wnd, [ref]$r) | Out-Null
$ww = $r.R - $r.L; $hh = $r.B - $r.T
$tabs = @(@(0,49), @(1,50), @(5,54), @(7,56))
foreach ($t in $tabs) {
  [MW]::PostMessage($wnd, 0x0100, [IntPtr]$t[1], [IntPtr]0) | Out-Null
  Start-Sleep -Milliseconds 700
  $bmp = New-Object System.Drawing.Bitmap $ww, $hh
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  [MW]::PrintWindow($wnd, $hdc, 2) | Out-Null
  $g.ReleaseHdc($hdc); $g.Dispose()
  $p = Join-Path $OutDir ("tab" + $t[0] + ".png")
  $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  Write-Output ("tab" + $t[0] + " " + $ww + "x" + $hh + " -> " + $p)
}
