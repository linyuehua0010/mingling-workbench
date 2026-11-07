Add-Type -AssemblyName System.Drawing
"bmp type: " + [System.Drawing.Bitmap].FullName
[System.Windows.Forms.SystemInformation]::VirtualScreen | Out-Null
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class R2 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static string Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r.L + " " + r.T + " " + r.R + " " + r.B; }
}
"@
[R2]::SetProcessDPIAware() | Out-Null
$p = Get-Process MinglingWorkbench -ErrorAction SilentlyContinue
if ($p) {
  "hwnd=" + $p.MainWindowHandle
  "rect=" + [R2]::Rect($p.MainWindowHandle)
  "screen=" + [System.Windows.Forms.SystemInformation]::VirtualScreen
} else { "no process" }
