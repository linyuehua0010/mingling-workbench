param([int]$X, [int]$Y, [string]$Out = "F:/dafeiyu/bili/win32/build/click.png", [int]$Wait = 1500, [string]$Class = "MinglingWorkbench")
# click a point measured on the window screenshot (restore first), then capture
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WinCap2 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  public static IntPtr Find(string cls) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, p) => {
      var sb = new StringBuilder(256); GetClassName(h, sb, 256);
      if (sb.ToString() == cls && IsWindowVisible(h)) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static string Prep(IntPtr h) {
    if (IsIconic(h)) { ShowWindow(h, 9); }
    SetForegroundWindow(h);
    RECT r; GetWindowRect(h, out r);
    POINT o; o.X = 0; o.Y = 0; ClientToScreen(h, ref o);
    return r.L + "," + r.T + "," + r.R + "," + r.B + ";" + o.X + "," + o.Y;
  }
  public static void ClickScreen(int sx, int sy) {
    SetCursorPos(sx, sy);
    mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);
    mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
  }
}
"@
[WinCap2]::SetProcessDPIAware() | Out-Null
$h = [WinCap2]::Find($Class)
if ($h -eq [IntPtr]::Zero) { Write-Output "NO_WINDOW"; exit 1 }
$info = [WinCap2]::Prep($h)
Start-Sleep -Milliseconds 500
$parts = $info.Split(';')
$rect = $parts[0].Split(',')
$orig = $parts[1].Split(',')
$sx = [int]$orig[0] + $X
$sy = [int]$orig[1] + $Y
[WinCap2]::ClickScreen($sx, $sy)
Start-Sleep -Milliseconds $Wait
$info2 = [WinCap2]::Prep($h)
$parts2 = $info2.Split(';')
$rect = $parts2[0].Split(',')
$l = [int]$rect[0]; $t = [int]$rect[1]; $r = [int]$rect[2]; $b = [int]$rect[3]
$w = $r - $l; $hh = $b - $t
if ($w -le 0 -or $hh -le 0) { Write-Output "BAD_RECT $w x $hh"; exit 1 }
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc()
$ok = [WinCap2]::PrintWindow($h, $dc, 2)
$g.ReleaseHdc($dc); $g.Dispose()
$bmp.Save($Out); $bmp.Dispose()
Write-Output ("info={0} click=({1},{2}) print={3} -> {4}" -f $info, $sx, $sy, $ok, $Out)
