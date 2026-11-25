# Testing

How the mods' tests run: headless in the toolchain container (`tools/check.sh`), and in a real game
window on Windows (`tools\check-window.ps1`). Both need the decompiled game in `reference/`
([Game code](game-code.md)). [Play locally](#play-locally) starts brotato:together as host and clients in
several game windows on one PC, without Steam, and [Pair tests](#pair-tests) run its scenarios
with a host and a client as two headless games (`tools/check-pair.sh`).

## Headless

`tools/check.sh [mods/<folder> ...]` boots the game headless with each mod and its test mod. It
fails when the test mod does not print `MOD-TESTS: PASS`, on any script error in mod code, and on a
game-script error or a `get_meta` / `get_child` / `get_node` engine error while the tests run.

- A test mod is split into named suites. `tools/check.sh -s <suite>[,<suite>]` runs only those, in
  one game process. `-q` prints failures, info lines and the summary only.
- `tests/<test_mod_id>/shards.txt` lists one group of suites per line. A full check starts one game
  process per line, all at the same time.
- A line that ends in `+<mod folder>` also loads that mod's `src/` in its process. brotato:trade
  uses this for its tests next to brotato:together. A process sees only the mods mounted for it.
- On a slow mount (a Windows drive under WSL) the game runs from a copy of `reference/` in
  `~/.cache/brotato-modtools`, because the game reads about 17000 files while booting and such a
  mount makes that slow. The copy is refreshed when `reference/project.godot` changes.
  `MOD_CHECK_CACHE=1` or `0` forces the copy on or off, and `MOD_CHECK_RESYNC=1` refreshes it.
- The scripts use podman, or docker when podman is missing (`CONTAINER=...` picks one).
- Besides `src/` and `tests/`, a mod folder can have `dev/<dev_mod_id>/`: dev-only mods that
  `tools/check.sh` and `tools\check-window.ps1` mount for the tests too, and that are never
  packaged. Every process loads them, so they must stay inert in a test run. See below.

## Local play (emulator)

brotato:together's `dev/einfluffles-TogetherLocal` is the local-play dev mod: a Steam stand-in
(`steam_emulator.gd`) the real transport binds instead of GodotSteam, so host and clients can run
without Steam's networking. In a test run it refuses to start (no `BT_LOCAL_ROLE`, the Steam build's
feature `steam`, the game's own user folder) and logs one line; the suites check that.

- `wire_memory.gd` puts two or more emulators in one process with one clock that moves only when a
  test steps it. Pacing, latency, loss, reordering, stalls and failures are therefore exact, and a
  suite on it runs the same every time without waiting in real time.
- `emulator` tests the stand-in itself, `emulator_transport` a real `Transport` and `Session` per
  player on it (handshake, messages, send results and the full resync, leave, kick, failures),
  `emulator_wire` the wire between game processes (`wire_tcp.gd`) with real sockets on 127.0.0.1,
  all ends in one process, `emulator_profiles` the link profiles and, with a real `Transport` and
  `Session` per player, that `bad` brings out the host's path, Slow answer, traffic and gap lines
  and `lan` none of them (that part waits in real time, about 9 s).
- The dev mod's design, activation rules and coverage of GodotSteam:
  [Local play](../mods/brotato-together/docs/implementation.md#local-play-dev-mod).

## Pair tests

`tools/check-pair.sh [-q] [scenario ...]` runs brotato:together's local-play scenarios with a host
and a client as two headless game processes, each scenario in its own container (four at once,
`PAIR_JOBS`). Without names it runs every scenario in `HEADLESS` of the dev mod's `scenarios.gd`
(all but `language`, which only takes screenshots). The whole set takes about a minute.

```
CONTAINER=docker tools/check-pair.sh                  # all of them
CONTAINER=docker tools/check-pair.sh kick bad_resync  # some
```

- The game is the one `tools/check.sh` boots (`reference/` or its copy), with its `project.godot`
  replaced, in the container only, by one without the feature `steam`: the game's local build, as
  in [Play locally](#play-locally). The mounted mods are brotato:together's `src/` and the dev mod,
  not the test mod.
- Each process has its own `HOME` and `XDG_DATA_HOME` (user folder `/pair/<name>/data/Brotato`),
  the dev mod's `BT_LOCAL_*` variables as `tools\play-local.ps1` sets them (role, id, name, a port
  and a random token for the wire on 127.0.0.1 inside the container, its folder, the link profile
  `lan`), the host `BT_LOCAL_AUTOHOST=1` and the client `+connect_lobby <the host's first lobby>`.
  The dev mod's refusal rules hold there as in a window: stock Godot has no Steam singleton, the
  copy has no feature `steam`, and the user folder is not `$HOME/.local/share/Brotato`.
- `BT_LOCAL_SCENARIO`, `BT_LOCAL_RUN` and `BT_LOCAL_PEERS` make each game run its part of the
  scenario from the start (see below), print `PAIR-TESTS: PASS` or `PAIR-TESTS: FAIL <why>` and
  close. A scenario passes when both games print PASS within `PAIR_TIMEOUT` (420 s), with no
  script error in mod code and none of the engine errors `tools/check.sh` fails on.
- On a failure it prints both games' steps, checks and verdicts, their script errors and the
  mods' warnings, and keeps the scenario's folder (`host/` and `client1/`: `stdout.log`, the user
  folder, `out/` with every answer). `PAIR_KEEP=1` keeps passed ones too, `PAIR_DIR` picks the
  folder, `-q` prints the summary lines only.
- Godot 3.6.2's headless build sometimes crashes in its own teardown when a client closes in a
  run (signal 11 after every script has ended). That comes after the game's verdict, so it is
  printed as an `info:` line and does not fail the scenario; a crash before the verdict does.
- `PAIR_BREAK=token` gives the client another wire token than the host: the host's game refuses
  it, the lobby never fills, and every scenario must fail (about three minutes, the first wait's
  timeout). A check of the layer itself.
- `tools/local-check.sh` runs the pair tests after `tools/check.sh` when brotato:together is among
  its mods. For now they are informative: a failure is printed and named in the commit status's
  description, but the status is still posted. `PAIR_BLOCKING=1` at the top of the script makes a
  failure stop the check, once they have run stable for a few releases. Not in GitHub's CI:
  `reference/` never goes there.

**One scenario, two games.** The scenarios are GDScript, `scenarios.gd` in the dev mod, and
`scenario_runner.gd` runs one in every game of a session at once: each game runs the same
scenario code. A step names the games that act (`r.on("host", {...})`, `r.on(BOTH, {...})`, or a
command per game); each of them carries out its director command and writes the answer to its
`out/` folder, and every game reads the others' answers from their folders (the instance folders
are siblings). So each step is a meeting point, every game sees the same answers, takes the same
branches and comes to the same checks. The same code runs in game windows through
`tools\play-local.ps1 -Scenario <name>` (the director's `scenario` command, with screenshots).

| Scenario | What it checks |
|---|---|
| `join` | The client joins through `+connect_lobby`: both in one lobby, the host's session has the client ready and the client has the host's `WELCOME`, no lobby error. |
| `join_wave_shop` | Lobby, Start, both join character selection, character, weapon and difficulty by accept, wave 1 with XP and gold, the level-up panels, the shop; the client buys the item under its cursor (checked on the host: gold down, one more item or weapon). |
| `resume_leave_rejoin` | Wave 1 into the shop; the host quits to the title screen and continues the saved run. On the co-op resume screen the client takes saved player 1, leaves (the host gets saved player 1 back and stays on the screen), joins again, takes saved player 1 again; the host takes saved player 2 and the shop loads with both. |
| `host_quits` | The host's game closes mid-wave: the client drops back to its title screen with "The host left the lobby", out of client mode. |
| `client_quits` | The client's game closes mid-wave: the host plays on in its lobby with the client's slot kept, and the closing game logs no script error. |
| `kick` | The host kicks the client: it leaves with "The host removed you from the lobby"; it can join again. |
| `version_mismatch` | The client leaves, takes another brotato:together version (the director's `mod_version`) and joins again: rejected with the code `mod` and both versions, in its language; with its own version it joins. |
| `bad_resync` | Both games on the `bad` profile, the host's next reliable send fails (`fail_send`): the host runs a full resync for the client, and both still get through character selection into a wave with the session up. |
| `language` | Windows only (screenshots): both games switch to German and Russian at the title screen, in character selection, in the wave and in the shop. |

To add a scenario: a function `scenario_<name>(r)` in `scenarios.gd` (the shared parts are there:
`lobby_step`, `character_join_step`, `select_until`, `wave_to_shop`, `host_quits_run`,
`join_hold`), its name in `NAMES` and, when it has checks, in `HEADLESS`, and its row here. Every
step begins with `yield(r.step("<label>"), "completed")`. Rules: branch and loop only on answers
(`r.state(name)`, the answers of `r.on`) and on counts, never on a game's own clock or state,
since each game decides for itself; wait for states (`wait_for`) rather than fixed times; give a
check a text with the values it saw (`r.check(condition, text)`). A command the director lacks
goes into `director.gd` (its table in the implementation notes). Run it here
(`tools/check-pair.sh <name>`) and once in windows (`tools\play-local.ps1 -Scenario <name>`).

## Play locally

On Windows, one command starts a host and a client of brotato:together as two game windows side by
side, connected without Steam:

```
tools\play-local.ps1
```

(`powershell -ExecutionPolicy Bypass -File tools\play-local.ps1` if scripts are blocked.) It needs
`reference/` and the installed game. What you get, after about a minute on the first start (it
copies the game) and 10 to 45 s after that:

- Two windows, the host on the left. The host opens a lobby at the title screen by itself, the
  client joins it through the real launch option `+connect_lobby <lobby id>`, as Steam starts a
  game for an invite. Both show the lobby with both players. From there it is the real game: Start
  on the host, then each player holds Enter (or Space) in its own window to join a slot.
- Keyboard and mouse act in the focused window. Gamepads are not split per window yet: play with
  keyboard and mouse. Neither window pauses or mutes when it loses focus; the clients are silent.
- The mods come from this worktree: brotato:together's `src/`, the dev mod, and brotato:trade
  (`-With none` leaves it out). The game is the installed game's engine (`BrotatoLocal.exe`, copied)
  on a copy of `reference/` without the feature `steam`, so it runs as the game's local build:
  Steam is never started or initialised, there are no achievements or Steam saves, and both DLCs
  count as owned.
- Each game has its own user folder (saves, settings, logs). The real saves in `%APPDATA%\Brotato`
  are never read or written.

Options:

| Option | What |
|---|---|
| `-Clients 1..3` | More clients (two or more: a 2x2 grid). |
| `-Engine godot` | Stock Godot 3.6.2 (downloaded once, as for `check-window.ps1`) instead of the game's engine: a debug build, so the version shows `-debug` and the game's debug keys work. |
| `-NoJoin` | Nobody hosts or joins by itself. Host in the host window; Invite (title screen or lobby page) sends every client an accepted invite. |
| `-Mute client\|all\|none` | Who is silent (default `client`). |
| `-With mods\<folder>[,...]`, `-With none` | Other mods to load (default `mods\brotato-trade`). |
| `-Run <name>`, `-Fresh` | Instance folders under `play\<name>` (default `default`, kept between starts, so unlocks and saved runs stay); `-Fresh` starts from empty ones. |
| `-GameDir <folder>` | The installed game, when it is not found in Steam's libraries. |
| `-Stop` | Closes the windows of the running session (the games leave as a closed window does), then ends what is left. Closing the windows by hand does the same; a new start closes the previous session first. |
| `-Screenshot <name> [-On <instance>]` | Every running game (or one) saves its window to `<instance>\shots\<name>.png`. |
| `-Key <name> [-HoldMs <msec>] [-On <instance>]` | A key press in a game, by Godot key name (`Enter`, `Escape`, `Right`, `D`, ...). Joining a co-op slot needs a hold: `-Key Enter -HoldMs 1500 -On client1`. |
| `-Profile <name>` | The link profile every game starts with: `lan` (default), `relay-good`, `relay-typical`, `bad`, `stall`, or `none` (no latency at all). See below. |
| `-Profile <name> -On <instance>\|all` | Switches a running game's profile (`-On all`: every game) through the director's `set_profile` and prints the profile each game answers with. A game's profile is the line for what it sends, so `-Profile bad -On client1` makes only the client's way to the host bad. |
| `-FailSession [-Reason <n>] [-On <instance>]` | That game's sessions fail at both ends with Steam's end reason (default 5003, timed out); the next message opens new ones (`fail_session`). |
| `-FailSend [-Count <n>] [-On <instance>]` | The game's next reliable send(s) fail with LimitExceeded; on the host the mod then runs a full resync for that client (`fail_send`). |
| `-Stall <msec> [-On <instance>]` | Nothing the game sends moves for that long (`stall`). |
| `-Do <command> [-On <instance>]` | Any director command (below), as `key=value` pairs (`-Do "cmd=button name=StartButton" -On host`, `-Do "cmd=wait_for scene=coop_resume timeout_sec=20"`) or a JSON object; prints the answer with the screen's state. Windows PowerShell drops the double quotes of an argument to another `powershell.exe`, so JSON only works from cmd or with `& tools\play-local.ps1` in the same session. |
| `-Scenario <name>` | A scripted scenario in fresh games (below); exits with `PASS` (0) or `FAIL` (1). |

Everything is in `%LOCALAPPDATA%\brotato-modtools\play`: `game\` (the game copy, refreshed when
`reference/project.godot` changes, mods replaced on every start), `engine\` (refreshed when the
installed `Brotato.exe` changes), and per instance `<run>\host`, `<run>\client1`, ...: `appdata\`
(the instance's `APPDATA`; Mod Loader log in `appdata\Brotato\logs\modloader.log`),
`stdout.log`, `stderr.log`, `instance.json` (what was started: pid, arguments, paths),
`status.json` (written by the dev mod every second: role, wire, link, lobby, members, scene),
`control\`, `out\` and `shots\` (the director's commands, answers and screenshots). A scenario's
run is `play\scenario-<name>\` with `scenario.log` (every command, answer and check).

### Director and scenarios

Every game of a local session has a director (the dev mod's `director.gd`): it takes JSON commands
from the instance's `control\` folder, one at a time, and answers each in `out\<id>.json` with
`ok`, `error`, a `result` and the screen's `state` (scene, players, run, lobby, the co-op resume
screen's saved player, ...). It drives the menus as a player does: keys through the game's input,
buttons by focus and accept. Commands: `press`, `button`, `wait_for`, `query`, `screenshot`,
`host_lobby`, `join`, `invite`, `leave`, `kick`, `debug`, `language`, `mod_version`, `scenario`,
`quit`, and on the link of what the game sends `set_profile`, `fail_session`, `fail_send` and
`stall`; fields and state:
[the director](../mods/brotato-together/docs/implementation.md#local-play-dev-mod).
`-Key`, `-Screenshot`, `-Do` and the link switches (`-Profile` with `-On`, `-FailSession`,
`-FailSend`, `-Stall`) send them to a running session: the director is the one way to control a
running game.

Screenshots come from the game's own viewport, so windows on top of it do not matter; a
minimised window is drawn once for its screenshot.

`tools\play-local.ps1 -Scenario <name>` starts fresh games (run `scenario-<name>`, empty user
folders), plays the scenario through the directors, takes a screenshot of every game after every
step (`<instance>\shots\<NN>-<step>.png`, `<NN>-failed.png` when a step fails), closes the games
and prints `PASS <name>` (exit 0) or `FAIL <name>` (exit 1). The steps live in the dev mod's
`scenarios.gd`, the same ones [Pair tests](#pair-tests) run headless (the table of scenarios is
there): the launcher sends every game the director's `scenario` command at once, each runs its
part in step with the others and takes its screenshots, and the launcher shows the host's steps
as they come. The host's runs use the game's own test settings (`debug`: invulnerable, short
waves), so nobody dies and a wave takes 10 to 30 s.

In `resume_leave_rejoin` the client joins first on the resume screen: had the host taken one of
the two saved players first, the client's join would take the last one and load the shop at once.

For an agent: run a scenario, read its `scenario.log`, then look at the screenshots of the steps
the change is about. To try something else, start a session (`tools\play-local.ps1`) and drive it
step by step with `-Do`, reading each answer's `state`. Only one local session runs at a time on a
PC: a start closes the previous one, and every start fills `play\game\mods-unpacked` from its own
worktree.

The launcher deletes each instance's logs before a start: the game reads the last log at boot
and turns all mods off after an error in it that names a mod. Expected in `stderr.log`: none with
`-Engine godot`; with the game's engine one line "User class not found, Steam may not be
initialized: getSteamID" (the dev mod asking whether Steam is logged on) and "CrashReporter:
Failed to find engine logs" (the deleted logs).

Link profiles, from the measured sessions
([Link profiles](../mods/brotato-together/docs/implementation.md#link-profiles) has the numbers
and their sources):

| Profile | Steam ping | What the host's log shows |
|---|---|---|
| `lan` | 2 ms | the first path line per client, nothing else from the network |
| `relay-good` | 26 ms | as `lan`, a POP change line after 10 minutes |
| `relay-typical` | 40 ms, 0.5 % loss | a short stall every minute or two: now and then a gap line or a Slow answer |
| `bad` | 200 ms, 3 % loss, 64 KB/s | path changes, Slow answers with the traffic summary, "Reliable burst" in the shop, input gaps after its stalls (every 4 to 10 s) |
| `stall` | 16 ms | the direct route of 2026-11-16: gaps of 300 ms to 3.3 s, the long ones about every half minute |

The log is each game's `appdata\Brotato\logs\modloader.log`; `status.json` has the profile and
per client Steam's numbers (ping, queue, pending bytes, quality, bytes per second).

What it shows and what it cannot: the mod's transport runs unchanged on the stand-in, so lobby,
handshake, sessions, sends, leaves and kicks take the same code paths as with Steam, and the
profiles put measured latency, jitter, loss, slow lines and stalls under them. The line itself is
still loopback in the end: no real Steam relay, NAT or route choice, no real Steam overlay,
invites, friends-only lobbies, DLC ownership, achievements or Workshop. Both games share one PC's
CPU and GPU, and the game copy is decompiled code, not the shipped `.pck`. Real sessions between
two Steam accounts stay the check before a release.

## With real graphics

The container's Godot is headless: its graphics and audio drivers are dummies. Costs that only
exist with a real driver do not show there, such as uploads to the GPU, the driver waiting for the
GPU, shaders, particles and sounds. On Windows, `tools\check-window.ps1` runs a mod's tests in a
real game window instead (`powershell -ExecutionPolicy Bypass -File ...` if scripts are blocked).

- It uses the official Godot build of `-GodotVersion` (default 3.6.2, as in `tools/Containerfile`),
  downloaded once to `%LOCALAPPDATA%\brotato-modtools`, or the exe given with `-Godot`. The game
  itself runs a custom 3.7 build.
- The game runs from a copy of `reference/` there, refreshed when `reference/project.godot`
  changes. The copy's `project.godot` gets its own user folder, `%APPDATA%\BrotatoModTests`: the
  game's own one holds the real saves and logs.
- `-Mod mods\<folder>` picks the mod (default brotato-together). Without `-Suites`, every line of
  its test mod's `shards.txt` runs in its own game process, one after the other, with the mods its
  `+<mod folder>` names (`tools\check-window.ps1 -Mod mods\brotato-trade` runs brotato:trade's
  tests, the together ones next to brotato:together). `-Suites <suite>[,<suite>]` runs those in one
  process, `-With mods\<folder>` loads another mod next to them. `-All` prints the ok lines too.
- The full log of the last run is `%LOCALAPPDATA%\brotato-modtools\check-window.log`, its errors
  (Godot prints them to stderr) `check-window.err.log` next to it. A run fails on every script
  error except the missing Steam's, and on every engine error not listed in `$KnownErrors` at the
  top of the script (Steam, the deleted logs, the engine's reports at exit). That is stricter than
  `tools/check.sh`: an error at boot that names no mod (issue #91) fails it too.
- The test copy's logs are deleted before each run: the game reads the last one at boot and, when
  an error in it names `mods-unpacked`, turns all mods off ("Recovering from unexpected error in
  mod ...").
- Frames are much shorter than headless. A test that waits a few frames for something that takes
  real time (the game's buttons ignore a second press within 0.05 s) can pass headless and fail
  here.
- Times are this machine's. Compare them with each other (one scene against another, a frame
  against the next), not with what a player's log shows.

Example: brotato:together's `wave_start` suite showed this way that instancing an enemy waits for
the GPU once per frame (its burning particles), which the headless run could not show.
