Add-Type @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class W3 {
 public delegate bool EP(IntPtr h, IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr p);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int n);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 public static List<string> List(){
   var r=new List<string>();
   EnumWindows((h,p)=>{ if(!IsWindowVisible(h)) return true; var t=new StringBuilder(512); GetWindowText(h,t,512); var c=new StringBuilder(256); GetClassName(h,c,256);
     if(t.Length>0) r.Add(c.ToString()+" | "+t.ToString()); return true;}, IntPtr.Zero);
   return r; }
}
"@
[W3]::List() | Select-Object -First 40
