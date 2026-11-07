Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class P2 {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
 public delegate bool EP(IntPtr h, IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr p);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 public static IntPtr Find(string cls){ IntPtr f=IntPtr.Zero; EnumWindows((h,p)=>{ var sb=new StringBuilder(256); GetClassName(h,sb,256); if(sb.ToString()==cls && IsWindowVisible(h)){ f=h; return false;} return true;}, IntPtr.Zero); return f; }
}
"@
[P2]::SetProcessDPIAware() | Out-Null
$h=[P2]::Find("MinglingWorkbench")
$wr=New-Object P2+RECT; [P2]::GetWindowRect($h,[ref]$wr) | Out-Null
$cr=New-Object P2+RECT; [P2]::GetClientRect($h,[ref]$cr) | Out-Null
$dpi=[P2]::GetDpiForWindow($h)
"hwnd=$h window=$($wr.L),$($wr.T),$($wr.R),$($wr.B) client=$($cr.R)x$($cr.B) dpi=$dpi"
