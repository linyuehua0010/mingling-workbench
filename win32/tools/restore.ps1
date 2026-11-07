param([string]$Out = "F:/dafeiyu/bili/win32/build/restore.png")
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class R2 {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
 public delegate bool EP(IntPtr h, IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr p);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 public static IntPtr Find(string cls){ IntPtr f=IntPtr.Zero; EnumWindows((h,p)=>{ var sb=new StringBuilder(256); GetClassName(h,sb,256); if(sb.ToString()==cls && IsWindowVisible(h)){ f=h; return false;} return true;}, IntPtr.Zero); return f; }
}
"@
[R2]::SetProcessDPIAware() | Out-Null
$h=[R2]::Find("MinglingWorkbench")
if ($h -eq [IntPtr]::Zero) { "NO_WINDOW"; exit 1 }
[R2]::ShowWindow($h, 9) | Out-Null
[R2]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 900
$r=New-Object R2+RECT; [R2]::GetWindowRect($h,[ref]$r) | Out-Null
$w=$r.R-$r.L; $hh=$r.B-$r.T
$bmp=New-Object System.Drawing.Bitmap $w,$hh
$g=[System.Drawing.Graphics]::FromImage($bmp)
$dc=$g.GetHdc(); [R2]::PrintWindow($h,$dc,2) | Out-Null; $g.ReleaseHdc($dc); $g.Dispose()
$bmp.Save($Out); $bmp.Dispose()
"rect=$($r.L),$($r.T),$($r.R),$($r.B) size=${w}x${hh} -> $Out"
