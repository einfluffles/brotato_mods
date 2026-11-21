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
# Usage: tools\check-window.ps1 -Suites <suite>[,<suite>...] [-Mod mods\<folder>] [-Godot <exe>] [-All]
#   -All  print the ok lines too
param(
    [Parameter(Mandatory = $true)][string]$Suites,
    [string]$Mod = "mods\brotato-together",
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

if (-not (Test-Path (Join-Path $Root "reference\project.godot"))) {
    Write-Error "reference/ missing: decompile the game first (README)"
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

# The mod and its test mod, fresh for every run (a leftover folder without manifest stops the loader).
$mods = Join-Path $Game "mods-unpacked"
if (Test-Path $mods) { Remove-Item -Recurse -Force $mods }
New-Item -ItemType Directory -Force $mods | Out-Null
$dirs = @(Get-ChildItem -Directory (Join-Path $ModDir "src")) + @(Get-ChildItem -Directory (Join-Path $ModDir "tests"))
foreach ($dir in $dirs) {
    robocopy $dir.FullName (Join-Path $mods $dir.Name) /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Error "copying $($dir.Name) failed (robocopy $LASTEXITCODE)" }
}

$log = Join-Path $Cache "check-window.log"
$errLog = Join-Path $Cache "check-window.err.log"
$before = $env:MOD_TEST_SUITES
$env:MOD_TEST_SUITES = $Suites
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

$output = Get-Content $log
$pattern = if ($All) { '^  (ok  |FAIL|info:) |MOD-TESTS: (PASS|FAIL)' } else { '^  (FAIL|info:) |MOD-TESTS: (PASS|FAIL)' }
$output | Where-Object { $_ -match $pattern }
$ownErrors = @()
for ($i = 0; $i -lt $output.Count; $i++) {
    if ($output[$i] -match 'SCRIPT ERROR' -and ($output[($i + 1)..($i + 2)] -match 'mods-unpacked')) {
        $ownErrors += $output[$i..($i + 2)]
    }
}
if ($ownErrors.Count -gt 0) {
    Write-Host "Script errors in mod code:"
    $ownErrors
}
Write-Host "full log: $log"
if ($ownErrors.Count -gt 0 -or -not ($output -match 'MOD-TESTS: PASS')) { exit 1 }
exit 0
