# console_check.ps1: tsmc at a Windows console, which no other test has.
# Run from the repository's root; it opens a console window of its own
# for a few seconds:
#
#   pwsh -NoProfile -File test/console/console_check.ps1
#
# In that console it puts key events in the input (a, the up arrow, a
# with ring, an emoji, Ctrl with the left arrow, Enter, q), runs
# test/console/keys.js, and then compares the bytes the script took,
# what the screen shows of its line (display attributes taken, UTF-8
# written whole) and the console's modes and code page before and
# after (put back as they were). PASSED or FAILED, with what differed.
param([switch]$Inner, [string]$Result = '')
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if (-not $Inner) {
    $res = Join-Path $root 'build\console_check.json'
    if (Test-Path $res) { Remove-Item $res }
    $p = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $PSCommandPath, '-Inner', '-Result', $res -PassThru
    if (-not $p.WaitForExit(30000)) { $p.Kill($true); "FAILED: the console did not finish in 30 s"; exit 1 }
    if (-not (Test-Path $res)) { "FAILED: no result"; exit 1 }
    $r = Get-Content -Raw $res | ConvertFrom-Json
    $want = @(97, 27, 91, 65, 0xC3, 0xA5, 0xF0, 0x9F, 0x98, 0x80, 27, 91, 49, 59, 53, 68, 13, 113)
    $bad = @()
    if ($null -eq $r.keys) { $bad += "keys.js wrote nothing: $($r.note)" }
    else {
        if (($r.keys.bytes -join ',') -ne ($want -join ',')) { $bad += "bytes: $($r.keys.bytes -join ',') (want $($want -join ','))" }
        if (-not $r.keys.tty.stdin -or -not $r.keys.tty.stdout) { $bad += "not a terminal: $($r.keys.tty | ConvertTo-Json -Compress)" }
        if (-not ($r.keys.columns -gt 0 -and $r.keys.rows -gt 0)) { $bad += "no size: $($r.keys.columns) by $($r.keys.rows)" }
        if ($r.keys.raw) { $bad += "still raw" }
    }
    if ($r.screen -notmatch 'BOLD cyan • åäö done') { $bad += "the screen: '$($r.screen.Trim())'" }
    if ($r.before -ne $r.after) { $bad += "the console was not put back: before $($r.before), after $($r.after)" }
    if ($bad.Count -eq 0) { "PASSED: the keys' bytes, a terminal of $($r.keys.columns) by $($r.keys.rows), the line drawn, the console put back ($($r.after))"; exit 0 }
    "FAILED"; $bad | ForEach-Object { "  $_" }; exit 1
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Con {
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    public struct Rec {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(4)] public int Down;
        [FieldOffset(8)] public ushort Repeat;
        [FieldOffset(10)] public ushort Vk;
        [FieldOffset(12)] public ushort Scan;
        [FieldOffset(14)] public char Ch;
        [FieldOffset(16)] public uint State;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Coord { public short X; public short Y; }
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll")] public static extern uint GetConsoleOutputCP();
    [DllImport("kernel32.dll")] public static extern bool FlushConsoleInputBuffer(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool WriteConsoleInputW(IntPtr h, Rec[] recs, uint n, out uint written);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool ReadConsoleOutputCharacterW(IntPtr h, StringBuilder buf, uint n, Coord at, out uint read);
    public static Rec Key(ushort vk, char ch, uint state, bool down) {
        Rec r = new Rec(); r.Type = 1; r.Down = down ? 1 : 0; r.Repeat = 1; r.Vk = vk; r.Ch = ch; r.State = state; return r;
    }
    public static string Modes() {
        uint i, o; GetConsoleMode(GetStdHandle(-10), out i); GetConsoleMode(GetStdHandle(-11), out o);
        return "in 0x" + i.ToString("x") + ", out 0x" + o.ToString("x") + ", code page " + GetConsoleOutputCP();
    }
    public static string Screen(int rows, int width) {
        StringBuilder all = new StringBuilder();
        for (short y = 0; y < rows; y++) {
            StringBuilder sb = new StringBuilder(width); uint got; Coord c = new Coord(); c.X = 0; c.Y = y;
            ReadConsoleOutputCharacterW(GetStdHandle(-11), sb, (uint)width, c, out got);
            all.Append(sb.ToString(0, (int)got).TrimEnd()).Append("\n");
        }
        return all.ToString();
    }
}
'@

$before = [Con]::Modes()
$recs = @(
    [Con]::Key(0x41, 'a', 0, $true), [Con]::Key(0x41, 'a', 0, $false),
    [Con]::Key(0x26, [char]0, 0, $true), [Con]::Key(0x26, [char]0, 0, $false),
    [Con]::Key(0xDD, [char]0xE5, 0, $true),
    [Con]::Key(0, [char]0xD83D, 0, $true), [Con]::Key(0, [char]0xDE00, 0, $true),
    [Con]::Key(0x11, [char]0, 0x8, $true), [Con]::Key(0x25, [char]0, 0x8, $true), [Con]::Key(0x25, [char]0, 0x8, $false),
    [Con]::Key(0x0D, [char]13, 0, $true),
    [Con]::Key(0x51, 'q', 0, $true)
)
$w = 0
# what was typed into the window as it opened is not the check's
[void][Con]::FlushConsoleInputBuffer([Con]::GetStdHandle(-10))
[void][Con]::WriteConsoleInputW([Con]::GetStdHandle(-10), [Con+Rec[]]$recs, [uint32]$recs.Count, [ref]$w)
$keysOut = Join-Path $root 'build\console_keys.json'
if (Test-Path $keysOut) { Remove-Item $keysOut }
Clear-Host
& (Join-Path $root 'build\tsmc.exe') (Join-Path $root 'test\console\keys.js') $keysOut
$after = [Con]::Modes()
$screen = [Con]::Screen(10, [Console]::BufferWidth)
$keys = if (Test-Path $keysOut) { Get-Content -Raw $keysOut | ConvertFrom-Json } else { $null }
@{ before = $before; after = $after; screen = $screen; keys = $keys; note = "wrote $w of $($recs.Count) events" } | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $Result
