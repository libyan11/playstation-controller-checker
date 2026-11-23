# Tests every connected USB gamepad that looks like a DualShock 4, straight through the Windows HID API.
# Runs the same checks as ds4-checker.html: PS4 security-chip handshake (RSA-PSS verified), firmware info,
# factory calibration, Bluetooth address, input report rate / timestamp / layout, battery.
# Usage:  powershell -ExecutionPolicy Bypass -File tools\ds4-hid-test.ps1 [-Raw] [-Red]
param([switch]$Raw, [switch]$Red)

$cs = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public class HidInfo { public string Path; public ushort Vid; public ushort Pid; public string Product; public int InLen; public int OutLen; public int FeatLen; public ushort UsagePage; public ushort Usage; }
public class HidSample { public double T; public byte[] Data; }

public static class Hid {
  [StructLayout(LayoutKind.Sequential)] struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }
  [StructLayout(LayoutKind.Sequential)] struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }
  [StructLayout(LayoutKind.Sequential)] struct HIDP_CAPS {
    public ushort Usage; public ushort UsagePage; public ushort InputReportByteLength; public ushort OutputReportByteLength; public ushort FeatureReportByteLength;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
    public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices, NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices, NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
  }
  [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
  [DllImport("hid.dll", SetLastError = true)] static extern bool HidD_GetAttributes(SafeFileHandle h, ref HIDD_ATTRIBUTES a);
  [DllImport("hid.dll", SetLastError = true)] static extern bool HidD_GetFeature(SafeFileHandle h, byte[] b, int len);
  [DllImport("hid.dll", SetLastError = true)] static extern bool HidD_SetFeature(SafeFileHandle h, byte[] b, int len);
  [DllImport("hid.dll", SetLastError = true)] static extern bool HidD_SetOutputReport(SafeFileHandle h, byte[] b, int len);
  [DllImport("hid.dll", SetLastError = true)] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr p);
  [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr p);
  [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr p, ref HIDP_CAPS c);
  [DllImport("hid.dll")] static extern bool HidD_GetProductString(SafeFileHandle h, byte[] b, int len);
  [DllImport("setupapi.dll", SetLastError = true)] static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr hwnd, int flags);
  [DllImport("setupapi.dll", SetLastError = true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr info, ref Guid g, int idx, ref SP_DEVICE_INTERFACE_DATA d);
  [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr set, ref SP_DEVICE_INTERFACE_DATA d, IntPtr detail, int size, out int req, IntPtr info);
  [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(SafeFileHandle h, byte[] b, int n, out int read, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(SafeFileHandle h, byte[] b, int n, out int written, IntPtr ov);

  // Output report over the interrupt OUT pipe (what Chrome/DS4Windows use for lightbar & rumble)
  public static bool Write(SafeFileHandle h, byte[] b) {
    int w;
    if (!WriteFile(h, b, b.Length, out w, IntPtr.Zero)) { LastError = Marshal.GetLastWin32Error(); return false; }
    return true;
  }

  public static int LastError;

  public static List<HidInfo> List() {
    var res = new List<HidInfo>();
    Guid g; HidD_GetHidGuid(out g);
    IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
    try {
      for (int i = 0; ; i++) {
        var d = new SP_DEVICE_INTERFACE_DATA(); d.cbSize = Marshal.SizeOf(d);
        if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref d)) break;
        int req; SetupDiGetDeviceInterfaceDetailW(set, ref d, IntPtr.Zero, 0, out req, IntPtr.Zero);
        IntPtr buf = Marshal.AllocHGlobal(req);
        try {
          Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
          if (!SetupDiGetDeviceInterfaceDetailW(set, ref d, buf, req, out req, IntPtr.Zero)) continue;
          string path = Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4));
          using (var h = CreateFileW(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (h.IsInvalid) continue;
            var a = new HIDD_ATTRIBUTES(); a.Size = Marshal.SizeOf(a);
            if (!HidD_GetAttributes(h, ref a)) continue;
            var info = new HidInfo(); info.Path = path; info.Vid = a.VendorID; info.Pid = a.ProductID;
            var pb = new byte[256];
            if (HidD_GetProductString(h, pb, pb.Length)) info.Product = System.Text.Encoding.Unicode.GetString(pb).TrimEnd('\0');
            IntPtr pp;
            if (HidD_GetPreparsedData(h, out pp)) {
              var c = new HIDP_CAPS(); HidP_GetCaps(pp, ref c);
              info.InLen = c.InputReportByteLength; info.OutLen = c.OutputReportByteLength; info.FeatLen = c.FeatureReportByteLength;
              info.UsagePage = c.UsagePage; info.Usage = c.Usage;
              HidD_FreePreparsedData(pp);
            }
            res.Add(info);
          }
        } finally { Marshal.FreeHGlobal(buf); }
      }
    } finally { SetupDiDestroyDeviceInfoList(set); }
    return res;
  }

  public static SafeFileHandle Open(string path) {
    var h = CreateFileW(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    if (h.IsInvalid) throw new IOException("Couldn't open the controller (Windows error " + Marshal.GetLastWin32Error() + "). Is another app using it?");
    return h;
  }
  public static byte[] GetFeature(SafeFileHandle h, byte id, int len) {
    var b = new byte[len]; b[0] = id;
    if (!HidD_GetFeature(h, b, len)) { LastError = Marshal.GetLastWin32Error(); return null; }
    return b;
  }
  public static bool SetFeature(SafeFileHandle h, byte[] b) {
    if (!HidD_SetFeature(h, b, b.Length)) { LastError = Marshal.GetLastWin32Error(); return false; }
    return true;
  }
  public static bool SetOutput(SafeFileHandle h, byte[] b) {
    if (!HidD_SetOutputReport(h, b, b.Length)) { LastError = Marshal.GetLastWin32Error(); return false; }
    return true;
  }
  public static List<HidSample> ReadInputs(SafeFileHandle h, int len, int ms) {
    var list = new List<HidSample>(); var sw = Stopwatch.StartNew();
    var th = new Thread(() => {
      while (sw.ElapsedMilliseconds < ms) {
        var b = new byte[len]; int r;
        if (!ReadFile(h, b, len, out r, IntPtr.Zero)) break;
        var s = new HidSample(); s.T = sw.Elapsed.TotalMilliseconds; s.Data = b;
        lock (list) list.Add(s);
      }
    });
    th.IsBackground = true; th.Start(); th.Join(ms + 1500);
    lock (list) return new List<HidSample>(list);
  }

  static readonly uint[] crcTable = MakeCrc();
  static uint[] MakeCrc() { var t = new uint[256]; for (uint n = 0; n < 256; n++) { uint c = n; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1; t[n] = c; } return t; }
  public static uint Crc32(byte[] d, int off, int len) { uint c = 0xFFFFFFFF; for (int i = off; i < off + len; i++) c = crcTable[(c ^ d[i]) & 0xFF] ^ (c >> 8); return c ^ 0xFFFFFFFF; }

  static BigInteger FromBE(byte[] be) { var le = new byte[be.Length + 1]; for (int i = 0; i < be.Length; i++) le[i] = be[be.Length - 1 - i]; return new BigInteger(le); }
  static byte[] ToBE(BigInteger v, int len) { var le = v.ToByteArray(); var be = new byte[len]; for (int i = 0; i < len && i < le.Length; i++) be[len - 1 - i] = le[i]; return be; }
  static byte[] Mgf1(byte[] seed, int len) {
    var outp = new byte[len]; int pos = 0; uint ctr = 0;
    using (var sha = SHA256.Create()) {
      while (pos < len) {
        var inb = new byte[seed.Length + 4]; Buffer.BlockCopy(seed, 0, inb, 0, seed.Length);
        inb[seed.Length] = (byte)(ctr >> 24); inb[seed.Length + 1] = (byte)(ctr >> 16); inb[seed.Length + 2] = (byte)(ctr >> 8); inb[seed.Length + 3] = (byte)ctr;
        var hh = sha.ComputeHash(inb); int n = Math.Min(hh.Length, len - pos); Buffer.BlockCopy(hh, 0, outp, pos, n); pos += n; ctr++;
      }
    }
    return outp;
  }
  // RSASSA-PSS (SHA-256, MGF1-SHA256) verification that accepts any salt length.
  public static string PssVerify(byte[] nBE, byte[] eBE, byte[] sig, byte[] msg) {
    var n = FromBE(nBE); var e = FromBE(eBE); var s = FromBE(sig);
    if (n.IsZero || e.IsZero) return "fail: empty public key";
    if (s >= n) return "fail: signature larger than key";
    var em = ToBE(BigInteger.ModPow(s, e, n), 256);
    if (em[255] != 0xBC) return "fail: not an RSA-PSS signature (trailer " + em[255].ToString("X2") + ")";
    int hLen = 32, dbLen = 256 - hLen - 1;
    var H = new byte[hLen]; Buffer.BlockCopy(em, dbLen, H, 0, hLen);
    var mask = Mgf1(H, dbLen); var db = new byte[dbLen];
    for (int i = 0; i < dbLen; i++) db[i] = (byte)(em[i] ^ mask[i]);
    db[0] &= 0x7F;
    int idx = 0; while (idx < dbLen && db[idx] == 0) idx++;
    if (idx == dbLen || db[idx] != 1) return "fail: bad PSS padding";
    int saltLen = dbLen - idx - 1; var salt = new byte[saltLen]; Buffer.BlockCopy(db, idx + 1, salt, 0, saltLen);
    using (var sha = SHA256.Create()) {
      var mh = sha.ComputeHash(msg);
      var mp = new byte[8 + 32 + saltLen]; Buffer.BlockCopy(mh, 0, mp, 8, 32); Buffer.BlockCopy(salt, 0, mp, 40, saltLen);
      var h2 = sha.ComputeHash(mp);
      for (int i = 0; i < 32; i++) if (h2[i] != H[i]) return "fail: valid RSA-PSS structure but signs a different message (salt " + saltLen + ")";
    }
    return "ok: salt " + saltLen;
  }
}
'@
if (-not ('Hid' -as [type])) { Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Numerics }

function Hex([byte[]]$b, [int]$max = 64) { if (-not $b) { return '(none)' }; (($b | Select-Object -First $max) | ForEach-Object { $_.ToString('x2') }) -join ' ' }
function Mac([byte[]]$b, [int]$o) { (($b[($o + 5)..$o]) | ForEach-Object { $_.ToString('X2') }) -join ':' }
$S16 = { param($b, $o) [BitConverter]::ToInt16($b, $o) }

$known = @{ 0x05C4 = 'DualShock 4 (CUH-ZCT1, 1st gen)'; 0x09CC = 'DualShock 4 (CUH-ZCT2, 2nd gen)'; 0x0BA0 = 'Sony wireless adapter' }
$pads = [Hid]::List() | Where-Object { $_.UsagePage -eq 1 -and ($_.Usage -eq 4 -or $_.Usage -eq 5) }
if (-not $pads) { Write-Output "No game controllers found. Plug one in with a USB data cable."; return }

$n = 0
foreach ($d in $pads) {
  $n++
  $notSony = $false
  $results = New-Object System.Collections.Generic.List[object]
  function Add($status, $name, $detail = '') { $results.Add([pscustomobject]@{ Status = $status; Check = $name; Detail = $detail }) }
  $bt = $d.Path -match '00001124-0000-1000-8000-00805f9b34fb|bthenum' -or $d.InLen -gt 64
  Write-Output ""
  Write-Output ("=" * 78)
  Write-Output ("Controller {0}: ""{1}""  VID {2:X4} PID {3:X4}  {4}" -f $n, $d.Product, $d.Vid, $d.Pid, $(if ($bt) { 'Bluetooth' } else { 'USB' }))
  Write-Output ("Report sizes: input {0}, output {1}, feature {2}" -f $d.InLen, $d.OutLen, $d.FeatLen)
  Write-Output ("=" * 78)
  if ($d.Vid -eq 0x054C -and $known.ContainsKey([int]$d.Pid)) { Add 'INFO' "Reports itself as $($known[[int]$d.Pid])" 'Clones copy this ID too.' }
  else { Add 'WARN' 'Not a Sony DualShock 4 ID' ("VID {0:X4} PID {1:X4}" -f $d.Vid, $d.Pid) }
  if ($bt) { Add 'INFO' 'Connected over Bluetooth' 'Plug in with USB for the full test (security chip needs USB).' }

  try { $h = [Hid]::Open($d.Path) } catch { Add 'FAIL' 'Could not open the controller' $_.Exception.Message; $results | Format-Table -Wrap -AutoSize | Out-String -Width 200; continue }
  try {
    $FL = [Math]::Max(64, $d.FeatLen)
    function GF([byte]$id) { $b = [Hid]::GetFeature($h, $id, $d.FeatLen); if ($Raw) { Write-Output ("  get 0x{0:X2}: {1}" -f $id, $(if ($b) { Hex $b } else { "error $([Hid]::LastError)" })) | Out-Host }; return ,$b }

    # ---- 1. PS4 security chip handshake ----
    if (-not $bt) {
      # 0xF3 (reset / page size) only exists on 2nd-gen controllers; 1st-gen ones go straight to 0xF0.
      $f3 = GF 0xF3
      if (-not $f3) { Add 'INFO' 'No auth page-size report (0xF3)' 'Normal for a 1st-gen DS4 (CUH-ZCT1). Starting the handshake directly.' }
      if ($true) {
        $seq = [byte](Get-Random -Minimum 1 -Maximum 255)
        $nonce = New-Object byte[] 256; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($nonce)
        $sent = $true
        for ($page = 0; $page -lt 5; $page++) {
          $buf = New-Object byte[] 64
          $buf[0] = 0xF0; $buf[1] = $seq; $buf[2] = $page
          $cnt = [Math]::Min(56, 256 - $page * 56); [Array]::Copy($nonce, $page * 56, $buf, 4, $cnt)
          $crc = [BitConverter]::GetBytes([Hid]::Crc32($buf, 0, 60)); [Array]::Copy($crc, 0, $buf, 60, 4)
          $ok = [Hid]::SetFeature($h, $buf)
          if (-not $ok -and $d.FeatLen -gt 64) { $big = New-Object byte[] $d.FeatLen; [Array]::Copy($buf, $big, 64); $ok = [Hid]::SetFeature($h, $big) }
          if (-not $ok) { $sent = $false; Add 'FAIL' "No PS4 security chip: controller rejected the auth challenge (0xF0 page $page)" "Windows error $([Hid]::LastError). Every genuine DS4 accepts this."; break }
        }
        if ($sent) {
          $ready = $false; $sw = [Diagnostics.Stopwatch]::StartNew(); $lastSt = $null
          while ($sw.ElapsedMilliseconds -lt 10000) {
            $st = GF 0xF2; $lastSt = $st
            if ($st -and $st[1] -eq $seq -and $st[2] -eq 0) { $ready = $true; break }
            Start-Sleep -Milliseconds 100
          }
          if (-not $ready) { Add 'FAIL' 'Controller never finished signing the challenge' ("Last status: " + (Hex $lastSt 8)) }
          else {
            $resp = New-Object byte[] (19 * 56); $okRead = $true
            for ($i = 0; $i -lt 19; $i++) {
              $p = GF 0xF1
              if (-not $p) { $okRead = $false; Add 'FAIL' "Couldn't read auth response page $i" "Windows error $([Hid]::LastError)"; break }
              $pg = $p[2]; if ($pg -gt 18) { $okRead = $false; Add 'FAIL' "Auth response has bad page number $pg" ''; break }
              [Array]::Copy($p, 4, $resp, $pg * 56, 56)
            }
            if ($okRead) {
              $sig = $resp[0..255]; $serial = $resp[256..271]; $nn = $resp[272..527]; $ee = $resp[528..783]
              $v = [Hid]::PssVerify([byte[]]$nn, [byte[]]$ee, [byte[]]$sig, $nonce)
              $serialHex = ($serial | ForEach-Object { $_.ToString('X2') }) -join ''
              if ($v -like 'ok*') { Add 'PASS' 'Security chip signed our random challenge with a valid RSA-2048 key' "Proves a real PS4 auth chip. Key serial $serialHex ($v)" }
              else { Add 'FAIL' 'Security chip answered but the signature is invalid' "$v. Key serial $serialHex" }
            }
          }
        }
      }
    }

    # ---- 2. Firmware info ----
    $a3 = GF 0xA3
    if (-not $a3) { Add $(if ($bt) { 'WARN' } else { 'FAIL' }) 'Firmware info report (0xA3) not supported' "Windows error $([Hid]::LastError). Genuine DS4s answer this." }
    else {
      $date = [Text.Encoding]::ASCII.GetString($a3, 1, 11).Trim([char]0, ' ')
      $time = [Text.Encoding]::ASCII.GetString($a3, 17, 8).Trim([char]0, ' ')
      $hw = '{0:x}.{1:x}' -f [BitConverter]::ToUInt16($a3, 0x21), [BitConverter]::ToUInt16($a3, 0x23)
      $fw = '{0:x}.{1:x}' -f [BitConverter]::ToUInt32($a3, 0x25), [BitConverter]::ToUInt16($a3, 0x29)
      $ok = $date -match '^[A-Z][a-z]{2}\s+\d{1,2}\s+20\d\d$'
      Add $(if ($ok) { 'PASS' } else { 'WARN' }) $(if ($ok) { 'Firmware info looks normal' } else { 'Firmware info is malformed' }) "Build date ""$date"" $time, HW $hw, FW $fw"
      # Board model from the HW version high byte (mapping from DualShock Tools)
      $a = [BitConverter]::ToUInt16($a3, 0x23) -shr 8
      $board = if ($a -eq 0x31) { 'JDM-001 (1st gen, 2013)' } elseif ($a -eq 0x43) { 'JDM-011 (1st gen)' } elseif ($a -eq 0x54) { 'JDM-030 (1st gen, 2015)' }
               elseif ($a -ge 0x64 -and $a -le 0x74) { 'JDM-040 (2nd gen)' } elseif (($a -gt 0x80 -and $a -lt 0x84) -or $a -eq 0x93) { 'JDM-020 (1st gen)' }
               elseif ($a -in 0xa4, 0x90, 0xa0) { 'JDM-050 (2nd gen)' } elseif ($a -eq 0xb0) { 'JDM-055 (2nd gen, possibly Scuf)' } elseif ($a -eq 0xb4) { 'JDM-055 (2nd gen)' } else { $null }
      if ($board) { Add 'PASS' "Circuit board: $board" 'A known Sony board revision (printed on the board inside).' }
      else { Add 'WARN' ("Unrecognised circuit board (hardware code 0x{0:x2})" -f $a) 'Not one of Sony''s known DS4 boards.' }
      # The board must match the model the ID claims (third-party pads and clones copy the 2nd-gen ID onto 1st-gen firmware)
      $gen = if ($a -in 0x31, 0x43, 0x54, 0x81, 0x82, 0x83, 0x93) { 1 } elseif (($a -ge 0x64 -and $a -le 0x74) -or $a -in 0xa4, 0x90, 0xa0, 0xb0, 0xb4) { 2 } else { $null }
      $claimed = if ($d.Pid -eq 0x09CC) { 2 } elseif ($d.Pid -eq 0x05C4) { 1 } else { $null }
      if ($gen -and $claimed) {
        if ($gen -eq $claimed) { Add 'PASS' "Board matches the model it claims (gen $gen)" '' }
        else { Add 'FAIL' "Hardware doesn't match the model it claims" "ID says gen $claimed (CUH-ZCT$claimed) but board/firmware are gen $gen ($board, built $date). Genuine controllers always match; third-party pads and clones copy Sony's ID." ; $notSony = $true }
      }
    }

    # ---- 2b. DualShock Tools' clone probe: genuine DS4s answer 0x81 instantly ----
    if (-not $bt) {
      $r81 = GF 0x81
      if ($r81) { Add 'PASS' 'Answers Sony''s hidden 0x81 report' 'DualShock Tools'' genuine check: clones ignore it.' }
      else { Add 'FAIL' 'Doesn''t answer Sony''s hidden 0x81 report' "Windows error $([Hid]::LastError). DualShock Tools treats this as a clone." }
    }

    # ---- 3. Factory calibration ----
    $calId = if ($bt) { 0x05 } else { 0x02 }
    $cal = GF $calId
    if (-not $cal) { Add 'FAIL' "Sensor calibration report (0x$('{0:X2}' -f $calId)) not supported" "Windows error $([Hid]::LastError)" }
    else {
      $s = { param($i) [BitConverter]::ToInt16($cal, 1 + $i) }
      if ($bt) { $g = @((& $s 6), (& $s 12), (& $s 8), (& $s 14), (& $s 10), (& $s 16)) } else { $g = @((& $s 6), (& $s 8), (& $s 10), (& $s 12), (& $s 14), (& $s 16)) }
      $ac = @((& $s 22), (& $s 24), (& $s 26), (& $s 28), (& $s 30), (& $s 32))
      $blank = -not ($cal[1..34] | Where-Object { $_ -ne 0 }) -or -not ($cal[1..34] | Where-Object { $_ -ne 255 })
      $gyroOk = $g[0] -gt 0 -and $g[1] -lt 0 -and $g[2] -gt 0 -and $g[3] -lt 0 -and $g[4] -gt 0 -and $g[5] -lt 0
      $accOk = ($ac[0], $ac[2], $ac[4] | Where-Object { $_ -gt 4000 -and $_ -lt 12000 }).Count -eq 3 -and ($ac[1], $ac[3], $ac[5] | Where-Object { $_ -lt -4000 -and $_ -gt -12000 }).Count -eq 3
      $det = "gyro +/- $($g -join ', '); accel +/- $($ac -join ', ')"
      $gAbs = $g | ForEach-Object { [Math]::Abs($_) }; $aAbs = $ac | ForEach-Object { [Math]::Abs($_) }
      $generic = -not $blank -and ((@($gAbs | Select-Object -Unique).Count -eq 1) -or (@($aAbs | Where-Object { $_ -ne 8192 }).Count -eq 0))
      if ($blank) { Add 'FAIL' 'Sensor calibration is blank' $det }
      elseif ($generic) { Add 'FAIL' 'Sensor calibration is a generic default, not factory-measured' "Same round value on every axis. Genuine Sony controllers are calibrated one by one. $det"; $notSony = $true }
      elseif ($gyroOk -and $accOk) { Add 'PASS' 'Factory sensor calibration looks plausible' $det }
      else { Add 'WARN' 'Sensor calibration values look unusual' $det }
    }

    # ---- 4. Bluetooth address ----
    if ($bt) {
      # Over Bluetooth the controller's address is in its Windows device ID
      $idPattern = '^BTHENUM\\\{00001124-[^_]+_VID&0002' + $d.Vid.ToString('X4') + '_PID&' + $d.Pid.ToString('X4') + '\\'
      $bthIds = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match $idPattern } |
        ForEach-Object { if ($_.InstanceId -match '&([0-9A-F]{12})_C') { $Matches[1] } })
      if ($bthIds.Count -eq 1) {
        $mac = ($bthIds[0] -split '(..)' | Where-Object { $_ }) -join ':'
        $top = [Convert]::ToByte($bthIds[0].Substring(0, 2), 16)
        if ($top -band 3) { Add 'WARN' "Bluetooth address $mac isn't a registered manufacturer address" ("It's marked as {0} address. Sony uses registered manufacturer prefixes; third-party pads and clones often make one up." -f $(if ($top -band 1) { 'a group (multicast)' } else { 'a locally assigned' })) }
        else { Add 'INFO' "Bluetooth address $mac" '' }
      }
    }
    if (-not $bt) {
      $m = GF 0x12
      if (-not $m) { Add 'WARN' "Couldn't read the Bluetooth address (0x12)" "Windows error $([Hid]::LastError)" }
      else {
        $mac = Mac $m 1; $host_ = Mac $m 10
        $top = $m[6]
        $hostTxt = if (($m[10..15] | Where-Object { $_ -ne 0 })) { "paired with $host_" } else { 'not paired with anything' }
        if (-not ($m[1..6] | Where-Object { $_ -ne 0 })) { Add 'WARN' 'Bluetooth address is blank' '' }
        elseif ($top -band 3) { Add 'WARN' "Bluetooth address $mac isn't a registered manufacturer address" "Some clones make one up. $hostTxt" }
        else { Add 'INFO' "Bluetooth address $mac" $hostTxt }
      }
    }

    # ---- 5. Input reports: rate, layout, timestamp, counter, battery ----
    $samples = [Hid]::ReadInputs($h, $d.InLen, 3000)
    $samples = @($samples | Where-Object { $_.T -gt 300 })    # skip the first 0.3 s (settling)
    $full = @($samples | Where-Object { ($_.Data[0] -eq 1 -and -not $bt) -or $_.Data[0] -eq 0x11 })
    if ($samples.Count -eq 0) { Add 'FAIL' 'No input reports received' 'Close Steam/DS4Windows and replug.' }
    else {
      $hz = [Math]::Round($samples.Count / 2.7)
      $iv = for ($i = 1; $i -lt $samples.Count; $i++) { $samples[$i].T - $samples[$i - 1].T }
      $mean = ($iv | Measure-Object -Average).Average
      $jit = [Math]::Sqrt((($iv | ForEach-Object { ($_ - $mean) * ($_ - $mean) }) | Measure-Object -Average).Average)
      if ($bt) { Add $(if ($hz -lt 60) { 'WARN' } else { 'INFO' }) "Bluetooth report rate $hz Hz" ("one update every {0:N0} ms{1}; jitter {2:N2} ms" -f (1000 / [Math]::Max(1, $hz)), $(if ($hz -lt 60) { ', which adds noticeable input lag' } else { '' }), $jit) }
      elseif ($hz -ge 200) { Add 'PASS' "USB report rate $hz Hz" ("A genuine DS4 sends ~250 Hz. Jitter {0:N2} ms" -f $jit) }
      else { Add 'WARN' "Low USB report rate: $hz Hz" ("A genuine DS4 sends ~250 Hz; many clones 125 Hz. Jitter {0:N2} ms" -f $jit) }
      if ($full.Count) {
        $off = if ($full[0].Data[0] -eq 0x11) { 3 } else { 1 }
        $ts = $full | ForEach-Object { [BitConverter]::ToUInt16($_.Data, $off + 9) } | Select-Object -Unique
        $ctr = $full | ForEach-Object { $_.Data[$off + 6] -shr 2 } | Select-Object -Unique
        if (@($ts).Count -gt $full.Count / 2) { Add 'PASS' 'Internal sensor timestamp is ticking' '' } else { Add 'FAIL' 'Internal sensor timestamp is frozen' 'Genuine DS4s stamp every report.' }
        # 6-bit counter: expect most reports to carry a new value (up to its 64-value range)
        if (@($ctr).Count -gt [Math]::Min(32, $full.Count / 4)) { Add 'PASS' 'Report counter increments' '' } else { Add 'WARN' "Report counter barely changes ($(@($ctr).Count) values in $($full.Count) reports)" '' }
        $last = $full[-1].Data
        $batt = $last[$off + 29]; $cable = ($batt -band 0x10) -ne 0; $lvl = $batt -band 0x0F
        $pct = if ($cable -and $lvl -ge 11) { 100 } else { [Math]::Min(100, $lvl * 10) }
        Add 'INFO' "Battery ~$pct%" $(if ($cable) { if ($lvl -ge 11) { 'plugged in, full' } else { 'plugged in, charging' } } else { 'on battery' })
        Add 'INFO' 'Sticks right now (128 = centre)' ("L x{0} y{1}, R x{2} y{3}, L2 {4}, R2 {5}" -f $last[$off], $last[$off + 1], $last[$off + 2], $last[$off + 3], $last[$off + 7], $last[$off + 8])
        $len = $full[0].Data.Length
        Add $(if ($len -eq 64 -or $len -eq 78 -or $bt) { 'PASS' } else { 'WARN' }) "Input report size $len bytes" ''

        # ---- 6. Hands-off condition checks (controller lying still, nothing pressed) ----
        foreach ($stick in @(@{ Name = 'Left'; X = 0; Y = 1 }, @{ Name = 'Right'; X = 2; Y = 3 })) {
          $xs = $full | ForEach-Object { [int]$_.Data[$off + $stick.X] }
          $ys = $full | ForEach-Object { [int]$_.Data[$off + $stick.Y] }
          $ax = ($xs | Measure-Object -Average).Average; $ay = ($ys | Measure-Object -Average).Average
          $maxR = ($full | ForEach-Object { [Math]::Sqrt([Math]::Pow(($_.Data[$off + $stick.X] - 127.5) / 127.5, 2) + [Math]::Pow(($_.Data[$off + $stick.Y] - 127.5) / 127.5, 2)) } | Measure-Object -Maximum).Maximum
          $pct = [Math]::Ceiling($maxR * 100)
          $jit = [Math]::Max((($xs | Measure-Object -Maximum).Maximum - ($xs | Measure-Object -Minimum).Minimum), (($ys | Measure-Object -Maximum).Maximum - ($ys | Measure-Object -Minimum).Minimum))
          $st = if ($pct -le 6) { 'PASS' } elseif ($pct -le 12) { 'WARN' } else { 'FAIL' }
          $lbl = if ($pct -le 6) { 'no noticeable drift' } elseif ($pct -le 12) { 'slight drift' } else { 'significant drift (or being touched)' }
          Add $st "$($stick.Name) stick at rest: $lbl" ("rests at ({0:N1}, {1:N1}), centre 127.5; needs ~{2}% deadzone; jitter {3} step(s)" -f $ax, $ay, $pct, $jit)
        }
        $l2max = ($full | ForEach-Object { $_.Data[$off + 7] } | Measure-Object -Maximum).Maximum
        $r2max = ($full | ForEach-Object { $_.Data[$off + 8] } | Measure-Object -Maximum).Maximum
        if ($l2max -le 3 -and $r2max -le 3) { Add 'PASS' 'Triggers rest at zero' "L2 max $l2max, R2 max $r2max" }
        else { Add 'WARN' 'A trigger reads above zero at rest' "L2 max $l2max, R2 max $r2max. Sticking trigger, or it was being pressed." }
        # Buttons held in more than half the samples = stuck (or being held)
        $names = @{}
        foreach ($smp in $full) {
          $b4 = $smp.Data[$off + 4]; $b5 = $smp.Data[$off + 5]; $b6 = $smp.Data[$off + 6]
          $dp = $b4 -band 0x0F
          if ($dp -ne 8) { $names['D-pad'] = 1 + $names['D-pad'] }
          $map = @(@($b4, 0x10, 'Square'), @($b4, 0x20, 'Cross'), @($b4, 0x40, 'Circle'), @($b4, 0x80, 'Triangle'), @($b5, 0x01, 'L1'), @($b5, 0x02, 'R1'), @($b5, 0x10, 'Share'), @($b5, 0x20, 'Options'), @($b5, 0x40, 'L3'), @($b5, 0x80, 'R3'), @($b6, 0x01, 'PS'), @($b6, 0x02, 'Touchpad click'))
          foreach ($m in $map) { if ($m[0] -band $m[1]) { $names[$m[2]] = 1 + $names[$m[2]] } }
          if (($smp.Data[$off + 34] -band 0x80) -eq 0) { $names['Touchpad touch'] = 1 + $names['Touchpad touch'] }
        }
        $stuck = @($names.Keys | Where-Object { $names[$_] -gt $full.Count / 2 })
        if ($stuck.Count) { Add 'WARN' "Held or stuck at rest: $($stuck -join ', ')" 'If nobody was touching it, that button/touchpad is stuck.' } else { Add 'PASS' 'No buttons or touchpad stuck' '' }
        # Accelerometer should read ~1 g (8192) total at rest; gyro should be quiet
        $mag = $full | ForEach-Object { $d_ = $_.Data; [Math]::Sqrt([Math]::Pow([BitConverter]::ToInt16($d_, $off + 18), 2) + [Math]::Pow([BitConverter]::ToInt16($d_, $off + 20), 2) + [Math]::Pow([BitConverter]::ToInt16($d_, $off + 22), 2)) }
        $g = ($mag | Measure-Object -Average).Average
        if ($g -gt 6500 -and $g -lt 10000) { Add 'PASS' ('Accelerometer feels gravity ({0:N2} g)' -f ($g / 8192)) 'Motion sensor is alive and calibrated.' }
        elseif ($g -lt 500) { Add 'FAIL' 'Accelerometer reads zero' 'No working motion sensor. Common in cheap clones.' }
        else { Add 'WARN' ('Accelerometer reads {0:N2} g at rest (expected ~1 g)' -f ($g / 8192)) 'Badly calibrated, or it was moving.' }
        $gn = foreach ($ax_ in 0, 1, 2) { $vals = $full | ForEach-Object { [BitConverter]::ToInt16($_.Data, $off + 12 + $ax_ * 2) }; $mu = ($vals | Measure-Object -Average).Average; [Math]::Sqrt((($vals | ForEach-Object { ($_ - $mu) * ($_ - $mu) }) | Measure-Object -Average).Average) }
        $gnoise = ($gn | Measure-Object -Maximum).Maximum
        $gzero = -not ($full | Where-Object { [BitConverter]::ToInt16($_.Data, $off + 12) -ne 0 -or [BitConverter]::ToInt16($_.Data, $off + 14) -ne 0 })
        if ($gzero) { Add 'FAIL' 'Gyroscope reads exactly zero' 'No working gyro. Common in cheap clones.' }
        elseif ($gnoise -lt 60) { Add 'PASS' ('Gyroscope is steady at rest (noise {0:N1})' -f $gnoise) '' }
        else { Add 'WARN' ('Gyroscope is noisy or moving (noise {0:N1})' -f $gnoise) 'Leave the controller still on a table and rerun.' }
      } else { Add 'WARN' 'Only short input reports received' 'Expected full 64-byte reports.' }
    }

    # ---- optional: set lightbar to pure red (USB output report 0x05) ----
    if ($Red -and -not $bt) {
      $o = New-Object byte[] ([Math]::Max(32, $d.OutLen)); $o[0] = 0x05; $o[1] = 0x07; $o[2] = 0x04; $o[6] = 255   # [4]=weak [5]=strong [6]=R [7]=G [8]=B
      if ([Hid]::SetOutput($h, $o)) { Add 'INFO' 'Lightbar set to pure RED' 'Check what colour it actually shows.' } else { Add 'WARN' 'Lightbar command rejected' "Windows error $([Hid]::LastError)" }
    }
  } finally { $h.Dispose() }

  $results | Format-Table -Wrap -AutoSize -Property Status, Check, Detail | Out-String -Width 220
  $fails = @($results | Where-Object Status -eq 'FAIL').Count
  $authPass = @($results | Where-Object { $_.Status -eq 'PASS' -and $_.Check -like 'Security chip*' }).Count
  $verdict = if ($notSony -and -not $authPass) { 'NOT A GENUINE SONY CONTROLLER (third-party, e.g. Gioteck, or a clone)' }
             elseif ($bt) { 'Bluetooth: security chip not checked (needs USB), no other signs of a fake' }
             elseif ($authPass -and $fails -eq 0) { 'GENUINE (security chip verified)' }
             elseif ($authPass) { 'Security chip verified, but other checks failed' }
             else { 'LIKELY COUNTERFEIT' }
  Write-Output "VERDICT for controller ${n}: $verdict  ($fails failed checks)"
}
