param([int]$Vk = 56, [int]$Notches = 15, [string]$Out = "win32\build\ui-min\tab7-bottom.png")
# Press a tab key, scroll the page with the wheel, then capture the window.
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MW3 {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  public struct RECT { public int L, T, R, B; }
  public struct POINT { public int X, Y; }
}
"@
[MW3]::SetProcessDPIAware() | Out-Null
$script:wnd = [IntPtr]::Zero
$cb = [MW3+EnumProc]{
  param($h, $p)
  $sb = New-Object System.Text.StringBuilder 256
  [MW3]::GetClassName($h, $sb, 256) | Out-Null
  if ($sb.ToString() -eq "MinglingWorkbench") { $script:wnd = $h; return $false }
  return $true
}
[MW3]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
$wnd = $script:wnd
if ($wnd -eq [IntPtr]::Zero) { Write-Output "no window"; exit 1 }
[MW3]::PostMessage($wnd, 0x0100, [IntPtr]$Vk, [IntPtr]0) | Out-Null
Start-Sleep -Milliseconds 700
$cr = New-Object MW3+RECT
[MW3]::GetClientRect($wnd, [ref]$cr) | Out-Null
$pt = New-Object MW3+POINT
$pt.X = [int]($cr.R * 0.6); $pt.Y = [int]($cr.B * 0.6)
[MW3]::ClientToScreen($wnd, [ref]$pt) | Out-Null
$lp = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))
$wp = [IntPtr](((-120) -band 0xFFFF) -shl 16)
for ($i = 0; $i -lt $Notches; $i++) {
  [MW3]::PostMessage($wnd, 0x020A, $wp, $lp) | Out-Null
  Start-Sleep -Milliseconds 60
}
Start-Sleep -Milliseconds 500
$r = New-Object MW3+RECT
[MW3]::GetWindowRect($wnd, [ref]$r) | Out-Null
$ww = $r.R - $r.L; $hh = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $ww, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[MW3]::PrintWindow($wnd, $hdc, 2) | Out-Null
$g.ReleaseHdc($hdc); $g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
Write-Output ("ok " + $Out)
