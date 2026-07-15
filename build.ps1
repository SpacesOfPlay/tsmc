# build.ps1 — build and test tsmc on Windows.
#
# Requires the minc compiler. MINC: minc install dir (the folder
# holding minc.exe and its lib/); defaults to the local deploy at
# .\minc (gitignored — refresh by copying in a new deploy).

param(
    [Parameter(Position=0)]
    [ValidateSet("build", "test", "bench", "clean", "help")]
    [string]$Command = "help"
)

$ProjectDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$BuildDir = Join-Path $ProjectDir "build"
$OutExe = Join-Path $BuildDir "tsmc.exe"

$MincDir = if ($env:MINC) { $env:MINC } else { Join-Path $ProjectDir "minc" }

function Step($msg) { Write-Host ":: $msg" -ForegroundColor Cyan }
function Pass($msg) { Write-Host "  PASS  $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "  FAIL  $msg" -ForegroundColor Red }

function Assert-Toolchain {
    if (-not (Test-Path (Join-Path $MincDir "minc.exe"))) {
        Fail "minc.exe not found in $MincDir"
        Write-Host "  copy a minc deploy into minc\, or set MINC (see README.md)"
        exit 1
    }
    $script:MincDir = (Resolve-Path $MincDir).Path
    if (-not (Test-Path (Join-Path $MincDir "lib\str.mc"))) {
        Fail "no lib\ in $MincDir — bare imports (import str;) cannot resolve"
        Write-Host "  a minc install has lib\ beside the binary"
        exit 1
    }
    $env:Path = "$script:MincDir;$env:Path"
}

# Compile from the project folder; `minc` comes from PATH (install dir
# prepended above), which anchors stdlib resolution on <install>\lib.
function Invoke-Minc([string[]]$MincArgs) {
    Push-Location $ProjectDir
    try { & minc @MincArgs; return $LASTEXITCODE }
    finally { Pop-Location }
}

function Build-Tsmc {
    Step "build tsmc"
    Assert-Toolchain
    New-Item -ItemType Directory -Force $BuildDir | Out-Null
    $rc = Invoke-Minc @((Join-Path $ProjectDir "src\main.mc"), "-o", $OutExe)
    if ($rc -ne 0) { Fail "compile failed"; exit 1 }
    Pass $OutExe
}

function Run-Tests {
    Build-Tsmc
    $fail = 0
    $pass = 0

    # Unit tests: each test/unit/*.mc is a standalone program; exit 0 = pass.
    Step "unit tests"
    $unitBuild = Join-Path $BuildDir "unit"
    New-Item -ItemType Directory -Force $unitBuild | Out-Null
    $unitTests = @(Get-ChildItem (Join-Path $ProjectDir "test\unit\*.mc") -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $unitTests) {
        $exe = Join-Path $unitBuild ($f.BaseName + ".exe")
        $rc = Invoke-Minc @($f.FullName, "-o", $exe)
        if ($rc -ne 0) { Fail "$($f.BaseName) (compile)"; $fail++; continue }
        & $exe
        if ($LASTEXITCODE -ne 0) { Fail "$($f.BaseName) (exit $LASTEXITCODE)"; $fail++; continue }
        Pass $f.BaseName; $pass++
    }

    # CLI smoke: flag handling and exit codes.
    Step "cli smoke"
    $out = (& $OutExe --version) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $out -eq "tsmc 0.1.0-dev") { Pass "--version"; $pass++ }
    else { Fail "--version (got '$out', exit $LASTEXITCODE)"; $fail++ }

    & $OutExe > $null 2> $null
    if ($LASTEXITCODE -eq 2) { Pass "no args exits 2"; $pass++ }
    else { Fail "no args (exit $LASTEXITCODE)"; $fail++ }

    & $OutExe (Join-Path $BuildDir "no_such_file.ts") 2> $null
    if ($LASTEXITCODE -eq 2) { Pass "missing file exits 2"; $pass++ }
    else { Fail "missing file (exit $LASTEXITCODE)"; $fail++ }

    # Golden run tests: run test/run/<name>.ts, diff stdout against <name>.expected.
    Step "run tests"
    $runTests = @(Get-ChildItem (Join-Path $ProjectDir "test\run\*.ts") -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $runTests) {
        $expPath = [IO.Path]::ChangeExtension($f.FullName, ".expected")
        if (-not (Test-Path $expPath)) { Fail "$($f.BaseName) (no .expected)"; $fail++; continue }
        $actual = (& $OutExe $f.FullName 2> $null) -join "`n"
        if ($LASTEXITCODE -ne 0) { Fail "$($f.BaseName) (exit $LASTEXITCODE)"; $fail++; continue }
        $expected = (Get-Content $expPath) -join "`n"
        if ($actual -ne $expected) { Fail "$($f.BaseName) (diff)"; $fail++; continue }
        Pass $f.BaseName; $pass++
    }
    if ($runTests.Count -eq 0) { Write-Host "  (none yet)" }

    Write-Host ""
    if ($fail -eq 0) { Pass "all $pass tests passed"; exit 0 }
    else { Fail "$fail test(s) failed"; exit 1 }
}

function Run-Bench {
    Build-Tsmc
    Step "benchmarks"
    $benches = @(Get-ChildItem (Join-Path $ProjectDir "bench\*.ts") -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($benches.Count -eq 0) { Write-Host "  (none)"; return }
    foreach ($f in $benches) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $out = (& $OutExe $f.FullName 2>&1) -join " "
        $sw.Stop()
        $ms = "{0,7:N0}" -f $sw.Elapsed.TotalMilliseconds
        Write-Host ("  {0} ms  {1}  -> {2}" -f $ms, $f.BaseName.PadRight(12), $out)
    }
}

switch ($Command) {
    "build" { Build-Tsmc }
    "test"  { Run-Tests }
    "bench" { Run-Bench }
    "clean" {
        Step "clean"
        if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
        Pass "removed build/"
    }
    "help" {
        Write-Host "usage: ./build.ps1 <build|test|bench|clean>"
        Write-Host "  build   compile build/tsmc.exe"
        Write-Host "  test    build, then run unit + cli + golden run tests"
        Write-Host "  bench   build, then time bench/*.ts"
        Write-Host "  clean   remove build/"
    }
}
