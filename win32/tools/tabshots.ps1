param([string]$OutDir = "F:/dafeiyu/bili/win32/build/ui-before", [string]$Class = "MinglingWorkbench")
# Capture all 8 tabs: post WM_KEYDOWN VK_1..VK_8, then PrintWindow each.
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class TabShot {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static IntPtr Find(string cls) {
    IntPtr f = IntPtr.Zero;
    EnumWindows((h,p) => { var sb = new StringBuilder(256); GetClassName(h,sb,256);
      if (sb.ToString()==cls && IsWindowVisible(h)) { f=h; return false; } return true; }, IntPtr.Zero);
    return f;
  }
}
"@
[TabShot]::SetProcessDPIAware() | Out-Null
$h = [TabShot]::Find($Class)
if ($h -eq [IntPtr]::Zero) { Write-Output "NO_WINDOW"; exit 1 }
if ([TabShot]::IsIconic($h)) { [TabShot]::ShowWindow($h, 9) | Out-Null; Start-Sleep -Milliseconds 600 }
$r = New-Object TabShot+RECT
[TabShot]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.R - $r.L; $hh = $r.B - $r.T
if ($w -le 0 -or $hh -le 0) { Write-Output "BAD_RECT"; exit 1 }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
for ($i = 0; $i -lt 8; $i++) {
  $vk = 0x31 + $i
  [TabShot]::PostMessage($h, 0x0100, [IntPtr]$vk, [IntPtr]0) | Out-Null
  Start-Sleep -Milliseconds 800
  $bmp = New-Object System.Drawing.Bitmap $w, $hh
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $dc = $g.GetHdc()
  $ok = [TabShot]::PrintWindow($h, $dc, 2)
  $g.ReleaseHdc($dc); $g.Dispose()
  $out = Join-Path $OutDir ("tab" + $i + ".png")
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Output ("tab" + $i + " vk=" + $vk + " print=" + $ok + " -> " + $out)
}
