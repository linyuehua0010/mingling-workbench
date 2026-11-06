param([string]$Out = "win32\build\icon-check\taskbar.png", [string]$Mode = "taskbar")
# Reveal the auto-hidden taskbar or open the Alt-Tab switcher, then capture the screen.
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class U32 {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  public const uint KEYEVENTF_KEYUP = 0x0002;
  public const byte VK_MENU = 0x12;
  public const byte VK_TAB = 0x09;
}
"@
[U32]::SetProcessDPIAware() | Out-Null
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
if ($Mode -eq "alttab") {
  [U32]::keybd_event([U32]::VK_MENU, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 150
  [U32]::keybd_event([U32]::VK_TAB, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 150
  [U32]::keybd_event([U32]::VK_TAB, 0, [U32]::KEYEVENTF_KEYUP, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 600
} else {
  [U32]::SetCursorPos([int]($vs.Width / 2), [int]($vs.Height - 2)) | Out-Null
  Start-Sleep -Milliseconds 800
}
$bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($vs.X, $vs.Y, 0, 0, (New-Object System.Drawing.Size $vs.Width, $vs.Height))
$g.Dispose()
$bmp.Save((Join-Path (Get-Location) $Out), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
if ($Mode -eq "alttab") {
  [U32]::keybd_event([U32]::VK_MENU, 0, [U32]::KEYEVENTF_KEYUP, [UIntPtr]::Zero)
  [U32]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
  [U32]::keybd_event(0x1B, 0, [U32]::KEYEVENTF_KEYUP, [UIntPtr]::Zero)
}
Write-Output ("shot " + $Mode + " -> " + $Out)
