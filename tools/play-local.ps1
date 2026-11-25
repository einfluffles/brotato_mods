# Local play: a host and one to three clients of brotato:together as game windows on this PC,
# connected without Steam (docs/testing.md, "Play locally"). The dev mod
# mods/brotato-together/dev/einfluffles-TogetherLocal puts a Steam stand-in under the mod's
# unchanged transport and links the games over TCP on 127.0.0.1.
#
# Everything lives in %LOCALAPPDATA%\brotato-modtools\play:
#   game\         a copy of reference/ (decompiled game) without the feature "steam" (so the game
#                 runs as its local build: no Steam start, no Steam init), refreshed when
#                 reference/project.godot changes; mods-unpacked\ is filled fresh on every start
#                 from this worktree (brotato:together, the dev mod, -With mods)
#   engine\       BrotatoLocal.exe and steam_api64.dll, copied from the installed game (the game's
#                 own engine build; its install is only read), refreshed when Brotato.exe changes
#   <run>\<inst>\ per instance (host, client1, ...): appdata\ (the instance's APPDATA, so its
#                 user folder appdata\Brotato is its own), stdout.log, stderr.log, instance.json
#                 (what was started), status.json (the dev mod, every second), control\, shots\
#   session.json  the processes of the running session (for -Stop and the next start)
# The real saves in %APPDATA%\Brotato are never touched: each game gets its own APPDATA, and the
# launcher refuses to start if an instance's user folder would be that one.
#
# Usage: tools\play-local.ps1 [-Clients 1..3] [-Engine game|godot] [-NoJoin] [-Mute client|all|none]
#            [-With mods\<folder>[,...] | -With none] [-GameDir <Brotato install>] [-Run <name>]
#            [-Fresh] [-Profile lan|relay-good|relay-typical|bad|stall|none]
#        tools\play-local.ps1 -Screenshot <name> [-On <instance>]
#                                   each running game saves its window to <inst>\shots\<name>.png
#        tools\play-local.ps1 -Key <Godot key name> [-HoldMs <msec>] [-On <instance>]
#                                   a key press in that game (Enter, Escape, Right, A, ...); a
#                                   co-op slot is joined by holding Enter: -Key Enter -HoldMs 1000
#        tools\play-local.ps1 -Profile <name> -On <instance>|all
#                                   switches the link profile of what that game sends (each game's
#                                   profile is one direction); waits until its status shows it
#        tools\play-local.ps1 -FailSession [-Reason <Steam end reason>] [-On <instance>]
#                                   that game's sessions fail on both ends (default reason 5003)
#        tools\play-local.ps1 -FailSend [-Count <n>] [-On <instance>]
#                                   its next reliable send(s) fail: on the host, a full resync
#        tools\play-local.ps1 -Stall <msec> [-On <instance>]
#                                   nothing that game sends moves for that long
#        tools\play-local.ps1 -Stop closes the windows of the running session
#   -Engine game   the installed game's engine (default); godot: stock Godot (GodotVersion), cached
#   -NoJoin        nobody hosts or joins by itself (Invite on the host's lobby page invites all)
#   -Mute          which games are silent (default: the clients)
#   -With          more mods to load (default mods\brotato-trade); none: only brotato:together
#   -Run           instance folders under play\<run> (default "default"; kept between starts)
#   -Fresh         start the run's instances from empty user folders
#   -Profile       the link profile every game sends with (default lan; none: no latency at all);
#                  profiles and their sources: dev\einfluffles-TogetherLocal\link_profiles.gd
param(
    [ValidateRange(1, 3)][int]$Clients = 1,
    [ValidateSet("game", "godot")][string]$Engine = "game",
    [switch]$NoJoin,
    [ValidateSet("client", "all", "none")][string]$Mute = "client",
    [string[]]$With = @("mods\brotato-trade"),
    [string]$GameDir = "",
    [ValidatePattern("^[A-Za-z0-9_-]+$")][string]$Run = "default",
    [switch]$Fresh,
    [switch]$Stop,
    [string]$Screenshot = "",
    [string]$Key = "",
    [string]$On = "",
    [int]$HoldMs = 0,
    [ValidateSet("lan", "relay-good", "relay-typical", "bad", "stall", "none")][string]$Profile = "",
    [switch]$FailSession,
    [ValidateRange(0, 9999)][int]$Reason = 0,
    [switch]$FailSend,
    [ValidateRange(0, 100)][int]$Count = 0,
    [ValidateRange(0, 60000)][int]$Stall = 0,
    [int]$Width = 0,
    [string]$GodotVersion = "3.6.2",
    [int]$TimeoutSec = 180
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if (-not $env:LOCALAPPDATA -or -not $env:APPDATA) { throw "LOCALAPPDATA or APPDATA is not set" }
$Cache = Join-Path $env:LOCALAPPDATA "brotato-modtools"
$Play = Join-Path $Cache "play"
$GameCopy = Join-Path $Play "game"
$EngineDir = Join-Path $Play "engine"
$SessionFile = Join-Path $Play "session.json"
$PatchVersion = "local-play 1"  # part of the game copy's stamp: a new patch set re-copies
$UserDirName = "Brotato"  # project.godot config/name (use_custom_user_dir, no custom name)
$HostNumber = 1
# The emulator's first lobby of the host (steam_emulator.gd: FAKE_LOBBY_BASE + (number << 8) + 1)
$FirstLobby = [int64]0x0080000000000000 + ($HostNumber -shl 8) + 1
$Utf8 = New-Object Text.UTF8Encoding $false

function Write-Note([string]$Text) { Write-Host "play-local: $Text" }

function Get-Session {
    if (-not (Test-Path $SessionFile)) { return $null }
    try { return Get-Content $SessionFile -Raw | ConvertFrom-Json } catch { return $null }
}

# The processes of a session that still run (same id, same start time: not a reused id).
function Get-SessionProcesses($Session) {
    $alive = @()
    if ($null -eq $Session) { return $alive }
    foreach ($entry in $Session.instances) {
        $process = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
        if ($null -ne $process -and $process.StartTime.ToUniversalTime().Ticks -eq [int64]$entry.start) {
            $alive += $process
        }
    }
    return $alive
}

# Closes the windows (the games tell the others they leave), then ends what is left.
function Stop-Session {
    $session = Get-Session
    $alive = @(Get-SessionProcesses $session)
    foreach ($process in $alive) { [void]$process.CloseMainWindow() }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and @($alive | Where-Object { -not $_.HasExited }).Count -gt 0) {
        Start-Sleep -Milliseconds 200
    }
    foreach ($process in $alive) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    }
    if (Test-Path $SessionFile) { Remove-Item $SessionFile }
    return $alive.Count
}

if ($Stop) {
    $count = Stop-Session
    Write-Note "stopped ($count game$(if ($count -ne 1) { 's were' } else { ' was' }) running)"
    exit 0
}

# The running instances (all, or the one -On names; -On all: all) for a control command.
function Get-Targets {
    $session = Get-Session
    $alive = @(Get-SessionProcesses $session | ForEach-Object { $_.Id })
    $name = if ($On -eq "all") { "" } else { $On }
    $targets = @($session.instances | Where-Object { $alive -contains $_.pid -and ($name -eq "" -or $_.name -eq $name) })
    if ($targets.Count -eq 0) { throw "no running instance$(if ($On -ne '') { " named $On" }) of a local session" }
    return $targets
}

function Send-Control([object]$Entry, [string]$Command) {
    New-Item -ItemType Directory -Force (Join-Path $Entry.dir "control") | Out-Null
    [IO.File]::WriteAllText((Join-Path $Entry.dir "control\$Command"), "")
}

if ($Key -ne "") {
    if ($Key -notmatch '^[A-Za-z0-9]+$') { throw "-Key takes a Godot key name such as Enter, Escape, Right, A" }
    foreach ($entry in (Get-Targets)) {
        Send-Control $entry "key-$Key$(if ($HoldMs -gt 0) { "-$HoldMs" })"
        Write-Note "$($entry.name): key $Key$(if ($HoldMs -gt 0) { " held $HoldMs ms" })"
    }
    exit 0
}

function Read-Status([string]$Dir) {
    $path = Join-Path $Dir "status.json"
    if (-not (Test-Path $path)) { return $null }
    try { return Get-Content $path -Raw | ConvertFrom-Json } catch { return $null }
}

# A link profile at run time: only with -On (without it, -Profile is the start's profile).
if ($Profile -ne "" -and $On -ne "") {
    $targets = @(Get-Targets)
    foreach ($entry in $targets) { Send-Control $entry "profile-$Profile" }
    $deadline = (Get-Date).AddSeconds(5)
    $pending = $targets
    while ((Get-Date) -lt $deadline -and $pending.Count -gt 0) {
        Start-Sleep -Milliseconds 200
        $pending = @($pending | Where-Object { (Read-Status $_.dir).link.profile -ne $Profile })
    }
    foreach ($entry in $targets) {
        $link = (Read-Status $entry.dir).link
        Write-Note "$($entry.name): link profile $($link.profile)$(if ($link.profile -ne $Profile) { " (not $Profile yet)" })"
    }
    exit $(if ($pending.Count -eq 0) { 0 } else { 1 })
}

if ($FailSession -or $FailSend -or $Stall -gt 0) {
    foreach ($entry in (Get-Targets)) {
        if ($FailSession) {
            Send-Control $entry "fail-session$(if ($Reason -gt 0) { "-$Reason" })"
            Write-Note "$($entry.name): sessions fail$(if ($Reason -gt 0) { " (reason $Reason)" })"
        }
        if ($FailSend) {
            Send-Control $entry "fail-send$(if ($Count -gt 0) { "-$Count" })"
            Write-Note "$($entry.name): next $([Math]::Max(1, $Count)) reliable send(s) fail"
        }
        if ($Stall -gt 0) {
            Send-Control $entry "stall-$Stall"
            Write-Note "$($entry.name): link stalls for $Stall ms"
        }
    }
    exit 0
}

if ($Screenshot -ne "") {
    $name = $Screenshot -replace '[^A-Za-z0-9_-]', '_'
    $shots = @()
    foreach ($entry in (Get-Targets)) {
        $shot = Join-Path $entry.dir "shots\$name.png"
        if (Test-Path $shot) { Remove-Item $shot }
        Send-Control $entry "screenshot-$name"
        $shots += $shot
    }
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and @($shots | Where-Object { -not (Test-Path $_) }).Count -gt 0) {
        Start-Sleep -Milliseconds 200
    }
    foreach ($shot in $shots) { Write-Host "$(if (Test-Path $shot) { 'saved  ' } else { 'MISSING' }) $shot" }
    exit $(if (@($shots | Where-Object { -not (Test-Path $_) }).Count -eq 0) { 0 } else { 1 })
}

# --- Checks and copies ---

if (-not (Test-Path (Join-Path $Root "reference\project.godot"))) {
    throw "reference/ missing: decompile the game first (docs/game-code.md)"
}
$previous = Stop-Session
if ($previous -gt 0) { Write-Note "closed the previous local session ($previous games)" }
New-Item -ItemType Directory -Force $Play | Out-Null

# The installed game: -GameDir, else every Steam library (Steam's registry entry and its
# libraryfolders.vdf), else the Workshop folder's library (BROTATO_WORKSHOP_DIR). Only read.
function Find-GameDir {
    if ($GameDir -ne "") { return $GameDir }
    $libraries = @()
    $steam = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        $libraries += $steam
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($match in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libraries += $match.Groups[1].Value -replace '\\\\', '\'
            }
        }
    }
    if ($env:BROTATO_WORKSHOP_DIR) {
        $workshop = $env:BROTATO_WORKSHOP_DIR -replace '^/([a-zA-Z])/', '$1:\' -replace '/', '\'
        $libraries += (Split-Path (Split-Path (Split-Path (Split-Path $workshop))))
    }
    foreach ($library in $libraries) {
        $candidate = Join-Path $library "steamapps\common\Brotato"
        if (Test-Path (Join-Path $candidate "Brotato.exe")) { return $candidate }
    }
    throw "the installed game was not found: pass -GameDir <folder with Brotato.exe>"
}

function Get-Stamp([string]$Path, [string]$Extra) {
    $item = Get-Item $Path
    return "$($item.LastWriteTimeUtc.Ticks) $($item.Length) $Extra"
}

function Read-Stamp([string]$Path) {
    if (Test-Path $Path) { return (Get-Content $Path -Raw).Trim() }
    return ""
}

if ($Engine -eq "game") {
    $installed = Find-GameDir
    $sourceExe = Join-Path $installed "Brotato.exe"
    $sourceDll = Join-Path $installed "steam_api64.dll"
    foreach ($file in @($sourceExe, $sourceDll)) {
        if (-not (Test-Path $file)) { throw "missing in the installed game: $file" }
    }
    # Under another name the engine finds no .pck of its own and runs the game copy (--path).
    $EngineExe = Join-Path $EngineDir "BrotatoLocal.exe"
    $stamp = Get-Stamp $sourceExe "engine"
    $stampFile = Join-Path $EngineDir ".source-stamp"
    if ((Read-Stamp $stampFile) -ne $stamp -or -not (Test-Path $EngineExe)) {
        Write-Note "copying the game's engine from $installed ..."
        New-Item -ItemType Directory -Force $EngineDir | Out-Null
        Copy-Item -LiteralPath $sourceExe -Destination $EngineExe -Force
        Copy-Item -LiteralPath $sourceDll -Destination (Join-Path $EngineDir "steam_api64.dll") -Force
        [IO.File]::WriteAllText($stampFile, $stamp)
    }
    if (Test-Path (Join-Path $EngineDir "BrotatoLocal.pck")) { throw "unexpected BrotatoLocal.pck in $EngineDir" }
} else {
    $godotDir = Join-Path $Cache "godot-$GodotVersion"
    $EngineExe = Join-Path $godotDir "Godot_v$GodotVersion-stable_win64.exe"
    if (-not (Test-Path $EngineExe)) {
        Write-Note "downloading Godot $GodotVersion ..."
        New-Item -ItemType Directory -Force $godotDir | Out-Null
        $zip = Join-Path $godotDir "godot.zip"
        $url = "https://github.com/godotengine/godot/releases/download/$GodotVersion-stable/" `
            + "Godot_v$GodotVersion-stable_win64.exe.zip"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
        Expand-Archive -Force -Path $zip -DestinationPath $godotDir
        Remove-Item $zip
    }
}

# The game copy: reference/ without mods-unpacked, the feature "steam" removed.
$stamp = Get-Stamp (Join-Path $Root "reference\project.godot") $PatchVersion
$stampFile = Join-Path $GameCopy ".source-stamp"
if ((Read-Stamp $stampFile) -ne $stamp) {
    Write-Note "copying reference/ to $GameCopy (once per game version) ..."
    if (Test-Path $stampFile) { Remove-Item $stampFile }
    robocopy (Join-Path $Root "reference") $GameCopy /MIR /XD (Join-Path $Root "reference\mods-unpacked") `
        /XF ".source-stamp" /NFL /NDL /NJH /NJS /NP /MT:16 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "copying reference/ failed (robocopy $LASTEXITCODE)" }
    $project = Join-Path $GameCopy "project.godot"
    $lines = [IO.File]::ReadAllLines($project)
    $patched = @($lines | Where-Object { $_ -ne '_custom_features="steam"' })
    if ($patched.Count -ne $lines.Count - 1) {
        throw "project.godot has no line _custom_features=`"steam`": the local build cannot be made"
    }
    foreach ($needed in @("config/name=`"$UserDirName`"", "config/use_custom_user_dir=true")) {
        if (-not ($patched -contains $needed)) { throw "project.godot lacks $($needed): the user folder is unknown" }
    }
    [IO.File]::WriteAllLines($project, $patched)
    [IO.File]::WriteAllText($stampFile, $stamp)
}

# Mods, fresh: brotato:together, the dev mod, the -With mods.
$mods = Join-Path $GameCopy "mods-unpacked"
if (Test-Path $mods) { Remove-Item -Recurse -Force $mods }
New-Item -ItemType Directory -Force $mods | Out-Null
$together = Join-Path $Root "mods\brotato-together"
$dirs = @(Get-ChildItem -Directory (Join-Path $together "src")) + @(Get-ChildItem -Directory (Join-Path $together "dev"))
foreach ($other in $With) {
    if ($other -eq "" -or $other -eq "none") { continue }
    $dirs += @(Get-ChildItem -Directory (Join-Path (Resolve-Path (Join-Path $Root $other)) "src"))
}
foreach ($dir in $dirs) {
    robocopy $dir.FullName (Join-Path $mods $dir.Name) /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "copying $($dir.Name) failed (robocopy $LASTEXITCODE)" }
}
$modNames = ($dirs | ForEach-Object { $_.Name }) -join ", "

# --- Instances ---

$udp = New-Object Net.Sockets.UdpClient (New-Object Net.IPEndPoint ([Net.IPAddress]::Loopback, 0))
$port = $udp.Client.LocalEndPoint.Port
$udp.Close()
$bytes = New-Object byte[] 16
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$token = -join ($bytes | ForEach-Object { $_.ToString("x2") })

$startProfile = if ($Profile -eq "") { "lan" } else { $Profile }
$runDir = Join-Path $Play $Run
if ($Fresh -and (Test-Path $runDir)) { Remove-Item -Recurse -Force $runDir }
$realUserDir = [IO.Path]::GetFullPath((Join-Path $env:APPDATA $UserDirName)).TrimEnd('\')

# Side by side (two) or in a 2x2 grid (three or four), 16:9, on the primary screen.
Add-Type -AssemblyName System.Windows.Forms
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$count = 1 + $Clients
$rows = if ($count -le 2) { 1 } else { 2 }
$gap = 16
$titleBar = 40
$w = if ($Width -gt 0) { $Width } else { [Math]::Min(1280, [int](($area.Width - 3 * $gap) / 2)) }
$h = [int]($w * 9 / 16)
$maxH = [int](($area.Height - ($rows + 1) * $gap) / $rows) - $titleBar
if ($h -gt $maxH) { $h = $maxH; $w = [int]($h * 16 / 9) }

$forced = [ordered]@{ fullscreen = $false; pause_on_focus_lost = $false; mute_on_focus_lost = $false; on_lost_focus = 0 }
function Set-InstanceSettings([string]$UserDir) {
    $file = Join-Path $UserDir "user\settings.json"
    $data = $null
    if (Test-Path $file) { try { $data = Get-Content $file -Raw | ConvertFrom-Json } catch { $data = $null } }
    if ($null -eq $data) { $data = [pscustomobject]@{ current_profile_id = 0 } }
    if ($null -eq $data.settings) {
        $data | Add-Member -NotePropertyName settings -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    foreach ($key in $forced.Keys) {
        $data.settings | Add-Member -NotePropertyName $key -NotePropertyValue $forced[$key] -Force
    }
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    [IO.File]::WriteAllText($file, ($data | ConvertTo-Json -Depth 30 -Compress), $Utf8)
}

$instances = @()
for ($i = 0; $i -lt $count; $i++) {
    $role = if ($i -eq 0) { "host" } else { "client" }
    $name = if ($i -eq 0) { "host" } else { "client$i" }
    $dir = Join-Path $runDir $name
    $appdata = Join-Path $dir "appdata"
    $userDir = [IO.Path]::GetFullPath((Join-Path $appdata $UserDirName)).TrimEnd('\')
    if ($userDir -ieq $realUserDir -or $userDir.StartsWith("$realUserDir\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "refused: the user folder of $name would be the game's own ($realUserDir)"
    }
    New-Item -ItemType Directory -Force $dir | Out-Null
    # The game reads the last log at boot and turns all mods off after an error that names a mod.
    foreach ($old in @((Join-Path $userDir "logs"), (Join-Path $dir "control"), (Join-Path $dir "shots"))) {
        if (Test-Path $old) { Remove-Item -Recurse -Force $old }
    }
    foreach ($old in @("stdout.log", "stderr.log", "status.json", "instance.json")) {
        $path = Join-Path $dir $old
        if (Test-Path $path) { Remove-Item -Force $path }
    }
    Set-InstanceSettings $userDir
    $column = $i % 2
    $row = [int][Math]::Floor($i / 2)
    $x = $area.X + $gap + $column * ($w + $gap)
    $y = $area.Y + $gap + $row * ($h + $titleBar + $gap) + $titleBar
    $arguments = @("--path", "`"$GameCopy`"", "--windowed", "--resolution", "${w}x$h", "--position", "$x,$y")
    if ($role -eq "client" -and -not $NoJoin) { $arguments += @("+connect_lobby", "$FirstLobby") }
    $muted = ($Mute -eq "all") -or ($Mute -eq "client" -and $role -eq "client")
    $environment = [ordered]@{
        APPDATA = $appdata
        BT_LOCAL_ROLE = $role
        BT_LOCAL_ID = "$($HostNumber + $i)"
        BT_LOCAL_NAME = $(if ($i -eq 0) { "Host" } else { "Client $i" })
        BT_LOCAL_PORT = "$port"
        BT_LOCAL_TOKEN = $token
        BT_LOCAL_DIR = $dir
        BT_LOCAL_AUTOHOST = $(if ($role -eq "host" -and -not $NoJoin) { "1" } else { $null })
        BT_LOCAL_MUTE = $(if ($muted) { "1" } else { $null })
        BT_LOCAL_PROFILE = $(if ($startProfile -eq "none") { $null } else { $startProfile })
    }
    $saved = @{}
    foreach ($key in $environment.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $environment[$key])
    }
    try {
        $process = Start-Process -FilePath $EngineExe -ArgumentList $arguments -WorkingDirectory $dir -PassThru `
            -RedirectStandardOutput (Join-Path $dir "stdout.log") -RedirectStandardError (Join-Path $dir "stderr.log")
    } finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }
    $info = [ordered]@{
        name = $name
        role = $role
        pid = $process.Id
        start = $process.StartTime.ToUniversalTime().Ticks
        dir = $dir
        engine = $EngineExe
        arguments = ($arguments -join " ")
        user_dir = $userDir
        mod_loader_log = (Join-Path $userDir "logs\modloader.log")
        godot_log = (Join-Path $userDir "logs\godot.log")
        stdout = (Join-Path $dir "stdout.log")
        stderr = (Join-Path $dir "stderr.log")
        status = (Join-Path $dir "status.json")
        shots = (Join-Path $dir "shots")
        mods = $modNames
        port = $port
    }
    [IO.File]::WriteAllText((Join-Path $dir "instance.json"), ($info | ConvertTo-Json), $Utf8)
    $instances += [pscustomobject]$info
}
$session = [ordered]@{ run = $Run; engine = $Engine; port = $port; profile = $startProfile; instances = $instances }
[IO.File]::WriteAllText($SessionFile, ($session | ConvertTo-Json -Depth 5), $Utf8)
Write-Note "$Engine engine, $count games on 127.0.0.1:$port, link profile $startProfile, mods: $modNames"
foreach ($entry in $instances) { Write-Note "  $($entry.name): pid $($entry.pid), $($entry.dir)" }

# --- Until the games are up (and the clients in the host's lobby) ---

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
$lastLine = ""
while (-not $done -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $parts = @()
    $done = $true
    foreach ($entry in $instances) {
        $process = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.HasExited) {
            Write-Note "$($entry.name) has ended; last lines of $($entry.stderr):"
            if (Test-Path $entry.stderr) { Get-Content $entry.stderr -Tail 15 | Write-Host }
            exit 1
        }
        $status = Read-Status $entry.dir
        if ($null -eq $status) { $parts += "$($entry.name): booting"; $done = $false; continue }
        $lobby = if ($status.lobby.id) { "in lobby" } else { "no lobby" }
        $parts += "$($entry.name): $(if ($status.bound) { 'bound' } else { 'waiting' }), $lobby"
        $ready = $status.bound -and ($NoJoin -or $status.lobby.id)
        if (-not $ready) { $done = $false }
    }
    $line = $parts -join "; "
    if ($line -ne $lastLine) { Write-Note $line; $lastLine = $line }
}
if (-not $done) { Write-Note "not all games were ready after $TimeoutSec s (see status.json and stderr.log)" }
foreach ($entry in $instances) {
    if (-not (Test-Path $entry.stderr)) { continue }
    $errors = @(Get-Content $entry.stderr | Where-Object { $_ -match '^SCRIPT ERROR' })
    if ($errors.Count -gt 0) { Write-Note "$($entry.name): $($errors.Count) script errors in $($entry.stderr)" }
}
Write-Note "screenshots: tools\play-local.ps1 -Screenshot <name>; stop: tools\play-local.ps1 -Stop (or close the windows)"
exit $(if ($done) { 0 } else { 1 })
