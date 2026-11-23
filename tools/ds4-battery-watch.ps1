# Watches a USB-connected DS4's battery level while it charges and logs every change.
# A healthy DS4 gains one 10% step roughly every 12 minutes while charging.
# Usage:  powershell -ExecutionPolicy Bypass -File tools\ds4-battery-watch.ps1 [-Minutes 15] [-Every 20]
param([int]$Minutes = 15, [int]$Every = 20)

# Reuse the HID helper class from ds4-hid-test.ps1
$src = Get-Content (Join-Path $PSScriptRoot 'ds4-hid-test.ps1') -Raw
$cs = [regex]::Match($src, "(?s)\`$cs = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not ('Hid' -as [type])) { Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Numerics }

$pad = [Hid]::List() | Where-Object { $_.UsagePage -eq 1 -and $_.Usage -eq 5 -and $_.InLen -eq 64 } | Select-Object -First 1
if (-not $pad) { Write-Output 'No USB-connected DS4 found.'; return }
$h = [Hid]::Open($pad.Path)
$start = Get-Date; $last = $null; $changes = @()
Write-Output ("Watching battery for {0} min (checking every {1}s)" -f $Minutes, $Every)
try {
  while (((Get-Date) - $start).TotalMinutes -lt $Minutes) {
    $s = [Hid]::ReadInputs($h, $pad.InLen, 300) | Where-Object { $_.Data[0] -eq 1 } | Select-Object -Last 1
    if ($s) {
      $b = $s.Data[30]; $lvl = $b -band 0x0F; $cable = ($b -band 0x10) -ne 0
      if ($lvl -ne $last) {
        $mins = ((Get-Date) - $start).TotalMinutes
        Write-Output ("{0:HH:mm:ss}  +{1,5:N1} min  level {2} (~{3}%)  cable={4}  raw=0x{5:X2}" -f (Get-Date), $mins, $lvl, [Math]::Min(100, $lvl * 10), $cable, $b)
        if ($null -ne $last) { $changes += $mins }
        $last = $lvl
      }
    } else { Write-Output ("{0:HH:mm:ss}  no input report (unplugged?)" -f (Get-Date)) }
    Start-Sleep -Seconds $Every
  }
} finally { $h.Dispose() }
Write-Output ("Done after {0} min. Final level {1}. Level changes: {2}" -f $Minutes, $last, $changes.Count)
if ($changes.Count -eq 0) { Write-Output 'Battery level never rose while plugged in. That points to a flat or worn battery, a bad cable/port, or a charging fault. Try another cable or USB port.' }
