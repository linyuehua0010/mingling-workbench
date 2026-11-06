param([int]$X, [int]$Y, [string]$Out = "F:/dafeiyu/bili/win32/build/click.png", [int]$Wait = 900, [string]$Class = "MinglingWorkbench")
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class TabCap {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static IntPtr Find(string cls) {
    IntPtr f = IntPtr.Zero;
    EnumWindows((h,p) => { var sb = new StringBuilder(256); GetClassName(h,sb,256);
      if (sb.ToString()==cls && IsWindowVisible(h)) { f=h; return false; } return true; }, IntPtr.Zero);
    return f;
  }
  public static void Click(IntPtr h, int sx, int sy) {
    POINT p = new POINT(); p.X = sx; p.Y = sy; ScreenToClient(h, ref p);
    IntPtr lp = (IntPtr)((p.Y << 16) | (p.X & 0xFFFF));
    PostMessage(h, 0x0200, IntPtr.Zero, lp);
    PostMessage(h, 0x0201, (IntPtr)1, lp);
    PostMessage(h, 0x0202, IntPtr.Zero, lp);
  }
}
"@
[TabCap]::SetProcessDPIAware() | Out-Null
$h = [TabCap]::Find($Class)
if ($h -eq [IntPtr]::Zero) { "NO_WINDOW"; exit 1 }
$r = New-Object TabCap+RECT
[TabCap]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.R-$r.L; $hh = $r.B-$r.T
[TabCap]::Click($h, $r.L + $X, $r.T + $Y)
Start-Sleep -Milliseconds $Wait
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc()
$ok = [TabCap]::PrintWindow($h, $dc, 2)
$g.ReleaseHdc($dc); $g.Dispose()
$bmp.Save($Out); $bmp.Dispose()
Write-Output ("clicked " + $X + "," + $Y + " -> " + $Out)
