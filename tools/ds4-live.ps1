# Live hardware test for a PS4-style controller over USB or Bluetooth.
#   Default: cycles the lightbar and rumble (USB only), then shows button presses / sticks / triggers live.
#   -Map:    guided button test. It names each button in turn, you press it, and it records which button the
#            controller actually reported, so swapped or mislabelled buttons show up clearly.
# Results are saved to tools\live-test-log.txt.
# Usage:  powershell -ExecutionPolicy Bypass -File tools\ds4-live.ps1 [-Seconds 60] [-Map]
param([int]$Seconds = 60, [switch]$Map, [string[]]$Buttons, [int]$WaitSeconds = 15)

$src = Get-Content (Join-Path $PSScriptRoot 'ds4-hid-test.ps1') -Raw
$cs = [regex]::Match($src, "(?s)\`$cs = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not ('Hid' -as [type])) { Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Numerics }
$logPath = Join-Path $PSScriptRoot 'live-test-log.txt'
"Controller live test $(Get-Date)" | Set-Content $logPath
function Log($t) { Write-Host $t; Add-Content $logPath $t }

$pad = [Hid]::List() | Where-Object { $_.UsagePage -eq 1 -and $_.Usage -eq 5 -and $_.Vid -eq 0x054C } | Select-Object -First 1
if (-not $pad) { Log 'No PS4-style controller found. Plug it in with a data cable, or connect it over Bluetooth.'; return }
$bt = $pad.InLen -gt 64
$repId = if ($bt) { 0x11 } else { 0x01 }
$off = if ($bt) { 3 } else { 1 }          # payload start inside the report buffer (report ID, plus 2 header bytes on Bluetooth)
$h = [Hid]::Open($pad.Path)
Log ("Controller: ""{0}"" {1:X4}:{2:X4} over {3}" -f $pad.Product, $pad.Vid, $pad.Pid, $(if ($bt) { 'Bluetooth' } else { 'USB' }))
if ($bt) { [void][Hid]::GetFeature($h, 0x05, $pad.FeatLen) }   # switches Bluetooth controllers to full reports

# Decode the pressed buttons from one report, using the standard DualShock 4 layout
function Decode([byte[]]$d) {
  $b4 = $d[$off + 4]; $b5 = $d[$off + 5]; $b6 = $d[$off + 6]
  $dp = $b4 -band 0x0F; $p = @()
  if ($dp -in 7, 0, 1) { $p += 'Up' }; if ($dp -in 1, 2, 3) { $p += 'Right' }; if ($dp -in 3, 4, 5) { $p += 'Down' }; if ($dp -in 5, 6, 7) { $p += 'Left' }
  if ($b4 -band 0x10) { $p += 'Square' }; if ($b4 -band 0x20) { $p += 'Cross' }; if ($b4 -band 0x40) { $p += 'Circle' }; if ($b4 -band 0x80) { $p += 'Triangle' }
  if ($b5 -band 0x01) { $p += 'L1' }; if ($b5 -band 0x02) { $p += 'R1' }; if ($b5 -band 0x04) { $p += 'L2' }; if ($b5 -band 0x08) { $p += 'R2' }
  if ($b5 -band 0x10) { $p += 'Share' }; if ($b5 -band 0x20) { $p += 'Options' }; if ($b5 -band 0x40) { $p += 'L3' }; if ($b5 -band 0x80) { $p += 'R3' }
  if ($b6 -band 0x01) { $p += 'PS' }; if ($b6 -band 0x02) { $p += 'Touchpad click' }
  return , $p
}
function RawBits([byte[]]$d) { '{0:X2} {1:X2} {2:X2}' -f $d[$off + 4], $d[$off + 5], ($d[$off + 6] -band 0x03) }
function Batch([int]$ms) { @([Hid]::ReadInputs($h, $pad.InLen, $ms) | Where-Object { $_.Data[0] -eq $repId }) }

try {
  if ($Map) {
    Log ''
    Log '=== GUIDED BUTTON TEST ==='
    Log 'Press each button when its name appears, then let go. Hold the controller so nothing else is pressed.'
    $order = 'Cross', 'Circle', 'Square', 'Triangle', 'Up', 'Right', 'Down', 'Left', 'L1', 'R1', 'L2', 'R2', 'L3', 'R3', 'Share', 'Options', 'PS', 'Touchpad click'
    if ($Buttons) { $order = $Buttons }
    $results = @()
    foreach ($want in $order) {
      # wait until nothing is pressed
      $t0 = Get-Date
      do { $b = Batch 60; $idle = $b.Count -and -not (Decode $b[-1].Data).Count } until ($idle -or ((Get-Date) - $t0).TotalSeconds -gt 5)
      Write-Host ''
      Write-Host ">>> Press and release:  $want" -ForegroundColor Yellow
      $got = $null; $raw = ''; $t0 = Get-Date
      while (((Get-Date) - $t0).TotalSeconds -lt $WaitSeconds -and -not $got) {
        foreach ($s in (Batch 60)) { $p = Decode $s.Data; if ($p.Count) { $got = $p; $raw = RawBits $s.Data; break } }
      }
      if (-not $got) { $line = "  {0,-15} -> nothing registered ({1} s)" -f $want, $WaitSeconds; $ok = 'MISSING' }
      else {
        # let the press settle (two buttons can register a moment apart), then wait for release
        Start-Sleep -Milliseconds 150
        $more = Batch 80 | ForEach-Object { Decode $_.Data } | Where-Object { $_ }
        $got = @($got + $more | Select-Object -Unique)
        $ok = if ($got.Count -eq 1 -and $got[0] -eq $want) { 'OK' } elseif ($got -contains $want) { 'EXTRA' } else { 'WRONG' }
        $line = "  {0,-15} -> controller reported: {1,-22} [{2}]  raw {3}" -f $want, ($got -join ' + '), $ok, $raw
      }
      Log $line
      $results += [pscustomobject]@{ Asked = $want; Reported = ($got -join ' + '); Result = $ok }
    }
    Log ''
    $bad = $results | Where-Object Result -ne 'OK'
    if (-not $bad) { Log 'Every button reported correctly.' }
    else {
      Log "$(@($bad).Count) button(s) didn't report correctly:"
      foreach ($r in $bad) { Log ("  {0}: {1}" -f $r.Asked, $(switch ($r.Result) { 'MISSING' { 'nothing registered' } 'EXTRA' { "also reported $($r.Reported)" } default { "reported as $($r.Reported)" } })) }
    }
  } else {
    if (-not $bt) {
      function Send-Out([int]$r, [int]$g, [int]$b, [int]$weak = 0, [int]$strong = 0) {
        $o = New-Object byte[] ([Math]::Max(32, $pad.OutLen))
        $o[0] = 0x05; $o[1] = 0x07; $o[2] = 0x04; $o[4] = $weak; $o[5] = $strong; $o[6] = $r; $o[7] = $g; $o[8] = $b
        if ([Hid]::Write($h, $o)) { return 'sent' }
        $e1 = [Hid]::LastError
        if ([Hid]::SetOutput($h, $o)) { return "sent via control pipe (interrupt write failed, error $e1)" }
        return "FAILED (errors $e1 / $([Hid]::LastError))"
      }
      Log '=== LIGHTBAR: watch the light on the front of the controller ==='
      foreach ($c in @(@('RED', 255, 0, 0), @('GREEN', 0, 255, 0), @('BLUE', 0, 0, 255), @('WHITE', 255, 255, 255))) { Log ("  Lightbar -> {0,-6} ({1})" -f $c[0], (Send-Out $c[1] $c[2] $c[3])); Start-Sleep -Milliseconds 1500 }
      Log '=== RUMBLE ==='
      Log ('  Left (heavy) motor  ({0})' -f (Send-Out 0 0 255 0 255)); Start-Sleep -Milliseconds 1200
      Log ('  Right (light) motor ({0})' -f (Send-Out 0 0 255 255 0)); Start-Sleep -Milliseconds 1200
      [void](Send-Out 0 0 255)
    } else { Log '(Lightbar and rumble are tested in the web checker over Bluetooth.)' }

    Log ''
    Log "=== BUTTONS: press every button, move both sticks, squeeze L2/R2 ($Seconds s) ==="
    $all = 'Up', 'Down', 'Left', 'Right', 'Triangle', 'Circle', 'Cross', 'Square', 'L1', 'R1', 'L2', 'R2', 'L3', 'R3', 'Share', 'Options', 'PS', 'Touchpad click', 'Touchpad touch'
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $reports = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds -and $seen.Count -lt $all.Count) {
      $batch = Batch 100
      foreach ($s in $batch) {
        $d = $s.Data; $reports++
        $p = Decode $d
        if (($d[$off + 34] -band 0x80) -eq 0) { $p += 'Touchpad touch' }
        foreach ($x in $p) { if ($seen.Add($x)) { Add-Content $logPath ("  +{0,5:N1}s  first press: {1}" -f $sw.Elapsed.TotalSeconds, $x) } }
      }
      if ($batch) {
        $d = $batch[-1].Data
        Write-Host ("`r  L({0,3},{1,3}) R({2,3},{3,3}) L2 {4,3} R2 {5,3} | pressed now: {6,-28} | found {7}/{8}" -f $d[$off], $d[$off + 1], $d[$off + 2], $d[$off + 3], $d[$off + 7], $d[$off + 8], ((Decode $d) -join ' '), $seen.Count, $all.Count) -NoNewline
      } else { Write-Host "`r  (no input from controller)                                        " -NoNewline }
    }
    Write-Host ''
    Log "Input reports received: $reports"
    $missing = $all | Where-Object { -not $seen.Contains($_) }
    Log ("Buttons registered: {0}/{1}" -f $seen.Count, $all.Count)
    if ($missing) { Log ("Never registered: " + ($missing -join ', ')) } else { Log 'Every button, trigger and the touchpad registered.' }
  }
} catch {
  Log ''
  Log "ERROR: $($_.Exception.Message)"
  Log "  at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally { $h.Dispose() }
Log ''
Log 'Done. You can close this window.'
