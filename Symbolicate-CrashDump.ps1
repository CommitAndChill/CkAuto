<#
.SYNOPSIS
    Symbolicate a packaged-build crash dump against a matching PDB.

.DESCRIPTION
    Packaged builds ship without symbols — the Steam depot upload strips *.pdb
    (.runreal/scripts/deploy-steam.ts -> "FileExclusion" "*.pdb"), so every callstack QA
    sends reads BusterBlock.exe!UnknownFunction. The PDB still exists in the CI artifact
    for that build; this script pairs the two back up offline, without changing what ships.

    It reads the minidump directly (exception / module / thread streams), so it works on
    BOTH sources of dump this project produces:

      * UE's own  <Game>/Saved/Crashes/UECC-*/UEMinidump.dmp
      * Sentry's  <Game>/.sentry-native/reports/<guid>.dmp

    The Sentry one matters: a fatal access violation can kill the process before UE's
    CrashReportClient runs, leaving NO UECC folder at all. In the 2026-08-13 save/load
    crash the only UECC folder present was an unrelated boot ensure, and the actual fatal
    existed solely under .sentry-native. Check there first.

    HARD MATCH CHECK: a mismatched PDB does not fail loudly — dbghelp silently falls back
    to export symbols and resolves to confident nonsense. This script compares the PDB
    GUID recorded in the dump against the one in the supplied image and REFUSES to print
    frames unless they are identical.

.PARAMETER DumpPath
    A .dmp file, or a UECC-* crash folder (UEMinidump.dmp is found inside it).

.PARAMETER BuildDir
    Directory holding the matching BusterBlock.exe AND BusterBlock.pdb — i.e.
    <extracted CI artifact>/BusterBlock/Binaries/Win64. Both are required: the exe carries
    the CodeView record used for the match check, the pdb carries the symbols.

.PARAMETER ModuleName
    Image to symbolicate. Default BusterBlock.exe.

.PARAMETER MaxFrames
    Cap on resolved stack candidates. Default 60.

.EXAMPLE
    ./CkAuto/Symbolicate-CrashDump.ps1 `
        -DumpPath "C:/.../\.sentry-native/reports/0dd09c05-....dmp" `
        -BuildDir "D:/Downloads/BusterBlock-Win64-Development.dev-6328e8e64-1134/BusterBlock/Binaries/Win64"

.NOTES
    The stack walk is a conservative SCAN of the crashing thread's stack for values landing
    inside the module, not a true unwind — it over-reports (stale frames, spilled pointers).
    Read it as an ordered candidate list. The exception address, printed first and separately,
    IS exact.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $DumpPath,
    [Parameter(Mandatory = $true)] [string] $BuildDir,
    [string] $ModuleName = 'BusterBlock.exe',
    [int]    $MaxFrames  = 60
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------
# Resolve inputs
# ---------------------------------------------------------------------------------------

if (Test-Path $DumpPath -PathType Container)
{
    $found = Get-ChildItem $DumpPath -Filter *.dmp -Recurse -File | Select-Object -First 1
    if (-not $found) { throw "No .dmp found under '$DumpPath'." }
    $DumpPath = $found.FullName
}
if (-not (Test-Path $DumpPath -PathType Leaf)) { throw "Dump not found: '$DumpPath'." }

$imagePath = Join-Path $BuildDir $ModuleName
$pdbLeaf   = [IO.Path]::ChangeExtension($ModuleName, '.pdb')
$pdbPath   = Join-Path $BuildDir $pdbLeaf
if (-not (Test-Path $imagePath)) { throw "Image not found: '$imagePath'." }
if (-not (Test-Path $pdbPath))   { throw "PDB not found: '$pdbPath'. The CI artifact has it; the Steam depot does not." }

# ---------------------------------------------------------------------------------------
# Minidump parsing (streams: 3 ThreadList, 4 ModuleList, 6 Exception)
# ---------------------------------------------------------------------------------------

$fs = [IO.File]::OpenRead($DumpPath)
$br = New-Object IO.BinaryReader($fs)
try
{
    $sig = [Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
    if ($sig -ne 'MDMP') { throw "'$DumpPath' is not a minidump (signature '$sig')." }
    [void]$br.ReadUInt32(); $streamCount = $br.ReadUInt32(); $dirRva = $br.ReadUInt32()

    $dirs = @{}
    $fs.Position = $dirRva
    for ($i = 0; $i -lt $streamCount; $i++)
    {
        $type = [int]$br.ReadUInt32(); $size = $br.ReadUInt32(); $rva = $br.ReadUInt32()
        if (-not $dirs.ContainsKey($type)) { $dirs[$type] = @{ Size = $size; Rva = $rva } }
    }

    # --- Exception stream -------------------------------------------------------------
    if (-not $dirs.ContainsKey(6)) { throw 'Dump carries no exception stream.' }
    $fs.Position = $dirs[6].Rva
    $crashTid = $br.ReadUInt32(); [void]$br.ReadUInt32()
    $excCode  = $br.ReadUInt32(); [void]$br.ReadUInt32(); [void]$br.ReadUInt64()
    $excAddr  = $br.ReadUInt64(); $paramCount = $br.ReadUInt32(); [void]$br.ReadUInt32()
    $excParams = @(); for ($i = 0; $i -lt 15; $i++) { $excParams += $br.ReadUInt64() }

    # --- Module list ------------------------------------------------------------------
    $fs.Position = $dirs[4].Rva
    $moduleCount = $br.ReadUInt32()
    $target = $null
    for ($m = 0; $m -lt $moduleCount; $m++)
    {
        $base = $br.ReadUInt64(); $size = $br.ReadUInt32(); [void]$br.ReadUInt32()
        [void]$br.ReadUInt32(); $nameRva = $br.ReadUInt32()
        [void]$br.ReadBytes(52)
        $cvSize = $br.ReadUInt32(); $cvRva = $br.ReadUInt32()
        [void]$br.ReadBytes(8); [void]$br.ReadBytes(16)
        $resume = $fs.Position

        $fs.Position = $nameRva
        $nameLen = $br.ReadUInt32()
        $name = [Text.Encoding]::Unicode.GetString($br.ReadBytes($nameLen))
        if ((Split-Path $name -Leaf) -ieq $ModuleName -and $cvSize -gt 24)
        {
            $fs.Position = $cvRva
            if ([Text.Encoding]::ASCII.GetString($br.ReadBytes(4)) -eq 'RSDS')
            {
                $guid = New-Object Guid(, $br.ReadBytes(16))
                $age  = $br.ReadUInt32()
                $target = [pscustomobject]@{
                    Base = $base; Size = $size
                    Guid = $guid.ToString('N').ToUpper(); Age = $age
                }
            }
        }
        $fs.Position = $resume
    }
    if (-not $target) { throw "Module '$ModuleName' not present in the dump." }

    # --- Crashing thread: context + stack blob -----------------------------------------
    $fs.Position = $dirs[3].Rva
    $threadCount = $br.ReadUInt32(); $crashThread = $null
    for ($t = 0; $t -lt $threadCount; $t++)
    {
        $tid = $br.ReadUInt32()
        [void]$br.ReadUInt32(); [void]$br.ReadUInt32(); [void]$br.ReadUInt32(); [void]$br.ReadUInt64()
        $stackStart = $br.ReadUInt64(); $stackSize = $br.ReadUInt32(); $stackRva = $br.ReadUInt32()
        $ctxSize = $br.ReadUInt32(); $ctxRva = $br.ReadUInt32()
        if ($tid -eq $crashTid)
        {
            $crashThread = [pscustomobject]@{
                Start = $stackStart; Size = $stackSize; Rva = $stackRva
                CtxRva = $ctxRva; CtxSize = $ctxSize
            }
        }
    }

    $stackBlob = $null; $rsp = 0
    if ($crashThread)
    {
        $fs.Position = $crashThread.CtxRva
        $ctx = $br.ReadBytes($crashThread.CtxSize)
        if ($ctx.Length -ge 0x100) { $rsp = [BitConverter]::ToUInt64($ctx, 0x98) }   # CONTEXT_AMD64.Rsp
        $fs.Position = $crashThread.Rva
        $stackBlob = $br.ReadBytes($crashThread.Size)
    }
}
finally { $br.Dispose(); $fs.Dispose() }

# ---------------------------------------------------------------------------------------
# Hard PDB match check — read the image's own CodeView record
# ---------------------------------------------------------------------------------------

function Get-ImageCodeView([string]$Path)
{
    $f = [IO.File]::OpenRead($Path); $r = New-Object IO.BinaryReader($f)
    try
    {
        $f.Position = 0x3C; $peOff = $r.ReadUInt32(); $f.Position = $peOff
        [void]$r.ReadUInt32()
        [void]$r.ReadUInt16(); $nSec = $r.ReadUInt16()
        [void]$r.ReadUInt32(); [void]$r.ReadUInt32(); [void]$r.ReadUInt32()
        $optSize = $r.ReadUInt16(); [void]$r.ReadUInt16()
        $optStart = $f.Position
        $magic = $r.ReadUInt16()
        $f.Position = $optStart + $(if ($magic -eq 0x20b) { 112 } else { 96 }) + (6 * 8)
        $dbgRva = $r.ReadUInt32(); $dbgSize = $r.ReadUInt32()

        $f.Position = $optStart + $optSize
        $secs = @()
        for ($i = 0; $i -lt $nSec; $i++)
        {
            [void]$r.ReadBytes(8); [void]$r.ReadUInt32()
            $va = $r.ReadUInt32(); $rawSz = $r.ReadUInt32(); $ptr = $r.ReadUInt32()
            [void]$r.ReadBytes(16)
            $secs += [pscustomobject]@{ VA = $va; RawSz = $rawSz; Ptr = $ptr }
        }
        $off = 0
        foreach ($s in $secs) { if ($dbgRva -ge $s.VA -and $dbgRva -lt ($s.VA + $s.RawSz)) { $off = $s.Ptr + ($dbgRva - $s.VA) } }

        for ($i = 0; $i -lt [int]($dbgSize / 28); $i++)
        {
            $f.Position = $off + $i * 28
            [void]$r.ReadUInt32(); [void]$r.ReadUInt32(); [void]$r.ReadUInt16(); [void]$r.ReadUInt16()
            $type = $r.ReadUInt32(); $szData = $r.ReadUInt32(); [void]$r.ReadUInt32(); $ptrRaw = $r.ReadUInt32()
            if ($type -ne 2) { continue }
            $f.Position = $ptrRaw
            if ([Text.Encoding]::ASCII.GetString($r.ReadBytes(4)) -ne 'RSDS') { continue }
            $g = New-Object Guid(, $r.ReadBytes(16)); $a = $r.ReadUInt32()
            return [pscustomobject]@{ Guid = $g.ToString('N').ToUpper(); Age = $a }
        }
        return $null
    }
    finally { $r.Dispose(); $f.Dispose() }
}

$imageCv = Get-ImageCodeView $imagePath

Write-Host ''
Write-Host '=== Crash ===' -ForegroundColor Cyan
Write-Host ("  Dump              : {0}" -f $DumpPath)
Write-Host ("  ExceptionCode     : 0x{0:X8}{1}" -f $excCode, $(if ($excCode -eq 0xC0000005) { '  (ACCESS_VIOLATION)' } else { '' }))
Write-Host ("  ExceptionAddress  : 0x{0:X16}   (module RVA 0x{1:X})" -f $excAddr, ($excAddr - $target.Base))
if ($paramCount -ge 2)
{
    $access = switch ($excParams[0]) { 0 { 'READ' } 1 { 'WRITE' } 8 { 'EXECUTE/DEP' } default { $excParams[0] } }
    Write-Host ("  Access            : {0} of 0x{1:X16}" -f $access, $excParams[1])
    if ($excParams[1] -gt 0x10000)
    { Write-Host '  Shape             : non-null fault address -> dangling pointer / use-after-free, not a null deref' -ForegroundColor Yellow }
}
Write-Host ("  CrashingThreadId  : {0}" -f $crashTid)

Write-Host ''
Write-Host '=== Symbol match ===' -ForegroundColor Cyan
Write-Host ("  Dump wants  : {0} age {1}" -f $target.Guid, $target.Age)
Write-Host ("  Image has   : {0} age {1}" -f $imageCv.Guid, $imageCv.Age)

if ((-not $imageCv) -or $imageCv.Guid -ne $target.Guid -or $imageCv.Age -ne $target.Age)
{
    Write-Host '  VERDICT     : MISMATCH — refusing to symbolicate.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'A mismatched PDB resolves to plausible-looking WRONG symbols rather than failing.' -ForegroundColor Red
    Write-Host 'Fetch the CI artifact whose build produced this dump and retry.' -ForegroundColor Red
    exit 2
}
Write-Host '  VERDICT     : MATCH' -ForegroundColor Green

# ---------------------------------------------------------------------------------------
# Resolve via dbghelp
# ---------------------------------------------------------------------------------------

if (-not ('CkSym' -as [type]))
{
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class CkSym {
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)] public static extern IntPtr LoadLibrary(string p);
  [DllImport("dbghelp.dll", CharSet=CharSet.Ansi, SetLastError=true)] public static extern bool SymInitialize(IntPtr h, string path, bool invade);
  [DllImport("dbghelp.dll")] public static extern uint SymSetOptions(uint o);
  [DllImport("dbghelp.dll", CharSet=CharSet.Ansi, SetLastError=true)] public static extern ulong SymLoadModuleEx(IntPtr h, IntPtr f, string img, string mod, ulong b, uint sz, IntPtr d, uint fl);
  [DllImport("dbghelp.dll", SetLastError=true)] public static extern bool SymFromAddr(IntPtr h, ulong addr, out ulong disp, IntPtr info);
  [StructLayout(LayoutKind.Sequential)] public struct LINE64 { public uint SizeOfStruct; public IntPtr Key; public uint LineNumber; public IntPtr FileName; public ulong Address; }
  [DllImport("dbghelp.dll", SetLastError=true)] public static extern bool SymGetLineFromAddr64(IntPtr h, ulong addr, out uint disp, ref LINE64 line);
  [DllImport("dbghelp.dll", CharSet=CharSet.Ansi, SetLastError=true)] public static extern uint UnDecorateSymbolName(string name, StringBuilder outStr, uint maxLen, uint flags);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
  public struct MODINFO {
    public uint SizeOfStruct; public ulong BaseOfImage; public uint ImageSize; public uint TimeDateStamp;
    public uint CheckSum; public uint NumSyms; public int SymType;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)]  public string ModuleName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string ImageName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string LoadedImageName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string LoadedPdbName;
    public uint CVSig; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=780)] public string CVData;
    public uint PdbSig; public Guid PdbSig70; public uint PdbAge;
    public bool PdbUnmatched; public bool DbgUnmatched; public bool LineNumbers; public bool GlobalSymbols; public bool TypeInfo;
    public bool SourceIndexed; public bool Publics; public uint MachineType; public uint Reserved;
  }
  [DllImport("dbghelp.dll", CharSet=CharSet.Ansi, SetLastError=true)] public static extern bool SymGetModuleInfo64(IntPtr h, ulong addr, ref MODINFO m);
  static IntPtr Buf = Marshal.AllocHGlobal(8192);
  public static string Resolve(IntPtr h, ulong addr) {
    for (int i = 0; i < 8192; i++) Marshal.WriteByte(Buf, i, 0);
    Marshal.WriteInt32(Buf, 0, 88); Marshal.WriteInt32(Buf, 80, 6000);
    ulong disp; if (!SymFromAddr(h, addr, out disp, Buf)) return null;
    string raw = Marshal.PtrToStringAnsi(IntPtr.Add(Buf, 84));
    var sb = new StringBuilder(4096);
    string name = (UnDecorateSymbolName(raw, sb, 4096, 0x1000|0x0004|0x0010) > 0) ? sb.ToString() : raw;
    LINE64 l = new LINE64(); l.SizeOfStruct = (uint)Marshal.SizeOf(typeof(LINE64)); uint ld; string loc = "";
    if (SymGetLineFromAddr64(h, addr, out ld, ref l)) {
      string fn = Marshal.PtrToStringAnsi(l.FileName); int ix = fn.LastIndexOf('\\');
      loc = "  [" + (ix >= 0 ? fn.Substring(ix + 1) : fn) + ":" + l.LineNumber + "]";
    }
    return name + loc;
  }
}
'@
}

$sdkDbgHelp = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\dbghelp.dll'
if (Test-Path $sdkDbgHelp) { [void][CkSym]::LoadLibrary($sdkDbgHelp) }

$LOADBASE = [uint64]0x10000000
$h = [System.Diagnostics.Process]::GetCurrentProcess().Handle
[void][CkSym]::SymSetOptions([uint32](0x10 -bor 0x200 -bor 0x4000))   # LOAD_LINES | FAIL_CRITICAL_ERRORS | UNDNAME
if (-not [CkSym]::SymInitialize($h, $BuildDir, $false))
{ throw "SymInitialize failed (win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }
if ([CkSym]::SymLoadModuleEx($h, [IntPtr]::Zero, $imagePath, 'MOD', $LOADBASE, [uint32](Get-Item $imagePath).Length, [IntPtr]::Zero, 0) -eq 0)
{ throw "SymLoadModuleEx failed (win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }

# The GUID comparison above proves dump<->exe. It says NOTHING about the .pdb sitting next to that
# exe — a stale or mismatched pdb in the same folder would still be handed to dbghelp, which falls
# back to export symbols and resolves to confident nonsense: the exact failure this script exists to
# prevent. So ask dbghelp what it ACTUALLY loaded and refuse anything short of a matched PDB.
$mi = New-Object CkSym+MODINFO
$mi.SizeOfStruct = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type]'CkSym+MODINFO')
[void][CkSym]::SymGetModuleInfo64($h, $LOADBASE, [ref]$mi)

$SymPdb = 3
Write-Host ("  Loaded pdb  : {0}" -f $(if ([string]::IsNullOrEmpty($mi.LoadedPdbName)) { '<none>' } else { $mi.LoadedPdbName }))
if ($mi.SymType -ne $SymPdb -or $mi.PdbUnmatched)
{
    Write-Host ("  VERDICT     : PDB NOT LOADED (SymType={0}, PdbUnmatched={1}) — refusing." -f $mi.SymType, $mi.PdbUnmatched) -ForegroundColor Red
    Write-Host ''
    Write-Host 'The exe matches the dump, but dbghelp did not load a MATCHING pdb beside it.' -ForegroundColor Red
    Write-Host 'Without this check every frame below would silently resolve from export symbols.' -ForegroundColor Red
    exit 3
}

Write-Host ''
Write-Host '=== Crash site (exact) ===' -ForegroundColor Cyan
$siteRva = $excAddr - $target.Base
$site = [CkSym]::Resolve($h, ($LOADBASE + $siteRva))
Write-Host ("  {0}" -f $(if ($site) { $site } else { '<unresolved>' }))

if (-not $stackBlob) { Write-Host ''; Write-Host 'No stack memory captured for the crashing thread.' -ForegroundColor Yellow; exit 0 }

Write-Host ''
Write-Host '=== Stack candidates (conservative scan, ordered) ===' -ForegroundColor Cyan
$startOff = [int64]($rsp - $crashThread.Start)
if ($startOff -lt 0 -or $startOff -ge $stackBlob.Length) { $startOff = 0 }

$seen = @{}; $shown = 0
for ($o = [int]$startOff; $o -le $stackBlob.Length - 8; $o += 8)
{
    $v = [BitConverter]::ToUInt64($stackBlob, $o)
    if ($v -lt $target.Base -or $v -ge ($target.Base + $target.Size)) { continue }
    $rva = $v - $target.Base
    $key = '0x{0:X}' -f $rva
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $sym = [CkSym]::Resolve($h, ($LOADBASE + $rva))
    if (-not $sym) { continue }
    $shown++
    Write-Host ("{0,3}. {1}  ({2})" -f $shown, $sym, $key)
    if ($shown -ge $MaxFrames) { break }
}

Write-Host ''
Write-Host 'Scan over-reports (stale frames, spilled pointers). The crash site above is exact.' -ForegroundColor DarkGray
