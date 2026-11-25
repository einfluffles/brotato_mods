# Director commands and scripted scenarios for local play. Dot-sourced by tools\play-local.ps1
# (uses its Write-Note and $Utf8); not run on its own.
#
# A command is a JSON object written to <instance>\control\<id>.json; the game's director
# (mods/brotato-together/dev/einfluffles-TogetherLocal/director.gd) handles the files in name
# order, one at a time, and answers in <instance>\out\<id>.json: ok, error, result and the
# screen's state. Ids start with the time, so commands from separate calls keep their order.
#
# A scenario (Invoke-Scenario) runs on the instances of a fresh session. Its steps are GDScript,
# mods/brotato-together/dev/einfluffles-TogetherLocal/scenarios.gd, the same that
# tools/check-pair.sh runs headless: every game runs its part in step with the others. Every step
# ends with a screenshot of every game, <instance>\shots\<NN>-<step>.png; a step that fails, or a
# check that does not hold, ends the scenario with FAIL and a screenshot "<NN>-failed". The steps
# and their answers go to <run>\scenario.log.

$ScenariosFile = Join-Path $Root "mods\brotato-together\dev\einfluffles-TogetherLocal\scenarios.gd"
$ScenarioSec = 900  # the longest a scenario may take (language: two runs into the shop)
$DirectorSlackSec = 30  # an answer may come this long after the command's own timeout
$script:CommandSeq = 0

# The scenario names: scenarios.gd's NAMES.
function Get-ScenarioNames {
    $text = [IO.File]::ReadAllText($ScenariosFile)
    $list = [regex]::Match($text, '(?s)const NAMES := \[(.*?)\]')
    if (-not $list.Success) { throw "no const NAMES in $ScenariosFile" }
    return @([regex]::Matches($list.Groups[1].Value, '"([a-z_]+)"') | ForEach-Object { $_.Groups[1].Value })
}
$ScenarioNames = @(Get-ScenarioNames)

function Test-ScenarioName([string]$Name) { return $ScenarioNames -contains $Name }

# -Do's text: a JSON object, or key=value pairs ("cmd=wait_for scene=coop_resume timeout_sec=10";
# numbers and true / false are converted). Windows PowerShell drops the double quotes of an
# argument to another powershell.exe, so a JSON object only survives from cmd or within one session.
function ConvertFrom-DoText([string]$Text) {
    if ($Text.TrimStart().StartsWith("{")) {
        try { $parsed = $Text | ConvertFrom-Json } catch { $parsed = $null }
        if ($null -ne $parsed) { return $parsed }
    }
    $command = @{}
    foreach ($pair in @($Text -split '\s+' | Where-Object { $_ -ne "" })) {
        if ($pair -notmatch '^([A-Za-z_.]+)=(.*)$') { throw "-Do takes a JSON object or key=value pairs, not '$pair'" }
        $key = $Matches[1]
        $value = $Matches[2]  # the checks below overwrite $Matches
        if ($value -match '^-?\d+$') { $value = [int64]$value }
        elseif ($value -match '^-?\d+\.\d+$') { $value = [double]::Parse($value, [Globalization.CultureInfo]::InvariantCulture) }
        elseif ($value -eq "true") { $value = $true }
        elseif ($value -eq "false") { $value = $false }
        $command[$key] = $value
    }
    if (-not $command["cmd"]) { throw "-Do needs a cmd (cmd=query, or a JSON object with `"cmd`")" }
    return $command
}

function Get-CommandValue($Command, [string]$Key) {
    if ($Command -is [hashtable]) { return $Command[$Key] }
    return $Command.$Key
}

# Writes one command to an instance's control folder; returns its id.
function Send-Director([object]$Entry, $Command) {
    $script:CommandSeq++
    $name = "$(Get-CommandValue $Command 'cmd')" -replace '[^A-Za-z0-9_]', '_'
    $id = "{0}-{1:D4}-{2}" -f [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff"), $script:CommandSeq, $name
    $control = Join-Path $Entry.dir "control"
    New-Item -ItemType Directory -Force $control | Out-Null
    $path = Join-Path $control "$id.json"
    [IO.File]::WriteAllText("$path.tmp", ($Command | ConvertTo-Json -Depth 8 -Compress), $Utf8)
    Move-Item -Force "$path.tmp" $path
    return $id
}

# The answer to command $Id, or a failed one when the game has ended or the time is up.
function Wait-Director([object]$Entry, [string]$Id, [double]$TimeoutSec) {
    $path = Join-Path $Entry.dir "out\$Id.json"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $answer = $null
    while ($null -eq $answer) {
        if (Test-Path $path) {
            try { $answer = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $answer = $null }
            if ($null -ne $answer) { break }
        }
        $process = Get-Process -Id $Entry.pid -ErrorAction SilentlyContinue
        $gone = $null -eq $process -or $process.HasExited
        if ($gone -or (Get-Date) -gt $deadline) {
            $why = if ($gone) { "the game has ended" } else { "no answer after $TimeoutSec s" }
            $answer = [pscustomobject]@{ id = $Id; cmd = ""; ok = $false; error = $why; result = $null; state = $null }
            break
        }
        Start-Sleep -Milliseconds 100
    }
    $answer | Add-Member -NotePropertyName instance -NotePropertyValue $Entry.name -Force
    return $answer
}

# Sends $Command to every target at once, then waits for each answer (in the order of $Targets).
function Invoke-Director([object[]]$Targets, $Command) {
    $wait = Get-CommandValue $Command "timeout_sec"
    $timeout = $(if ($wait) { [double]$wait } else { 30.0 }) + $DirectorSlackSec
    $ids = @($Targets | ForEach-Object { Send-Director $_ $Command })
    $answers = @()
    for ($i = 0; $i -lt $Targets.Count; $i++) {
        $answers += Wait-Director $Targets[$i] $ids[$i] $timeout
    }
    return , $answers
}

# --- Scenarios ---

$script:ScenarioRun = $null

function Write-ScenarioLog([string]$Text) {
    Write-Note $Text
    $line = "$((Get-Date).ToString('HH:mm:ss.fff')) $Text`r`n"
    # Shared for reading and writing: a reader (tail -f) must not stop the scenario.
    for ($try = 0; $try -lt 5; $try++) {
        try {
            $stream = New-Object IO.FileStream($script:ScenarioRun.log, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            try { $bytes = $Utf8.GetBytes($line); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            break
        } catch { Start-Sleep -Milliseconds 50 }
    }
}

# The new lines of a game's Mod Loader log that the scenario runner wrote ("Scenario: ..."), from
# byte $From on: [lines, the next $From]. Best effort: the log may not be there yet.
function Read-ScenarioProgress([string]$Path, [int64]$From) {
    if (-not (Test-Path $Path)) { return @(@(), $From) }
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            if ($stream.Length -le $From) { return @(@(), $From) }
            [void]$stream.Seek($From, [IO.SeekOrigin]::Begin)
            $bytes = New-Object byte[] ($stream.Length - $From)
            $read = $stream.Read($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
    } catch { return @(@(), $From) }
    $text = $Utf8.GetString($bytes, 0, $read)
    $end = $text.LastIndexOf("`n")
    if ($end -lt 0) { return @(@(), $From) }
    $lines = @($text.Substring(0, $end) -split "`r?`n" | Where-Object { $_ -match 'Scenario: (step |PAIR-TESTS)' } |
        ForEach-Object { $_ -replace '^.*Scenario: ', '' })
    return @($lines, ($From + $Utf8.GetByteCount($text.Substring(0, $end + 1))))
}

# Runs scenario $Name on the session's instances; true when every game passed its part.
# Every game gets the director command "scenario" at once and runs the scenario's GDScript
# (scenarios.gd, in step with the others: scenario_runner.gd) with a screenshot of itself after
# every step. Meanwhile the first game's steps are shown; at the end every game's lines go to
# <run>\scenario.log.
function Invoke-Scenario([string]$Name, [object[]]$Instances, [string]$RunDir) {
    $script:ScenarioRun = @{ log = (Join-Path $RunDir "scenario.log") }
    if (Test-Path $script:ScenarioRun.log) { Remove-Item $script:ScenarioRun.log }
    Write-ScenarioLog "scenario $Name"
    $names = @($Instances | ForEach-Object { $_.name })
    $command = @{
        cmd = "scenario"; name = $Name; run = "$Name-$([DateTime]::UtcNow.ToString('HHmmssfff'))"
        peers = $names; shots = $true; timeout_sec = $ScenarioSec
    }
    $ids = @($Instances | ForEach-Object { Send-Director $_ $command })
    $progress = @{ path = $Instances[0].mod_loader_log; from = [int64]0 }
    if (Test-Path $progress.path) { $progress.from = (Get-Item $progress.path).Length }
    $answers = @{}
    $deadline = (Get-Date).AddSeconds($ScenarioSec + $DirectorSlackSec)
    while ($answers.Count -lt $Instances.Count) {
        $read = Read-ScenarioProgress $progress.path $progress.from
        $progress.from = $read[1]
        foreach ($line in $read[0]) { Write-Note "  $($Instances[0].name): $line" }
        for ($i = 0; $i -lt $Instances.Count; $i++) {
            if ($answers.ContainsKey($i)) { continue }
            $path = Join-Path $Instances[$i].dir "out\$($ids[$i]).json"
            $process = Get-Process -Id $Instances[$i].pid -ErrorAction SilentlyContinue
            $gone = $null -eq $process -or $process.HasExited
            if ((Test-Path $path) -or $gone -or (Get-Date) -gt $deadline) {
                $answers[$i] = Wait-Director $Instances[$i] $ids[$i] 1
            }
        }
        Start-Sleep -Milliseconds 500
    }
    $passed = $true
    $shots = @()
    for ($i = 0; $i -lt $Instances.Count; $i++) {
        $answer = $answers[$i]
        Write-ScenarioLog "$($answer.instance):"
        if ($null -ne $answer.result) {
            foreach ($line in @($answer.result.lines)) { Write-ScenarioLog "  $line" }
            foreach ($shot in @($answer.result.shots)) { $shots += "$($answer.instance): $shot" }
        }
        if (-not $answer.ok) {
            $passed = $false
            Write-ScenarioLog "$($answer.instance): FAILED: $($answer.error)"
        }
    }
    foreach ($entry in $Instances) {
        if (-not (Test-Path $entry.stderr)) { continue }
        $errors = @(Get-Content $entry.stderr | Where-Object { $_ -match '^SCRIPT ERROR|^ERROR' })
        if ($errors.Count -gt 0) { Write-ScenarioLog "$($entry.name): $($errors.Count) error lines in $($entry.stderr)" }
    }
    Write-ScenarioLog "screenshots:"
    foreach ($shot in $shots) { Write-ScenarioLog "  $shot" }
    Write-ScenarioLog "$(if ($passed) { 'PASS' } else { 'FAIL' }) $Name"
    return $passed
}
