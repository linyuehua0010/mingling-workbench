param(
  [Parameter(Mandatory=$true)][string]$Source,
  [string]$Out = "win32\build\icon-cand\c1-alpha.png",
  [int]$Tolerance = 28
)
# Knock the flat white background out of an icon drawing: flood fill from the border
# through near-white pixels, clear their alpha, and leave the dark outline intact.
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
public class Knockout {
  public static int Run(string src, string dst, int tol) {
    using (Bitmap original = new Bitmap(src))
    using (Bitmap bmp = new Bitmap(original.Width, original.Height, PixelFormat.Format32bppArgb)) {
      using (Graphics g = Graphics.FromImage(bmp)) {
        g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
        g.DrawImage(original, new Rectangle(0, 0, original.Width, original.Height));
      }
      int w = bmp.Width, h = bmp.Height;
      Rectangle rect = new Rectangle(0, 0, w, h);
      BitmapData data = bmp.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
      int stride = data.Stride;
      byte[] px = new byte[stride * h];
      System.Runtime.InteropServices.Marshal.Copy(data.Scan0, px, 0, px.Length);
      bool[] seen = new bool[w * h];
      Queue<int> q = new Queue<int>();
      for (int x = 0; x < w; x++) { q.Enqueue(x); q.Enqueue((h - 1) * w + x); }
      for (int y = 0; y < h; y++) { q.Enqueue(y * w); q.Enqueue(y * w + w - 1); }
      int cleared = 0;
      while (q.Count > 0) {
        int idx = q.Dequeue();
        if (seen[idx]) continue;
        seen[idx] = true;
        int x = idx % w, y = idx / w;
        int o = y * stride + x * 4;
        byte b = px[o], g = px[o + 1], r = px[o + 2];
        int d = Math.Max(Math.Abs(r - 255), Math.Max(Math.Abs(g - 255), Math.Abs(b - 255)));
        if (d > tol) continue;
        px[o + 3] = 0;
        cleared++;
        if (x > 0) q.Enqueue(idx - 1);
        if (x < w - 1) q.Enqueue(idx + 1);
        if (y > 0) q.Enqueue(idx - w);
        if (y < h - 1) q.Enqueue(idx + w);
      }
      System.Runtime.InteropServices.Marshal.Copy(px, 0, data.Scan0, px.Length);
      bmp.UnlockBits(data);
      bmp.Save(dst, ImageFormat.Png);
      return cleared;
    }
  }
}
"@
$dstPath = Join-Path (Get-Location) $Out
$cleared = [Knockout]::Run((Resolve-Path $Source).Path, $dstPath, $Tolerance)
Write-Output ("alpha " + $Out + " cleared=" + $cleared + " bytes=" + (Get-Item $Out).Length)
