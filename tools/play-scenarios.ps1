# Director commands and scripted scenarios for local play. Dot-sourced by tools\play-local.ps1
# (uses its Write-Note and $Utf8); not run on its own.
#
# A command is a JSON object written to <instance>\control\<id>.json; the game's director
# (mods/brotato-together/dev/einfluffles-TogetherLocal/director.gd) handles the files in name
# order, one at a time, and answers in <instance>\out\<id>.json: ok, error, result and the
# screen's state. Ids start with the time, so commands from separate calls keep their order.
#
# A scenario (Invoke-Scenario) runs steps on the instances of a fresh session. Every step ends
# with a screenshot of every game, <instance>\shots\<NN>-<step>.png; a step that fails, or a check
# that does not hold, ends the scenario with FAIL and a screenshot "<NN>-failed". The steps and
# their answers go to <run>\scenario.log.

$ScenarioNames = @("resume_leave_rejoin", "join_wave_shop", "language")
$DirectorSlackSec = 30  # an answer may come this long after the command's own timeout
$script:CommandSeq = 0

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

# --- Scenario steps ---

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

function Format-Command([hashtable]$Command) {
    $parts = @($Command["cmd"])
    foreach ($key in ($Command.Keys | Where-Object { $_ -ne "cmd" } | Sort-Object)) { $parts += "$key=$($Command[$key])" }
    return $parts -join " "
}

# Runs $Command on the named instances ("host", "client1", "all"); throws when one fails.
# Returns the answers (an array, in the order of the names).
function Invoke-On([string[]]$Names, [hashtable]$Command, [switch]$MayFail) {
    if ($Names -contains "all") { $Names = $script:ScenarioRun.names }
    $targets = @($Names | ForEach-Object { $script:ScenarioRun.instances[$_] })
    $answers = Invoke-Director $targets $Command
    foreach ($answer in $answers) {
        $text = if ($answer.ok) { "ok" } else { "FAILED: $($answer.error)" }
        Write-ScenarioLog "  $($answer.instance): $(Format-Command $Command): $text ($($answer.msec) ms)"
        if (-not $answer.ok -and -not $MayFail) {
            throw "$($answer.instance): $($Command['cmd']) failed: $($answer.error)"
        }
    }
    return , $answers
}

# The screen state of one instance (the director's query).
function Get-State([string]$Name) {
    return (Invoke-On $Name @{ cmd = "query" })[0].state
}

function Assert-Check([bool]$Condition, [string]$What) {
    Write-ScenarioLog "  check: ${What}: $(if ($Condition) { 'yes' } else { 'NO' })"
    if (-not $Condition) { throw "check failed: $What" }
}

# One step: its body, then a screenshot of every game named <NN>-<label>.
function Invoke-Step([string]$Label, [scriptblock]$Body) {
    $script:ScenarioRun.step++
    $tag = "{0:D2}-{1}" -f $script:ScenarioRun.step, $Label
    $script:ScenarioRun.current = $tag
    Write-ScenarioLog "step $tag"
    & $Body
    Save-Shots $tag
}

function Save-Shots([string]$Tag) {
    $answers = Invoke-On "all" @{ cmd = "screenshot"; name = $Tag } -MayFail
    foreach ($answer in $answers) {
        if ($answer.ok) { $script:ScenarioRun.shots += "$($answer.instance): $($answer.result.path)" }
    }
}

function Wait-Seconds([double]$Seconds) { Start-Sleep -Milliseconds ([int]($Seconds * 1000)) }

# --- Shared parts of the scenarios ---

# Holds accept in $Name's game to join a slot, with a screenshot of every game while it is held
# (<NN>-<step>-holding: the join's progress, before the join takes the slot after about 0.7 s).
function Invoke-JoinHold([string]$Name) {
    $tag = "$($script:ScenarioRun.current)-holding"
    $entry = $script:ScenarioRun.instances[$Name]
    $command = @{ cmd = "press"; key = "Enter"; hold_ms = 1500; shot = $tag; shot_ms = 400 }
    $id = Send-Director $entry $command
    Wait-Seconds 0.45
    foreach ($other in @($script:ScenarioRun.names | Where-Object { $_ -ne $Name })) {
        $answers = Invoke-On $other @{ cmd = "screenshot"; name = $tag } -MayFail
        if ($answers[0].ok) { $script:ScenarioRun.shots += "$other`: $($answers[0].result.path)" }
    }
    $answer = Wait-Director $entry $id 60
    $text = if ($answer.ok) { "ok" } else { "FAILED: $($answer.error)" }
    Write-ScenarioLog "  $Name`: $(Format-Command $command): $text ($($answer.msec) ms)"
    if (-not $answer.ok) { throw "$Name`: press failed: $($answer.error)" }
    $script:ScenarioRun.shots += "$Name`: $($answer.result.path)"
}

# Both games in the host's lobby at the title screen; the host's runs are short and nobody dies
# (the game's DebugService: the director's debug command).
function Invoke-LobbyStep([int]$WaveSec) {
    Invoke-Step "lobby" {
        Invoke-On host @{ cmd = "debug"; invulnerable = $true; wave_sec = $WaveSec } | Out-Null
        Invoke-On host @{ cmd = "wait_for"; scene = "title_screen"; "lobby.members" = 2 } | Out-Null
        Invoke-On client1 @{ cmd = "wait_for"; scene = "title_screen"; "lobby.in" = $true } | Out-Null
    }
}

# Start on the host, then both players hold accept to join: the host's player first.
# Players who are still in from a run before do not hold again. $Suffix ends the step names.
function Invoke-CharacterJoinStep([string]$Suffix = "") {
    Invoke-Step "character_selection$Suffix" {
        Invoke-On host @{ cmd = "button"; name = "StartButton" } | Out-Null
        Invoke-On host, client1 @{ cmd = "wait_for"; scene = "character_selection" } | Out-Null
        Wait-Seconds 1
        if ((Get-State host).players -lt 1) {
            Invoke-On host @{ cmd = "press"; key = "Enter"; hold_ms = 1500 } | Out-Null
        }
        Invoke-On host @{ cmd = "wait_for"; players = 1; timeout_sec = 10 } | Out-Null
        if ((Get-State host).players -lt 2) {
            Invoke-On client1 @{ cmd = "press"; key = "Enter"; hold_ms = 1500 } | Out-Null
        }
        Invoke-On host @{ cmd = "wait_for"; players = 2; timeout_sec = 10 } | Out-Null
        Wait-Seconds 1
    }
}

# Accept on both games, screen by screen (character, weapon, difficulty), until the host's
# scene is $Target. Each new screen is a step of its own.
function Invoke-SelectUntil([string]$Target, [string]$Suffix = "", [int]$MaxPresses = 12) {
    $seen = "character_selection"
    for ($i = 0; $i -lt $MaxPresses; $i++) {
        $scene = (Get-State host).scene
        if ($scene -eq $Target) { break }
        if ($scene -ne $seen) {
            Invoke-Step "$scene$Suffix" { Invoke-On client1 @{ cmd = "wait_for"; scene = $scene } | Out-Null }
            $seen = $scene
        }
        Invoke-On host, client1 @{ cmd = "press"; key = "Enter" } | Out-Null
        Wait-Seconds 1.5
    }
    Invoke-On host, client1 @{ cmd = "wait_for"; scene = $Target } | Out-Null
}

# From the start of the wave to the shop: XP and gold for every player (a level-up at the end
# of the wave, gold to buy with), the level-up panels chosen with accept on both games.
function Invoke-WaveToShop([int]$WaveSec, [string]$Suffix = "") {
    Invoke-Step "wave$Suffix" {
        Invoke-On host @{ cmd = "debug"; xp = 20; gold = 100 } | Out-Null
        Wait-Seconds 4
    }
    $levelUp = $false
    $deadline = (Get-Date).AddSeconds($WaveSec + 60)
    while ((Get-Date) -lt $deadline) {
        $state = Get-State host
        if ($state.scene -eq "coop_shop") { break }
        if ($state.scene -eq "main" -and $state.upgrades) {
            if (-not $levelUp) {
                $levelUp = $true
                Invoke-Step "level_up$Suffix" { Wait-Seconds 1 }
            }
            Invoke-On host, client1 @{ cmd = "press"; key = "Enter" } | Out-Null
        }
        Wait-Seconds 1
    }
    Assert-Check $levelUp "the wave ended with level-up panels"
    Invoke-Step "shop$Suffix" {
        Invoke-On host, client1 @{ cmd = "wait_for"; scene = "coop_shop" } | Out-Null
        Wait-Seconds 2
    }
}

# The host quits the run to the title screen (Pause, Quit, Confirm); the client follows.
function Invoke-HostQuit {
    Invoke-On host @{ cmd = "press"; key = "Escape" } | Out-Null
    Invoke-On host @{ cmd = "button"; name = "QuitButton" } | Out-Null
    Invoke-On host @{ cmd = "button"; name = "ConfirmButton" } | Out-Null
    Invoke-On host, client1 @{ cmd = "wait_for"; scene = "title_screen" } | Out-Null
}

# --- Scenarios ---

function Invoke-ScenarioJoinWaveShop {
    $waveSec = 12
    Invoke-LobbyStep $waveSec
    Invoke-CharacterJoinStep
    Invoke-SelectUntil "main"
    Invoke-WaveToShop $waveSec
    Invoke-Step "client_buys" {
        $before = (Get-State host).run
        Invoke-On client1 @{ cmd = "press"; key = "Enter" } | Out-Null
        Wait-Seconds 2
        $after = (Get-State host).run
        $bought = ($after.gold[1] -lt $before.gold[1]) -and
            (($after.items[1] + $after.weapons[1]) -gt ($before.items[1] + $before.weapons[1]))
        Assert-Check $bought ("the client's player bought something on the host (gold {0} -> {1}, items {2}+{3} -> {4}+{5})" -f `
            $before.gold[1], $after.gold[1], $before.items[1], $before.weapons[1], $after.items[1], $after.weapons[1])
    }
}

function Invoke-ScenarioResumeLeaveRejoin {
    $waveSec = 10
    Invoke-LobbyStep $waveSec
    Invoke-CharacterJoinStep
    Invoke-SelectUntil "main"
    Invoke-WaveToShop $waveSec
    Invoke-Step "host_quits_to_title" {
        Invoke-HostQuit
        $state = Get-State host
        Assert-Check ($state.run.saved -and $state.lobby.members -eq 2) `
            "the host has a saved run and both are still in the lobby ($($state.run.saved), $($state.lobby.members))"
    }
    Invoke-Step "host_continues" {
        Invoke-On host @{ cmd = "button"; name = "ContinueButton" } | Out-Null
        Invoke-On host, client1 @{ cmd = "wait_for"; scene = "coop_resume" } | Out-Null
        Wait-Seconds 1.5
        $hostState = Get-State host
        $clientState = Get-State client1
        Assert-Check ($hostState.run.count -eq 2 -and $hostState.resume_shown -eq 0 -and $hostState.players -eq 0) `
            "the host's resume screen shows saved player 1 of 2, nobody in ($($hostState.resume_shown), $($hostState.players))"
        Assert-Check ($clientState.resume_shown -eq 0 -and $clientState.resume_gold -eq $hostState.resume_gold) `
            "the client's copy shows the same saved player and gold ($($clientState.resume_shown), $($clientState.resume_gold))"
    }
    Invoke-Step "client_takes_saved_player_1" {
        Invoke-JoinHold client1
        Invoke-On host @{ cmd = "wait_for"; players = 1; resume_shown = 1; timeout_sec = 10 } | Out-Null
        Invoke-On client1 @{ cmd = "wait_for"; resume_shown = 1; timeout_sec = 10 } | Out-Null
    }
    Invoke-Step "client_leaves" {
        Invoke-On client1 @{ cmd = "leave" } | Out-Null
        Invoke-On host @{ cmd = "wait_for"; "lobby.members" = 1; players = 0; resume_shown = 0; timeout_sec = 10 } | Out-Null
        Wait-Seconds 3
        $state = Get-State host
        Assert-Check ($state.scene -eq "coop_resume" -and $state.resume_shown -eq 0 -and $state.players -eq 0) `
            "the host gives saved player 1 back and stays on the resume screen ($($state.scene), $($state.resume_shown))"
    }
    Invoke-Step "client_rejoins" {
        Invoke-On client1 @{ cmd = "join" } | Out-Null
        Invoke-On client1 @{ cmd = "wait_for"; scene = "coop_resume"; resume_shown = 0 } | Out-Null
        Invoke-On host @{ cmd = "wait_for"; "lobby.members" = 2 } | Out-Null
        Wait-Seconds 1
    }
    Invoke-Step "client_takes_saved_player_1_again" {
        Invoke-JoinHold client1
        Invoke-On host @{ cmd = "wait_for"; players = 1; resume_shown = 1; timeout_sec = 10 } | Out-Null
        Invoke-On client1 @{ cmd = "wait_for"; resume_shown = 1; timeout_sec = 10 } | Out-Null
    }
    Invoke-Step "host_takes_saved_player_2" {
        Invoke-JoinHold host
        Invoke-On host, client1 @{ cmd = "wait_for"; scene = "coop_shop" } | Out-Null
        Wait-Seconds 2
        $state = Get-State host
        Assert-Check ($state.players -eq 2 -and $state.run.count -eq 2) `
            "the shop loads with both players ($($state.players) connected, $($state.run.count) in the run)"
    }
}

function Invoke-ScenarioLanguage {
    $waveSec = 12
    Invoke-LobbyStep $waveSec
    foreach ($locale in @("de", "ru")) {
        Invoke-Step "lobby-$locale" {
            Invoke-On all @{ cmd = "language"; locale = $locale } | Out-Null
            Wait-Seconds 1
        }
        Invoke-CharacterJoinStep "-$locale"
        Invoke-SelectUntil "main" "-$locale"
        Invoke-WaveToShop $waveSec "-$locale"  # the damage meter in the wave, its board in the shop
        Invoke-Step "title-$locale" { Invoke-HostQuit }
    }
}

# Runs scenario $Name on the session's instances; true when every step passed.
function Invoke-Scenario([string]$Name, [object[]]$Instances, [string]$RunDir) {
    $byName = @{}
    foreach ($entry in $Instances) { $byName[$entry.name] = $entry }
    $script:ScenarioRun = @{
        name = $Name; instances = $byName; names = @($Instances | ForEach-Object { $_.name })
        log = (Join-Path $RunDir "scenario.log"); step = 0; current = ""; shots = @()
    }
    if (Test-Path $script:ScenarioRun.log) { Remove-Item $script:ScenarioRun.log }
    Write-ScenarioLog "scenario $Name"
    $passed = $false
    try {
        switch ($Name) {
            "resume_leave_rejoin" { Invoke-ScenarioResumeLeaveRejoin }
            "join_wave_shop" { Invoke-ScenarioJoinWaveShop }
            "language" { Invoke-ScenarioLanguage }
        }
        $passed = $true
    } catch {
        Write-ScenarioLog "FAILED in step $($script:ScenarioRun.current): $($_.Exception.Message)"
        $script:ScenarioRun.step++
        Save-Shots ("{0:D2}-failed" -f $script:ScenarioRun.step)
    }
    foreach ($entry in $Instances) {
        if (-not (Test-Path $entry.stderr)) { continue }
        $errors = @(Get-Content $entry.stderr | Where-Object { $_ -match '^SCRIPT ERROR|^ERROR' })
        if ($errors.Count -gt 0) { Write-ScenarioLog "$($entry.name): $($errors.Count) error lines in $($entry.stderr)" }
    }
    Write-ScenarioLog "screenshots:"
    foreach ($shot in $script:ScenarioRun.shots) { Write-ScenarioLog "  $shot" }
    Write-ScenarioLog "$(if ($passed) { 'PASS' } else { 'FAIL' }) $Name ($($script:ScenarioRun.step) steps)"
    return $passed
}
