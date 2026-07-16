# build.ps1 — build and test tsmc on Windows.
#
# Requires the minc compiler. MINC: minc install dir (the folder
# holding minc.exe and its lib/); defaults to the local deploy at
# .\minc (gitignored — refresh by copying in a new deploy).

param(
    [Parameter(Position=0)]
    [ValidateSet("build", "test", "bench", "diff", "t262", "clean", "help")]
    [string]$Command = "help",

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Rest = @()
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

# Differential test: run test/diff/*.js through tsmc and a reference
# node, comparing stdout. Skips cleanly if node is unavailable.
function Run-Diff {
    Build-Tsmc
    Step "differential (vs node)"
    $node = if ($env:NODE) { $env:NODE } else { (Get-Command node -ErrorAction SilentlyContinue).Source }
    if (-not $node) { Write-Host "  skipped - node not found (set NODE)"; return }
    $scripts = @(Get-ChildItem (Join-Path $ProjectDir "test\diff\*.js") -ErrorAction SilentlyContinue | Sort-Object Name)
    $fail = 0
    foreach ($f in $scripts) {
        $ref = (& $node $f.FullName 2>&1) -join "`n"
        $got = (& $OutExe $f.FullName 2>&1) -join "`n"
        if ($ref -eq $got) { Pass $f.BaseName }
        else { Fail "$($f.BaseName) (differs from node)"; $fail++ }
    }
    if ($scripts.Count -eq 0) { Write-Host "  (none)" }
    elseif ($fail -eq 0) { Pass "all match node" } else { Fail "$fail differ"; exit 1 }
}

switch ($Command) {
    "build" { Build-Tsmc }
    "test"  { Run-Tests }
    "bench" { Run-Bench }
    "diff"  { Run-Diff }
    "t262"  {
        Build-Tsmc
        # The runner is one portable bash script (dir-walk + process spawn).
        # On Windows use Git Bash — derived from git's own location so we
        # don't pick up the WSL 'bash' launcher in System32.
        $bash = $null
        $git = (Get-Command git -ErrorAction SilentlyContinue).Source
        if ($git) {
            $gitRoot = Split-Path (Split-Path $git)
            foreach ($c in @("bin\bash.exe", "usr\bin\bash.exe")) {
                $p = Join-Path $gitRoot $c
                if (Test-Path $p) { $bash = $p; break }
            }
        }
        if (-not $bash) { Fail "Git Bash not found (install Git for Windows) — needed for the test262 runner"; exit 1 }
        & $bash (Join-Path $ProjectDir "tools/test262.sh") @Rest
    }
    "clean" {
        Step "clean"
        if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
        Pass "removed build/"
    }
    "help" {
        Write-Host "usage: ./build.ps1 <build|test|bench|diff|t262|clean>"
        Write-Host "  build   compile build/tsmc.exe"
        Write-Host "  test    build, then run unit + cli + golden run tests"
        Write-Host "  bench   build, then time bench/*.ts"
        Write-Host "  diff    build, then diff test/diff/*.js vs node"
        Write-Host "  t262    build, then run test262 (fetched to vendor/ on first use)"
        Write-Host "  clean   remove build/"
    }
}
