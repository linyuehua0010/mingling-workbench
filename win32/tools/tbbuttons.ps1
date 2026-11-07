param([string]$Prefix = "win32\build\icon-check\tbbtn")
# Enumerate taskbar buttons and capture each button box in one pass.
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class TBX {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
}
"@
[TBX]::SetProcessDPIAware() | Out-Null
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, "Shell_TrayWnd")
$tb = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
if (-not $tb) { Write-Output "no taskbar"; exit 1 }
$all = $tb.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$i = 0
foreach ($e in $all) {
  $r = $e.Current.BoundingRectangle
  $n = $e.Current.Name
  if ($n -and $e.Current.ControlType.ProgrammaticName -eq "ControlType.Button" -and $r.Width -ge 40 -and $r.Width -le 90 -and $r.Height -ge 40) {
    $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, (New-Object System.Drawing.Size ([int]$r.Width), ([int]$r.Height)))
    $g.Dispose()
    $path = $Prefix + "-" + $i + ".png"
    $bmp.Save((Join-Path (Get-Location) $path), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output ("[" + $i + "] x=" + [int]$r.X + " " + $n)
    $i++
  }
}
Write-Output ("buttons " + $i)
