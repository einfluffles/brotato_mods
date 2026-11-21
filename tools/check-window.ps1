# Runs test suites of a mod in a real game window on Windows: with the graphics driver and audio the
# container's headless Godot replaces by dummies. For costs that only exist there (GPU uploads and
# waits, shaders, particles, sounds). Times are this machine's: compare them with each other.
#
# The game runs from a copy of reference/ in %LOCALAPPDATA%\brotato-modtools, refreshed when
# reference/project.godot changes. The copy's project.godot gets its own user folder
# (%APPDATA%\BrotatoModTests): the game's own one holds the real saves and logs. Godot is the
# official build of GodotVersion (the closest to the game's own 3.7 build, as in tools/Containerfile),
# downloaded once, or -Godot <exe>.
#
# Usage: tools\check-window.ps1 [-Mod mods\<folder>] [-Suites <suite>[,<suite>...]]
#            [-With mods\<folder>[,...]] [-Godot <exe>] [-All]
#   -Suites  run these in one process; without it every line of the test mod's shards.txt runs in
#            its own process, one after the other, with its "+<mod folder>" mods
#   -With    with -Suites: also load these mods' src/
#   -All     print the ok lines too
param(
    [string]$Suites = "",
    [string]$Mod = "mods\brotato-together",
    [string[]]$With = @(),
    [string]$Godot = "",
    [string]$GodotVersion = "3.6.2",
    [int]$TimeoutSec = 600,
    [switch]$All
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Cache = Join-Path $env:LOCALAPPDATA "brotato-modtools"
$Game = Join-Path $Cache "reference"
$UserDir = "BrotatoModTests"
# Engine errors of every run that are not the mods': no Steam here, the logs deleted on purpose
# (Invoke-Run), the engine's own reports at exit.
$KnownErrors = @(
    "Can't open steam_data file",
    "Can't open workshop folder",
    'Steam singleton not available',
    'Steam transport unavailable',
    'CrashReporter: Failed to find engine logs',
    'Condition "_first != nullptr" is true',
    'Resources still in use at exit',
    'MemoryPool allocs in use at exit'
)

if (-not (Test-Path (Join-Path $Root "reference\project.godot"))) {
    Write-Error "reference/ missing: decompile the game first (docs/game-code.md)"
}
$ModDir = Resolve-Path (Join-Path $Root $Mod)
if (-not (Test-Path (Join-Path $ModDir "tests"))) {
    Write-Error "$Mod has no tests/"
}

if ($Godot -eq "") {
    $GodotDir = Join-Path $Cache "godot-$GodotVersion"
    $Godot = Join-Path $GodotDir "Godot_v$GodotVersion-stable_win64.exe"
    if (-not (Test-Path $Godot)) {
        Write-Host "downloading Godot $GodotVersion ..."
        New-Item -ItemType Directory -Force $GodotDir | Out-Null
        $zip = Join-Path $GodotDir "godot.zip"
        $url = "https://github.com/godotengine/godot/releases/download/$GodotVersion-stable/" `
            + "Godot_v$GodotVersion-stable_win64.exe.zip"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
        Expand-Archive -Force -Path $zip -DestinationPath $GodotDir
        Remove-Item $zip
    }
}

$source = Get-Item (Join-Path $Root "reference\project.godot")
$stamp = "$($source.LastWriteTimeUtc.Ticks) $($source.Length)"
$stampFile = Join-Path $Game ".source-stamp"
$current = if (Test-Path $stampFile) { (Get-Content $stampFile -Raw).Trim() } else { "" }
if ($current -ne $stamp) {
    Write-Host "copying reference/ to $Game (once per game version) ..."
    robocopy (Join-Path $Root "reference") $Game /MIR /XD (Join-Path $Root "reference\mods-unpacked") `
        /XF ".source-stamp" /NFL /NDL /NJH /NJS /NP /MT:16 | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Error "copying reference/ failed (robocopy $LASTEXITCODE)" }
    $project = Join-Path $Game "project.godot"
    $lines = Get-Content $project
    $patched = @()
    foreach ($line in $lines) {
        if ($line -match '^config/custom_user_dir_name=') { continue }
        $patched += $line
        if ($line -eq 'config/use_custom_user_dir=true') {
            $patched += "config/custom_user_dir_name=`"$UserDir`""
        }
    }
    if (-not ($patched -contains "config/custom_user_dir_name=`"$UserDir`"")) {
        Write-Error "project.godot has no config/use_custom_user_dir=true: the own user folder is not set"
    }
    [IO.File]::WriteAllLines($project, $patched)
    Set-Content -Path $stampFile -Value $stamp -Encoding ascii
}


# One game process: the mod, its test mod and the -With mods, fresh in mods-unpacked/ (a leftover
# folder without manifest stops the loader). The test copy's logs go first: the game reads the
# last one at boot and turns all mods off when an error in it names mods-unpacked.
function Invoke-Run([string]$RunSuites, [string[]]$Others) {
    $logs = Join-Path $env:APPDATA "$UserDir\logs"
    if (Test-Path $logs) { Remove-Item -Recurse -Force $logs }
    $mods = Join-Path $Game "mods-unpacked"
    if (Test-Path $mods) { Remove-Item -Recurse -Force $mods }
    New-Item -ItemType Directory -Force $mods | Out-Null
    $dirs = @(Get-ChildItem -Directory (Join-Path $ModDir "src")) `
        + @(Get-ChildItem -Directory (Join-Path $ModDir "tests"))
    foreach ($other in $Others) {
        $dirs += @(Get-ChildItem -Directory (Join-Path (Resolve-Path (Join-Path $Root $other)) "src"))
    }
    foreach ($dir in $dirs) {
        robocopy $dir.FullName (Join-Path $mods $dir.Name) /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { Write-Error "copying $($dir.Name) failed (robocopy $LASTEXITCODE)" }
    }

    $log = Join-Path $Cache "check-window.log"
    $errLog = Join-Path $Cache "check-window.err.log"
    $before = $env:MOD_TEST_SUITES
    $env:MOD_TEST_SUITES = $RunSuites
    try {
        $process = Start-Process -FilePath $Godot -ArgumentList @("--path", "`"$Game`"") -PassThru `
            -RedirectStandardOutput $log -RedirectStandardError $errLog
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            $process | Stop-Process -Force
            Write-Host "timed out after $TimeoutSec s"
        }
    } finally {
        $env:MOD_TEST_SUITES = $before
    }

    $output = @(Get-Content $log)
    $pattern = if ($All) { '^  (ok  |FAIL|info:) |MOD-TESTS: (PASS|FAIL)' } else { '^  (FAIL|info:) |MOD-TESTS: (PASS|FAIL)' }
    $output | Where-Object { $_ -match $pattern } | Write-Host
    $start = [Array]::FindIndex([string[]]$output, [Predicate[string]] { param($l) $l -match 'MOD-TESTS: START' })
    # Godot prints errors to stderr: every SCRIPT ERROR but the missing Steam's, and every engine
    # ERROR not in $KnownErrors (one like the Mod Loader's failing script backup of issue #91
    # names no mod, so all of them count).
    $stderr = @(Get-Content $errLog)
    $errors = @()
    for ($i = 0; $i -lt $stderr.Count; $i++) {
        $line = $stderr[$i]
        if ($line -match '^SCRIPT ERROR') {
            $at = ($stderr[($i + 1)..($i + 2)] -join " ")
            if ($line -match "in base 'Nil'|set_locale" -or $at -match 'SteamPlatform') { continue }
        } elseif ($line -match '^ERROR: ') {
            if ($KnownErrors | Where-Object { $line -match $_ }) { continue }
        } else {
            continue
        }
        $errors += $stderr[$i..($i + 1)]
    }
    if ($errors.Count -gt 0) {
        Write-Host "Errors:"
        $errors | Write-Host
    }
    if ($start -lt 0) { Write-Host "no test output: the mods did not load (see the log)" }
    Write-Host "full log: $log"
    return ($errors.Count -eq 0 -and ($output -match 'MOD-TESTS: PASS'))
}

$runs = @()  # [suites, other mods]
if ($Suites -ne "") {
    $runs += , @($Suites, ($With -join ",").Split(",", [StringSplitOptions]::RemoveEmptyEntries))
} else {
    # Every line of the test mod's shards.txt, one process each, as tools/check.sh runs them.
    foreach ($shards in (Get-ChildItem (Join-Path $ModDir "tests") -Recurse -Filter shards.txt)) {
        foreach ($line in (Get-Content $shards.FullName)) {
            $line = ($line -replace '\s', '')
            if ($line -eq "" -or $line.StartsWith("#")) { continue }
            $parts = $line.Split("+")
            $others = @($parts | Select-Object -Skip 1 | ForEach-Object { "mods\$_" })
            $runs += , @($parts[0], $others)
        }
    }
}
$failed = @()
foreach ($run in $runs) {
    $label = $run[0] + $(if ($run[1].Count -gt 0) { " (with " + ($run[1] -join ", ") + ")" } else { "" })
    Write-Host "== $label"
    if (-not (Invoke-Run $run[0] $run[1])) { $failed += $label }
}
if ($failed.Count -gt 0) {
    Write-Host "FAILED: $($failed -join '; ')"
    exit 1
}
Write-Host "passed ($($runs.Count) run$(if ($runs.Count -ne 1) { 's' }))"
exit 0
