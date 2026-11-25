# brotato:together: implementation notes

How the mod works, for a developer who is new to it. The game hooks it builds on are listed in
[`docs/brotato-hooks.md`](../../../docs/brotato-hooks.md). This document describes the code as of
2026-11-23 (protocol 33, mod version 0.2.1). File paths are relative to
`src/einfluffles-BrotatoTogether/`, test suites live in `tests/einfluffles-TogetherTests/`.

Contents: [Overview](#1-overview), [Glossary](#2-glossary), [Session](#3-session),
[Transport](#4-transport), [State stream and run state](#5-state-stream-and-run-state),
[Battle](#6-battle), [Screens](#7-screens), [Lobby UI](#8-lobby-ui), [Extras](#9-extras),
[Game bugs worked around](#10-game-bugs-worked-around), [Diagnostics](#11-diagnostics),
[Measurements and session findings](#12-measurements-and-session-findings),
[Known gaps](#13-known-gaps).

## 1. Overview

brotato:together turns the game's local co-op into online co-op over Steam. One player hosts a Steam
lobby, up to three others join it.

The model is host-authoritative. The host runs the real game. Each remote player occupies a local
co-op slot on the host and is driven through a virtual input device. A client runs the game's own
scenes as frozen copies ("puppets") that decide nothing: it shows what the host sends and sends back
what its player does.

### Message flows

All messages are `var2bytes([msg_type, body])` and are decoded without objects (`net/protocol.gd`,
which lists every message with its fields).

| Flow | Messages | Delivery | Content |
|---|---|---|---|
| Handshake and session | `HELLO`, `WELCOME`, `PING`, `PONG`, `KICK` | reliable (PING / PONG unreliable) | compatibility check, DLC list, round-trip time |
| Battle world, host to client | `BATTLE_START`, `TYPE_DEF`, `BATTLE_END` (reliable), `SNAPSHOT` (unreliable, 30 per second) | mixed | run state, type table, then positions, stats and one-shot events |
| Player input, client to host | `INPUT` | unreliable, every physics frame | movement, aim, buttons |
| Screen state, host to client | `STATE` | reliable, ordered | shop, level-up panels, menus, pause, cursors and more, in sections (see [State stream](#5-state-stream-and-run-state)) |
| Decisions, client to host | `SHOP_INTENT`, `UPGRADE_INTENT` | reliable | a press on the client's own panel that changes the run |
| Presence, client to host | `SHOP_FOCUS`, `UPGRADE_FOCUS`, `PANEL_SCROLL` | reliable | where the client's cursor, page and scroll positions are (cosmetic) |
| Other | `UI_SOUNDS`, `SHOP_TEXT`, `PROGRESS` (host to client), `CLIENT_REPORT` (client to host) | reliable | menu sounds, a reroll's stat text, what the run earns, client timings for the host's log |

### Module map

| Directory | Role |
|---|---|
| `l10n.gd`, `translations.csv` | the mod's own texts in the game's languages ([Localization](#localization)) |
| `mod_main.gd` | creates every module, installs the script extensions, switches a client between its own menus and the host's screens |
| `net/` | Steam transport (`steam_transport.gd`), message list (`protocol.gd`), connection path and traffic logs |
| `session/` | handshake, compatibility, puppet mode, DLC borrowing, sound relay, progress sharing, settings |
| `sync/` | everything that mirrors game state: battle (`battle_host.gd`, `battle_client.gd`, `snapshot.gd` and helpers), input, state stream, shop, level-up panels, menus, cursors, pause |
| `ui/` | controls the mod adds to the game's screens (lobby, Co-op row, damage meter views) and helpers for cursors and scrolling |
| `extensions/` | script extensions of game scripts (singletons, UI scenes, one effect, one weapon), and `script_backup.gd` for the Mod Loader's backups of them |

### Engine and game behaviour several modules rely on

These facts explain many design choices below. They are stated here once.

- **Signal order.** Godot 3 calls a signal's targets in order of object id, not in connection order.
- **Input order.** `_input` runs in reverse tree order, so the last child of a scene sees an event
  first. A `FocusEmulator` that has a cursor marks every event that is not a co-op action as handled,
  so on a co-op screen neither the GUI nor `InputService` sees mouse or unbound key events.
- **Multilevel calls.** Godot 3 calls `_input` and `_process` at every script level, the extension's
  level first.
- **Freed objects.** The game's release build does not check for calls on null or freed objects: such
  a call crashes natively, without a script error. `is_instance_valid()` answers true again once the
  freed address is reused. A debug build (the headless tests) reads a freed object as null. The mod
  therefore keeps references to per-wave nodes as instance ids or drops them with the wave.
- **Log memory.** The Mod Loader keeps every log line in memory, so every repeating log line of the
  mod has a rate limit.
- **Script load order.** Naming `BaseShop` in a script that loads with the mod loads `base_shop.gd`
  too early, and the game's shop scripts then fail to parse. Extensions name the concrete shop
  scripts by path, and code that needs to tell a shop asks for its methods.

## 2. Glossary

| Term | Meaning |
|---|---|
| host, client, peer | The host runs the game. A client mirrors it. A peer is any other lobby member. A *ready* peer has completed the handshake. |
| puppet | A node on a client that only displays: physics, collisions, timers and game logic are off. |
| puppet mode | The client-wide state while it mirrors the host (`session/puppet.gd`). Its own run data is stashed, and saves and challenges are blocked. |
| copy | Two uses. A client's *copy of a screen* is the game's own scene running as a puppet. The *host's copy of a panel* is the panel the host's game shows for a remote player. |
| own panel, local view | The panel of the client's own player in the shop or on the level-up screen. It runs on the client (cursor, pages, popups), only decisions go to the host. |
| intent | A client's decision sent to the host (`SHOP_INTENT`, `UPGRADE_INTENT`). The host checks it and applies it with the game's own code. |
| state stream, section | The ordered reliable stream of host state. A section is one topic in it (shop, cursors, ...). |
| provider, handler | The object that builds a section's state on the host, and the one that applies it on a client. |
| revision | The counter of one section. It rises when the section's key changes. |
| panel revision (`seqs`, an intent's `seq`) | A counter per player and panel. The host raises it when the panel offers something new, so a press made on an outdated panel can be dropped. |
| INPUT `seq` | The number of an `INPUT` message, one per physics step. The snapshot's input ack refers to it. |
| run state | The game's serialized run (`ProgressData.get_run_state()`), the same data a save file holds. |
| run part | A piece of the run state: `c` (common), `s` (the shop's own fields), `t` (tracked item effects), `g<p>` (gear of player p: weapons and items), `p<p>` (the rest of player p). |
| run cache, fingerprint, `rev` | `sync/run_cache.gd` decides when the run must be serialized again. The fingerprint is a cheap value that every game mutation moves. `rev` rises when a part's id changes. |
| net id | The host's number for a mirrored battle node (u16). |
| type table | Per battle, index to scene path. Snapshots name types by index. |
| rest | An entity that has not moved for 4 snapshots. Its position is left out of most snapshots. |
| pose, look | Extra per-entity data in a snapshot: rotating parts (`sync/pose.gd`) and lasting visual states such as burning (`sync/looks.gd`). |
| `FocusEmulator`, emulator, cursor | The game's per-player focus system on co-op screens. Each player has an emulator whose `focused_control` is that player's cursor. |
| cursor target, anchor | How a control is named on the wire: `[anchor, player, index, steps]`. The anchor is a part of a player's panel that the game hands out by accessor (see [Cursors](#cursors)). |
| virtual device | An input device id the mod invents for a remote player (`sync/virtual_devices.gd`). On a client, every slot has one. |
| slot | A local co-op player place (0 to 3). |
| carousel, page | A co-op panel has pages (shop or upgrades, gear, stats, damage) switched with the triggers. |
| borrowed DLC, parked | A client registers the host's DLC content for the session without owning it. Parked means handed back while the client is in its own main menu. |
| live menu | The pause menu opened during an online wave without pausing the game. |
| heavy section | A section with large bodies (shop, upgrades) that is held back while a peer's send queue is full. |
| meca | DLC 2 content: meca weapons, their upgrade popup and its two rolled options. |
| client view, waiting screen | `ui/client_view.gd`, shown on a client when the host is on a screen that has no copy. |
| resync | The host sends a peer its whole state again. |

## 3. Session

### Handshake

`session/session.gd`. The client resends `HELLO` every second until it gets `WELCOME`, because the
host's member list can lag behind the join and a message from a non-member is dropped. The host
answers every `HELLO`. A repeated `HELLO` from a ready peer means that the peer missed `WELCOME` and
what followed, so it gets a full resync. The transport accepts a member's message session when the
member enters the lobby and refreshes the member list for unknown senders.

### Join compatibility

`session/compat.gd`. `HELLO` carries the protocol version (`Protocol.VERSION`), the game version
(`ProgressData.VERSION`) and the mod version (`version_number` of the manifest). All three must
match the host's. A rejection carries a code (`protocol`, `game`, `mod`) with its two versions as
`args`, which the client shows in its own language (`Compat.describe`) like every lobby error (see
[Errors](#errors)), and the English `reason`, which the host logs and a client shows for a code it
does not know (a malformed `HELLO` has none). DLC ownership never rejects (see [Host DLC on clients](#host-dlc-on-clients)).

Consequence for wire changes: a build with another mod version is turned away, so a message does
not need optional fields for older builds. Builds that share a mod version (0.2.1 has covered many)
are told apart only by the protocol number, so a change that an older build would misread bumps
`Protocol.VERSION`. One body is lenient: `DamageMeter.clean` accepts a board without `time`,
`hits` and `run`, and older builds ignore `run`. Local settings (route, send rate) are not wire changes.

### Resync

A full resync re-emits `peer_ready` for that peer, at most once per second per peer. Every sync
module resends its whole state on `peer_ready`, and the state stream then resends every section. A
resync is queued when a reliable send fails (`sendMessageToUser` returns an EResult other than 1,
logged as a warning). Unreliable failures are only logged at debug level, at most one line a second.
A client asks for a resync itself with `Session.ask_resync` (another `HELLO`).

### Leaving

Leaving is role-aware (`transport.was_host`).

- A client that leaves turns puppet mode off (its own run is restored), clears the puppet slots and
  loads the title screen, unless it is already there.
- A host that leaves the lobby mid-run keeps the run. The remote players' co-op slots stay, idle, as
  with a local pad unplugged mid-run. Their steam id to device mapping is kept, so they get their
  characters back when they join the host's next lobby.
- When a remote player leaves or is removed mid-run (`peer_removed`), its slot stays too and waits
  for a rejoin. Shop and level-ups wait for the player (a game rule), which
  [absent players](#absent-players) resolves.
- While players can still join (`CoopService.listening_for_inputs`), a leaving player's slot is
  freed.

*Leave lobby* mid-run asks first. A Steam invite accepted mid-run opens the lobby page and waits for
*Join invite*. Outside a run it is taken at once. See [Lobby UI](#8-lobby-ui).

### Kick

Steam lobbies have no kick. `Session.kick` sends `KICK` (reliable) and `Transport.kick` drops the
member at once: it leaves `members` and is kept out of `_refresh_members` while listed in `kicked`,
`peer_left` and `peer_removed` fire as for a player who left, and its messages are dropped as a
non-member's. Its session is closed 3 s later (`KICK_CLOSE_MSEC`), because closing at once could
drop the `KICK`. The client leaves on `KICK` with `lobby_failed("The host removed you from the
lobby")`. `kicked` forgets the id when Steam reports it gone from the lobby, so the player can be
invited again. A game that ignores the `KICK` stays in Steam's lobby and takes a slot, but is not
listened to.

### Host DLC on clients

`session/dlc_borrow.gd`. This works like Steam Remote Play Together. All DLC content ships in the
base `Brotato.pck`. Ownership only decides registration: `ProgressData.available_dlc_ids`, from which
`ItemService.items / characters / weapons` are rebuilt, and `DLCData.add_resources()` (backgrounds,
title backgrounds, enemy data, effect scripts).

Without the host's DLC a client would lose content: `deserialize_run_state` and
`PlayerRunData.deserialize` drop DLC characters, items, weapons and shop items (`get_element_safe`
returns null) and effects with DLC effect scripts, the DLC background falls back to the first one,
and grids, item cards, panels and the shop cannot find DLC ids. Zones, enemy and boss scenes (loaded
by path), `get_dlc_data_by_id` and the run's `enabled_dlcs` / `active_update_data_ids` do not depend
on ownership.

- **Borrow.** `WELCOME` carries the host's own DLCs. On the first accepted `WELCOME`, before
  `peer_ready`, the client borrows the ones it lacks (only ids in `ProgressData.dlc_ids`). It stashes
  `available_dlc_ids`, `active_update_data`, the unlock lists that `save()` writes,
  `ItemService._tiers_data` and its id lookups, then appends the ids, calls `add_resources()` in
  `update_data_list` order and invalidates the item lists.
- **Revert.** `remove_resources()` in reverse order, the stash restored in place, borrowed music
  tracks dropped from `MusicManager.shuffled_tracks`. It runs on `lobby_left` (every way out of
  client mode) and on `lobby_ready`, before the title screen loads. `Session._process` also reverts
  when borrowed DLC exists without a welcomed client role.
- **While borrowed**, saves and challenges are blocked as in puppet mode
  (`Puppet.blocks_progress()`). `HELLO` and `WELCOME` report only owned DLC. Challenges of a borrowed
  DLC are not loaded. The lobby page's details show "Using the host's DLC for this session: ...".
- **Parked.** A client in its own main menu has the DLC handed back until the host's next screen
  (`Session.set_borrow_parked`, see [Client in its own main menu](#client-in-its-own-main-menu)).
- **DLC drops** (poisoned, meca, mutant and mutation fruit, meca parts) are not in
  `ItemService.consumables`, even for owners. `OwnPickups.find_data` also reads them from every
  `DLCData`.

### Saves and challenges on a client

`session/puppet.gd` and the `ProgressData` / `ChallengeService` extensions block a client's saves and
challenges in puppet mode, except for what the host's run earns the client (see
[Progress for clients](#progress-for-clients)). Entering puppet mode stashes what
`ProgressData.save()` persists from the run side (`saved_run_state`, `last_saved_run_state`, `data`,
`killed_enemies`, `killed_by_enemies`, `items_bought`), and leaving it restores them. This is needed
because the shop's resume path overwrites `saved_run_state` with the host's run. Unlocks and
difficulties only change in host-only code paths (run won, `complete_challenge`).
`active_update_data` is reset by the title screen's `RunData.reset()`.

### Absent players

`sync/absent_players.gd`. After 20 s without messages from a player (stale or left), the host makes
that player's pending choice the game's way: the first level-up option, taking the crate item
(recycling it if it cannot be taken), Go in the shop. The lobby page's details list absent players.
A returning player just plays on.

## 4. Transport

`net/steam_transport.gd` sends through Steam Networking Messages (GodotSteam). Messages are read
once a frame (`Transport._process`). Sends use `SEND_AUTO_RESTART_BROKEN_SESSION`, so after a broken
session the next message opens a new one.

### Steam object

Every Steam call of the mod goes to one object, `Transport.steam`. `Transport.setup(lobby_tag)`
keeps the lobby tag and hands the engine's GodotSteam singleton to
`Transport.bind_steam(steam_object) -> bool`, which:

- leaves a lobby of the object bound before and disconnects that object's signals, so binding
  again replaces the old object cleanly (binding the same object again is fine too). `null` only
  unbinds: no object, local id 0, no route or send rate claimed.
- reads the local steam id. 0 (not logged on) logs an error, connects nothing and returns false.
- connects GodotSteam's signals (`STEAM_SIGNALS`), calls `initRelayNetworkAccess`, applies the
  [route](#route) and the [send rate](#send-rate) and clears the Join button.
- on the first bind of the process that gets this far, acts on `+connect_lobby <id>`.

Why the seam: it lets another object stand in for the singleton while the transport stays as it
is. The headless tests bind a fake GodotSteam (`FakeSteam` in `session_lifecycle_tests.gd`). The
local-play dev mod ([Local play](#local-play-dev-mod), outside `src/`, never packaged) binds an
object with GodotSteam's method and signal names that carries lobby and messages between game
instances, so every line of the transport runs as in a Steam session. A player's game binds the
singleton once, at startup, as before. Outside the transport only `net/link_watch.gd` (handed the
object on each poll) and the lobby page's availability check (`transport.steam != null`) see the
object. The zip guard keeps sockets out of shipped code
([Releasing](../../../docs/releasing.md#notes)).

### Route

`Transport.apply_route` runs when the Steam object is bound (startup), before any session. It sets `P2P_Transport_ICE_Enable` to
disabled with `setGlobalConfigValueInt32`, so sessions go through Steam's relays (SDR) only.

- Launch option `+bt_direct` leaves Steam's default (direct or relayed, Steam picks). `+bt_relay` is
  accepted and has no effect.
- If GodotSteam lacks the setter or Steam refuses the value, a warning is logged and Steam's default
  stays. `Transport.relay_only` is false then.
- The setting is local. Whether one side's relay-only alone prevents a direct route is not tested,
  so `net/link_watch.gd` warns once per lobby member when a session comes up direct while relay-only
  is on.

Why relays by default: the direct route showed periodic stalls of up to seconds that the relayed
route did not (sessions of 2026-11-16 in
[Measurements](#12-measurements-and-session-findings)). Steam keeps probing the route it does not
use and re-evaluates its choice every second (GameNetworkingSockets,
`steamnetworkingsockets_p2p.cpp`). With one route left it stops evaluating.

### Send rate

`Transport.apply_send_rate` runs right after the route. It sets `SendRateMax` and `SendRateMin` to
524288 B/s (512 KB/s). Steam's default is 256 KB/s for both. The settings are looked up by
GodotSteam's names (`NETWORKING_CONFIG_SEND_RATE_MAX` / `_MIN`, ESteamNetworkingConfigValue 11 and
10; `P2P_Transport_ICE_Enable` is 104). If either value cannot be set, a warning
is logged, `Transport.send_rate` stays 0 and Steam's default applies.

- Why both values: Steam does not estimate the line. A session starts at 4380 B per round trip and
  that value is clamped to [min, max] (`steamnetworkingsockets_snp.cpp`, `SNP_ClampSendRate`).
  Nothing raises it later, so in practice the minimum is the rate. Steam's header says to set both
  to the same value.
- Why not higher: the host has one session per client, each paced at this fixed rate. With three
  clients a backlog leaves at up to 12 Mbit/s, more than many home uploads. Data beyond the line's
  speed waits or is dropped in the router, where it delays snapshots too.
- The rate only paces data that is waiting. With nothing queued it changes nothing.

Why raise it at all: see the session of 2026-11-16 in
[Measurements and session findings](#12-measurements-and-session-findings).

### Ping

`Session._process` sends `PING` once a second, unreliable. The transport answers with `PONG` where
it reads the message. Because messages are read once a frame, the raw round trip includes up to a
frame of each game and all of a stalled frame. `rtt_ms` leaves that out: the transport compares
GodotSteam's `time_received` with `getLocalTimestamp()` when the message is handled
(`Transport.held_msec`), and the `PONG` carries how long the `PING` waited (`held`). What remains is
the network and Steam's send queue. The whole time stays in `answer_ms` (shown on the lobby page as
"with frame time"). Without a plausible receive time nothing is subtracted.

### Broken sessions

`network_messages_session_failed` is logged with the reason in words (5008: P2P rendezvous failed,
and so on). A follow-up line says when the session was up again and over which path, or that it
still was not after 15 s.

### Local play (dev mod)

Host and clients as game instances on one PC, without Steam's networking. A dev mod puts a
Steam-shaped emulator under the unchanged transport (`Transport.bind_steam`, [Steam
object](#steam-object)) and links the games over TCP on 127.0.0.1. Status: the emulator, the
in-process wire, the wire between game processes, the activation rules, the launcher
`tools\play-local.ps1` ([Play locally](../../../docs/testing.md#play-locally)) with its scenario
director, the link profiles ([Link profiles](#link-profiles)), up to three clients, other builds
on one side (`-ClientRef`, `-HostRef`), DLCs per game, gamepad routing and the headless pair
tests `tools/check-pair.sh` ([Pair tests](../../../docs/testing.md#pair-tests)), which run the
same scenarios, are in.

**Layout.** `mods/brotato-together/dev/einfluffles-TogetherLocal/`, next to `src/` and `tests/`:

| File | What |
|---|---|
| `manifest.json` | Mod `einfluffles-TogetherLocal`, depends on `einfluffles-BrotatoTogether`, so it loads after it. |
| `mod_main.gd` | Activation rules; when active, builds an emulator, binds it to the transport, starts the wire, hosts or joins. |
| `local_transport.gd` | Script extension of `net/steam_transport.gd`, installed only when active: `setup` hands the transport to the dev mod instead of binding GodotSteam. |
| `steam_emulator.gd` | The Steam stand-in: lobbies, sessions, queues, pacing, connection info. No sockets. |
| `link.gd` | The line one emulator sends over: latency, jitter, loss, retransmits, line rate, stalls, relay POP changes. |
| `link_profiles.gd` | The named link profiles and the sessions their numbers come from. |
| `wire_memory.gd` | A wire for two or more emulators in one process, with a clock that moves only when told to. |
| `wire_tcp.gd` | The wire between game processes: TCP on 127.0.0.1, the host listens, clients connect. |
| `local_instance.gd` | The instance's side of the launcher: settings and `status.json`. |
| `joypad_filter.gd` | Which gamepads drive this game (`BT_LOCAL_JOYPAD`): the others are blocked in the engine's mapping. |
| `director.gd` | The scenario director: JSON commands in the instance's `control\` folder, answers in `out\`. |
| `menu_driver.gd` | Menus driven as a player drives them (keys, buttons by focus and accept), screenshots, the screen's state. The test mod's `director` suite uses it too. |
| `scenario_runner.gd` | Runs a scenario in every game of a session at once, in step: each step's answers go through the instances' `out\` folders. |
| `scenarios.gd` | The scenarios, one coroutine each, for the windows (`-Scenario`) and the headless pair tests (`tools/check-pair.sh`), and what each needs from the launcher (`LAUNCH`: clients, DLCs, another build, no join). |
| `scenario_steps.gd` | The steps several scenarios share (lobby, character selection, the selection screens, a wave into the shop, buying, quitting the run), for a host and any number of clients; `scenarios.gd` extends it. |

Nothing under `dev/` is packaged: `tools/package.sh` takes `mods/*/src/<mod_id>/` only, and the zip
guard fails on any second mod folder in a zip, also one whose manifest sits in `dev/`
(`tools/test_zip_guard.py`). The network-class check covers `mods/*/src` only, so a dev mod may use
sockets; gdlint covers `dev/` like the rest. `tools/check.sh` and `tools\check-window.ps1` mount
`dev/*/` next to `src/` and `tests/`, so the test mod preloads the emulator from
`res://mods-unpacked/einfluffles-TogetherLocal/` and every test run also checks that the dev mod
stays inert.

**Activation.** `mod_main.gd` decides in its `_init`, which the Mod Loader runs for every mod
before any mod's `_ready`. It acts only if all of these hold (`refusal()`, in this order), else it
logs one line ("Local play off: ...") and does nothing else:

1. `BT_LOCAL_ROLE` is `host` or `client`.
2. Steam is not logged on here: no GodotSteam singleton, or its `getSteamID()` is 0.
3. The game is not the Steam build: feature `steam` is absent (the Steam build's `project.godot`
   sets it; the local game copy has it removed).
4. The user folder lies under `BT_LOCAL_DIR`, the instance's folder the launcher made:
   `tools\play-local.ps1` gives each instance its own `APPDATA` in that folder
   (`<inst>\appdata\Brotato`), `tools/check-pair.sh` its own `XDG_DATA_HOME`
   (`/pair/<name>/data/Brotato`). A rule of where the folder may be, not a list of where it must
   not be: a real save folder in a place nobody listed cannot pass. The paths are compared as
   text (case and slashes aside), so a path with a `.` or `..` part is refused.

The test container's game has feature `steam` and no `BT_LOCAL_DIR`, so the dev mod refuses there
even with a role. Rule 2 asks the
game's GodotSteam, which is not initialised in a local instance and logs one engine error for it
("User class not found ... getSteamID"); stock Godot has no GodotSteam.

When active, `_init` builds the emulator (`BT_LOCAL_ID`: instance number, default 1 for the host
and 2 for a client; `BT_LOCAL_NAME`: persona name) and installs `local_transport.gd`. The Mod
Loader applies script extensions after every mod's `_init`, so brotato:together's `_ready` creates
the transport from the extended script, and its `setup` calls the dev mod's `take_transport`
instead of binding GodotSteam: the host binds the emulator right there, a client later (below).
So a local instance never logs "Steam not logged on" or "Steam transport unavailable", errors the
game would read at the next boot (it turns mods off after a logged error that names a mod). If the
extension did not apply, the dev mod binds after the transport's own `setup` as a fallback. The
launcher deletes each instance's logs before a start anyway.

Then `_ready` sets the DLCs (`BT_LOCAL_DLCS`, below), adds the gamepad filter (`BT_LOCAL_JOYPAD`,
below), starts the wire (`BT_LOCAL_PORT`, `BT_LOCAL_TOKEN`; without a port only this game, as in
the tests), adds `local_instance.gd`, titles the window "Brotato (local host: Host)" and polls
wire and emulator every frame (`PAUSE_MODE_PROCESS`). The startup line names the DLCs and the
gamepads too.

- DLCs: `BT_LOCAL_DLCS` is `none` or DLC ids of `ProgressData.dlc_ids` (comma-separated; unset or
  `all`: the local build's default, every DLC). It becomes `DebugService.owned_dlc_ids`, which
  `LocalPlatform.is_dlc_owned` asks. The Mod Loader instances the mods in its `_init`, before the
  later autoloads exist, but their nodes get `_ready` when the Mod Loader enters the tree, before
  ProgressData's `_ready` reads the DLCs (`check_for_available_dlcs`): so the setting is applied in
  `_ready`, and a warning says if ProgressData had read them already. A client without the host's
  DLC then borrows it as with Steam ([Host DLC on clients](#host-dlc-on-clients)).
- Older builds: a brotato:together from before the seam has no `bind_steam`. The dev mod then
  binds the emulator as that build's `setup` bound GodotSteam (`steam`, `local_id`, its six Steam
  signals, relay access, route, send rate, no Join button, `+connect_lobby`) and logs "a build
  without bind_steam". This is what `tools\play-local.ps1 -ClientRef` / `-HostRef` run.
- Gamepads (`joypad_filter.gd`): the engine polls XInput and DirectInput itself, so every game
  process gets every pad's input, focused or not. `BT_LOCAL_JOYPAD` is `all` (unset), `none`, or
  device numbers. A pad this game must not see is blocked in the engine's own mapping: the engine
  reads a pad's buttons, axes and hat through the SDL mapping of its GUID and drops what the
  mapping does not name, before `Input`'s state, the actions or any event. So the filter adds a
  mapping for a GUID of its own (`btlocalblockedNN`) that names no button and no axis (its hat goes
  to `misc1`, which the game binds to nothing; an empty mapping would leave the hat as the d-pad)
  and reports the pad to the engine again under that GUID (`Input.joy_connection_changed`, as a
  driver does). The pad stays connected under its own name. The engine emits
  `joy_connection_changed` deferred, so the filter counts its own reports and skips their signals;
  any other report of a blocked pad (the driver's, on a reconnect) gives it its own mapping back,
  and the filter blocks it again. `Input.get_joy_guid` answers the mapped GUID on Windows but a
  fixed text in headless Godot, so what is blocked is kept in the filter. Input that a script
  sends (`Input.parse_input_event`, the director) comes in after the mapping and is never
  filtered.

- Host: with `BT_LOCAL_AUTOHOST=1` it opens a lobby (`LobbyMenu.host()`, what the title screen's
  host button does) once the title screen is up. The lobby page's Invite
  (`activateGameOverlayInviteDialog`) sends every client an invite, which its emulator fires as
  `join_requested`: Steam's overlay invite, accepted.
- Client: binds once its wire is online and, with a launch option `+connect_lobby <lobby id>`,
  once the host's game owns that lobby (the wire's roster carries the host's lobbies). The
  transport acts on `+connect_lobby` at its first bind (`_check_launch_args`), so the client joins
  through the same code as a Steam invite that starts the game. The launcher passes the host's
  first lobby id, `0x0080000000000000 + (1 << 8) + 1`.
- The transport's `peer_joined`, `peer_left` and `lobby_failed` are logged ("Peer left: <id>"):
  the mod itself logs a leaving peer nowhere.
- `_exit_tree` closes the wire: a closed window leaves at once, as Steam reports a game that quit.

**Wire between games (`wire_tcp.gd`).** Star: the host's game listens with a `TCP_Server` bound to
127.0.0.1 on the launcher's port; each client connects with a `StreamPeerTCP` (an outgoing
connection, no socket of its own to reach). A client talks to the host's game only; a packet for
another client goes through it (the lobby can pass to a client when the host leaves it). Polled by
hand, never blocking: what a socket does not take waits in the connection's outbox.

- Frames: length (4 bytes, little endian), magic `BTLW`, wire version 1, then `var2bytes` of a
  Dictionary (read with `bytes2var` without objects). At most 2 MB; a broken frame drops the
  connection.
- Handshake: the client's first frame is `hello` with the launcher's random token (32 hex
  characters), its fake steam id and name. The host refuses a wrong token, a missing or late hello
  (5 s), a non-fake or taken id (a client that restarted replaces its old connection) and a fourth
  client, else answers `welcome`. `roster` frames give each client the others' ids and the host's
  lobbies; `invite` carries the Invite above.
- Everything else is an emulator packet; the host sets its `from` to the sender's id, so no client
  speaks for another. A connection that closes (window closed, process killed: the OS closes its
  sockets) calls `wire_lost` on the emulators that knew it, at once.
- Reliable and unreliable: the wire carries everything reliable and in order. The emulator's link
  decides loss, delay and order of unreliable messages before the wire, and loopback adds nothing
  to that.
- Why not ENet, as first planned: Godot 3's ENet client binds its UDP socket to every interface,
  whatever `set_bind_ip` says (checked with the game's engine and with Godot 3.6.2: the client's
  port showed on `::`), and Windows then offers to let the program through its firewall. Local
  play must not open anything beyond 127.0.0.1. With TCP, `Get-NetTCPConnection` shows the host's
  listener on 127.0.0.1 and connections between 127.0.0.1 ports only, and there is no UDP socket.

**The instance (`local_instance.gd`).** With `BT_LOCAL_DIR` (the instance's folder):

- Settings: the launcher seeds `settings.json` (windowed, `pause_on_focus_lost` and
  `mute_on_focus_lost` off, `on_lost_focus` 0; with two windows one always lacks focus, and the
  three keys are coupled, `menu_options.gd`). The dev mod enforces them again after ProgressData
  has loaded them (deferred: the autoloads enter the tree together and get `_ready` afterwards in
  order, so ProgressData exists before it has loaded anything). `BT_LOCAL_MUTE=1` mutes the Master
  bus. `--windowed` alone loses against `fullscreen` in the settings (`progress_data.gd`,
  `apply_settings`).
- `status.json` every second: role, pid, steam id, name, bound, the `+connect_lobby` lobby, wire
  (state, port, peers, host lobbies, frames), lobby (id, host, members), scene, fps, the
  director (commands done, the last one, screenshots taken), the settings line, `lobby_error`,
  `build` (the lobby tag), `dlcs` (the setting, `available`), `joypads` (the setting, the pads
  with `blocked`, `guid`, `mapped_guid`), and `link`: the
  profile, its main numbers, stalls and POP changes so far, messages sent, dropped and refused,
  and per peer what Steam would show (state, ping, queue time, pending bytes, both qualities,
  bytes per second out and in, relayed).

**The director (`director.gd`, `menu_driver.gd`).** With `BT_LOCAL_DIR`, every instance reads
commands from its `control\` folder: each `*.json` file is one command, `{"cmd": "<name>", ...}`,
its id the file's name without `.json`. The files are taken in name order, one at a time (a
command that waits blocks the next), and deleted when taken; the answer goes to
`out\<id>.json`: `id`, `cmd`, `ok`, `error` (why it failed), `msec`, `result` and `state`, the
screen's state after the command. The launcher names files `<UTC time>-<counter>-<cmd>`, so commands
from separate calls keep their order. Menus are driven as a player drives them: keys go through
`Input.parse_input_event` as the OS's key events come in, a button is focused and gets accept.

| Command | Fields | What |
|---|---|---|
| `press` | `key` (Godot key name: `Enter`, `Escape`, `Right`, `A`) or `action` (its first key in the InputMap), `hold_ms`, `times`, `shot`, `shot_ms` | Key down, held at least 150 ms or `hold_ms`, up. The client's input reaches the host's game in samples, so a 3-frame tap can fall between them. Joining a co-op slot needs a hold (the scenarios hold 1500 ms; the join comes after about 0.7 s). With `shot`, a screenshot of that name `shot_ms` (default half the hold) into the hold: a join's progress. |
| `button` | `name` (node name) or `text` (its text, any case) | The last shown, enabled button of that name (popups come after the scene) gets the focus and accept; one that takes no focus gets `pressed`. |
| `wait_for` | any key of the state, `timeout_sec` (30) | Until the state has every value: `scene` (the file's name, e.g. `coop_resume`, or its path), `players`, `resume_shown`, `lobby.members`; dotted keys look into nested values, numbers compare as numbers. Fails after the timeout with the state it saw. |
| `query` | | Only the state. |
| `screenshot` | `name` | The window's root viewport after the next frame is drawn, to `shots\<name>.png` (written as `.tmp`, then renamed). It reads the game's own picture, so overlapping windows do not matter; a minimised window is not drawn by the engine, so it is drawn once with `VisualServer.force_draw`. |
| `host_lobby` | `timeout_sec` | Host: what Host lobby does (`LobbyMenu.host`), then waits for the lobby. |
| `join` | `lobby` (default: the host's first lobby, from the wire's roster), `wait` (true) | Client: the emulator fires `join_requested`, as a Steam invite accepted in the overlay; waits until in that lobby, or with `wait` false answers at once (a join that may be refused; the caller looks at `lobby.error`). |
| `invite` | | Host: Invite friends (`LobbyMenu.invite`): every client's game gets an accepted invite. |
| `leave` | | Leave lobby (`LobbyMenu.leave`, as the title frame's and the lobby page's button); waits until out. |
| `set_profile` | `name` | The link profile of what this game sends from now on (`lan`, `relay-good`, `relay-typical`, `bad`, `stall`, or `none`: no latency at all), through the emulator's `set_profile`; what is on its way keeps its time. The result has the link's status. An unknown name fails and changes nothing. |
| `fail_session` | `peer` (default: every live session), `reason` (5003), `debug`, `both` (true) | The emulator's `fail_session` / `fail_sessions`: Steam reports the session as failed, at both ends unless `both` is false; the next send opens a new one. Fails when there is no session. |
| `fail_send` | `count` (1) | The next reliable send(s) answer LimitExceeded (`fail_next_sends`): on the host, the Session runs a full resync for that client. |
| `stall` | `msec` | Nothing this game sends moves for that long (`stall`); the queues keep it. |
| `debug` | `invulnerable`, `wave_sec`, `xp`, `gold` | The game's own test settings (`DebugService.invulnerable`, `custom_wave_duration`; read at run start and wave start) and, in a run, XP and gold for every player. Host. |
| `language` | `locale` (`de`, `ru`, ... of `ProgressData.languages`) | What the options' language choice calls (`ProgressData.change_language`). |
| `text` | `key`, `args` | What this game shows for a translation key with its arguments in its language now (the game's `Text.text`): a scenario's expected text in another game's language. Fails for a key no translation has. |
| `kick` | `peer` (a steam id; default every other member), `timeout_sec` | Host: what the lobby page's kick does (`LobbyMenu.kick`, `Session.kick`), then waits until the transport no longer lists the player. |
| `mod_version` | `version` (`""`: the real one again) | This game's brotato:together version from now on: the manifest's `version_number` in the Mod Loader's data, which `Compat` reads for `HELLO`, as a game with another build would have it. |
| `scenario` | `name`, `run` (the same id in every game), `peers` (instance names, default `host`, `client1`), `shots`, `timeout_sec` (900) | Runs this game's part of a scenario (`scenarios.gd`) in step with the others (below). The result has `passed`, the scenario's `lines` and the `shots`; a game that quit in the scenario closes after the answer. |
| `joypad` | `connect` (true / false), `device` (0), `name`, `guid` (`__XINPUT_DEVICE__`) | The gamepads as this game sees them (`joypad_filter.gd`'s status: per pad `blocked`, its own `guid`, `mapped_guid`). With `connect`, first a pad reported to the engine as a driver reports one; no input comes from it, it shows what the filter does with a connection. |
| `quit` | | Answers, then closes the game as its window's close button does: the others see it leave. |

The state (`MenuDriver.snapshot` plus the lobby): `scene`, `scene_path`, `paused`, `locale`,
`focus` (the focused control's name), `players` (`CoopService.connected_players`), `listening`,
`run` (`coop`, `count`, `wave`, per player `gold`, `levels`, `items`, `weapons`; `saved`: a run to
continue), `lobby` (`in`, `is_host`, `members` with this game, `id`; `details`: the lobby page's
details text; `tag`: this build's lobby tag), `session` (`ready`: peers whose handshake is done,
`peer_ready`: the Session's `peer_ready` signals so far, a handshake each and then one per full
resync, `error`: the lobby error shown last, `LobbyMenu.last_error`, also after a refused join,
`mod_version`), `dlcs` (`owned`: `DebugService.owned_dlc_ids`; `available`:
`ProgressData.available_dlc_ids`; `borrowed`: available but not owned), `ref` (`BT_LOCAL_REF`:
the other build this game runs, empty for this worktree's), `role`; on the co-op resume screen
`resume_shown` (the saved player shown), `resume_gold` and `resume_progress`; in a wave
`wave_left` and `upgrades` (the level-up or crate panels are shown). A client's copy of a screen
is the game's own scene, so its state reads the same way.

Godot's headless build never flushes the input events `Input.parse_input_event` buffers (the
desktop builds do it every frame), so in a headless game the director flushes them every frame;
the test mod does the same for its suites. The director's flush runs first in the frame
(`process_priority` -1000), as a desktop build's does at the frame's start: code that polls
`Input.is_action_just_pressed`, such as the client's pause (`PauseControl`), only sees a key in
the frame it came in.

**Scenarios (`scenario_runner.gd`, `scenarios.gd`).** A scenario is one GDScript coroutine,
`scenario_<name>(r)`, that every game of the session runs at the same time: the director's
`scenario` command, from `tools\play-local.ps1 -Scenario` (every game at once, with screenshots),
or `BT_LOCAL_SCENARIO` from the start, which `tools/check-pair.sh` sets for its headless pairs
(`BT_LOCAL_RUN`: the run id, `BT_LOCAL_PEERS`: the instance names; the game closes after its
verdict). A step, `r.on(games, command)`, names the games that act, with one command for all or
one each. Each of them runs its command through its director (`execute`, the same path as a
command file), takes the answer through JSON (as the others will read it) and writes it to its
`out/` as `scn-<run>-<NNNN>.json`; every game then reads the others' answers from their folders
(sibling folders: a game's name is its folder's name). So every game sees the same answers,
takes the same branches and comes to the same checks; a scenario may only branch or loop on
answers and counts, never on a game's own clock. `r.check` prints `  ok   ...` or fails the
scenario; a game that fails (a failed command, a check, no answer within the command's timeout
plus 30 s) writes `scn-<run>-abort.json`, so the others stop waiting at once, and its coroutine
never resumes. A game that runs `quit` in a scenario ends its part there; the others go on without
it (`host_quits`, `client_quits`). Each game prints `PAIR-TESTS: START`, its steps, the commands
with their answers, its checks and `PAIR-TESTS: PASS` or `PAIR-TESTS: FAIL <why>`, to stdout and
to the Mod Loader log. The scenarios and how to add one:
[Pair tests](../../../docs/testing.md#pair-tests).

**Launcher (`tools\play-local.ps1`).** Builds `%LOCALAPPDATA%\brotato-modtools\play\game`, a copy
of `reference/` without `mods-unpacked` and without the line `_custom_features="steam"`: the game
then picks its `LocalPlatform`, never restarts through Steam or initialises it, and the Mod
Loader's default profile reads `mods-unpacked`. It fails if that line or
`config/use_custom_user_dir` is missing. And `play\engine\BrotatoLocal.exe` with
`steam_api64.dll`, from the installed game (found through Steam's registry entry and
`libraryfolders.vdf`, `BROTATO_WORKSHOP_DIR` or `-GameDir`; only read). Under another name the
engine finds no `.pck` of its own and runs `--path`. Both copies are refreshed by a stamp (size and
time of `reference/project.godot`, of `Brotato.exe`). On each start it closes a running session,
fills `mods-unpacked` fresh (brotato:together's `src/`, the dev mod, the `-With` mods), picks a
free port and a token, and per instance: deletes its logs, seeds its settings, refuses if its user
folder would be `%APPDATA%\Brotato`, and starts the engine with `--path <game> --windowed
--resolution WxH --position X,Y` (a client also `+connect_lobby <id>`) and its own `APPDATA` and
`BT_LOCAL_*` variables (set for the child only: also `BT_LOCAL_DLCS` from `-HostDlcs` /
`-ClientDlcs` and `BT_LOCAL_JOYPAD` from `-Joypad`). With `-ClientRef` / `-HostRef` that side runs
`play\game-ref`, a copy of the game copy (refreshed with it) whose `mods-unpacked` has the commit's
brotato:together and `-With` mods (`git archive` of `mods\` into `play\refs\<commit>`, once per
commit) and this worktree's dev mod, with `BT_LOCAL_REF` (the build's name: `ref` in the
director's state). It waits until the host is bound and every client is in the lobby (or
refused: `lobby_error` in its status), then returns; `session.json` lists the processes (id and
start time) for `-Stop`, which closes the windows and ends what is left after 10 s.

Engine spike (2026-11-25): both the game's engine copy and stock Godot 3.6.2 boot the patched game
copy with the mods to the title screen (warm boot 8-10 s, a first boot after fresh files up to
46 s). Default: the game's engine (the real engine build and GodotSteam class, a release build).
Stock Godot (`-Engine godot`) is a debug build with the game's debug keys and the Mod Loader's
editor profile, and the only choice for headless runs. Zipped mods (`--mods-path`) and
`mods-unpacked` cannot be mixed, so the launcher uses unpacked mods.

**The emulator.** One `steam_emulator.gd` object is one player's Steam.

- Ids: `make_id(n)` = `0x0010000100000000 + n`. A real Steam user id has universe 1 in its top
  byte (7656119...); these have universe 0 (Invalid), so no fake id is ever a real one. Number 0
  gives steam id 0 (not logged on). Lobby ids have universe 0, type 8 and the owner's number in
  them (`lobby_owner(lobby_id)`), so a wire can route a join to the owner.
- Callbacks are queued and emitted in `poll()`, as Steam's `run_callbacks` does once a frame.
- Lobbies live in the emulator that created them. A join goes to the owner over the wire; the
  owner answers with the lobby (members, data, joinable, names) and sends every change to the
  members, which keep a copy. The owner leaving hands the lobby to the next member, as Steam does.
- Messages: `sendMessageToUser` checks, queues in the session's send queue, `poll()` paces the
  queue out with a token bucket at the send rate, or the line's rate when the profile's is lower
  (`BURST_BYTES` 4380), the link adds latency, jitter, loss and stalls, then the packet goes to
  the wire. Reliable messages keep their order (a lost one arrives `retransmit_msec` later, and
  the ones after it wait); unreliable ones can be dropped or overtake. The receiver stamps
  `time_received` from its own `getLocalTimestamp()`.
- Lobby traffic and session control (join, lobby updates, accepted, close, fail, refused) reach
  the wire after the link's latency without jitter, loss or stalls: Steam's servers carry them,
  not the session. Without latency they go at once, as before. A delayed join the wire then
  cannot carry answers "no such lobby".
- Sessions: the first message to a peer opens one. The receiver holds its messages and fires
  `network_messages_session_request` until `acceptSessionWithUser` (or a send to that peer, which
  accepts too); then both sides are connected. A session nobody accepts fails at the sender after
  `accept_timeout_msec` (10 s, reason 5003). `closeSessionWithUser` closes the peer's side as well
  (state 4, reason 1000). A broken session answers NoConnection unless the send has
  `SEND_AUTO_RESTART_BROKEN_SESSION`, which opens a new one.
- Path: relayed unless both sides allow ICE (`setGlobalConfigValueInt32` with
  `P2P_Transport_ICE_Enable`), so the transport's relay-only on either side relays the session,
  shown with the fake POP `lcl`.

GodotSteam calls of the mod and what the emulator does with them:

| GodotSteam | Emulator |
|---|---|
| `getSteamID`, `getPersonaName`, `getFriendPersonaName`, `get_godotsteam_version` | fake id, persona from `_init`, names learned with the lobby (`[unknown]` otherwise) |
| `initRelayNetworkAccess` | counted (`relay_inits`) |
| `setGlobalConfigValueInt32` | send rate min / max (pacing uses min, capped by max), ICE on or off; every value in `config_values` |
| `createLobby`, `joinLobby`, `leaveLobby` | as above; join answers: 1 success, 2 no such lobby, 3 not joinable, 4 full, 5 no wire |
| `getLobbyOwner`, `getNumLobbyMembers`, `getLobbyMemberByIndex`, `getLobbyData`, `setLobbyData`, `setLobbyJoinable` | from the lobby or its copy; only the owner sets |
| `lobby_created`, `lobby_joined`, `lobby_chat_update` | from `poll()`; chat states 1 entered, 2 left, 4 disconnected (a game gone from the wire) |
| `join_requested` | `fire_join_requested(lobby_id, friend_id)` |
| `activateGameOverlayInviteDialog` | recorded (`invite_dialogs`) |
| `setRichPresence`, `clearRichPresence` | recorded (`rich_presence`, `presence_log`) |
| `sendMessageToUser` | real flags and channels; results 1 OK, 3 NoConnection (no wire, broken session without restart flag), 8 InvalidParam (no id, own id, negative channel, over 512 KB), 25 LimitExceeded (send queue over 512 KB) |
| `receiveMessagesOnChannel` | per channel, up to the maximum; `payload`, `size`, `identity`, `channel`, `flags`, `message_number`, `time_received` |
| `getLocalTimestamp` | the emulator's clock plus its own origin (another one per emulator) |
| `network_messages_session_request`, `acceptSessionWithUser`, `closeSessionWithUser` | as above |
| `network_messages_session_failed` | reason, remote id, state 5, debug text: `fail_session(remote_id, reason, debug, both_sides)`, a session nobody accepts (5003), a peer gone from the wire (4001) |
| `getSessionConnectionInfo` | state, end reason and debug text, relayed flag and POP (`lcl`, `lcx` after a POP change), ping, send rate (the configured one, also on a slower line), pending reliable / unreliable bytes, unacknowledged reliable bytes in flight, queue time (at the rate the line carries), local and remote quality, packets and bytes per second out and in |

Control (not GodotSteam): `attach_wire(wire)`, `poll()`, `set_link({...})` (link.gd's keys) and
`set_profile(name)` for what this side sends, `seed_link(seed)`, `stall(msec)`,
`fail_session(...)`, `fail_sessions(reason, debug)` (every live one), `fail_next_sends(count,
result)`, `fire_join_requested(...)`, `wire_lost(remote_id)`, `send_rate()`,
`is_relayed(remote_id)`, `link_status()` (for `status.json`), and the clock (`clock.now_usec()`, a
real one by default).

#### Link profiles

Each emulator's `link` (`link.gd`) is the line for what that game sends, so a profile is one
direction: the launcher gives every game the same one, and switching one game changes only its
way out. Settings: `latency_msec` (one way), `relay_latency_msec` (more on a relayed session),
`jitter_msec` (+- per message), `loss` (an unreliable message is dropped, a reliable one comes
`retransmit_msec` later per loss, retransmits can be lost too), `line_rate` (B/s the line carries;
0: Steam's send rate), `stalls` (kinds of burst stalls: every `[min, max]` msec, a `chance` per
turn, `[min, max]` msec long; nothing this side sends moves meanwhile, the queues keep it) and
`pop_switch_msec` (the relay POP alternates between `lcl` and `lcx`). Jitter and loss draw from
one random stream, the stall and POP schedule from another, both seeded by the instance number,
so when a stall comes does not depend on how much is sent.

The profiles (`link_profiles.gd`), with the sessions of
[Measurements](#12-measurements-and-session-findings) they are taken from:

| Profile | Steam ping (relayed) | Jitter, loss | Line | Stalls, POP | Source |
|---|---|---|---|---|---|
| `lan` | 2 ms | none | Steam's rate | none | no session: the floor of a wired LAN |
| `relay-good` | 26 ms (8 + 5 one way) | 2 ms, none | Steam's rate | POP change every 10 min | 2026-11-16, two players relayed via fra for 8 waves: no network stall, one POP change; direct ping on the same lines 15 to 18 ms, the relay's 10 ms estimated |
| `relay-typical` | 40 ms (12 + 8) | 6 ms, 0.5 % | Steam's rate | 150 to 300 ms every 1 to 2 min | the stall tests' client (Steam ping 25 ms) through a relay; the three-player session of 2026-11-16, whose gaps were almost all scene changes; loss never logged, assumed |
| `bad` | 200 ms (70 + 30) | 25 ms, 3 % | 64 KB/s | 300 to 800 ms every 4 to 10 s; POP change every minute | the worst of each measurement, more often: the three-player session's backlogs (20 to 250 KB, pings of about 1 s), a slow upload ([Send rate](#send-rate)), the direct route's stalls (300 to 500 ms), a POP change; loss assumed |
| `stall` | 16 ms (8 + 0) | 2 ms, none | Steam's rate | 300 to 500 ms every 20 to 50 s, and 0.5 to 3.3 s on a 12 s beat (0.44 a beat) | the direct route of 2026-11-16 as measured (22 long stalls in 10 minutes) |

`none` (and no `BT_LOCAL_PROFILE`) is no latency at all, the emulator's default. The ping is the
sum of both sides' one-way base latency (each side's packets carry its own), without jitter or
queue, as Steam reports it.

What each shows in the host's log ([Diagnostics](#11-diagnostics)):

- `lan`: the first path line per member ("relayed via lcl (Steam ping 2 ms)") and nothing else
  from the network: the baseline for a change that should stay quiet.
- `relay-good`: as `lan` with a realistic ping (the lobby page's ping and "with frame time"), and
  after 10 minutes one path line for the POP change.
- `relay-typical`: now and then a short stall: a gap line ("held up on the way") at most every
  minute or two, a Slow answer when a PING falls into it.
- `bad`: every line: path changes ("relayed via lcx (peer's POP lcl)"), Slow answers with
  Steam's numbers and "; reliable in the last 2 s: ...", "Reliable burst to ..." when the shop's
  states back up on the 64 KB/s line, input gaps on the host and snapshot gaps on a client after
  each stall, and lower quality values. The game stays playable but visibly behind.
- `stall`: the direct-route stalls: gap lines of 300 ms to 3.3 s, the long ones about every
  half minute, and the render delay and prediction riding out the short ones.

Switching at run time: `set_profile(name)` (the director's `set_profile`, launcher `-Profile
<name> -On <instance>`) applies to what is sent from then on. What is on its way keeps its time:
an unreliable message sent after a switch to a faster profile overtakes, a reliable one waits for
the reliable ones before it. The stall and POP schedule starts again with the new profile.
`link.bring_forward(now, msec)` moves every scheduled stall and POP change to at most msec from
now, for tests.

Failures on command: `fail_next_sends(count, result)` makes the next reliable sends answer
LimitExceeded (25) or another EResult: the transport reports `send_failed`, and on the host the
Session queues a full resync and runs it ("Full resync for ..."). `fail_sessions(reason)` fails
every live session at both ends with Steam's end reason (default 5003): the transport logs the
failure, and after the next message link_watch logs "Session with ... up again ... after it
failed: relayed via lcl". `stall(msec)` stalls the line now. The director's `fail_send`,
`fail_session` and `stall` call these (launcher `-FailSend`, `-FailSession`, `-Stall`).

Quality and rates: `remote_quality` is the share of this side's transmissions that arrived (a
reliable message lost twice is three transmissions, one arrived), `local_quality` the same for
the peer's transmissions, as its packets report it. Both are -1 until connected and counted once;
after that a second's counts make a new value once 20 or more transmissions weigh in, each
second's counts half as much in the next. Packets and bytes per second out and in are the last
full second's, by GodotSteam 3.x's names (`packets_out_per_second`, `bytes_out_per_second`, ...);
the mod does not read them, `status.json` shows them.

**Wires.** A wire has `send_packet(packet: Dictionary) -> bool` (false: the peer is unknown or
gone) and hands what arrives to the target's `receive_packet(packet)`; when a peer's game is gone
it calls `wire_lost(remote_id)` on the others. Packets are dictionaries of plain values with `k`
(kind: `msg`, `accepted`, `close`, `fail`, `refused`, `join`, `join_fail`, `leave`, `lobby`),
`from` and `to`, safe for `var2bytes`. `wire_memory.gd` carries them within one process through
`var2bytes` / `bytes2var` and gives all its emulators one manual clock (`step(msec)` moves it and
polls every emulator by steam id), so a test runs the same every time.

Not there yet, or simplified:

- Gamepads are not routed per window yet: play with keyboard and mouse. The director presses keys
  only (no mouse, no pad).
- Steam's real ordering races between lobby updates and messages are not injected: both take the
  same base latency.
- Nagle (`SEND_NO_NAGLE`) is not modelled. A stall holds messages, not lobby traffic. A long stall
  never times a session out (Steam would after 10 s); `fail_sessions` does that on command.
- The profiles' loss and the relayed pings of `relay-good` and `relay-typical` are assumptions:
  no session logged them.
- A lobby whose owner left keeps the first owner in its id, so a later join finds no lobby.

Tests: the suites `emulator` (the emulator on the memory wire), `emulator_transport` (a real
`Transport` and `Session` per player, bound to emulators: hosting, joining, HELLO / WELCOME,
messages both ways, send results down to the full resync, leave, kick, a game that is gone, a
failed session and its restart, another version's lobby tag) and `emulator_wire` (`wire_tcp.gd`
with real sockets on 127.0.0.1 in one process: framing, token, roster, join, messages, relay
through the host, a client and the host leaving; every dev mod script compiles) and
`emulator_profiles` (each profile's ping, both directions, the stall profile over two minutes,
the line rate, loss and quality, rates, lobby latency, switching, forced failures; then a real
`Transport` and `Session` per player under `bad` and `lan`: under `bad` the host's path change,
Slow answer, traffic and gap lines and a full resync after a forced failed send, under `lan` none
of these lines). That last part keeps real time at or behind the emulators' clock, because the
Session times with `OS.get_ticks_msec()`: a delay the profile makes is then certain to show, and
about 9 s of the suite are this wait. The suite `director` runs the director in one process:
command files and answers, keys and buttons, the state and its matching, and the link commands on
a real emulator.

## 5. State stream and run state

### State stream

`sync/state_stream.gd`. Message `STATE = [section, revision, body or null]`. It is one ordered,
reliable stream of host state in fixed sections. The section number is the apply order on a client
and the send order of a resync: sections that build controls come before the cursors and scroll
positions on those controls.

| # | Section | Provider (host) | Handler (client) | Check interval | Pending timeout | Body |
|---|---|---|---|---|---|---|
| 0 | `shop` (heavy) | `ShopSync` | `ShopSync` | 0.1 s | 10 s | see [Shop](#shop) |
| 1 | `upgrades` (heavy) | `UpgradesSync` | `UpgradesSync` | 0.1 s | 30 s | see [Level-up and crate panels](#level-up-and-crate-panels) |
| 2 | `menu` | `MenuSync` | `MenuSync` | 0.1 s | 10 s | see [Selection screens](#selection-screens-and-end-of-run) |
| 3 | `menu_grids` | `MenuSync` | `MenuSync` | 0.1 s | 10 s | the grids' elements and, where needed, the run state |
| 4 | `retry` | `RetrySync` | `RetrySync` | 0.1 s | 30 s | see [Retry prompt](#retry-prompt) |
| 5 | `pause_battle` | `BattleHost` | `BattleClient` | 0.1 s | 30 s | who paused the battle |
| 6 | `pause_shop` | `PauseControl` | `ShopSync` | 0.1 s | 10 s | `[paused, by, by_id]` while the host is in the shop |
| 7 | `pickups` | `PickupList` | `PickupList` | 0.1 s | 30 s | picked-up crates in the HUD |
| 8 | `damage` | `DamageMeter` | `DamageMeter` | 0.5 s | 10 s | the damage board |
| 9 | `cursors` | `FocusSync` | `FocusSync` | 0.05 s | 10 s | every player's cursor |
| 10 | `scrolls` | `ScrollSync` | `ScrollSync` | 0.1 s | 10 s | every panel's scroll positions |
| 11 | `input_types` | `InputTypes` | `InputTypes` | 0.1 s | 10 s | the device type of every slot's key hints, `you` (see [Key hints of other players](#key-hints-of-other-players)) |

**Host.** A provider answers three calls:

- `state_key(section)` returns a text, or "" when the section is inactive. It is checked every
  interval and should be cheap.
- `state_body(section)` is built only when something goes out.
- `state_patch(section, steam_id)` (optional) is merged into a copy of the body per peer, for
  example `you`, the peer's own player index.

A key change bumps the section's revision and sends the body to every ready peer. A section that
turns inactive sends null once. `flush(section)` runs the check in the next idle frame, and
`flush(section, true)` also holds the section until then, for game code that runs deferred (for
example a shop purchase). `mark_dirty` resends without a key change. The optional
`state_sent(section, steam_id)` runs right after each send to that peer. The stream does nothing
while not host, and it runs while the tree is paused.

**Cursors after the gear they name.** `cursors` is checked every 0.05 s, `shop` and `upgrades`
(`StateStream.BUILDERS`) every 0.1 s, and those two can be held (a flush with hold, or Steam's
queue, see below). An item that comes in before a resting cursor changes both in one frame, and a
client resolves the cursor on the rows it has. So when the cursors' key changed, the stream waits a
frame while a builder is held for deferred game code, and first checks a builder not checked this
frame yet, ahead of its interval, so that its change goes out first. A peer a builder still owes a
state (in its dirty set: held by Steam's queue, or marked dirty) gets the cursors with a later
check. No wire change; the cost is one extra builder key per cursor move.

**Resync order.** On `peer_ready` every section is queued for that peer, in section order, for the
stream's next step. What the other modules send from their own `peer_ready` handlers
(`BATTLE_START`, the input device behind `you`) therefore reaches the peer before any `STATE`. The
queue is needed because of the signal order (see [Overview](#1-overview)): the stream is created
before the modules, so its handler would run first.

**Client.** A handler implements `apply_state(section, body, revision) -> bool`.

- Returning false keeps the newest body of the section pending. It is retried every frame, in
  section order, until it applies, is replaced or cleared, or its timeout passes. `retry()` tries at
  once (for example on `battle_entered`).
- A null body calls the optional `clear_state`.
- A revision lower than the last received one is dropped. An equal one is applied again (a resync),
  so handlers must be idempotent.
- The optional `accept_state(section, body, revision)` runs once for every body that is not stale,
  as it arrives and before it becomes pending. The run parts are stored there, because a pending
  body that a newer one replaces is never applied.
- A handler that returns anything but a bool loses its body. The other sections go on.
- Only the host's messages are accepted. `lobby_left` drops everything.

Tests step the stream by hand (`step`) and pass `message_for(section, steam_id)` to `receive`
(`state_stream_tests.gd`).

### Backpressure for heavy sections

A message handed to Steam cannot be withdrawn, so quick successive changes of a large state would
queue full states behind each other (see the session of 2026-11-16 in
[Measurements](#12-measurements-and-session-findings)). `shop` and `upgrades` are therefore
registered as heavy (`register_provider(section, provider, interval, heavy)`).

When a heavy section sends a body, the stream asks `Transport.connection_status(peer)` once per
target peer and sends only to peers with at most `HOLD_BYTES` (24 KB) of reliable data pending. A
peer over the limit stays in the section's dirty set. The next check tries again, and the peer then
gets the revision current at that time: one message for all the changes it missed. Its run parts are
right, because the provider builds and records the patch only for peers actually sent to.

Never held: a null body, a light section, a peer that has waited `MAX_HOLD_MSEC` (2 s), and a peer
Steam has no numbers for. A resync target is held the same way.

A held shop state reaches that peer after lighter sections sent meanwhile (`pause_shop`), but not
after changed cursors: those wait for it (see [State stream](#state-stream)). Even so a cursor is
named so that the order does not matter for it: a gear element by its item, which resolves to
nothing (the body stays pending) while the client's rows lack it, and the shop's item controls are
the same nodes before and after a shop state. Shop and upgrades never overtake each other for a
peer, because both go through one `RunParts.Sender` record.

When the section closes, the host logs one line per client that was held, for example "Shop state
held 3 times for X, longest 2001 ms (Steam's queue over 24 KB)".

### Run state serialization

`sync/run_state_codec.gd`. The run state travels the save-file path. The host calls
`ProgressData.get_run_state()`, `ProgressDataLoaderV3.serialize_run_state`, `JSON.print` and zstd.
The client calls `JSON.parse`, `deserialize_run_state` and `RunData.resume_from_state`. The JSON
step is required: the game's deserializers expect string keys and float numbers.

Three things the game does not do by itself:

- **NaN and infinite numbers** (`sync/finite_json.gd`). Godot's `JSON.print` writes them as `nan`,
  `inf` and `-inf` on Linux, and as `nan`, `1.#INF` and `-1.#INF` on Windows (the scan also knows
  the other msvcrt forms `1.#IND`, `1.#QNAN`, `1.#SNAN`). `JSON.parse` rejects all of them (error
  43), so the client loses the whole text. The
  game can make them (a stat divided by a stat gain of 0, for example), and its own save file has
  the same problem. Every JSON text the host sends goes through `FiniteJson.to_text`: the run
  parts (`RunCache.refresh`, `RunParts.entry`), `RunStateCodec.encode_json` (battle start, menus)
  and a crate item's JSON. It looks for such a value in the printed text with two `find` calls (a
  bare token after `:`, `,` or `[`; one inside a string such as "banana" is none). Only on a hit
  it walks the value, replaces each NaN or infinite float with 0 in a copy, logs a warning per
  path (`p1.effects.stat_luck`, at most once a minute per path, at most 3 lines and a summary
  line per print, at most 256 paths remembered) and prints the copy. `RunData` keeps its values. The check costs about 0.5 ms on the parts of a late test run (334 KB of JSON),
  against 10 ms for their `JSON.print`, and only parts whose hash changed are printed at all.
- `RunStateCodec.apply` resets `RunData`'s item-count caches before `resume_from_state`. The game
  only refreshes them when an item is added or removed, and `LinkedStats` reads them.
- **Effects' custom args** (`sync/effect_args.gd`). `Effect.get_text` adds an effect's custom args
  (`_add_custom_args`: burn chance, burning, turret, fire puddle, carbon bow, temporary stats per
  interval) the first time its description is shown, and `serialize()` writes them. Effects are
  shared resources, so a tooltip shown on the host would change the serialized gear of every player
  who owns that effect. `RunStateCodec.serialize` therefore gives every effect its custom args first
  (`EffectArgs.settle(state, true)`). A client marks the effects it deserializes as having them, so
  its own tooltip does not add them a second time.

### Change detection (run cache)

`sync/run_cache.gd`, one instance per screen (shop, level-up panels, battle start). Serializing the
whole run on every check is too slow for late runs, so the cache serializes only when the run can
have changed:

- **Fingerprint.** A value built from cheap reads whose cost does not grow with the item lists and
  that every mutation the game makes moves: offered and locked items by instance and wave value,
  reroll and steal counters, per player gold, meca parts, health, level, xp, ban tokens, item count
  and the last item's instance, weapon instances, the sizes of the other lists (banned items,
  upgrades, mutations, sets, effects), and wave, endless, bonus gold, retries, background and
  challenges. `RunData.tracked_item_effects` (four dictionaries of about 93 small counters) goes in
  as its `hash()`, by content: the battle goes on under the level-up panels, and a pet such as
  Bot-O-Mine's counts its mines there (`add_tracked_value`), which left alone filled the host's log
  with safety net warnings. Each screen adds its own values (`ShopSync.shop_args`; for the panels
  the option each panel processes, its crate item, rerolls and done). Fingerprints compare with
  a NaN equal to a NaN (`RunCache.same_values`): a NaN xp would else make every check serialize.
- **Force.** The check after an applied intent (`force()`) and after `peer_ready` serializes in any
  case.
- **Safety net.** Every second, while a peer is ready, the run is serialized without `JSON.print`
  and the dictionary's `hash()` is compared. A change found while the fingerprint stayed the same (a
  stat or effect written directly, for example by another mod) is logged as a warning and sent. The
  warning names what changed: `RunCache.miss_paths` and `RunParts.changed_paths` list the paths whose
  hash differs, 4 levels deep, at most 6 ("shop run state changed without a change of its
  fingerprint: g0.weapons[0].dmg_dealt_last_wave, p0.effects.stat_max_hp; sent").

The cache keeps text and ints only. It is dropped when its screen closes and on `lobby_left`.

### Run state in parts

`sync/run_parts.gd`. A run change sends only the parts of the run that changed, and only to peers
that lack them.

- **Split.** `RunParts.split` cuts the serialized dictionary into `c` (everything but
  `players_data`, which is replaced by its size), the parts of their own of `RunParts.OWN_PARTS`,
  and per player `g<p>` (`{weapons, items}`) and `p<p>` (the rest of the player, with weapons and
  items kept as null so that `join` puts them back in place). The parts of their own hold keys
  that move more often than the rest of `c`, kept as null in `c` the same way: `s` the shop's own
  fields (`shop_items`, `reroll_count`, `paid_reroll_count`, `initial_free_rerolls`,
  `free_rerolls`, `item_steals`, `locked_shop_items`), which every reroll, buy, lock and steal
  changes, and `t` `tracked_item_effects`, which items count in the shop and pets during the
  battle under the level-up panels. Both are always there (`{}` when the run has none of their
  keys). A part's id is `[hash(), length of its JSON text]`. `join` is the inverse; it and
  `state_for` put `s` and `t` back through `Store.put_back` and give no run at all when one is
  missing, so that no shop item or tracked value is dropped silently.
- **Host.** After a serialization `RunCache.refresh` splits and hashes each part. Only a part whose
  hash changed is printed and compressed. One `RunParts.Sender` (created in `mod_main.gd`, shared by
  `ShopSync`, `UpgradesSync` and `BattleHost`) records per peer the ids it was last sent.
  `state_body` offers the cache, `state_patch` puts in the parts whose id differs from that peer's
  record (`run_for`), and `state_sent` commits them. A run in which nothing differs goes as `{}`.
- **Forget.** `forget(peer)` makes the next send full. It runs on each provider's `peer_ready`, on
  `peer_removed` and on `lobby_left`, so a resync, a late joiner and a failed reliable send all get
  every part. `forget` is idempotent per idle frame, because a commit between the two providers'
  `peer_ready` calls must survive (signal order).
- **Client.** One `RunParts.Store` for all sections. `accept_state` keeps the compressed parts by key
  and id (the last two versions of each key) and fills in the ids of a `{}` run. A body that names a
  part the client has neither stored nor been sent logs a warning, asks the host for a resync and
  applies nothing. `state_for(ids)` decompresses and parses only parts it has not parsed. It runs
  `deserialize_run_state` on a deep copy of `c` with `s` and `t` put back (the game writes into
  its input) whose `players_data` holds only the players whose parts changed, and puts the
  previous `PlayerRunData` objects back for the others. `changed_players()` and `gear_changed(p)`
  name what moved.
- **Unreadable part.** A stored part whose JSON does not parse (a host without `FiniteJson`) is
  marked as such: one warning with its key, id and the parse error, and it is never parsed again.
  A resync would not help (the host sends the same text), so the sections keep the run they have,
  as if it had not changed (`Store.has_unreadable`): the level-up panels and an open shop apply
  the rest of the body. A shop that is still to be entered has no run to keep and drops the body
  as before. An end-of-run screen whose run (`RunStateCodec`) does not parse shows the client's
  own run state when it has the host's players (`MenuPuppet._keeps_run`). Until 2026-11-23 the
  panels then showed nothing at all.
- **Kept items** (`Store._kept_items`, issue #110). A changed player keeps the item objects of its
  previous `PlayerRunData` whose dictionary in the `g` part hashes the same (all of them when only
  `p<p>` moved); only the others go through `deserialize_run_state`. A crate item then deserializes
  one item instead of ~250. Weapons are always deserialized (few, and the player's effects are
  resolved against them). No item is kept when the old part is no longer stored or the old objects
  no longer line up with it index for index. `timed_state(ids)` is `state_for` with the client
  report's marks (run parse, deserialize); every section uses it.

Ids are content hashes, so parts carry over between screens: the shop's first state after the panels
sends little more than `c` and `s`. A purchase sends `s`, `p<p>` and `g<p>`, a paid reroll `s` and
`p<p>`, a lock `s`, a level-up choice `p<p>` only, and a tracked value (a mine laid by the
Bot-O-Mine pet under the level-up panels) `t` only. Either of the first two also sends `t` when an
item counts what it saved (coupon, spyglass), and a purchase `c` when it completes a challenge.
Until 2026-11-22 `s` and `t` were in `c`, and `c` (with every player's offered items) went out
with nearly every shop state.

When the shop or the panels close, the host logs one line per screen, for example "Shop 40: 28
states, 20 with run parts (501.9 KB: c 11, g0 5, ...), 8 view only (5.3 KB), largest 110.5 KB"
(`Sender.close`).

## 6. Battle

### Start and freeze

`sync/battle_host.gd`, `sync/battle_client.gd`.

1. The host sends `BATTLE_START` with the battle id, the run state (in parts), the type table, the
   player colours, the hole layout and every player's weapon slots. The wave's unit scenes, the
   players' projectile scenes, gold and `explosion.tscn` are in the type table from the start, so
   clients `load()` them while the scene loads and not mid-wave. Later types arrive as `TYPE_DEF`.
2. The client applies the run and loads `main.tscn` itself. `main.tscn` spawns players from
   `CoopService.connected_players`, so the client fills one slot per host player first.
3. The client freezes the scene right after `main._ready()`, before the first physics frame
   (`BattleClient._freeze`). The hooks are `SceneTree.node_added`, connected only from
   `BATTLE_START` until the scene is ready, and the scene's `ready` signal. Freezing means:
   `main.set_process(false)` (pause and aim), processing off for the wave manager, entity spawner,
   effect behaviours and stats manager, every Timer `timeout` connected to `main` disconnected
   (found with `get_incoming_connections()`), and the players turned into puppets.

Ordering cases the client handles, because two reliable messages can arrive in one frame after a
hitch and `change_scene` instances at once but swaps deferred:

- A `BATTLE_START` for the battle the client is in or is loading only adopts the type table, slot
  and pause. A resync mid-wave does not reload the scene.
- A `BATTLE_START` for another battle while a scene loads is queued until that scene is ready and
  frozen.
- A scene that becomes ready after its battle ended is frozen all the same.

Other details:

- **Bullet-hell waves.** `main._ready` adds its own generator (a random pattern) on the client too.
  `_freeze` frees it. The host's bullets arrive as puppets.
- **Boss parts.** Clients spawn in snapshot order and the host lists `bosses` first. A
  `BrachiosaurusFoot` waits until a "Brachiosaurus" puppet exists, because its `_ready` finds it by
  name. While puppeting, extensions skip the foot's `shoot()` and
  `StayEdgesOfMapMovementBehavior.move_away()` (called by the foot's `_ready` on its boss, and it
  needs `init()`, which puppets never run).

### Run state at battle start

The run in `BATTLE_START` goes through the shared `RunParts.Sender`, with a `RunCache` of its own.
It is sent directly, not through the stream: `_send_battle_start` offers the cache, puts in
`run_for(peer)` and commits at once.

The run sent is the one the battle scene entered the tree with (taken on `SceneTree.node_added`,
connected between battles only, while a peer is ready). The reason: `main._ready` starts the wave,
which sets every player's health to its start value (`hp_start_wave`, `hp_start_next_wave`) and
writes it into the player's part. The client's own `main._ready` does the same to the run it gets.
So the client runs the wave start once, like the host, and after a shop usually only `c` and `s`
have changed. A player's parts are sent only when Go took one of its items (hourglass, lifeform scanner,
`BaseShop._on_GoButton_pressed`).

- A peer that becomes ready mid-wave gets the run as it is then (`forget` first, then every part).
- A battle the host loaded with nobody ready serializes when the start is built.
- The candy bag's random stats at wave start (`gain_random_primary_stats_on_go_to_next_wave` in
  `main._ready`) are rolled on each machine, so a client shows its own roll until the next state
  with that player's parts (level-up panels, shop) brings the host's.

Client (`sync/battle_run.gd`): `take` ingests the parts as the message arrives, also for a start
that is only adopted or queued, so the store sees every body in the order the host sent it. A
missing part asks for a resync and the start is dropped. A queued start keeps its ids and runs
`state_for` when its turn comes.

### Snapshot format

`sync/snapshot.gd` holds the byte layout in its header. It is not repeated here. Design points:

- Snapshots are hand-packed little-endian bytes, sent unreliably 30 times a second
  (`BattleHost.SNAPSHOT_HZ`).
- Parsing is strict (bounds, counts, NaN, ASCII names, no trailing bytes). A malformed snapshot is
  dropped whole.
- **Sparse data.** A resting entity (unmoved for 4 snapshots: gold, structures, idle units) leaves
  out its position except in every 15th snapshot, staggered by id. Player HUD stats are sent for 4
  snapshots after a change and in every 10th. `Snapshot.resolve` fills both from earlier snapshots
  and builds the id to index map used for interpolation. A resting entity the client never saw is
  skipped until its refresh.
- **Events** are capped at 48 per snapshot. `HitNumbers.select_events` drops second copies of
  enemy damage numbers first, then duplicate sounds, enemy damage numbers (normal hits before
  crits, kills, one-shots and gold hits), sounds, numbers on players, explosions and the like, and
  animations and the state events last. Damage and heal numbers left out wait for the next
  snapshots ([Damage and heal numbers](#damage-and-heal-numbers)); everything else left out is lost.
- A one-shot event that is older than 250 ms when its turn comes (a stall, a scene load) is dropped.
  Animations and the state events are kept.

### Entities and net ids

Mirrored nodes are the entity spawner's lists (`bosses`, `enemies`, `neutrals`, `structures`,
`pets`), projectiles, gold, consumables, spawn markers, puddles, single holes and dig sites.

- **Net ids** are u16, wrap, and skip ids alive in the last snapshot. An id is assigned on the
  `EntitySpawner.*_respawned` signals (fired on every spawn, pool reuse included) and kept by the
  entity's first snapshot (`_fresh_ids`), so a hit that lands before that snapshot targets an id the
  clients will see. The same signal connects a unit's `took_damage`, so such a hit (one in the
  spawn tick) has its number. A node absent from the last snapshot gets a new id. The id is
  dropped on `tree_exiting`: the game's pools take nodes out of the tree and are LIFO, so a
  projectile or gold can be pooled and reused between two snapshots.
- **Types.** A type is the node's `filename`, sent once per battle. Some types carry a tag after
  `#` (spawn markers, puddles, see below).
- **Records.** The host keeps `[net id, type idx, kind bits, node, quantized x / y, still count]`
  per mirrored node (`BattleHost._record`), the client the kind bits of each puppet
  (`BattleClient._kind_of`). The per-snapshot and per-frame loops read those records and do not ask
  every node what it is. A record is dropped when its node leaves the tree or is respawned.
- **Client.** A puppet that did not move is not moved. An entity that moves faster than 6000 px/s is
  snapped, not interpolated. An id that comes back with another type is respawned. Puppets of
  non-Entity scenes (projectiles, gold, consumables) are pooled per type like the game's Entity
  pool, out of the tree, and freed when the battle state resets.
- **Prepared puppets** (`sync/warm_pools.gd`). Instancing an enemy or an explosion makes the
  graphics driver wait for the GPU once in the frame it happens in. The cost comes with the first
  `CPUParticles2D` the frame instances (every unit has `unit_burning_particles.tscn`), and the
  instances after it in the same frame are cheap. On a fast PC that is about 3 ms. On a slower one
  with frames queued it reads as a frame of 57 to 100 ms. A new main scene starts with empty pools,
  so at a wave's start nearly every frame with a new enemy paid it. In the frame that loads the
  battle scene, the client now makes the units, explosions and hit effects the battle will likely
  need and puts them into main's pool, the way the game pools them (into the tree once,
  puppetized, then out of it; effects as `EffectsManager.play` makes them). It also derives the
  pose layout of every type there, which instances the scene once.
  - **How many of a scene:** what the last battle with it used (made here and taken, plus
    instanced during it). Made but unused ones halve each battle. A scene no battle used yet: 6 of
    an enemy type that is not a boss, 4 of an explosion, none of anything else. Effects: a fixed
    number per `EffectsManager` export.
  - **Limits:** at most 40 of a scene and 200 in all, smaller counts first, so a horde cannot take
    the explosions' share. A scene under several type indices (a cursed and a normal structure)
    counts once.
  - **Which scenes:** the battle's types at that moment (BATTLE_START's, and TYPE_DEFs that came
    during the load) and scenes an earlier battle used, whose TYPE_DEF comes later. Not a boss part
    whose boss is missing, and nothing while another BATTLE_START waits to replace the scene.
  - **Measuring:** the GPU wait does not exist headless. The suite `wave_start` measures it with
    `tools\check-window.ps1 -Suites wave_start` ([docs/testing.md](../../../docs/testing.md#with-real-graphics)).

### Puppets

`sync/puppet_entity.gd`. A puppet has `propagate_call("set_physics_process", [false])`, body mode
`MODE_STATIC`, no collision layers and all `Area2D` monitoring off. Idle processing (animation
players) stays on.

- `update_animation(motion)` is called with the interpolated motion for players and pets, which
  switch their animations in it. For enemies, neutrals and structures it only faces the motion,
  which the host's facing flag decides, so it is not called.
- All timers are paused, except a unit's `FlashTimer` and a `UIProgressBar`'s timer. Their timeouts
  only put the sprite's material and the bar's tint back, and a hit unit would stay white without
  them.
- Every entity puppet loses the game's own `animation_finished` handlers at spawn (the turret
  cooldown needs stats, attack behaviours have no `_parent` on puppets).
- Pitfalls found by tests: `Enemy.respawn()` calls `update_target()`, which needs a spawner, so a
  puppet is revived visually. `PlayerProjectile.shoot()` needs weapon stats.

### Flags, poses and animations

**Flags.** Four bits per entity: `sprite.scale.x < 0` (facing: behaviours turn units toward their
target, and knockback would otherwise flip puppets), `!visible` (stampede dinos hide before
charging), `sprite.flip_h` (`JumpAttackBehavior` turns the sprite toward its landing spot and never
resets it) and `FLAG_REST`.

**Poses** (`sync/pose.gd`). Parts that physics code turns are sent sparsely, only for scenes that
have them, and interpolated with `lerp_angle`. The layout is a per-scene list of (node path, kind),
derived from a pristine `instance()` of the scene and cached per scene path. It is never derived
from a live node, because a puppet's `die()` frees its `Pivot`.

| What the game does | What is sent |
|---|---|
| `GoTowardsBorderOppositeMovementBehavior` rotates the whole unit (oviraptor, iguanodon) | the unit's rotation |
| `Pivot` children (predator, giant, jellyfish) spin rings of `EnemyProjectileRotating`, whose `position.x` grows outwards first | pivot rotation and bullet `position.x` |
| `CatlingGun._orient_gun` | `rotation` and `scale.y` of `%Gun_pivot_l/r` and their draw order |
| `EnemyLaser(Follow)` never moves | its `rotation` (aim) and the `visible` of the beam and aura sprites as one bitmask |
| `BrachiosaurusFoot` | `visible` of the shadow, foot and release sprites, and the foot's `flip_h` |
| every `Boss` scene | `Pose.Kind.HEALTH`, the health fraction, last of the base parts |
| `DigSite` (archaeologist) digs while a player stands in it | `DIG_PROGRESS`, the progress fraction (1: dug up), and `DIG_STATE`: its particles emitting, and being dug |
| `BuilderTurret.set_data` and `on_bonus_gold_converted` size the builder's turret from its owner's structure range (`set_size`: scale 0.5 to 1, raised up to 50 px) and pick its level texture | `SIZE` (`scale.y` of `Animation/Sprite`), its `position.y`, and `TEXTURE`, the index of the sprite's texture in `turret_sprites` |

The client sets a dig site's progress and `dug_up` and redraws it (`DigSite._draw` picks the
sprite), turns its particles on with the scene's `body_enter` squash as `_on_body_entered` does,
and loops the dig sound while it is being dug, as `_physics_process` does. The dug-up sound is a
`SoundManager2D` sound and the crate a consumable, both mirrored already.

The builder's turret is the only structure whose looks come from data: puppets never run
`set_data`, so before these values a client drew it at the scene's scale 1 with the level 1 texture
(about twice the host's size). The client keeps the facing flag's sign of `scale.x`. Like every
posed entity it sends its position in every snapshot, plus the 3 values (12 bytes). Other structures (the engineer's turrets, garden, wandering bot,
landmine, dart trap) look the same for any data; a cursed one's particles come with its type and
its outline with the [looks](#flags-poses-and-animations).

Turrets do not rotate in this game (`Turret.shoot` only aims projectiles). The client hands the
health value to the puppet's own `on_health_updated`, which follows this client's "life bars on
bosses" option, and builds the brachiosaurus' full-screen bar like `Boss.init` does.

**Pose groups.** At most one per scene, appended to the base values only while active. The value
count tells the client which case it is.

- `PIVOTS`: `Eel`, `Tyranosaurus` and `Brachiosaurus.on_state_changed(1)` add a `pivots_scene`
  instance (16 pivots and 16 bullets, 32 values). The host checks `entity.pivots`. The client
  instances the same scene under the same name on its puppet, with `entity.pivots` set so that its
  `die()` frees the bullets. The ring bullets are children of the boss, not of
  `_enemy_projectiles`, so they are not also tracked as projectiles.
- `JUMP`: while `%Land_shadow_warning` is visible, its local position and the `%Shadow`'s height and
  scale (the body flies, the shadow stays on the ground).
- `WARNING_LINE`: while `WarningChargingAttackBehavior._warning_line` is visible, its angle. The
  client parents the behaviour's own `Line2D`, as `init()` would have, and rebuilds the points like
  `show_warning`.

A scene with base parts that arrives without values means the host's parts are gone (a pooled
entity without its `Pivot`): the client hides its pivots. With values it re-creates missing `Pivot`
children from a pristine instance and shows them.

**Animations** (`sync/anim_mirror.gd`). Physics code and behaviours start most non-idle animations
(turret "shoot", enemy wind-ups and charges, jump attacks, foot stomps, pet states).

- Host: `EVENT_ANIM [net id, name, position, speed]` when an entity's
  `_animation_player.current_animation` changes or a non-looping one restarts. Nothing is sent for
  an entity in its `autoplay` animation. The event is re-sent about once a second while the entity
  is away from it, because snapshots are unreliable.
- Client: replayed at render time under the same name (the game's `update_animation` guards check
  names), only if the puppet has that animation. "death*" and "RESET" are never played.
- Animations with method tracks (`shoot()`, `start_shoot()` spawn projectiles) are swapped on the
  puppet for a cached copy without those tracks (`Animation.duplicate` and `remove_track`; the
  shared original stays intact).
- Projectile puppets play their autoplay animation without method tracks too
  (`AnimMirror.strip_projectile`). The enemy pillar's "shoot" ends in `stop()`, which would pool the
  puppet by a `pool_id` meta that clients do not have.
- Stampede dinos: the client shakes its grass (`main._shake_zone_sprites`) when one spawns, like
  `get_movement` does on the host. This costs no bytes.

### Lasting looks

`sync/looks.gd`. Looks are states the game shows for seconds or for an entity's life, set by game
logic that puppets never run. They are one byte of bits per entity: `BURNING` (with `BURN_RED` /
`BURN_BLUE`, the gradient `BurningParticles._update_color` picked), `CHARMED`, `CURSED`, `BOOSTED`,
`MECA`, `MUTANT`. The byte is full.

- **Host.** It reads what the game shows: the outline colours in `Entity._outline_colors`
  (`Utils.CHARM_COLOR`, `CURSE_COLOR`, `BOOST_COLOR` with `show_outline`, `MECA_COLOR`,
  `MUTANT_COLOR`), `Unit._is_burning`, and for enemy shots the hue shift material that a charmed
  enemy's `ShootingAttackBehavior` hands them. The material's `hue` is not read, because
  `get_shader_param` asks the VisualServer and returns null when headless.
- **Wire.** A look is sent for 4 snapshots after a change (also a change to plain) and, while not
  plain, in every 10th snapshot, staggered by id. A wave without looks costs 1 B per snapshot.
- **Client.** `Looks.resolve` keeps the last look per net id. It runs before `Snapshot.resolve`
  drops entities and shifts the indices. A look not confirmed for 45 received snapshots is plain
  again. A puppet that leaves the snapshots loses its look.
- **Applied** once per new snapshot through the puppet's own visual code: `Entity._set_outlines`
  with the charm's alpha 0.4 and desaturation 0.75, the sprite's white `self_modulate`, the unit's
  `BurningParticles.start_emitting / stop_emitting` (no `burning_data`, so nothing spreads), the
  `CurseParticles` of `curse_enemy_effect_behavior.tscn` instanced without its script next to (not
  among) the effect behaviours, a pet's `curse_particles`, the charm material on a shot.
- **Evolved enemies** (meca, mutant) also get their `evolution_meca` / `evolution_mutant` sprite
  (for the brachiosaurus foot, its foot sprite) before the outline, because the outline shader reads
  the texture's size. The scene's own sprite comes back when the look ends, so a pooled puppet
  reused for a plain enemy is plain.

### Projectile angles

`sync/facing.gd`. A projectile puppet has the host's rotation. Positions travel in half pixels, so
an angle derived from two positions would wobble for slow shots (for example the red line an enemy
slash shows before it strikes).

Every projectile without a pose sends its rotation for 3 snapshots after it changes and in every
15th, staggered by id. `Facing.resolve` keeps the newest angle per id while the id is listed. The
client turns a spinning shot between the two snapshots it renders. A puppet whose angle never
arrived faces its motion and stays hidden for its first snapshot. Puppets restart their animation
when reused.

### Spawn markers and puddles

**Spawn markers** (`EntityBirth`, `EntityGroupBirth`). The visible children of
`main._births_container` are mirrored like gold. The type key is
`<scene>#birth_enemy|neutral|structure|charmed` (colour and sprite, `PuppetEntity.birth_tag`). The
client calls the marker's own `start()` with a matching `SpawnRequest`, so it flickers and hides
itself after the same time as the host's. When the host moves a marker because a player stands on
it, the move arrives as a teleport and restarts the puppet. The begin and end sounds are the host's.

**Puddles** (`sync/puddles.gd`). Acid, petrol and fire puddles (children of `main._gpe_container`
and `_fire_puddles_container`) are tracked like gold. A puddle's sprite index and target scale are
set once in `init()` and travel in the type key, `<scene>#puddle:<sprite>:<scale x>:<scale y>`
(1/100). The sprite's random rotation is the client's own. The host drops a puddle from the
snapshots when it starts to fade (`is_active()`). The client runs the puddle's own spawn tween when
it appears and its `despawn()` fade before pooling the puppet. A reused puppet's tween is cleared
first (`remove_all`, as the game's `_return_to_pool` does): the fade left in it ended the spawn
tween at alpha 0, so after 2 s a magma boots trail showed one puddle at a time, and acid and
petrol puddles went invisible the same way (suite `puddle_reuse`). Damage, slow and ignition stay with
the host's puddles. The host's scan takes only `AcidPuddle`, `PetrolPuddle` and `FirePuddle`, so
holes, dig sites and poacher zones in the same container are left alone.
The client's explosion puppet never runs `start_explosion`, so the fire puddle an explosion leaves
(arsonist) comes from the host only.

### Scene state: holes, weapons, speed

`sync/battle_scene.gd`, one instance per battle on each side.

- **Hole layouts.** `main._ready` calls `GPESpawner.spawn_holes_full_scene` when the wave's
  `spawn_holes` is set (jungle waves 4, 10, 16). It instances one of the layout scenes at random.
  `BATTLE_START` carries the host's scene path (`holes`, "" for none). Right after the client's
  `_ready` its own layout is freed and the host's instanced, if the path is in its spawner's lists.
  `ZoneService.forbidden_circles` is cleared before that (`Hole._ready` is the only thing that adds
  circles). The swap only takes a child whose scene is one of the spawner's layouts, and it runs
  before any puddle puppet exists. A mid-wave resync keeps the layout.
- **Dig sites.** `DigSiteSceneEffectBehavior._ready` (archaeologist, the dig site item) places them
  at random in `_gpe_container`, on every machine. The client frees its own in
  `client_scene_ready`. The host's are static snapshot entities (`BattleScene.dig_sites`) whose dig
  travels as pose values (see [Flags, poses and animations](#flags-poses-and-animations)). The
  puppet goes into `_gpe_container`.
- **Single holes** (`BrachiosaurusFoot._stomp` calls `GPESpawner.spawn_single_hole_at_position`) are
  static snapshot entities (`BattleScene.spawned_holes`). The client's puppet goes into
  `_gpe_container` and keeps its body.
- **Holes block the prediction.** The client's players get `collision_mask` = obstacles (layer 8:
  holes and the map's limits) plus the blockers' layer (below) and have no layer of their own. Every
  replayed input is one `Unit._physics_process` tick (`BattleScene.step`: `body_test_motion` from
  the predicted position, then the slide). The slide only follows a hit as `RigidBody2D.test_motion`
  reports it: the server also reports a body that touches a wall (within the 0.08 px margin) and
  gets its whole way, and the node leaves that out (`collision_safe_fraction < 1`). Sliding after
  such a touch moved a player walking along the map's edge twice as far a tick, and snapshot
  positions (0.5 px steps) put the replay's start at the edge whenever the host was within 0.25 px
  of it: at a 200 ms round trip the client ran 100 px ahead along the edge (issue #109).
- **Weapons during a wave.** The only way the game changes a player's weapon nodes mid-wave is
  `Player.on_weapon_wanted_to_break` (the brick's `break_on_hit`). The host remembers the instance
  ids of each player's weapons at wave start. Once a player has fewer, every snapshot carries its
  weapons' wave-start slots (`PLAYER_WEAPON_SLOTS`). The client drops the puppet weapons whose slot
  is gone (`current_weapons`, `weapon_pos` and its `RunData` weapon list) before the per-weapon data
  is applied by index. `BATTLE_START` carries every player's current slots (`weapon_slots`), so a client that joins
  after a break maps the same way. Snapshots carry up to `Snapshot.MAX_WEAPONS` (32) weapons.
- **Speed.** `Player.get_move_speed()` in whole px/s (`PLAYER_SPEED`), sent for 4 snapshots after it
  changes and in every 10th. The client sets it as the puppet's `current_stats.speed` (bonus, slow
  and petrol zeroed), so the prediction and the walk animation follow it.

### Player state in snapshots

- **Dead.** The player flags carry `Player.dead` (`PLAYER_DEAD`) in every snapshot, and the client
  plays the death (`PuppetEntity.player_died`) when it is set. Health 0 is not used for this: a
  Veteran (`no_cure_between_wave`) who died starts the next wave alive at 0 health
  (`Player._get_health_kept_between_waves`).
- **Hit protection.** Tardigrades give `Player._hit_protection` charges, each blocking one hit. The
  HUD counter and the life bars' purple tint read that field. It is the last of the sparse player
  stats, and `BattleScene.apply_hit_protection` sets it and updates the counter (a blocked hit
  changes no health, so no `health_updated` fires).

### Events and one-shot feedback

Snapshots carry an `events` list. The client queues events and fires them when render time reaches
their snapshot, so feedback lines up with the interpolated world. `sync/feedback_mirror.gd` has one
instance per battle on each side and keeps no node references.

| Event | Host | Client |
|---|---|---|
| `EVENT_DAMAGE` `[target, value, knockback, flags, hit type, seq, effect scale, hitbox position or null]` | connects to the `took_damage` of every unit at its spawn signal (or its first snapshot) and of the players (target `-(player_index + 1)`) | for players, enemies and neutrals the handlers `main.connect_visual_effects` connects (`FloatingTextManager._on_unit_took_damage`, `EffectsManager._on_unit_took_damage`; pets get no number, like in the game), then `Unit.flash()` on every unit. See [Damage and heal numbers](#damage-and-heal-numbers). |
| `EVENT_HEAL` `[player, value, seq]` | connects to `Player.healed` | `FloatingTextManager._on_player_healed`, which `main` connects to it |
| `EVENT_SOUND` | see Sounds below | see Sounds below |
| `EVENT_ANIM` | see [Animations](#flags-poses-and-animations) | |
| `EVENT_EXPLOSION` `[scene type, position, scale, smoke amount]` (`WeaponService.explode`) | finds new children of `main._explosions` at each snapshot (a node whose "explode" restarted was pooled and reused) | takes a node from main's pool like the game, makes it a puppet (no physics: its first physics frame would play the sound; hitboxes off), sets this player's `explosion_opacity` and plays "explode" from the start. `end_explosion` pools it. Fog waves get their light (`FogViewport._on_spawn_explosion`). |
| `EVENT_BONUS_GOLD` `[RunData.bonus_gold, label visible]` | state, sent on change | updates the bonus gold bag |
| `EVENT_WAVE_END` `[failed / lost / won, label showing]` | state, sent once `main._cleaning_up` | dims (`UIDimScreen.dim`), stops the gold feedback of the floating texts and effects (their own `clean_up_room`), fades the ambient sound, starts and hides `WaveClearedLabel` with the host's, and stops the prediction |
| `EVENT_GOLD_BOOST` `[position, boost]` | hooks `picked_up` of mirrored gold and reads `boosted` in its handler | shows the "x2" text of `FloatingTextManager.on_gold_picked_up` |
| `EVENT_STAT` `[player, stat hash, value]` | connected to `RunData.stat_added` / `stat_removed` (removed: the negative value), at most 16 per snapshot | calls its own `FloatingTextManager.on_stat_added` with empty sound lists. The stat is `Keys.generate_hash`'s `String.hash()`, the same on every machine. |
| `EVENT_WEAPON_ANIM` `[player, weapon index, position]` | one event when a weapon's own `AnimationPlayer` starts its attack (whip and flail: "lash") | plays the puppet weapon's animation from that position, as a copy without the method track (`open_hitbox` / `close_hitbox`) |

State events are repeated for 4 snapshots and in every 15th, ranked like animations and kept after
a stall. An older copy that arrives late is ignored.

The gold boost handler relies on the signal order: the per-battle helper is created after `main`,
so `main`'s handler has already doubled the gold, and `Gold.pickup` resets `boosted` right after
the signal.

**Derived on the client, no bytes:**

- Screen shake (`Screenshaker._on_player_took_damage`, `_on_unit_took_damage`), called with each
  damage event (the host already leaves out `hide_feedback` hits). This client's screenshake option
  applies.
- The level-up text, from the host's player level compared with the previous one. It follows the
  newest snapshot, about 100 ms ahead of the interpolated world.
- The gold pickup sparkle where a gold puppet vanished from the snapshots (`main.on_gold_picked_up`
  is the only way out of `_active_golds`), not after the wave's end.

**Sounds** (`session/sound_relay.gd`). Extensions of `SoundManager.play / playSingle` and
`SoundManager2D.play` route through the relay.

- The host records only sounds the game actually queues. It skips a sound when all players are busy
  or the queue is full (`SoundManagerParent.MAX_SOUNDS`) without `always_play`, and a `playSingle`
  within its cooldown (detected after the call: `can_play_sound` stamps `_last_played` only when it
  passes). The stream path travels through the type table.
- Clients replay `playSingle` sounds as `playSingle` (cooldown minus 0.1 s for snapshot timing) and
  pass `always_play` on.
- A client in a battle drops locally triggered sounds (for example step sounds from puppet walk
  animations, which are method tracks) and plays only replays.
- The level-up and crate panels live in `main.tscn`, so their sounds travel with the snapshots.
  Sounds outside a battle are covered in [UI sounds](#ui-sounds).

**Picked-up crates in the HUD** (`sync/pickup_list.gd`, section `pickups`).
`main.on_consumable_picked_up` puts crates and the mutation fruit / meca parts into
`_things_to_process_player_containers[p].consumables`. This is state and not an event, because an
icon missing for the rest of the wave is worse than a missed text. The body is `{battle_id,
players: [[consumable my_id]]}` from the lists' `_elements`. The client makes its lists the same
with their own `add_element` / `remove_element` (a copy per entry, with the zone's sprite as
`ItemService.get_consumable_for_tier` sets it). Ids it does not know are left out. The level-up
icons of that row come from `BattleClient._show_level_up`.

### Damage and heal numbers

`sync/hit_numbers.gd`, one instance per battle on each side. A big hit (an explosion over 80
enemies) used to lose most of its numbers to the event cap, and a lost snapshot lost its numbers.

- **Host.** Every number gets a seq (u16 per battle, wrapping). It waits up to `MAX_DELAY` (3)
  snapshots, 100 ms, for room under the cap and goes out in two snapshots, the second copy in a
  later one than the first, so a lost snapshot loses none. At most `MAX_COPIES` (16) second copies
  go into one snapshot. Numbers are offered oldest first, so their seqs ascend and travel as a
  varint difference to the number before (mostly 1 B).
- **Queue cap.** Numbers waiting for their first copy are capped per kind: 256 plain enemy hits
  (`MAX_PENDING`), 256 crits, kills and the like, 64 player numbers and heals (`MAX_FEEDBACK`;
  i-frames and 4 players bound their rate). More of a kind are dropped before they are ranked, so
  a flood of hits (400 burning enemies and explosions) keeps out no player's "-N", heal, crit or
  kill. A number already sent once waits only for its second copy and does not count: it leaves
  the queue within 4 snapshots of being first offered, and at most 48 numbers go out a snapshot,
  so the queue holds at most 256 + 256 + 64 + 4 * 48 = 768 entries. The check comes before the
  event is built.
- **Rank** (`select_events`): crits, kills (health 0 after the hit), one-shots and gold hits go
  before other enemy hits. The second copy of an enemy number comes after everything else, a
  player number's second copy at the crits' rank. So an 80-hit tick sends its crits and kills with
  the first snapshot and all of its numbers within 4 snapshots. In suite `hit_numbers` (room for
  47 numbers a snapshot, an enemy's spawn-tick hit in the second) the 80 go out as 47, 46, 16 and
  16 numbers a snapshot: the first copies in the first two, then 13, 16 and 16 second copies, so
  45 of the 80 get their second copy in time.
- **Client.** `fresh` drops a seq it already queued (it remembers the last 1024), before the event
  is queued. A number fires at the time of the snapshot it came in, so one that waited or whose
  first copy was lost shows up to 100 ms late.
- **Hit effects.** `TakeDamageArgs.get_effect_scale()` (a weapon's `effect_scale`, 0.1 for a burn
  tick) is sent when it is not 1 (1 B). For a target with an aim shape (in the game only the
  brachiosaurus) the hitbox's position is sent too (4 B): the client puts a stand-in `Hitbox` there
  (in the battle scene, not monitoring or monitorable, its shape disabled), so
  `Unit.get_hit_feedback_position` gives the host's spot for the number and the hit effect.
- **Bytes.** A damage number is 9 B (8 before the seq), a heal 4 B. Each number goes out twice,
  which doubles what numbers cost in a fight that does not fill the cap; in a big fight the copies
  add at most 144 B to a snapshot (4.2 KB/s per client). In the crowded late wave of
  `late_load_tests.gd` (2026-11-22): 180 enemies 43.2 KB/s per client (43.5 before), 400
  enemies a median of 24 events and 2808 B per snapshot (14 and 2700 B before), still 2 and 3
  packets.

### Snapshot time and render delay

**Snapshot time.** `t` follows the simulation: 1/60 s per physics step
(`BattleHost.advance_clock`), not the wall clock. Below 60 fps the engine runs several physics steps
in one frame, and wall-clock stamps would make clients play the wave fast, slow, fast. The clock is
set back onto the wall clock when they differ by more than 250 ms (pause, long hitch). The client
uses a min-filtered offset.

**Render delay** (`sync/render_delay.gd`). The client renders 100 ms behind the newest snapshot.

- When the newest snapshot is all there is, render time holds on it and does not run past it. The
  delay grows by as long as the stall lasts, up to 500 ms. When the late snapshots arrive the world
  carries on from where it stopped and catches up by playing 15% faster.
- A longer stall or a host pause is not held: past 500 ms the delay drops back and the world jumps.
- Two holds within 5 s keep the delay at the longest of them (at most 250 ms) until it has been
  calm for 5 s.
- Render time never runs backwards.

**The world behind the own player.** The client shows the host's world the render delay behind the
newest snapshot, and that snapshot is half a round trip old, while its own player is predicted half
a round trip ahead of the host. Add the input's wait for its tick and the snapshot interval: at a
60 ms ping the world is about 190 ms behind the own player. Enemies chasing it, their bullets and
its own bullets show that offset, 85 px at 450 px/s and 170 px at 900 px/s, more visibly the more of
them there are. Items are predicted ([Own pickups](#own-pickups)). Lowering the offset costs holds
(a shorter render delay) or bandwidth and host time (more snapshots a second).

### Remote input

`sync/input_sync.gd`, `sync/remote_buttons.gd`, `sync/press_counter.gd`. `INPUT` is sent unreliably
every physics frame. Its 8 fields are listed in `net/protocol.gd`. Bodies are checked strictly
(field count, at most 4 finite previous moves, a finite move, an int send time), and anything else
is dropped whole.

**Buttons** (host, `RemoteButtons`). Each button has a held bit and a 4-bit press counter.

- A press needs a counted edge. A button still held after the timeout release or at rejoin does
  nothing until it is released.
- A tap lost in a loss burst is replayed once.
- `ui_pause` is never held. It is delivered as press and release on the client's release, so a
  timeout or disconnect cannot pause.
- Held menu directions repeat like the game's pad echo (following `set_gamepad_echo_processing`).

**Movement.** This is the one input a client predicts. The host queues each remote player's moves in
seq order and takes exactly one per physics tick. With none queued the player stands and the ack
waits. The snapshot's input ack is the newest input whose tick has run, so the client's replay
(host position plus one step per input after the ack) matches whatever the arrival pattern. Aim and
buttons are newest-wins on arrival.

- **Redundancy.** Each `INPUT` carries the moves of the 4 inputs before it
  (`InputSync.REDUNDANCY`), and the host queues those still due. A lost packet, or up to 4 in a row,
  costs no step.
- **Catch-up.** More than `MAX_WAITING` (2) moves waiting only happens after a gap, when packets
  held up on the way arrive together. The client predicted all of those steps, so the host keeps up
  to `MAX_BACKLOG` (36: 600 ms at 60 Hz, below the client's replay limit of 45) and takes one extra
  per tick (`CATCH_UP_PER_TICK`) as a physics step of its own before the snapshot (`InputSync._extra_step`: `test_motion`
  and a slide like `Unit._physics_process`; not while paused, dead or outside a battle). The player
  runs at most twice its speed until it is where the client showed it. Beyond `MAX_BACKLOG` the
  oldest moves are dropped, and the client blends that difference out.
- **Timeout.** After 600 ms without `INPUT` (`Protocol.STALL_LIMIT_MSEC`) the host lets go of the
  player's buttons, aim and stick. The value is shared with the client's prediction limit, so a gap
  the client rides out does not end with a release on the host. Movement does not need the timeout:
  with nothing queued the player stands.

**Client mode** (`VirtualDevices.set_client_mode`). The client's `InputService` tracks pad versus
mouse as in solo play, shows the mouse when it moves and does not emulate echo actions. The left
stick is sent as menu directions.

**Aim** (`sync/local_aim.gd`). The client's own `manual_aim` / `manual_aim_on_mouse_press` settings
and device decide. Mouse users send the direction from their predicted player to the mouse as the
stick. On the host a `Utils` extension answers `is_manual_aim` for virtual devices from that flag.

**Device type.** Bits 1..3 of the same flags carry the `PlayerType` the client's player used last,
plus 1 (`LocalAim.type_flags`, 0: none). It only changes key hints (see
[Key hints of other players](#key-hints-of-other-players)); a remote slot stays a gamepad for aim.

### Own-player prediction

`BattleClient._predict_own`. The client shows its own player at the host's last position plus one
step per input the host has not acked, at most 45 inputs (`MAX_REPLAY_INPUTS`, 0.75 s). Steps go
through `BattleScene.step`, so holes, the map's limits and other players block them, and a step
along a wall is the host's ([Scene state](#scene-state-holes-weapons-speed)). When the host
disagrees, the difference is blended out at 12/s (`PREDICTION_ERROR_DECAY`). The steps of inputs
sent since the last frame are motion, not a correction.

`sync/own_view.gd` holds what moves with the own player, one instance per battle:

- **Other players block it.** On the host every player is a kinematic body on layer 2 with layer 2
  in its mask, so players stop each other (`test_motion` counts kinematic and static bodies). The
  client's puppets have no layer. Instead each player gets a blocker, a `StaticBody2D` with a copy
  of its body shape on layer 21 (`OwnView.BLOCKER_LAYER`, unused by the game). Every frame, before
  the prediction runs, each other living player's blocker moves to that player's position in the
  newest snapshot, not to its puppet. The puppet is drawn a render delay (100 ms or more) behind,
  while the host applies this client's inputs against where the others are then, and the newest
  snapshot is the closest the client knows. The newest snapshot also gives the replay's start, so
  the two never overlap in it. The own player's blocker and dead players' blockers are off.
- **Drawn every frame.** The prediction moves on inputs, one per physics tick (60 Hz), while the
  puppets move every frame. On a faster screen the own player moved on some frames only and shook
  against the background where the camera stood still (at the map's edge). It is drawn between its
  last two ticks instead: a frame that took exactly one new input remembers how far it moved the
  display (`jump`), and the player is drawn `(1 - Engine.get_physics_interpolation_fraction()) *
  jump` short of it, a tick (16 ms) behind. `_own_display` itself stays the prediction: corrections
  and pickups use it.
- **Camera.** `MyCamera` moves a co-op camera in `_physics_process` (when it is snapped to one
  player, in `_process`), towards the players' average. On a client both are off, and
  `BattleClient._process` calls its `_process_internal(delta)` right after placing the players, so
  the camera follows the positions drawn in that frame. Its lerp and snap are time based, so the
  frame step changes nothing else. The host and single player keep the game's camera.

Prediction is off, and the player stands at the host's position, in these cases:

- The host is paused.
- The newest snapshot is older than 600 ms (`Protocol.STALL_LIMIT_MSEC`). Shorter snapshot stalls
  are ridden out, because the host still gets the inputs during a stall of the snapshots alone, so
  the prediction is right.
- The player is dead.

**Wave end.** `main.clean_up_room` stops the host's players (`Player.on_room_cleanup` sets
`_can_move` false) in the call that sets `_cleaning_up`, so the snapshots carry `EVENT_WAVE_END`
from then on (a repeated state event). The client takes it on arrival (`_note_wave_end`), not at
render time. Prediction stops, and the own player stays where it was last drawn
(`BattleClient._stand_own`). The host's player stands a few steps behind it: the inputs the client
predicted before it heard of the wave's end. Blending back to the host's position looked like a
step back (`input_ack_tests.gd`, `_test_wave_end`).

Nothing else stops a player mid-wave (`_move_locked` is used by enemies only).

### Own pickups

`sync/own_pickups.gd`. The own player is predicted ahead while items show the host's world about
100 ms back. The host attracts and takes them at its own position of that player, which is a round
trip, the render delay and a snapshot interval behind what the client shows: about 190 ms at a
60 ms ping, so 85 px at 450 px/s and 170 px at 900 px/s. Without prediction a fruit or crate the
player ran over would vanish late and behind the player, and gold would lie still while the player
ran through its attract circle, then fly after it and vanish behind it ("skipping items" at high
speed, issue #90).

Game rules: a touch takes an item (`Player._on_ItemPickupArea_area_entered`: the pickup circle,
radius 32 at (0, -24), against the item's 32 px box). Gold is always attracted, a healing
consumable only below max health (`_on_ItemAttractArea_area_entered`, radius 150 times pickup
range), and an attracted item flies to the player (`Item._physics_process`: 500 px/s, +20 per
tick). Gold lies turned at random (`Item.drop`), which is not mirrored: the client takes its box
unturned, so a corner can reach up to 7 px further on the host.

The client runs those rules on its predicted position for consumables and gold that stand where the
newest snapshot has them:

- A touch takes the puppet out of the mirror and plays one of its pickup sounds (gold: the game's
  or the alternative ones, by this player's setting, with the gold sparkle). An attracted one first
  flies to the player, but a healing one not while a heal taken here is still unconfirmed.
- Touches are checked along the way the predicted position took since the last frame, in steps of
  8 px (`OwnPickups.way`), as the host checks each tick. A slow frame covers several ticks: at
  20 fps and 1200 px/s that is 60 px, and a crate beside the way would be missed between the
  frames' ends. A way longer than 1.5 times the steps of its new inputs is a correction: only its end
  counts.
- The id is held (not respawned) until the newest snapshot drops it too. That snapshot's matching
  pickup sound is removed before it is queued.
- If the host still has it where it stood once it has applied 10 more inputs than the one the own
  player reached it with (touched or attracted; `CONFIRM_INPUTS`), it is released, respawns where
  the host has it and is never predicted again. While the host moves it (its own flight, to this
  player most likely) the client waits for it to land, at most 60 snapshots.
- Nothing is predicted while the prediction is off.
- If another player took it meanwhile, it vanished at the own player (the client cannot tell who
  took it). The HUD's gold count follows the host's snapshots.

### Pause and live menu

`sync/pause_control.gd`, `extensions/ui/pause_menu.gd`.

**Pause.** A client's puppet battle and shop get `PauseMenu.enabled = false` and lose the
`game_lost_focus` connection. The sections `pause_battle` and `pause_shop` carry who paused. Null
means resumed. `pause_battle` is flushed by `BattleHost._physics_process` on the change, `pause_shop`
on the menu's paused / unpaused.

- In the host's shop, remote buttons are blocked, pause included (`ShopSync._block_remote_buttons`):
  a client's pause opens its own menu (see the live menu below). A pause the host's menu gets for
  a remote player (focus loss names player 0) goes to the first local player; the player who paused
  resumes with pause (main page only).
- On a client, a host pause shows a banner over the scene ("PAUSE", "Paused by ...") on the pause
  menu's own backdrop. The bodies name the pauser by persona name and steam id (0: the host); a
  pauser the host cannot name is sent as `""` with -1, and each client says "a player" in its own
  language (`PauseControl.banner_line`). While the host is paused the client's own panel takes no input, every press
  except pause is dropped (`InputSync.held_while_paused_mask`), and a button held through the pause
  needs a new press afterwards.
- `retry`, `pause_battle` and `pickups` stay pending until the puppet battle of their `battle_id` is
  ready (`BattleClient` calls `retry()` on `battle_entered`). A peer that joins gets them right
  after its `BATTLE_START`, which only starts the scene load.
- The shop's pause applies when the body arrives, also while a shop loads. Only the banner waits for that
  shop. `clear_state` (the host left the shop) resumes, so no pause carries over to the next shop.
- `PauseControl` finds the pause menu when the current scene changes. It has no permanent
  `SceneTree.node_added` handler, which would cost one script call per spawned node.

**Live menu.** During a wave of an online session (until `main._end_wave_timer_timedout`) the menu
opens without pausing.

- Host with at least one peer: `PauseControl.host_update` sets `menu.live` every frame and keeps the
  pause bit off the remote devices for the whole battle scene (`InputSync.blocked_by["battle"]`), so
  only a local player opens it. The owner's `PlayerMovementBehavior.device` is parked on
  `VirtualDevices.IDLE` while the menu is open: its buttons move the cursor, not the character, and
  weapons go on firing. Focus loss does nothing in live mode. Restart, end run and quit work as in
  the game.
- Client: `PauseControl.client_update` polls the release of its own `ui_pause` and opens the puppet
  scene's menu for its own slot (`open_live`). `InputSync.set_local_menu` feeds the local buttons
  into the own slot's device and sends the host a neutral `INPUT`. When the menu closes, the press
  counters resume from what is held, so nothing counts as a press. Restart and end run are
  disabled. Quit switches the menu to its lobby page with the leave question.
- The menu closes when the wave ends on that machine (level-up panels, retry prompt,
  `BATTLE_END`).
- Client in the shop (`PauseControl.client_shop_update`): the same menu over its copy of the shop,
  live while it has an own panel and the host is not paused (the host's pause closes it). The
  menu's buttons reach the own slot's device, which the shop's own handlers read too (lock, steal,
  ban, page triggers, the cursors), so while it is open the shop node and its `FocusEmulator1..4`
  take no input, `ShopLocal.set_menu_open` takes the own panel's device and mouse, and the game's
  `on_paused` hides the shop's content. Closing puts the other players' cursors back
  (`FocusSync.reapply`): they could not apply to hidden controls. `PauseControl` keeps that shop
  by instance id (`_inert_shop_id`) and forgets it once it is freed. `open_menu` (a lobby
  question from outside the menu) opens this menu too. Tested in `shop_menu_tests.gd` (suite
  `local_shop`), also through `_update_live_menu`.
- A menu freed with its scene while open (the host starts the wave while a client's menu is open
  in the shop) drops the codex first (the extension's `_exit_tree`): the codex sets itself as
  `Utils._popup` and clears that only in its own close path, and `FocusEmulator` asks
  `Utils._popup` on every cursor move, which crashes a release build once it is freed.

### End of battle and wave lifetime

Nothing a wave allocated may outlive it. `cleanup_tests.gd` plays six waves as host and six as
client and requires that `Performance` object, node, orphan node and resource counts do not move
after two warm-up rounds.

- **Host.** The battle ends when its scene leaves the tree (`tree_exited` on `main`). `_end_battle`
  sends `BATTLE_END` and drops the type table, records, ids, stats and events.
  `main.clean_up_room` frees `_enemy_projectiles` while the scene lives on, so
  `BattleHost._tracked_nodes` checks the container with `is_instance_valid`.
- **Client.** `_leave_battle` frees the puppet pool, clears buffers and tables, resets
  `RunData.wave_in_progress` / `wave_timer` and emits `battle_left`. It runs on `BATTLE_END`, when
  the puppet scene leaves the tree without one, and when another battle's start replaces a live
  one. `UpgradesSync` drops its references to the scene's panels on `battle_left`.
- **Next screen.** On `BATTLE_END` the client keeps the frozen battle (muted) until the shop, the
  next battle or a menu state replaces it. After 2 s it falls back to the waiting screen, which says
  "Waiting for the host" only after 1.5 s.
- `mod_main._enter_client_view` takes the previous scene out of the tree before the view becomes
  the current scene, like `change_scene` does.

## 7. Screens

### The shared model: local view, decisions to the host

The shop and the level-up / crate panels follow one model. The other screens (selection screens,
end of run, retry prompt) are plain copies whose cursors make the round trip through the host.

- **The client's own panel runs on the client.** `InputSync.set_local_device(owner, device, reason)`
  feeds the local buttons into the own slot's device through a `RemoteButtons` (the host's code
  path: counted edges, echo, pause excluded). The device is a claim per screen (`"upgrades"`,
  `"shop"`). Passing -1 gives up only the caller's own claim and the newest claim drives, so a late
  stop of one screen leaves the next screen's device alone. `FocusSync.set_local_emulator(owner,
  emulator)` does the same for the emulators that the host's cursor stays off. Every claim change is
  logged with its reason. Cursor, carousel pages, popups and description scrolling then work as in
  local co-op, with no round trip.
- **Every way into the run is cut on the client.** The signals that would change the run lose the
  game's handlers, on every panel. The own panel's signals are sent as intents. On the other panels
  nothing listens. The view half of a cut handler is called where the panel needs it (for example
  `give_focus_to_mecha_choice` before a meca buy without a choice, and
  `BaseShop._on_item_cancel_button_pressed` after combine or recycle).
- **The host applies an intent with the game's own code**, after checking the sender's player, the
  panel revision and that the tree is not paused. After an applied intent the state goes out in the
  next frame (`StateStream.flush`), once the game's deferred handlers ran.
- **The host keeps remote buttons off its copy.** While the screen is up and the tree is not paused,
  `InputSync.blocked_by` / `blocked_buttons` keep every remote button but pause off the virtual
  devices, so a remote accept cannot also press the host's copy.
- **Presence is cosmetic.** The client reports its page, cursor and open popup (`SHOP_FOCUS`,
  `UPGRADE_FOCUS`: a cursor target restricted to the sender's own anchors, and a popup view, see
  [Open popups](#open-popups)). The host puts them on its copy, from where `FocusSync` and the
  state's `pages` and `popups` carry them to the other clients. Decisions never depend on it. A
  target that does not resolve or is not visible is ignored.
- **A control the mod does not know** (another mod's button) keeps its own handler and can show
  things. Other mods register their decisions (see below).
- **The client rebuilds as little as possible.** A panel is rebuilt only when its revision or data
  changed, because a rebuild of the own panel would fight the local cursor. A cursor is always
  taken off a control before that control is freed (see
  [Freed controls](#freed-controls-under-a-cursor)).

**Other mods' decisions.** `ShopSync.register_intent` / `send_intent` and the same pair on
`UpgradesSync`. A mod that adds a button to a panel registers a namespaced kind (brotato:trade uses
`trade.item`, `trade.weapon` and `trade.crate`). A game kind cannot be registered.

- Host: a remote player's press runs the mod's handler after the checks every intent gets
  (`handler(shop, player, slot, id, arg) -> bool` in the shop, `handler(ui, player, id, arg) ->
  bool` on the panels). True counts like an applied game intent: revision bumped, run check forced,
  state flushed.
- `ShopSync.register_intent(..., false)` skips the revision check, for a kind whose slot and id name
  its target and whose handler checks everything again. A second press sent before the host's
  answer then runs too (two quick trades of the same item).
- The state names the host's kinds (`kinds`, part of the key).
- A menu the mod opens in the item popup or on the panel (brotato:trade's player lists) is shown
  on the other machines when the popup or panel defines `together_menu()` and
  `together_show_menu(menu)` (see [Open popups](#open-popups)).
- Client: `is_puppet_shop(shop)` / `is_puppet_ui(ui)` tell the mod that it must not change the run,
  `host_handles(kind)` whether the host has the mod, `own_player()` whose panel is local (-1: none),
  and `send_intent(...)` sends a press of the own panel (false: not sent).
- A local player's decision on the host needs nothing: the fingerprint finds the changed run.

### Shop

`sync/shop_sync.gd` (state), `sync/shop_local.gd` (client's own panel), `sync/shop_intents.gd`
(host), `extensions/ui/shop_item.gd`.

**State.** The run state comes from `ProgressData.get_run_state(shop_items, reroll_count,
paid_reroll_count, initial_free_rerolls, free_rerolls, item_steals)` (the shop's own save
arguments). The key is the run cache's `rev` plus what is sent without serializing: per-slot
`active` layout, locks, Go flags (`_player_pressed_go_button`), panel revisions (`seqs`), carousel
pages (`pages`), meca rolls (`mecas`), open popups (`popups`), `shop_id`, colours, `kinds` and every
peer's player index.
`you` and the run parts the peer lacks are the per-peer patch.

**Entering.** The client enters through the game's resume path (`ProgressData.saved_run_state`,
`RunData.resumed_from_state_in_shop = true`, `shop_effects_checked = true`), so `BaseShop._ready`
rolls nothing. It disconnects `BaseShop._on_tree_exited`, which would roll curses on locked items.
`apply_state` returns false while the shop it entered loads, and `_on_shop_ready` calls `retry()`.

**Applying a state.** The client re-runs the per-player part of `BaseShop._ready`
(`set_weapons_data / items_data`, `_update_stats`, gold label, reroll price through
`ItemService.get_reroll_price`, `ShopItem.set_shop_item / activate / deactivate`, checkmarks).
`ShopSync.player_keys` keys each player's data (the ids of its `p` and `g` parts), its gear (the `g`
id) and its offered items (a hash of them in the `s` part).

- A player whose data did not change keeps its `PlayerRunData` object across `resume_from_state`,
  because the panel's gear elements and popup hold those objects.
- Gear rows are rebuilt only when the gear changed, and then in place (`UpgradesGear.sync_gear`,
  shared with the [level-up panels](#level-up-and-crate-panels)): an element that shows the same
  item is kept and pointed at the new object, so a cursor on it stays. A kept element also gets
  the marks `set_element` takes from the player's run (banned, recently mutated). Late in a run a
  purchase instances one element instead of about 250 (see
  [Measurements](#12-measurements-and-session-findings)). So does an item popup opened from it
  (its buttons, the meca choice, brotato:trade's player list),
  for example when another player trades this one something. The popup then holds the new object
  (Cancel finds its element by it, and a meca roll it waits for follows it), and its buttons are
  shown again for the run now (`ShopSync._refresh_popup_buttons`: Combine once a second copy came,
  the recycle value) unless it lists meca effects or another mod's menu (`together_menu`). A
  cursor on a button hidden that way goes to Cancel. Only when its element
  is gone does the popup close, and the cursor goes to the element at the same place; with no
  element left there (and no default for another player's panel) it is taken off. A node kept at
  the cursor's place that shows another item now gets the cursor anew, so its details follow. An
  empty row or a locked item takes the game's `set_*_data`, with the cursor taken off first.
- A change of a player's other parts only (`p<p>`: gold, stats, a reroll) brings new objects of
  the same weapons: the weapons row is pointed at them the same way (nothing instanced), so the
  elements and an open popup hold the run's weapons, as an intent names them.
- Shop item nodes are re-set only when the player's data, offered items or slot layout changed. A
  slot the host's state deactivates moves the cursor only when it was on that slot (or on nothing):
  `BaseShop.on_shop_item_deactivated` is cut and called only then (`ShopSync._deactivate`). The game
  also moves a cursor that rests on no shop item, which for a buy confirmed late would pull it out
  of an open popup.
- The same part ids again (only a Go flag, a page or a revision differs) skip `resume_from_state`.

**Locks.** The state carries the lock of every slot node (`locks`), and the client sets each node
to it (`ShopSync._apply_locks`). The game's `BaseShop._update_visual_locks` is not used: it finds a
locked item by its place in the offered list, which is the slot only at shop entry. The own panel's
press shows at once (`ShopLocal._on_own_lock`, view only). A state from before the host's answer
does not take it back. After 1 s without an agreeing state (`LOCK_WAIT_MSEC`) the slot shows the
host's lock again. A press that steals sends no lock.

**Go.** The client keeps no flag of its own. Its press sends "go", and the checkmark appears when
the host's state has it. The game clears the flag itself when the cursor leaves the button, so
`ShopLocal.process` sends "go 0" when the local flag is gone while the host still has it, and clears
a ready flag that arrives while the cursor is not on Go.

**Reroll text** (`SHOP_TEXT`). A reroll that gives a stat (bone dice, `gain_stats_on_reroll`) floats the stat's icon and
number over the player's reroll button. The host hears `RunData.stat_added` in the shop and,
deferred, sends the gain when that player's `_reroll_count` went up since. The client shows it
through `FloatingTextManagerShop.stat_added`, without the sound. Every client gets every player's.

**Guard and intents** (`ShopLocal.guard`). The cuts sit where the mutation is, which is below
`BaseShop` in places.

| Action | Cut on the client | Host applies |
|---|---|---|
| buy | `ShopItem.buy_button_pressed` loses `ShopItemsContainer.on_shop_item_buy_button_pressed` | sets `effect_choice_selected` for a meca item, then presses the item's buy button (`FocusEmulatorSignal.emit(button, "pressed", p)`) |
| steal | `steal_button_pressed` loses the container's handler | `ShopItem.steal_item()` when `_item_steals[p] > 0` |
| lock / unlock | `ShopItem.change_lock_status` is called directly by `BaseShop._input`, so a script extension emits `lock_requested` instead while puppeting | `change_lock_status(wanted)` when the item `is_lockable` and is not already in that state, then refreshes its copy of the player's hint |
| ban | `ban_item_pressed` loses the container's handler. The hold loop and the ban animation stay local and end in that signal. | emits the item's `ban_item_pressed` when its ban button is enabled |
| dismantle | `dismantle_button_pressed` loses the container's handler | `ShopItem._on_DismantleButton_pressed()` when `BaseShop._can_dismantle_with_shortcut` |
| reroll | the reroll button's `pressed` loses `BaseShop._on_RerollButton_pressed` | presses the reroll button |
| Go | the Go button's `pressed` loses `BaseShop._on_GoButton_pressed` | presses the Go button, or `_clear_go_button_pressed` |
| combine / recycle | the item popup's `item_combine_button_pressed` / `item_discard_button_pressed` lose `BaseShop`'s handlers | emits the popup's signal with the host's weapon object |
| meca upgrade | see [Meca upgrade](#meca-upgrade) | |
| endless (player 1, wave 20) | `EndlessButton.toggled` loses the panel's handler | sets `pressed` on the host's button, mirrored back with `set_pressed_no_signal` |

`SHOP_INTENT` is `shop_id, seq, kind, slot, id, arg`.

- `slot` and `id` name the target by place and by identity (shop item node index and `my_id`, or
  index in the weapons list and `my_id`). The host takes the node at the slot when it holds that
  id, else any node that does, else drops the intent.
- `seq` is the sender's panel revision. The host bumps it when the panel offers something new
  (offered item instances per node, reroll count, weapon instances; not locks or gold) and at once
  when it applies a press, because buy and steal run deferred in the game. A second press made
  before the host's answer arrived (two quick buys) is therefore dropped as stale.
- "go", "endless" and "lock" carry the wanted state, are applied at most once and ignore the
  revision.
- `ShopItemsContainer` ignores presses for 0.05 s after a buy, steal or dismantle, for an intent as
  for a local press.
- With a steal left, the select shortcut steals and locks in one press in local co-op. The client
  only sends the steal.

**Host cursor after an intent.** `_settle_host_cursor` runs deferred after every applied intent. The
game's combine handler moves the cursor with deferred `grab_focus` calls, one of them onto an
element it already queued for deletion. The function puts the cursor back on what the client last
reported (`ShopSync.host_apply_focus` keeps each player's last `SHOP_FOCUS` target) when a cursor
can rest there, else it leaves the game's place. A reported gear element is found by its item on
the host's rows, which can be newer than the client's ones it was described on. Once its item is
gone (recycled, combined) it is the live element at its last place, which is where the client's own
cursor goes when the host's state takes the item (`_refresh_gear`), until the client's next report.

**Client's own panel.** While the own panel runs and the host is not paused, `ShopLocal.process`
checks every frame that its device is the live one and takes it back if not, with a warning. The
slot type survives state updates (only `fill_puppet_slots` at shop entry resets it).
`CoopShopHint`s get the panel's player. Shop specific: while the own Go flag is set or a "go 1" is
on its way, and the cursor rests on Go, mouse hover leaves the cursor there
(`LocalPanel.hold_cursor`), because the game clears the flag when the cursor leaves Go.

### Level-up and crate panels

`sync/upgrades_sync.gd`, `sync/upgrades_gear.gd`, `sync/upgrade_options.gd`. Each
`CoopUpgradesUIPlayerContainer` is a `Carousel` with pages (upgrades, gear, stats) and a
per-player item popup toggle.

**State** (section `upgrades`). The provider is inactive unless the host's battle shows the panels.
The key is the run cache's `rev` plus the text of the panels (`capture` from `_old_upgrades`,
`_level`, `_reroll_price`, `_item_data`, `_checkmark_group`; `seqs`, `pages`, golds, meca rolls,
open popups, `kinds`, battle id). The run travels in parts as in the shop. A run change alone (gold or a fruit
still flying in) is sent too.

**Client.** `apply_state` returns false until the state's battle is the puppet's and its scene is
ready. `battle_entered` calls `retry()`. The client re-implements `show_upgrades_for_level` without
`ItemService.get_upgrades` and uses `show_item` for crates (the item rebuilt from the `ItemService`
base and `deserialize_and_merge`). A null body stops the own panel's input. The puppet's panels stay
shown until its scene goes.

- **Option ids** (`sync/upgrade_options.gd`). The host sends each panel's options as `my_id`s, and
  `UpgradeOptions.resolve` turns them back into what `get_upgrades` returned: an element of
  `ItemService.upgrades`, copied with its effects scaled like `get_upgrade_data` does when the
  player has `level_upgrades_modifications` (Captain, Barnacle; the run state is applied before the
  panels), or `ItemService.weapon_slot_upgrade_data`, which is not in that list. `get_upgrades`
  returns only the latter while a character has weapon slots to gain (Baby: one slot,
  `weapon_slot_upgrades`). An id that resolves to nothing is logged and left out. Before, only
  `ItemService.upgrades` was searched: Baby's panel showed no option and no reroll on a client,
  and a client playing Baby had its cursor on a hidden button that takes no accept, so the host
  waited for its choice until it left. `level_up_options_tests.gd` (suite `level_up_options`)
  checks Baby as a client, next to a spectator and as the host, and the scaled options.

- The own panel needs `Utils.set_process_input_where_defined(ui, true)`, which
  `main._on_EndWaveTimer_timeout` does on the host and which never runs on a puppet.
- **Per-player rebuild** (`UpgradesGear.changed_players`). A new run state rebuilds only the players
  whose parts changed: stats, gold label and crate weapons list when `p<p>` or `g<p>` moved, the
  gear page's items only when `g<p>` moved, its weapons (new objects of the same weapons) when
  either moved. The first state for new panels rebuilds every player.
- **Gear in place** (`UpgradesGear.sync_inventory`, issue #110). The game's `update_inventory` frees
  and instances every element (~250 late in a run, about 47 ms headless for one player). The gear
  page instead keeps every element that shows the same (item id, tier, cursed / meca / mutant,
  icon), points it at the new object and sets its count, repaints a spare one or instances only
  for the rest, and frees what is left. The order is the one `set_elements` leaves (entries
  reversed, the character and builder turret first, `order_of_addition`), then
  `need_to_sort_inventory` lets the game's sorter order them as it would after a rebuild. An empty
  inventory (new panels) or a locked item takes the game's way.

**Guard.** On every container the four decision signals lose `UpgradesUI`'s handlers
(`choose_button_pressed`, `item_take / discard / ban_button_pressed`), the reroll button loses
`_on_RerollButton_pressed`, and the crate weapon popup loses combine, discard and meca upgrade
(`UpgradesUI._on_weapon_*`). The container-local part still runs (press delay, meca choice, the
hold-to-ban loop with its progress bar).

**Host.** The panel revision is keyed on the entry, the option being processed, the item instance,
the reroll count and the player's weapons, so the same crate item twice still counts.
`host_apply_intent` drops an intent whose revision or option id does not match the sender's panel,
then calls the container's own handler (`_on_choose_button_pressed`, `_on_RerollButton_pressed`,
`_on_TakeButton_pressed` after setting `_meca_effect_choice_selected`, `_on_DiscardButton_pressed`,
`_on_BanButton_pressed`).

**Intents during a host pause.** `CoopUpgradesUI` runs with `pause_mode` process, and
`_on_choose_button_pressed` emits `options_processed` synchronously. A remote player's last decision
applied during the host's pause would make `main.gd` load the shop with the tree still paused.
`host_apply_intent` therefore holds an intent while the tree is paused (`UpgradesSync._held`, at
most 8) and applies the held ones in order once it resumes. As a safety net,
`PauseControl.release_stale_pause` resumes a host shop that starts paused with its menu closed.

**Crate weapon popup** (characters whose crates give weapons, `effect_crate_give_weapon`). Only the
host's `_show_next_player_options` fills the weapons list, so the client calls
`_refresh_weapons_inventory` for every panel it rebuilds and whenever that player's parts changed. A
cursor in the list keeps its slot. The own popup's actions leave as `UPGRADE_INTENT` kinds
`weapon_combine`, `weapon_discard`, `weapon_meca_roll` and `weapon_meca`, with `weapon` (the slot in
`RunData.get_player_weapons`) and `id` (its `my_id`). The popup then closes like after a cancel. The
host checks revision, `_weapons_inventory_enabled`, slot and id, calls the game's handler and counts
the intent as applied only if the weapons changed.

### Meca upgrade

`sync/meca_choice.gd`, the same for the crate weapon popup and the shop's item popup.

Game rule: `ItemPopup._get_upgrade_preview` rolls the two stat options (`DLC2Data.meca_item`) when
the upgrade button is hovered or pressed and keeps that roll per weapon object in
`_upgrade_preview_cache` for the popup's lifetime. Reopening the popup shows the same two options,
and while choosing there is no cancel.

- **Client.** Every popup's upgrade button loses `_on_UpgradeButton_pressed`, and
  `item_meca_upgrade_selected` loses the game's handler. The own popup's button sends
  `weapon_meca_roll` / shop "meca_roll" (slot, `my_id`, panel revision) when `can_meca_upgrade`.
  The host's rolls arrive in the state (`mecas`). If the popup is still open on that weapon, the
  preview is built like `meca_item` builds it but without rolling (`do_not_add_effect`), with two
  `EffectOption`s from the host's key hashes and values, put into the popup's cache, and the game's
  own `_on_UpgradeButton_pressed` shows it. A roll already in the state is shown at once. The pick
  leaves as `weapon_meca` (`meca`: 0 / 1) or shop "meca" (`arg`: 0 / 1). The hover preview still
  rolls locally, for display only.
- **Host.** `MecaChoice.roll` puts the roll into the host's copy of that player's popup cache with
  the game's code. An existing roll is returned, so asking again never rerolls. Checks: the weapon
  by slot and id, DLC active, `has_meca_upgrade_ui`, `can_weapon_be_mechanized`, cost above 0, the
  parts, the revision, and not paused (shop) or `_weapons_inventory_enabled` (crate). A roll does not
  change the revision. The state sends per player `[[weapon slot, my_id, stat key hash, value, stat
  key hash, value]]`.
- **Pick.** It needs a remembered roll for that weapon, an int index 0 or 1, a matching revision
  and the parts. The roll is then forgotten and `change_effect_option_to_modular_effect(roll,
  index)` goes to the game's handler (`UpgradesUI._on_weapon_meca_upgrade_selected`, or the popup's
  `item_meca_upgrade_selected`), which spends the parts. A client can therefore only get one of the
  two options the host rolled.
- **Other players' copies.** The choice is part of the popup's view (below). A copy shows it from
  the host's roll: the host's copy with the roll its popup keeps (`MecaChoice.show_kept`, never a
  new roll), a client's copy with the state's `mecas` entry of that weapon
  (`MecaChoice.show_roll`). A client's gear can show the weapon objects of an older run state
  (gear elements are only rebuilt when the gear changed), so an entry matches by slot and id when
  the popup's object is no longer the player's.
- **Log.** The game's `coop_item_popup.tscn` connects the two option buttons' signals to
  `_on_ButtonWithIcon_*` on the popup, which has no such methods: every focus, hover or press of
  an option logged "Method not found". `extensions/ui/coop_item_popup.gd` defines them empty (the
  buttons' own scene does the work), since the choice now shows on every machine.
### Open popups

`sync/popup_view.gd`, used by the shop and the level-up / crate panels. A player's open menu is
shown on every machine's copy of that player's panel, as in local co-op: the item popup the game
focuses on accept on a gear weapon (its buttons, or the meca upgrade's two options), and the menus
other mods open in that popup or on the panel.

- **View** (wire format): `[]` when nothing is open, else `[element, id, meca, mods]`: the gear
  element the popup was opened from (`PopupManager._elements_pressed`, as a cursor target in the
  player's panel, `[]` when a mod opened the popup on something else), its item's `my_id`, 1 while
  the meca choice shows, and `[popup's menu, panel's menu]` from `together_menu()` (null: none;
  only ints and strings, at most 256 bytes).
- **Where it travels.** A client reports its own panel's view with its cursor (`popup` in
  `SHOP_FOCUS` / `UPGRADE_FOCUS`). The host shows it on its copy before it puts the cursor there.
  The host's state carries every player's view as its copies have it (`popups`), and a client
  shows every view but its own.
- **Showing a view** (`PopupView.apply`) uses the game's own steps: the cursor onto the element,
  then the element's press through `FocusEmulatorSignal` (`PopupManager` focuses the popup, the
  shop dims the panel), then the meca choice (see [Meca upgrade](#meca-upgrade)), then
  `together_show_menu(menu)` on the popup or panel. A view that names something else closes what
  is open first: `together_show_menu(null)`, then the view half of the game's Cancel
  (`PopupManager.reset_focus`, the dim screen off, a cursor left on a hidden button back on the
  element). It does not emit `item_cancel_button_pressed`: the game's handler moves the cursor with
  a deferred `grab_focus`, which would land after the mirrored cursor. A popup left focused or a
  panel left dimmed with nothing open (the game hid the popup under a cursor move) counts as open
  and is closed by an empty view. An element whose item has another id opens nothing. A view this
  machine cannot show (no roll yet, a weapon that differs, its element hidden) is not tried again
  until the view, the rolls, whether the element shows or what the panel shows change (`memo`).
  The host's shop sets the reported carousel page before it shows the view, as the level-up side
  does: the element shows only on the gear page.
- **Godot's focus.** The press runs `ItemPopup.focus()`, whose `grab_focus` goes to that player's
  FocusEmulator, which releases the focus owner. A control that held the focus before (one no
  emulator takes, such as the lobby popup's buttons) gets it back at the end of `apply`.
- **Cursors.** Opening a popup takes that player's cursor to its Cancel button. A client then
  re-applies the last cursors body (`FocusSync.reapply`); a body still pending is retried by the
  stream anyway. The host puts the reported cursor back itself.
- **The host keeps a reported view** (`_reported_popups`) and shows it again each frame when its
  copy changed under it (a gear rebuild closes the popup), until an intent of that player is
  applied (the game's handler closes the popup then, and the client's next report says what is
  open) or that client leaves (`peer_removed`: the copy closes).
- brotato:trade's remote buy for another player closes the giver's buy-for list on the host's copy
  first (`trade_buy_apply_request`), as the local press does.
- brotato:trade defines the menu methods on its `CoopItemPopup` extension (`["give"]`, `["buy",
  shop item slot]`) and on its crate panel (`["trade"]`). On a client its lists and buttons show on
  another player's copy while the host trades (`Together.can_show*`), and only the own panel's
  presses are sent.

`shop_popup_view_tests.gd` (suite `local_shop`) checks a remote player's popup and meca choice on
the host's copy, the host's state, a client's copy of another player's popup and its meca choice
with the host's roll, the cursor going back into the copy, and the own popup's report; also a
copy left dimmed, a client that leaves, the cursor after a closing state, and gear changing under
another player's cursor; also a report with the gear page and its popup, Godot's focus kept,
`ShopSync._deactivate` and `FocusSync.reapply` with a body pending. `upgrades_change_tests.gd`
checks a crate weapon popup on the host's copy, in the panels' state, and on a client's copy
through `UpgradesSync.apply`; `upgrades_popup_tests.gd` (suite `upgrades_popup`) Godot's focus and
a client that leaves there. brotato:trade's `together` and `together_crate` suites check its lists
on both kinds of copies.

### Keyboard and mouse on the own panel

`sync/local_panel.gd`. `LocalPanel` is a node added as the last child of the puppet `UpgradesUI` or
puppet shop (after `FocusEmulator1..4`), so it sees every input event before the emulators (see
input order in the [Overview](#1-overview)). It does nothing while the lobby popup is open or the
host is paused.

**Device type.** Puppet slots are typed `GAMEPAD_XBOX` (`VirtualDevices.fill_puppet_slots`). A
keyboard has no trigger binding and `Carousel` disables its arrows for a gamepad, so the client's
own slot takes the `PlayerType` of what its player used last (`VirtualDevices.set_slot_type`): from
`InputService.using_gamepad` when the panel starts, then from the events (key, mouse button, mouse
motion faster than 1000 px/s as in `UIService._check_input`, pad button, stick past the deadzone).
The game fixes the type when a co-op player joins, so `LocalPanel.refresh_player_type` redoes what
`_ready` did: the carousel's arrows (textures from the scene file, since `Carousel` overwrites them
with trigger glyphs), `InputIcon`s and `CoopShopHint`s. The screen's module then calls the
container's `_set_focus_neighbours` and moves a cursor that sat on an arrow that became a glyph.

- On a puppet the type is read only by `Carousel`, the key glyphs and aim (behind
  `Utils.is_manual_aim`, never set on a client). The next `fill_puppet_slots` resets it.
- The other machines learn the type from `INPUT` and section `input_types` (next section).

### Key hints of other players

`sync/input_types.gd`, the `CoopService` and `Utils` extensions. The game reads one type per slot,
`connected_players[p][1]`, for two things: aim (`Utils.is_player_using_gamepad`: the right stick,
`weapon.gd`'s rotation) and the UI (`CoopService.get_player_input_type`: `Carousel`'s triggers or
arrows, `InputIcon`, `CoopShopHint`, `CoopShowCharacterHint`). A remote slot must stay a gamepad for
aim (its client sends mouse aim as the stick), so the two are split:

- The `Utils` extension answers `is_player_using_gamepad` in co-op from the slot's own type
  (`CoopService.bt_slot_uses_gamepad`), which never changes for a virtual device.
- The `CoopService` extension answers `get_player_input_type` (and through it
  `is_player_using_gamepad`) with the type the hints should show. Host: `bt_device_types`, remote
  device -> the type from its `INPUT` flags ([Remote input](#remote-input)). Client: `bt_slot_types`
  from section `input_types` for the other slots, and `VirtualDevices.local_player_type()` for its
  own slot (`bt_own_slot`). Anywhere else, and before anything arrived, the slot's own type.
- Section `input_types` is `{types}` (per slot) with `you` patched in per peer. The key covers the
  slots, the reported types and the peers' devices. It is active while there are slots, and a
  client drops what it has on a null body and on `lobby_left`.
- A changed type emits `CoopService.bt_input_types_changed(player)`. `InputTypes` then finds that
  player's open panels (`CoopShopPlayerContainer`, `CoopUpgradesUIPlayerContainer`,
  `EndRunPlayerContainer`, not inside `Node2D`s) and runs `LocalPanel.refresh_player_type` and the
  panel's `_set_focus_neighbours` on them, as for the own panel above. A client's own slot never
  emits: `LocalPanel` follows it.
- Game bug: the `InputIcon`s inside a panel (the shop items' lock and ban keys, the level-up ban
  key) stay on player 0, so every panel showed the first player's keys. The extensions of the three
  panel scripts call `InputTypes.adopt` in `_ready`, which gives them (and `CoopShopHint`s) the
  panel's player.

`input_hint_tests.gd` (suite `input_hints`) checks a keyboard client's shop and level-up panels on
the host and on another client, switches both ways, and the `INPUT` round trip. It names no game
class: naming `CoopShopHint` in a script that is preloaded at init makes two of the game's hint
scripts fail to parse when the shop loads.

**Mouse.**

- Motion over a focusable control of the own panel sets the own emulator's `focused_control`. A left
  click runs the emulator's own accept (`_handle_input` with an `ui_accept_<device>` action event),
  so the press carries the player index. A native GUI press could not: `PopupManager` books a press
  without `FocusEmulatorSignal` on player 0, and the container holds a plain `Control` over all of
  its content.
- The hit test asks what the emulator could focus: of the visible, enabled `FOCUS_ALL` controls
  under the pointer, the last in tree order, with clipping parents cutting their children. An open
  `ItemPopup` covers the controls below it, so hovering its description does not move the cursor or
  click the item underneath.
- The popup touches its item (`extensions/ui/coop_item_popup.gd`). `BasePopup._get_new_position`
  leaves `BasePopup.DIST` (10 px) above or below the item. In the stacked shop the next item lay in
  that gap, so the mouse on its way down into the popup hovered it and the popup switched to that
  item. The extension moves a popup that sits within `DIST` above or below its item onto the
  item's edge and keeps the game's flip above, clamping and sideways shift. It applies to every
  `CoopItemPopup` (shop, level-up, end of run) on every machine, online or not: on the host the
  game's own `mouse_exited` closes the popup when the mouse leaves the item, so nothing changes
  there but the drawing, and all machines draw the panels alike. The popup never covers its own
  item, so the keys' cursor stays visible.
- Motion from the cursor's item or its open popup (or within `BasePopup.DIST` of the item, the gap
  the game's sideways shift still leaves) to where no control is hit closes that popup, also off
  the panels. Only the popup is hidden: the
  cursor and the shop's focused item (lock, steal and ban keys) stay, where the game's
  `mouse_exited` unfocuses the item. Hovering the item again re-emits its `focus_entered`. A popup
  the cursor keys opened stays while the mouse moves in empty space.
- A popup that took the cursor (`ItemPopup._focused`, the crate weapon popup) keeps the mouse too:
  only its own buttons are hit.
- A mouse press stands for an accept that is held until the button comes up. `LocalPanel` then
  sends the release of `ui_accept_<device>`, which ends the popup's hold-to-recycle.
- Every mouse event over any player's panel is marked handled, so another player's panel never
  reacts.
- The wheel scrolls the innermost `ScrollContainer` under the pointer in the own panel only (see
  [Scroll positions](#scroll-positions-wheel-and-right-stick)).

### Cursors

`sync/focus_sync.gd`, `ui/focus_targets.gd`. Section `cursors` mirrors every `FocusEmulator` of the
host's scene. The body is `scene, cursors [[player, menu, control]]`, applied through the
`focused_control` setter. The section is inactive while the host's scene has no emulators.
`ui/scene_paths.gd` finds the emulators (used by `FocusSync`, `CoopSelection` and `CoopMode`).

Nothing travels as a tree position, because the trees differ between machines as soon as one side
has a mod that adds a control.

- **Emulator.** Its `player_index` among the `FocusEmulator` children of its menu (the node they hang
  under: the shop scene root, `UpgradesUI`, `PauseMenu`, `RetryWave`). A menu with a single emulator
  takes it whatever its index.
- **Control.** A cursor target `[anchor, player, index, steps]`. The anchor is the nearest part of
  the player's panel that the game hands out through its own accessors:

  | Anchors | Source |
  |---|---|
  | `shop_item` (k in `_get_shop_items_container(p)._shop_items`), `shop_reroll`, `shop_go`, `shop_popup`, `shop_gear`, `shop_panel` | `CoopShop._get_*` |
  | `up_option` (k in `_get_upgrade_uis()`), `up_reroll`, `up_popup`, `up_weapons`, `up_gear`, `up_panel` | `UpgradesUI._get_player_container` |
  | `scene` | the fallback for every other screen |

- **Steps** lead from the anchor to the control. A node from a scene file (it has an `owner`) is
  named. A node added by code (generated names differ between machines) is `[script path or class,
  k]`, the k-th such sibling of that type, with nodes queued for deletion not counted.
- **Gear elements** (protocol 32): an `InventoryElement` that shows an item below `shop_gear`,
  `up_gear` or `up_weapons` (`FocusTargets.KEYED`) is `[script path, key, copy]` instead. The key is
  what it shows, the same on every machine (`FocusTargets.item_key`: `my_id`, tier and the cursed,
  meca and mutant marks; not `UpgradesGear.shows`, which has a local icon's instance id), copy its
  place among the live siblings that show the same (two alike weapons, two cursed copies). It
  resolves by key and copy only, never by place: while a run state is on its way the rows of host
  and client differ (a gift, a purchase or a combine inserts an item before the cursor; ties of
  tier and name, such as a plain stack and its cursed copy, can sort either way), and a position
  named another item there. An item the receiver does not have resolves to nothing: `FocusSync`
  keeps the body pending until the run state brings it, and the host ignores a report naming it.
  A special (locked or random) element and the grids of the selection screens and the end of run
  keep `[type, k]`: `MenuSync` builds those in the host's order from the host's entries, which can
  show an item otherwise than this machine would (locked, another tier).
- Network data is checked (types, anchor names, player 0 to 3, counts, name lengths). The own-panel
  messages accept only that player's anchors, never `scene`.
- **Applying.** `apply_state` skips `local_emulators` and returns false until every cursor resolves
  to a visible control, so the stream retries for up to 10 s. A newer body for the next scene
  replaces one still waiting.
- **Re-applying.** A client's gear refresh of another player (`ShopSync._apply_body`,
  `UpgradesSync.apply`) can leave that player's cursor on the element at its place, when its own
  element was freed or now shows another item, and opening a copy of a popup takes it to Cancel.
  Both then re-apply the last cursors body (`FocusSync.reapply`, which leaves a body still pending
  to the stream).

**Key.** Describing a cursor is too slow for 20 checks a second, so the key is each cursor's control
and emulator by instance id and child indices up to the scene, plus the player count and the scene
instance, and for a gear element its item key (`sync_inventory` can point a kept element at another
item). `cursor_key_tests.gd` checks that every change the game makes to the description moves the
key. Known difference: a sibling queued for deletion (`BaseShop._combine_weapon`) moves the key only
when it is freed, so that cursor goes out one check late. Changes another mod could make without
moving the key (a rename, a script change, a sibling replaced at the same index) are caught by a
safety net: while the key stays the same, the cursors are described once a second and compared with
the last body. A difference is logged as a warning and sent.

**Tests.** Suite `focus_targets` (`focus_target_tests.gd`) checks gear element steps on a row
ordered otherwise, with an element more or less, with copies and cursed copies, an absent item and
malformed steps. The race of a cursor body with the run state that inserts an item before it, in
both orders and with a cursor on the item that comes in: `shop_gear_change_tests.gd` (shop),
`gear_rebuild_tests.gd` (suite `battle_loopback`, level-up gear page), and brotato:trade's
`together` suite (a gift). The host's side with a report described on older rows:
`shop_cursor_tests.gd` (suite `local_shop`). The stream's order: `state_stream_tests.gd`.

### Scroll positions, wheel and right stick

`sync/scroll_sync.gd`, `ui/wheel_scroll.gd`, `ui/shared_scroll.gd`.

**Mirroring.** A panel is scrolled where it is driven, so the positions travel both ways. This
covers the co-op shop (`CoopShopPlayerContainer`), the level-up / crate panels
(`UpgradesUIPlayerContainer`) and the selection screens (the player's panel).

- A panel's positions are every `ScrollContainer` below it that shows and has more content than room
  (`WheelScroll.can_scroll`), as `[target, scroll_vertical]`, at most 16 per player. The target is a
  cursor target by the player's anchors, or relative to the player's panel on the selection
  screens, which have no anchors.
- Client to host: `PANEL_SCROLL = {scene, scrolls}`, reliable, on change, checked every 0.1 s, for
  the own panel only. The host takes it for the sender's player on the same scene.
- Host to clients: section `scrolls`, `{scene, players: [[player, [[target, value]]]]}`. The key is
  the containers' instance ids and values. A client follows every panel but its own.
- A received value moves its container at least at the stick's speed (600 px/s) and faster over a
  long way (12 times the rest per second). It is let go once reached, so the receiver's own game is
  not held back by an old value. A target that does not resolve yet is retried for 2 s.

**Mouse wheel.** The game has no wheel on co-op screens (input order, and
`BaseSelection._scroll_with_mouse_wheel` returns at once in a co-op run). `ui/wheel_scroll.gd`,
called from the `FocusEmulator` extension's `_input`, scrolls the innermost `ScrollContainer` under
the pointer in the mouse player's own panel and marks the event handled. The mouse player is the
keyboard player (`KEYBOARD_REMAPPED_DEVICE_ID`) on the host and in local co-op, and `you` on a
client's copy. The panels are the shop's, the level-up panels', the selection screens' and the end
of run's (`CoopEndRun.player_containers`). A client's own shop or level-up panel scrolls in
`LocalPanel`. On the host the game
hides the pointer in co-op, so the wheel scrolls where the hidden pointer is.

**Right stick.** The game scrolls each panel's description with that player's right stick
(`CharacterPanelUI._process`, `ItemDescription._process`). A remote player's stick is its `INPUT`
aim on its virtual device. On a client's copy `InputSync._menu_copy_device` gives the own slot
device this player's right stick (the shop uses `_drive_local_stick`).

**Shared grid.** Every `FocusEmulator` scrolls its control into view (`_ensure_control_visible`). The
character grid is shared by all four emulators. `extensions/ui/focus_emulator.gd` and
`ui/shared_scroll.gd` skip that for a `ScrollContainer` another emulator of the same menu reaches,
unless the cursor is this machine's: on the host a player whose device is not virtual, on a client
the state's `you`. While no player of this machine has joined, every cursor counts.

### Selection screens and end of run

`sync/menu_sync.gd`, `sync/menu_puppet.gd`, `session/puppet_menu.gd`. The client runs the game's own
scenes (`character_selection.tscn`, `weapon_selection.tscn`, `difficulty_selection.tscn`,
`coop_end_run.tscn`, `coop_resume.tscn`) as copies that decide nothing.

**Host state.**

- `menu`: kind, `screen` (the host scene's instance id), player count, `coop`, who selected,
  colours, and `you` as the per-peer patch. Character selection adds the zone `[id, random]`,
  endless and `join` (hold progress while joining is open). Weapon selection adds `picks` and
  `character_shown`. End of run adds `pages`. The co-op resume screen adds `shown` (the saved
  player it shows, `_player_label.player_index`) and `join`.
- `menu_grids`: per visible grid every element `[my_id, flags, tier]` in the host's order. For
  weapon and difficulty selection, the end of run and the co-op resume screen it also carries the
  run state, packed once per screen, and `won`.

**Entering** (`MenuPuppet._enter`, when a state names another `screen`): puppet mode, one puppet
slot per host player, `RunData.reset()` for the character selection or the host's run for the
others, co-op play mode, `RunData.menu_selection_back` for the character selection
(`init_coop_service` keeps the slots only on that path), then `change_scene`. The copy is muted.

**Grids.** `session/puppet_menu.gd` keeps the host's lists as this machine's items (duplicates with
the host's tier and lock). Script extensions of the three selection scenes return them from
`_get_all_possible_elements` / `_get_unlocked_elements` while puppeting, so the scene's own code
builds the host's grid. A grid that still differs after a grids change is rebuilt the way
`_set_base_ui_player_count` does, with the cursors put back by index. Ids this machine does not know
are left out (logged). Character cells are coloured by the host's tiers (`MenuPuppet._apply_tiers`),
because `CharacterSelectionInventory.update_elements_color` reads this machine's progress.

**Cut while puppeting**, in the extensions: `_on_element_pressed`, `_on_selections_completed`,
`_go_back`; in character selection also `_on_BackButton_pressed`, `_on_coop_initialized` and
`_on_ZoneSelectionButton_item_selected` (it writes `ProgressData.settings`).
`CoopService.listening_for_inputs` is kept off (nobody joins on a client). At the end of run,
`BaseEndRun._button_pressed = true` spends its three buttons. On the selection screens a full-rect
control on top of the copy takes the mouse (the end of run: see below). A control of the copy that
gets the keyboard focus loses it in the same frame. On the co-op resume screen the copy's
`_on_connected_players_updated` is disconnected (it would step to the next saved player and load
the shop by itself) and its `_input` is off (cancel loads the title screen).

**Mouse at the end of run** (`sync/end_run_mouse.gd`). A node added as the copy's last child (after
`FocusEmulator1..4`, so its `_input` runs first) is the mouse for looking, as on the host:

- Every mouse event but the wheel is marked handled, so the copy's own controls never get one:
  restart, new run, exit, the inventories' sort buttons. Nothing is sent and no cursor moves.
- Hovering an item (weapons, items, the progress rewards) or a stat of any panel shows that
  player's popup, the progress rewards the own player's. Items go through
  `ItemPopup.display_element`, not `PopupManager._on_element_hovered`, which grabs the focus (a
  cursor would follow). Stats get `mouse_entered` / `mouse_exited` on their label through
  `FocusEmulatorSignal`, which names the player. The popup stays while the mouse is on it or in
  the gap to it. When the mouse leaves, the popup of that player's cursor shows again.
- A click on a carousel arrow turns that panel's page here only, through the `index` setter
  without `index_changed` (the container would move the cursor). A popup whose control the page
  took away closes. A page turned here stays until the host's page of that panel changes
  (`MenuPuppet._apply_pages` applies a page only when it differs from the last one received). A
  key or pad press brings the own panel back to the host's page, where its cursor moves.
- The wheel goes on to the emulators (`WheelScroll`, the own panel). The end of run has no
  scroll mirror, so it stays local.
- Nothing is handled while the lobby popup is open (`InputSync.local_input_blocked`).
- The script is loaded when the copy is ready, not preloaded: compiling its game classes at mod
  init broke the shop hints' scripts (`coop_ban_shop_hint.gd` parse errors).

**Applied from every state:**

- The player count (`connected_players_updated`; the scene adds and removes its panels itself). A
  rising count on the character selection waits until the grids carry the grid
  (`MenuPuppet._grid_ready_for`), because `CharacterSelection._on_connected_players_updated` puts
  the new player's cursor on the grid's first child.
- Who selected: `_has_player_selected` and the panel's `selected`, re-applied every frame, never
  `_set_selected_element`, which ends the screen.
- Zone, background and endless, without the scene's handlers.
- The join progress, through the `CoopService` extension (`bt_remote_progress`).
- The saved player the co-op resume screen shows (`CoopResume._update_player_index`).
- Pick counts and end-of-run carousel pages (a page changes only when the host's page does, see
  above).
- `character_shown`: `WeaponSelection._input` switches a panel to the player's character while
  `ui_info` is held. The copy makes the same calls when the state differs from what its panel
  shows. The host reads the value off its panels (`MenuSync.shows_character`).

**Locked in.** The game lets a co-op player's cursor wander after the pick, and accept on another
character replaces the pick. The `FocusEmulator` extension
(`_locked_in`) spends a selected player's moves and accepts, and ignores the Godot focus for it,
on every `BaseSelection` screen (character, weapon, difficulty) while `_has_player_selected` holds:
until cancel clears it or the screen moves on. On a client's copy the flags are the host's, so its
cursors stay too. A player who leaves character selection takes the pick along: the game keeps
`_has_player_selected` and `_player_characters` per slot, so the next player in that slot (a
rejoin, a player moving up) would start locked in on the old character. The `CharacterSelection`
extension's `_on_connected_players_updated` clears every slot from the first one whose device
changed (`_bt_slot_devices`), on the host only. Weapon and difficulty selection need nothing:
players join and leave only while the game listens for joins (character selection, the co-op
resume screen), so their slots do not change there. Suite `selection` checks both.

**Locked characters.** The game's `LockedPanel` shows on the copy through the same code, locked
where the host has it locked. The text is this machine's, so it is localised.

**Screens without a copy** (a host choosing for or playing a solo run) show
the waiting screen, `ui/client_view.gd` (key art, connection line, where the host is). The host's
title screen is not one of them (see
[Client in its own main menu](#client-in-its-own-main-menu)).

### Retry prompt

`sync/retry_sync.gd`. `main._on_EndWaveTimer_timeout` shows `UI/RetryWave`, which never runs on a
puppet. Section `retry` is active while the host's prompt is visible. It carries
`settings.retry_wave`, `RunData.retries` and the deciding player, and stays pending until the puppet
battle is ready. The client shows its copy with `confirm/cancel_button_pressed = true`, so local
clicks do nothing, and a line saying whose choice it is ("Waiting for Player 1 (name) to
choose...", with the game's `COOP_PLAYER`).

### UI sounds

`sync/ui_sounds.gd`. Outside a battle the host batches sounds per frame and sends them as
`UI_SOUNDS` (`res://` path, volume, pitch, position). The client checks paths
(`SoundRelay.is_sound_path`, `ResourceLoader.exists`, `AudioStream`) and clamps volume and pitch.

- The puppet shop and the menu copies are muted until they leave the tree, because mirrored state
  and cursors would replay their own sounds. The waiting screen stays audible.
- Sounds played while the host's tree is paused are not recorded.
- UI pages that play their own `AudioStreamPlayer` (profile, codex, item sets) bypass
  `SoundManager` and are host-only.
- `UiSounds.silent` is set while a client is in its own main menu.

## 8. Lobby UI

`ui/lobby_menu.gd`. The lobby lives in the game's own menus. `LobbyMenu` (a child of the mod node)
holds the lobby actions, the texts (`details_text`, `status_text`, `leave_question`) and the last
error. It finds the places for its controls when `current_scene` changes (polled, no script
extension of a menu). Layout sizes are constants in the `ui/` files and are checked by
`online_layout_tests.gd`, `coop_mode_tests.gd` and `lobby_menu_tests.gd`.

### Title screen

`ui/lobby_frame.gd`. There is no page on the title screen.

- **Entry button.** A `MyMenuButton` below `MainMenu.start_button` (same script, alignment, height
  and left / right focus neighbours) does what is next: *Host lobby* (without Steam, the reason
  appears in `%ErrorLabel`), *Creating lobby...*, then *Invite friends* as host or *Leave lobby* as
  client. Its minimum width is that of its widest text, so the column does not change width; it
  is measured again after a language switch ([Localization](#localization)).
- **Frame.** Shown while `transport.is_active()` or `creating`. It lists the players
  (`LobbyMenu.players()`, the host first, with a note per player: host, you, connecting, no
  response, ping), `n / 4`, a hint (`hint_text()`), and for the host *Kick* behind every other
  player and *Leave lobby*. It is a child of the `HBoxContainer` of the two button columns, right
  after `ButtonsLeft`, with `SIZE_EXPAND`, so it takes the row's spare width and the columns keep
  their rects.
- **A client's Start and Continue** get `disabled = true` every frame. `MyMenuButton.disable()` is
  not used: `MainMenu.setup_menu` grabs their focus on every return to the main page, which is an
  engine error on a `FOCUS_NONE` control, and `TitleScreen.update_continue_button` activates
  Continue again each time.
- Character selection entered from the title screen while hosting gets `CoopButton.pressed = true`.

### Client in its own main menu

`mod_main.gd`. While the host is on its title screen (menu state `kind == "title_screen"`, its pages
included) there is nothing to mirror, so the client is on its own title screen. A client that
becomes ready on its title screen stays there, and the title state (`_enter_own_menus`) loads the
title screen from anywhere else.

Meanwhile the game is its player's own: puppet mode is off (own run data and saves),
`MenuPuppet.release` has run, the borrowed DLC is parked (profile switch, item sets and options
would otherwise read and save the host's DLC), `InputSync.local_input_blocked` is set (neutral
`INPUT` to the host, no client mode in `InputService`) and `UiSounds.silent` is set.

This ends before the first message from a screen of the host is read. `Session.host_message` is
emitted right before `message`, as its own signal because of the signal order. `_is_host_screen` is
true for `BATTLE_START` and for any non-null `STATE` except `menu` with the title kind,
`menu_grids`, `cursors`, `scrolls` (those follow a `menu` of the same screen) and `input_types`.
Then the DLC is borrowed again, before any run state or grid is decoded, and input goes to the host.

### Page "Online co-op"

`ui/lobby_page.gd`. The page is built in code like the game's pages (`menu_mods.tscn`), with
`init()` and `back_button_pressed` as `Menus.switch` uses them. Buttons by state: *Host lobby*,
*Invite friends* and *Leave lobby*, *Join invite*. The cursor follows when its button goes away.

- **Pause menu** (battle and shop, host and client): in `PauseMenu._menus`, below `%OptionsButton`,
  and appended to `IngameMainMenu._buttons_array` so `init()` leaves the cursor on it. The button
  calls `menus.switch(main, page)` as `Menus.on_options_button_pressed` does.
- **Leaving mid-run** (`is_mid_run`) asks on the game's confirm page: an instance of
  `menu_confirm.tscn` inside the lobby page, its label set to `leave_question()` and its Yes rewired
  from `_on_ConfirmButton_pressed` (which ends the run) to `LobbyMenu.leave`.
  `focus_before_created` is set to *Leave lobby* after `init()`, because with a `FocusEmulator`
  there is no Godot focus owner and the page's own `null.grab_focus()` only passes in release
  builds. When the page is hidden, the question is dropped (a visible `MenuConfirm` takes every
  `ui_cancel`) and a pending invite is declined.

### Co-op row and invite slot in character selection

`ui/coop_mode.gd`. The game's Co-op toggle becomes one option with three values: "Co-op: Off",
"Co-op: Local", "Co-op: Online" (co-op plus `host()`). It is an `OptionButton` with the zone
dropdown's theme, in the toggle's place and at its height, so the run options box keeps its vanilla
layout. The game's `CoopButton` stays in the tree, hidden every frame, and still switches co-op: the
option sets its `pressed`. Choosing Off or Local leaves the lobby. Without Steam, Online is a
disabled item with a tooltip. On a client the row shows Online and takes no focus and no mouse.

`ui/slot_invite.gd` puts *Invite friends* and the lobby status at the bottom of the player slot the
next player takes (the game's `CoopJoinPanel` at `connected + connecting`). They show while
hosting; the status alone shows while the lobby is made or after it failed. Player 1 reaches the
button left from the Co-op row. The button has `grab_focus_with_mouse` off, because in co-op the
emulator would move player 1's cursor onto it and leave its focus style there. It is 260 px wide
or as wide as its translated text, and the status line (clipped, the whole text in its tooltip)
takes the same width.

`ui/coop_selection.gd` adds two hints. `CoopSelection._process` sets `instructions_visible` on every
free, non-connecting slot while `CoopService.listening_for_inputs` (the game shows the hold-to-join
hint, `COOP_HOLD_TO_JOIN`, only in the next free slot), and adds a "Player N" label (`COOP_PLAYER`) in the slot colour at the top of the
slot. The label's vertical size flags are 0, because a Label's default would centre it over the
hint.

**Host first.** In character selection the host's player joins first: the `CoopService`
extension's `_process`, which runs before the game's, holds back every remote (virtual) device's
hold timer while no device of this machine is in `connected_players` (`bt_holds_wait`,
`bt_local_joined`). It sets the timer to minus the frame's delta, so the game's `+= delta` leaves
it at 0 even after one long frame. A remote player who holds early joins a full hold after the
host's player is in. This is about the order of joining only: when the host's pad disconnects,
the game moves the remote players up. The co-op resume screen is not held back, because its slot
order decides who gets which saved character. Suite `selection` checks it (`host_first_tests.gd`).

**Co-op resume screen, a player who leaves.** The game's `CoopResume` shows one saved player at a
time and steps to the next on every `connected_players_updated`, a leave too: InputSync frees a
remote player's slot when its peer leaves while the game listens for joins, and an unplugged pad
does the same. A leave skipped a saved player, and the last step loaded the shop with fewer players
than the run has (none, in a run of two). The `CoopResume` extension (`extensions/ui/coop_resume.gd`)
steps on a join only: it keeps which saved player each device took (`_bt_taken`) and the saved
players nobody has (`_bt_free`, lowest first, the first is the one shown). A device that leaves
gives its saved player back, and the screen shows the lowest free one again. The shop loads once
every saved player is taken. The game gives saved player i to `connected_players[i]`, and after a
leave the players who joined later have moved up, so the extension first puts `connected_players`
in the order of the saved players taken and emits the signal once more (colours follow their
devices). No protocol change: it runs on the host only; a client's copy of the screen does not
step (`Puppet.is_active`). Suite `selection` checks it (`resume_leave_tests.gd`).

### Popup

`ui/lobby_popup.gd` shows the same page in a panel on the dimmed screen, for a client on a screen
without a pause menu (`popup_on_pause`: the waiting screen and mirrored selection screens, not the
title screen). `LobbyMenu._poll_pause` opens it when the client's own `ui_pause` comes up, read from
the action state because of the input order.

- **Input guard** (`ui/menu_input_guard.gd`). While the popup is open, a guard node kept as the
  root's last child sees key and pad events first, marks them handled and `Input.action_release`s
  what they pressed. After closing it also swallows the releases of keys pressed while open (the
  game pauses and goes back on release).
- The popup moves the Godot focus and handles the mouse itself (`handle_panel_mouse`). A
  FocusEmulator that takes a control (another player's mirrored cursor or popup on a co-op screen
  under the popup) releases that focus: the page gives it back to the button that had it, every
  frame and before an arrow or accept (`LobbyPage._keep_focus`).
- `InputService` hides the cursor in co-op, so the popup shows it again every frame.
- Clients send neutral `INPUT` while it is open (`InputSync.local_input_blocked`).

`LobbyMenu.open()` picks the page on screen, else the current scene's page
(`PauseControl.open_menu`), else the popup. It is used by `ask_leave()` (a client's *Quit*) and by a
Steam invite accepted mid-run.

### Errors

`lobby_failed` (lobby not created, join refused with the host's reason, host left, connection lost)
opens nothing. `last_error` shows in the page's details, in the run options' status line and in the
main menu's `%ErrorLabel` ("(!) ...", where the game reports a broken save): at once if the title
screen is up, else when it loads within 15 s. `MainMenu.init()` resets the label on every return to
the main page.

## 9. Extras

### Player colours

`extensions/singletons/coop_service.gd`. Every colour use in the game goes through
`CoopService.player_colors[slot]` / `get_player_color`. The extension keeps a palette (the game's 4
colours plus 4 pastels) and the picks per player (`_bt_slot_players`): a remote player by its steam
id (`InputSync.steam_id_of` its virtual device, through `CoopService.bt_players`), a local one by
its entry in `_bt_local`, the device each local player last played on. A local device takes its own
entry. A device without one takes over the first spare entry whose device is gone (a pad no longer
in `Input.get_connected_joypads()`: a replugged pad), else borrows the first spare entry whose
device is there but not in a slot (the host on another gamepad; keyboards are always there), else
gets a new entry. The borrow is kept in `_bt_borrow` (device -> entry) while the borrower stays in
its slot, so it does not move to another entry when other devices join or leave or a waiting pad is
unplugged. When the lender joins, the borrower gets a new entry of its own. So nobody keeps another
local player's entry for good: a new pad that joins before the host shows the host's colour, keeps
it while it stays in its slot (the host joining after it gets a free colour), and from the next run
the host has its pick again. The same holds the other way round, as the two cannot be told apart:
the host on a pad keeps its keyboard colour when a couch player joins on the keyboard, and from the
next run that colour is the keyboard's. A borrower that picks gets its own entry first.

It rewrites `player_colors` on `connected_players_updated` and on every pick. A device that stays in
its slot keeps the colour it shows (`_bt_shown`, by device), whoever joins or leaves; only its own
pick changes it. A device that comes into a slot gets its player's pick if no other slot shows it
(newcomers in slot order), else, like every empty slot, its default colour if free and not
reserved, else the first such one. A pick a newcomer finds taken is kept for a later run. Reserved
are the picks of players out of a slot: local entries' and those of remote players still in the
session (`InputSync.has_peer`), so a peer gone for good, kicks included, reserves nothing and a
rejoin brings its pick back. A peer is in the session from its Steam lobby join, so its pick is
reserved before it has a slot, but that moves no colour already on screen. `ui_info` on the
character selection cycles to the next colour that no other slot has and that is not reserved
(remote players send it as a button), and `CoopSelection` restyles what is on screen. A local
player's cycle passes over local reservations (only remote players' block it): the host who picked
on the keyboard and recolours on a pad can go back to its keyboard colour. Remote players and the
defaults still skip that colour while the keyboard has not joined, as the system cannot tell the
host from a couch player on the keyboard. Two local entries can so end up with the same pick; the
one that joins first in a run shows it.

Outside a lobby a pick goes with its slot, as `clear_coop_players` at every new character selection
empties them. From `lobby_ready` until `lobby_left` (`InputSync` calls `bt_set_lobby`) a pick stays
while its player is out of a slot, so the next run starts with it, in whatever slot the player
joins. A peer's pick goes (`bt_forget_player`) when it is removed and no slot is kept for its
rejoin, or when the kept mapping is dropped (`_forget_unassigned_devices`). A peer that drops
mid-run, or during the weapon or difficulty selection, keeps it. Closing the lobby drops the picks
of players out of a slot; the others go with their slot, so a run the host keeps after leaving, or
a switch to local co-op on the character selection, keeps its colours. The next run starts with the
game's, unless the host opens a lobby again before it: the picks of players still in a slot carry
into that lobby. Neither recolours a slot by itself.

The hint row is a child of the scene root anchored to its top right corner, outside the game's
containers, so the screen lays out as without the mod.

Colours travel as palette indices (`colors`) in the `menu` section, `BATTLE_START` and the shop
state. The client validates them (one distinct index per slot) and mirrors them until it leaves the
lobby (`bt_clear_remote_colors`). Nothing is saved.

### Progress for clients

`session/progress_share.gd`, the `ChallengeService` / `ProgressData` extensions, `session/puppet.gd`.
What the run earns counts for every player's own save, as in local co-op.

- **Host.** The `ChallengeService` extension hears every `try_complete_challenge(id, value, below)`
  and `complete_challenge(id)` call. The game returns early when the host already has the
  challenge, so the extension checks the value against the challenge itself
  (`ProgressShare.host_met`). Each id goes out once per session. `ProgressData.increment_stat(key)`
  is counted per key. `PROGRESS = {challenges, stats, won}` is sent at most once a second, at once
  when `run_won` is counted, and only while a peer is ready. A peer that joins later earns what
  comes from then on.
- **Never sent:** challenges that hang on the host's own history. For the lifetime counters
  (`check_counted_challenges`) each client reaches them with its own count, to which it adds the
  host's `stats` (a fixed list of counters).
- **Client.** `Puppet.set_own_progress(true)` around the apply is the one way through the save
  block. Challenges are completed by the game's own `complete_challenge` (popup, platform
  achievement, reward). `_bt_unlock_own` then puts the reward's hash onto the client's own list,
  whether the content is registered or not: while DLC is borrowed the live lists are thrown away by
  `DlcBorrow.revert`, and the own lists are in its stash (`Puppet.own_list`). Counters go onto
  `Puppet.own_data()`. `won` runs the game's `RunData.apply_run_won()` on the mirrored run. Its
  closing `reset_and_save_new_run_state` stays blocked. The danger levels land in
  `difficulties_unlocked`, whose per-character objects the borrow stash shares with the live list.
  An entry for a borrowed DLC character exists only live and goes with the borrow.
- **Saving.** `ProgressData.bt_save_own()` puts everything set aside for this client
  (`Puppet.own_fields`) into `ProgressData`, calls the game's `save()` and puts the live values
  back. It runs after a completed challenge or a win, for counters alone within 60 s, and when the
  lobby is left.

Achievements are set on the client's real Steam account and cannot be taken back by the mod.

### Damage meter

`sync/damage_meter.gd` (numbers), `ui/damage_views.gd` (views). It is modelled on the Damage Meter
mod by Oudstand (its README: "Feel free to modify and share") and written anew, because that mod
reads each machine's own counters, which stand still on a client.

**Total.** A player's total is the health that player's hits took. The meter connects to the
`EntitySpawner` (`enemy_spawned`, `neutral_spawned`, and the units already there when the battle
scene appears) and through it to each unit's `took_damage`, once per unit (the pools use units
again). A hit's value is `full_dmg_value`, per player by `TakeDamageArgs.from_player_index`. A hit
that leaves health takes exactly its value; a killing hit takes at most the health that was left,
which the meter keeps per unit: the health after its last hit, refreshed by the unit's `healed`
(healer enemies) and `stats_boosted` (buffers), dropped on `died`, and the unit's whole health for
a unit not hit since it spawned. A unit that died without a killing hit (the game's cap on enemies
removes some with `die()` in `EntitySpawner.on_group_spawn_timing_reached`; a tree's eighth hit)
keeps the health it had left, and hits on it go on: a bullet that entered it in the physics step
the cap removed it in lands afterwards (`_physics_process` runs between the area signals and the
deferred `Unit.hurt_area_entered_deferred`, which checks `_pending_die` but not `dead`), and a burn
goes on. Such a hit takes what the unit had left (kept per unit from `died`), and the weapon's
counter counts the same (`dmg_taken[1]`). Not counted: the brachiosaurus foot's hits that it hands
on to the boss (`hide_feedback`, the only hidden hits; the weapon counts the foot's). Damage to
players is left out. The suite `damage_run` checks the total against the health the units lost in
real waves, a crowded one past the cap included, and a hit on a removed enemy step by step.

**Sources.** The rows are the game's own counters: `WeaponData.dmg_dealt_last_wave`, and for
items `RunData.tracked_item_effects` where the item's `tracking_text` is `DAMAGE_DEALT` /
`EXPLOSION_DAMAGE_DEALT`, plus `EXTRA_IDS` whose text does not say so (the chef's consumable
explosions and burns under `character_chef`, the builder's turret under `item_builder_turret_0`
to `_3`, text `[EMPTY]`). Item counters run for the whole run, so the wave's part is the difference
to a copy taken when the battle scene appears. A counter that falls below that copy was set back
(each builder turret's `set_data` zeroes its levels' counters, maybe after the copy) and counts
from 0; the builder keys are checked every frame. Every tracked key that gained counts, in the
inventory or not. A list value's first entry is the damage. Equal ids are one source with their
number; the builder's levels are one source, named by the level the player holds.

- **Rows and total.** Some counters hold damage a weapon's counter holds too (`OVERLAPS`): Giant
  Belt's crit bonus is part of the weapon's hit (`Enemy.get_damage_value`), Greek Fire's bonus part
  of a burn tick, and burn ticks are credited to the weapon that applied the burn and to Scared
  Sausage as well (`Unit._on_BurningTimer_timeout`). Summing all counters overcounted (a Giant Belt
  crit build: 23,080 shown against 13,412 health lost). So the total comes from the hits, the rows
  stay the counters, and an overlapping row shows "included" in place of its share, with a paler
  bar. The views add an "Other" row: the total minus the shown rows that overlap nothing. It holds
  sources past the 10 rows, damage no counter holds (dart traps) and Scared Sausage's own burns,
  so the shares of the plain rows and Other add up to 100%. The total is never less than what the
  plain rows sum to (a hit on a unit the meter did not watch). Hits on a removed enemy once were
  not counted while its weapon's counter counted them: the counters then sat above the hits and
  the total jumped to them (the crowded wave in `damage_run`, 320 against 318 health lost). The
  overlap is a property of the id, so it does not travel.
- Per player the board holds `[total, sources as [my_id, count, damage]]`. During the wave it holds
  what the HUD shows: 4 sources, or 3 with 3 or 4 players (`DamageMeter.live_sources`). The wave's
  last measurement holds the 10 strongest, for the shop's board. The HUD has no Other line.
- During the wave, when the kept sources are all weapons or all of the other kind, the last gives
  way to the strongest of the other kind if that dealt at least 5% of the player's total
  (`OTHER_KIND_SHARE`).
- **Biggest hit.** The biggest number those hits showed above a unit, per player: the hit's whole
  value (`took_damage`'s `value`, the `full_dmg_value` that `FloatingTextManager` shows, after
  crit, armor and the bonuses), not capped, so a killing blow counts its overkill here while the
  total counts the health that was left. Hidden hits show no number and a one-shot that is no crit
  shows "ONE_SHOT" in its place, so neither counts; a crit one-shot shows its number. The source
  is read off the hitbox: its `from` weapon's tracking key, else that weapon's `my_id`, else
  the hitbox's tracking key, else none. `args.from` is never used: a burn tick reuses the unit's
  args with the hitbox cleared and `from` left as whatever hit the unit last.
- **Wave time** (for damage per second) is the meter's own count of frame time while `main`'s
  `WaveTimer` runs and the tree is not paused.
- **Kills and damage taken** (for the run stats): a killing hit on a unit with `enemy_id` counts a
  kill for the hit's player; a player's `took_damage` that was neither dodged nor blocked counts
  its value as damage taken.
- **Who measures.** The machine that runs the wave (the host, or any machine outside a session),
  every 0.5 s while the battle scene is current. A host with peers measures even with its own
  switch off. The game writes the counters inside the weapon's hit handler, so the numbers do not
  depend on the frame rate.
- **The wave's last measurement** (`freeze`) is taken once, when the wave is over: the meter
  connects to `EndWaveTimer.timeout`, and being older than the battle scene it runs before
  `main._on_EndWaveTimer_timeout` (signal order), so before `RunData.on_wave_end`, the crate and
  level-up panels and the retry prompt. Combining a weapon there gives the new one a counter of 0
  (`RunData.combine_weapon`), recycling takes the counter along, and Retry restores the run state
  (`retry_wave.gd`); measured later, the shop's board lost that damage or showed zeros. `_process`
  freezes too once `_end_wave_timer_timedout` is set, and the battle scene's `tree_exiting` does
  when the wave did not end (the pause menu's end run, restart or quit). After it the board stays
  as it is.
- **The wave's log line** (`wave_line`): at that last measurement the measuring machine logs one
  info line under `einfluffles-BrotatoTogether:DamageMeter`, to check the meter against a count
  of its own:
  `Wave 12 damage: total 15,234, health lost 15,234 (by no player 0, after death 2, hidden 0); p0
  9,100 (rows 8,900 + 1,200 included, biggest hit 1,204 weapon_smg_3, 50 kills), p1 ...; 87
  kills`. "total" sums the board's totals; "health lost" is what every shown hit on an enemy or
  tree took (capped like the totals) whoever dealt it, "by no player" the part of it from hits
  with no player index (they are in no total), "after death" the part from hits on units that
  died without a killing hit (in the totals), "hidden" what the hidden hits took (in neither). Per
  player: the board's total, the rows that overlap nothing and what the overlapping ones hold
  ("included"), the biggest hit with its source ("unknown" without one, "no hit" without a hit),
  the kills. Last the enemies killed by anyone. The suites `damage` and `damage_run` check it.

**Run stats.** `sync/damage_ledger.gd` sums the waves of a run per player: `{sources: {key:
[my_id, count, damage]}, total, hit, kills, taken}`, with the waves' count and time. The key joins
a weapon's tiers (`weapon_id`, Pistol I to IV one row) and the builder's levels; `my_id` and count
are the latest wave's. The wave's last measurement hands the wave over (`hold`, every source, not
only 10). It counts (`commit`) when the next scene is the shop or an end of run scene, so the last
wave of a run counts too. A battle that starts drops a held wave (a retry: the failed try never
reached those scenes), and one at or before the last counted wave starts the ledger anew (a new
run). Any scene outside a run (title screen, selection screens) clears the ledger and the board,
so a run started or resumed later does not show the last run's board; a resumed run's stats start
at the wave it resumes from. Leaving the lobby clears both too.

**Section `damage`.** Sent when the board changed, which is every 0.5 s while a wave runs. The
client checks the body strictly (`DamageMeter.clean`: at most 4 players, 10 sources, ids up to 96
characters, no negative numbers) and resolves ids against `ItemService.items / weapons /
characters`. The wave's last measurement adds `run`: `{waves, time, players: [[total, sources (10
strongest), [damage, my_id], kills, taken], ...]}`, the ledger with that wave in it, checked the
same way (a malformed run rejects the board). A board without `run` has no run view. An older build
of the same protocol ignores the key, so it needed no protocol bump.

**Views.** Numbers are shortened by `DamageViews.short`. Each view drops itself from
`DamageViews._views` when its panel leaves the tree.

- **HUD.** A panel in `UI/HUD/LifeContainerP<n>`, hidden while the total is 0.
- **Co-op shop and co-op end of run.** A fourth carousel page. A `Carousel` takes as many pages as
  `%Headings` has children. `DamageViews.add_page` appends a heading and a `DamagePage`. It is
  called from the containers' own `_ready` (`extensions/ui/coop_shop_player_container.gd`,
  `coop_end_run_player_container.gd`), because the page has to exist before a page index from the
  network is applied, or the setter clamps it. Nothing new travels: pages already travel in
  `SHOP_FOCUS` and the states' `pages`, and each machine builds the page from its own copy of the
  board. Receivers compare a page clamped to what this machine shows.
- **Solo shop and solo end of run.** A third tab in the stats panel
  (`extensions/ui/stats_container.gd`), inert until `DamageViews.add_tab` arms it, so the pause
  menu, the level-up screen and the co-op stats pages keep two tabs. The extension's `_input` runs
  before the game's (multilevel calls) and `update_tab` steps through three tabs. The solo shop is
  told by its methods (`_get_reroll_button` without `_get_coop_player_container`), not by class
  (script load order).
- **Board.** A title line ("Wave N"), one line with total, share of the team's, damage per second
  and biggest hit, 10 bars and the Other bar. The shops show the wave board. The end of run views
  (`add_page(container, true)` from the end of run container, `add_tab(stats, true)` on the solo
  end of run) show the board's `run` when it has one: "Run, N waves", the same line over the run
  (damage per second over the waves' time), its 10 sources and Other, and a line with kills and
  damage taken. Without `run` (an older host) they show the wave.

**Switch.** Options > Gameplay has a "Damage meter" check button (`extensions/ui/menu_options.gd`, a
copy of the "life bars on bosses" button). It is this machine's. Off: the rows are gone, the
carousels' last page is the one before (`carousel.max_index`), the solo tab is hidden. Stored by
`session/settings.gd` in the Mod Loader's config (`config_schema` in `manifest.json`, default on;
`user://mod_configs/einfluffles-BrotatoTogether/settings.json`, because the loader's "default"
config cannot be written). It governs the panels of this machine's players only
(`DamageMeter.shown_for`: on the host the slots on a local device, on a client its own slot): the
panel of a player on another machine keeps the damage page, so a host with the meter off neither
clamps a client's page nor passes a clamped one on. The views re-apply this every frame, because
slots and a client's own slot can change after a page was added.

Dart traps have no row: the game ships them without a tracking key. Their damage is in the
total and so in Other.

### Localization

The mod's own texts follow the game's language (`ProgressData.settings.language`, Options) and a
switch of it while the game runs.

- **Table.** `translations.csv`, UTF-8, header `key,en,fr,zh,ja,ko,zh_TW,ru,pl,es,pt,de,tr,it`
  (the game's languages in the game's order), one row per text, quoted cells for commas and line
  breaks. Placeholders are `{0}`, `{1}` as in the game's own texts.
- **Loader.** `l10n.gd`, `load_csv(path) -> int`, called from `mod_main.gd` `_init`, before any
  screen exists. It reads the file with `File.get_csv_line` and adds one `Translation` per
  language column to the `TranslationServer`, as the game does for its announcements
  (`singletons/announcement_manager.gd`). The CSV ships in the zip as is: the game cannot import
  it at runtime, and `tools/package.sh` leaves out `.import` files. A missing or malformed file
  is a warning in `modloader.log`, never an error. brotato:trade has the same file with the same
  API (each mod must work alone).
- **Fallback.** Every cell is filled (the `l10n` suite fails on an empty one). The loader still
  skips an empty cell, so the game's fallback would show the English text; for `zh_TW` the engine
  first takes the `zh` text (same language code), then English, and `zh` may take the `zh_TW`
  text the same way.
- **Terms.** Each language reuses the game's own words, looked up by English text in the
  reference CSV: co-op (`COOP`), player (`COOP_PLAYER`), wave, pause, damage, run (fr *partie*,
  ru *забег*, es/pt/it *partida/partita*, tr *oyun*; ja ゲーム and ko 게임 instead of the game's
  周回 and 달리기, which read oddly in a sentence), "Press {0} to ..." (brotato:trade). The game has no lobby, host, kick or invite: these take
  Steam's usual wording (fr *salon*, es/pt *sala*, zh *大厅 / 房主*, tr *lobi / kurucu*). Punctuation
  as in the game: a space before a French colon, full-width punctuation in Chinese and Japanese.
  Proper names (DLC names, Steam, Workshop items) and units (`ms`) stay.
- **Keys.** The mod's keys start with `BT_` and are never one of the game's. Where the game has
  the exact term, its key is reused (`MENU_BACK` on the lobby page). The decompiled
  `reference/resources/translations/translations.csv` mislabels some keys (90 of 1784 were not
  recovered, `MENU_BACK` holds a body part there), so it serves as a glossary by English text
  only; the `l10n` suite checks every reused key in the game's own translation resources, in all
  13 languages (the Chinese ones are `zh_Hans_CN` and `zh_Hant_TW` there).
- **Static texts** get the key as `text`: `Label` and `Button` translate it themselves and again
  on `NOTIFICATION_TRANSLATION_CHANGED`, which `TranslationServer.set_locale` sends through the
  whole tree. Such a control's `text` is the key (tests compare keys).
- **Built texts** use `tr(key)`, or the game's `Text.text(key, [args])` with placeholders, at the
  moment they are built. The lobby frame, the client view and character selection's slot labels
  build theirs every frame, the lobby page every 0.25 s. On `NOTIFICATION_TRANSLATION_CHANGED`
  these are built again at once: the lobby page (`LobbyPage._translate`, also for an open leave
  question), the pause banner (`PauseControl.BannerLabel` keeps its key and args), the retry
  prompt's lines (`RetrySync`, from the body it shows) and the damage boards (`DamageViews`,
  title, kills, damage taken, source names). The entry button's width covers its four texts and
  is measured again on a switch (`LobbyFrame._keep_entry_width`).
- **Whole texts.** A text with a value is one key with a placeholder, never pieces joined in
  code: the Co-op dropdown has a key per item ("Co-op: Off"), so a language can shorten the
  game's word there.
- **Errors** (`last_error`) are translated when they happen; the `modloader.log` line next to
  them stays English. A join rejection crosses the wire as a code (see
  [Join compatibility](#join-compatibility)).
- **Fonts.** A control of the mod takes the game's fonts (a scene's theme, `base_theme.tres` or a
  font of `resources/fonts/actual/base/`): they fall back to Noto Sans for Chinese, Japanese and
  Korean, Godot's default font has no such glyphs. The client view sets `base_theme.tres` itself
  (it replaces the scene). The `l10n` suite checks every character of every cell against every
  font and theme the mod's scripts load and the fonts of the real controls
  (`DynamicFont.get_available_chars`, with the fallbacks).
- **Room.** The places with little room, measured in every language by the language sweeps
  (`tests/.../l10n_layout.gd`, used by the `l10n`, `damage` and `lobby_menu` suites: no clipped
  text, nothing past the screen, the board and the frame as wide as in English):
  - The Co-op dropdown clips at 186 px: its items are short forms where the full word is too long
    (ja 協力なし / ローカル協力 / オンライン協力, ru *Кооп: локал.*, es/pt *Coop.:*).
  - The slot's *Invite friends* button is 260 px or its text; the lobby status under it has the
    slot's whole width (370 px).
  - Kills and Damage taken on a run's damage board stand side by side while they fit, else one
    under the other (`DamageViews._fit_extra`, a two-column `GridContainer`): the solo stats tab
    is 360 px wide, the pair needs up to 475 px (pl). English keeps one line.
  - The share column is 80 px at size 18: "included" is at most that (de *inkl.*).
  - The lobby frame stays 520 px: a player's note and *Kick* leave 120 px for the name. The
    entry button grows with its text, the main menu's row stays on screen. The pause banner, the
    client view, the lobby page's details and its leave question wrap.
  With `tools\check-window.ps1` the sweeps save screenshots of de, ru, ja and zh
  (`TOGETHER_L10N_SCREENSHOTS`).
- **Wording.** Sentences of one text are joined with a line break, not a space (Chinese and
  Japanese have none between sentences). Counts read "noun: number" ("Online · players: 2"):
  Godot 3 has no plural forms.
- **Stays English:** every `modloader.log` line, the diagnostics on the lobby page (`Battle: ...`
  lines, marked `# l10n: keep`), units (`ms`), numbers and DLC names.
- **Guard.** `tools/l10n_guard.py`, run by `tools/lint.sh` (also in CI): a string literal with
  letters assigned to `.text` or `hint_tooltip`, or passed to `add_item`, `set_text`,
  `set_tooltip` or a `..._button()` helper (also through a constant of the same file), is an
  error unless it is a key or its line carries `# l10n: keep`. It also checks that every `BT_`
  literal in the sources and tests is a key of the CSV and that every key of the CSV is used.
  Its allowlist (files not converted yet) is empty: both mods are converted. A node name passed
  to a `..._button()` helper carries `# l10n: keep`. It only sees a literal written at the
  assignment or call itself: text returned by a function (`status_text()`, `hint_text()`) or built
  on another line is up to review and the language-switch tests.

**Adding a text:** add a row with the key and a text in every language (a draft is fine, a
player corrects it), use the key in the code, run `tools/lint.sh` and
`tools/check.sh -s l10n,damage,lobby_menu`. A text on a screen the sweeps do not cover yet needs
its own check there.

**Corrections from players** come as pull requests that change only `translations.csv`. The
`l10n` suite checks the header, unique keys, every cell filled, the placeholders of the English
cell and the glyphs; the sweeps check the room.

## 10. Game bugs worked around

These are bugs or quirks of the game itself. Most also occur in local co-op without the mod.

### Freed controls under a cursor

A `FocusEmulator` that keeps a freed control crashes a release build on its next move (see freed
objects in the [Overview](#1-overview)). A real session crashed this way on the level-up gear page
(see [Measurements](#12-measurements-and-session-findings)). Three measures:

- **Take the cursor off first.** Before a gear rebuild (the game's way in
  `ShopSync._refresh_gear` and `UpgradesGear.rebuild_gear`) or `_refresh_weapons_inventory`, the
  cursor is taken off the element, also the element a focused popup was opened from. The gear
  updated in place (shop and level-up panels) frees only the elements nothing shows any more: the
  cursor stays on a kept one and is taken off a freed one; in the shop a popup opened from a kept
  one stays open. Afterwards it goes to the same item (the element nearest its old index), else the
  element at the same index, else for the own panel the page's default (`focus()`). The game's way
  back to the gear page (`_resume_inventory_control_focus`) is redirected the same way, and so is
  the shop's way back from the stats page (`_resume_shop_control_focus`, to the element at the
  same index).
- **Relink neighbours.** `CoopUpgradesUIPlayerContainer._set_focus_neighbours` links weapons and
  items by node path, and only on a page change (or, by `InputTypes`, on an input type switch).
  With trigger glyphs the rows name each other's elements. After every `update_inventory` (the
  extension's override: the game's crate weapons list, a client's rebuild, brotato:trade's crate
  trade), focus neighbours that name a freed node are dropped and, on the gear page,
  `_set_focus_neighbours` links the new elements. The game logs "Node not found" and
  `Parameter "p_node" is null` when this is missing, and `tools/check.sh` fails on both messages.
  A host logged both (suite `gear_links` repeats it: the client switches to its pad on the gear
  page, then recycles or combines a crate weapon). The gear updated in place (`sync_gear`, level-up
  and shop) drops them between the weapons and the items too: the items' sort inherits its row's
  neighbours at once,
  and the items row names the first weapon element (`gear_rebuild_tests.gd`, a client's first
  weapon goes).
- **Safety net** (`extensions/ui/focus_emulator.gd`, online or not). A control freed while it holds
  the cursor is dropped before the game's code touches it (`_input`, `_process`, the
  `focused_control` and `player_index` setters, `_clear_focused_control`). Existence is looked up by
  instance id (`_cursor_id`). The cursor goes to the control now at its place or is cleared. Each
  drop logs a warning (at most one per 10 s per emulator): a log that shows one found a path the
  mod does not handle yet.

### Anvil at shop entry

`ui/shop_gear.gd`, used by `extensions/ui/coop_shop.gd` and `extensions/ui/shop.gd` (both extend the
concrete shop scripts by path, and chain with brotato:trade's extension). `BaseShop._ready` upgrades
a random weapon (`upgrade_random_weapon`) with `_combine_weapon(weapon, p, true)` before it fills
the gear rows. The game's combine then adds an element to the still empty row and defers a
`grab_focus` on it, and `set_weapons_data` frees that element first. While
`RunData.shop_effects_checked` is false the override does only the run part:
`RunData.combine_weapon(weapon, null, p)`, `dmg_dealt_last_wave` kept, the combine sound. Online the
Anvil runs once, on the host, because a client enters its copy with `shop_effects_checked = true`.

### "WEAPONS (n/m)" label

`PlayerGearContainer._on_weapons_changed` computes the label and is connected only to the weapons
row's `elements_changed`. Buying an item that adds a weapon slot (Cybernetic Arm) changes the items
row only. The shop's `_update_stats` therefore computes the label of that player again.

### Axolotl crash

A host crashed natively when the co-op shop opened (wave 36 of an online endless run):
`ItemDescription.set_item` of an Axolotl offer (DLC 1) reaches `SwapMaxMinStatEffect.get_args`, which
calls `Keys.hash_to_string[stats_swapped[1]].to_upper()` on null.

- **Cause.** An Axolotl's effect object is shared: shop offers and the pools they are rolled from
  are shallow duplicates of the `ItemService` item, and a bought offer is added as it is. Buying one
  runs `apply`, which sets `has_been_applied = true` and `stats_swapped` on that shared object. When
  `ItemService._get_rand_item_for_wave` later rolls an Axolotl for another player, it sets
  `stats_swapped = []` on the shared object. `get_args` recomputes the stats only while
  `has_been_applied` is false. In solo the owner never gets a second offer.
- **Guard** (`extensions/effects/swap_max_min_stat_effect.gd`). `get_args` hands every state the
  game can render to the game's own code. For an applied effect with fewer than two entries, or an
  entry that is no int or is missing from `Keys.hash_to_string`, it names the player's current
  highest and lowest primary stats (`_find_min_max_stat_keys(player_index)`). It does not repair
  `stats_swapped`: the object is shared, so a repair would write one viewer's stats into everybody's
  Axolotl and into the run state.
- **Diagnostics.** A warning (`einfluffles-BrotatoTogether:Axolotl`) where such a state is met, with
  the effect's instance id, player, wave, the field values and whether the object is the shared
  original. The first 5 are logged, later ones at most once a minute.
- Only this `get_args` in the game indexes `Keys.hash_to_string`. The suite `axolotl_tests.gd`
  reproduces the state with the game's own roll.
- **Boot error.** `Effect` defines its own `duplicate()`, so the Mod Loader's backup of the game's
  script before the extension (`script.duplicate()`) logged `Can't call non-static function
  'duplicate' in script.` at every boot and stored null. `mod_main.gd` lists such game scripts in
  `OWN_DUPLICATE`, and `extensions/script_backup.gd` stores a fresh copy of each
  (`ResourceLoader.load(path, "", true)`) in `ModLoaderStore.saved_scripts` first, so the loader
  skips its own. That is Mod Loader 6.3.0 internal state: without the `ModLoaderStore` autoload or
  its `saved_scripts` dictionary, or with an entry already there, nothing is stored and the loader
  behaves as before. The suite `axolotl` checks that every extended script has a backup and that
  `OWN_DUPLICATE` names exactly the extended scripts whose class has its own `duplicate()`.

### Cursed Molotov

A cursed Molotov logged `Node not found: "Sprite/Muzzle/BurningParticles"` twice per throw (first
seen on a host, 2026-11-21: 100 to 200 per wave). `Weapon._ready` frees everything in
`Sprite/Muzzle` of a cursed weapon to put its curse particles there, and
`RangedWeapon.on_projectile_shot` hides and shows the paths in `throwned_projectile_hide` by
`get_node`, which for Molotov is the freed `BurningParticles`. In the game's release build the call
on null is skipped (no script error), so only the log suffers; in a debug build the throw's
coroutine stops and the bottle stays thrown. Only Molotov lists a path there.
`extensions/weapons/fireball.gd` (Fireball's script serves Molotov) keeps only the paths that
survive `_ready` on a cursed weapon. The suite `cursed_weapon` throws a plain and a cursed Molotov.

### Smaller quirks

- **Popup focus style.** In co-op a mouse press in an open `PopupMenu` gives it Godot's focus. A
  `FocusEmulator` then styles it as a focused button, and a `PopupMenu` has no `font_color_focus`,
  so every row but the hovered one turns black on black. This affects the game's zone dropdown too.
  `CoopMode._keep_cursor_on` moves such a cursor back to the dropdown, for both dropdowns.
- **Shop cursor after combine.** See [Host cursor after an intent](#shop).
- **Player 1's locked panel is narrower** than the other slots in co-op character selection.
  `LockedPanel1` has `rect_min_size` (320, 0) in the game's `character_selection.tscn`, the others
  (370, 0). This is not a mod bug.

## 11. Diagnostics

All of this is for the log only. Every line has a rate limit (log memory, see
[Overview](#1-overview)).

| Line | Source | When | What it tells |
|---|---|---|---|
| "Route: ...", "Send rate: ..." | `Transport` | startup | which route and send rate apply |
| path changes | `net/link_watch.gd` | once a second per member, on change | "connecting", "direct", "relayed via fra (peer's POP dfra)", "closed: ..." (data center codes). The peer's IP address is not logged. |
| "Slow answer from ..." | `Session` | a `PONG` later than 150 ms, at most one a second per peer | network time, each game's frame time, the scene, and Steam's numbers (`getSessionConnectionInfo`: ping, send queue time, pending and unacked bytes, send rate, quality), the path |
| "; reliable in the last 2 s: ..." | `net/traffic.gd` | appended when Steam's reliable queue holds 4 KB or more | the largest reliable messages by label, as count x mean size ("STATE shop 3 x 13.1 KB") |
| "Reliable burst to ..." | `net/traffic.gd` | one message above 32 KB or more than 64 KB queued after a send, at most one per peer in 5 s | which message filled the queue |
| snapshot / input gap | `sync/stream_gaps.gd` | a stream stops for 200 ms or more, at most one line per 5 s per stream | see below |
| "Input from ...: N missing input(s) filled in ..." | `InputSync` | after a client's gap, at most one per 5 s per client | inputs filled in from redundancy, steps caught up, steps dropped and how many of them moved |
| "Shop state held ...", "Shop 40: 28 states ..." | state stream, `RunParts.Sender` | when the screen closes | see [State stream](#5-state-stream-and-run-state) |
| "... run state changed without a change of its fingerprint ..." | `RunCache` | a safety net hit | a gap in the fingerprint, with the paths |
| "nan at p1.effects.stat_luck sent as 0 ..." | `sync/finite_json.gd` | host: a NaN or infinite number in a sent text, at most once a minute per path, 3 lines and a summary per print | which value of the run state the game made non-finite, see [Run state serialization](#run-state-serialization) |
| "Run part p1 [...] is not readable: ..." | `RunParts.Store` | client: once per stored part | a part whose JSON does not parse; the run state stays as it was |
| "Client X entered ...", "Client X frames ...", "Client X corrections ..." | `sync/client_report.gd` | see below | a client's timings in the host's log |
| "Wave N damage: total ..." | `DamageMeter` | once per wave, at the wave's last measurement, on the machine that runs the wave | the meter's totals against the health the enemies lost, per player rows, biggest hit and kills, see [Damage meter](#damage-meter) |

**Traffic.** `Session.send_reliable` notes every message with its encoded size, per peer. Steam's
queue is asked after every message of 4 KB or more, and after smaller ones at most once per 250 ms
per peer (`Traffic.query_due`).

**Gaps.** A client logs when the host's snapshots stop, the host when a client's `INPUT` stream
does. Gaps are timed by Steam's receive time (`Session.arrival_msec`), so this game's own long
frames are no gap. A host pause is no gap. The sender's clock tells the cases apart:

- Snapshots carry the host's snapshot time. The line reads "held up on the way" (sent at the usual
  pace, arrived together) or "not sent or lost".
- `INPUT` carries the client's `OS.get_ticks_msec()` next to its seq. A client whose frame stalls
  runs no physics steps meanwhile, so its clock jumps while its seq does not. If the send time that
  the seq steps do not account for is at least half the gap, the line reads "its game sent nothing
  for N ms (its own stall)". Else a seq step above 5 (4 redundant moves plus the packet itself)
  reads "N inputs lost on the way". Else "held up on the way".
- The line names the seq step, Steam's numbers, the path and the scene, and "; buttons released"
  when the 600 ms timeout let go of the player during the gap.

**Client reports** (`CLIENT_REPORT`, numbers only). A ready client measures and the host logs. The
node runs first in every frame (`process_priority` -1000), so the time between two of its `_process`
calls holds a whole frame.

- **Frames.** Per window of 10 s of unpaused frames in one scene: count, average, worst, frames of
  50 ms or more, and in a battle what `BattleClient._process` took and the most entities it
  mirrored. Sent when the worst frame took 50 ms or more, else once a minute.
- **Worst frame.** The window keeps what its worst frame was spent on: the timing marks of that
  frame, the four parts of `BattleClient._process` (players, entities, pickups, events) and how
  many puppets it instanced. A puppet instanced instead of taken from a pool (`_spawn`,
  `FeedbackMirror.explode`) is also counted per window with its time, the costliest by scene file
  name (`ClientReport.fresh(file, usec)`). The host adds this to the line only when the worst frame
  took 50 ms or more, and shows a file name that is not plain as "?". When the frame has a mark,
  mirror work or a fresh puppet, the line ends with the rest: what none of them holds (the game's
  own work, deferred layout, freed nodes).
- **Scene change.** The longest frame within 3 s of a change of `current_scene`, with the mod's
  share from timing marks (`ClientReport.mark(label, usec)`: run parse, deserialize, apply, puppet
  setup, level-up panels, shop panels). The host's line ends with the rest, the game's part.
  "level-up panels" is `UpgradesSync.apply` after the run (gear, stats, the panel shown), "shop
  panels" `ShopSync._apply_body` after `RunStateCodec.apply` (gear rows, stats, shop items, locks,
  popups; also the first state of a shop just entered); run parse and deserialize
  cover every section's run (`Store.timed_state`). The node registers itself with
  `Engine.set_meta`, because Godot 3 has no static variables.
- **Corrections.** In `_predict_own`, a new error longer than one step at the player's speed is
  counted per window, the largest with the snapshot's age, the inputs not acked and the speed. A
  correction still blending out counts again on each snapshot while it is longer than a step.
- **Host.** The sender must be a ready peer, and every value must be a number and is clamped, or the
  report is dropped. Scenes are sent as an index into a fixed list of the game's scene files. A
  client sends at most 6 window lines and 2 scene lines a minute, and the host logs at most 8 lines
  a minute per client.

## 12. Measurements and session findings

Test measurements come from the headless test container. "Late run" means the late endless test
runs with 2 / 4 players and 250 items each. The date and commit are when the number was recorded;
later changes may have moved it.

| What | Value | Date, commit | Source |
|---|---|---|---|
| Snapshot size with envelope: 45 entities and 8 events / 136 and 11 / 300 and 44 | 452 / 968 / 2184 B | 2026-11-15, 82a0d7e | `snapshot_tests.gd`, `looks_tests.gd` |
| The same with the damage numbers' seq (4 / 6 / 30 damage events); on main the same day | 460 / 980 / 2220 B; 452 / 972 / 2188 B | 2026-11-22, 5bc2d0e | `snapshot_tests.gd` |
| Late endless wave (400 enemies, 200 projectiles, 50 gold, 2 players): host per snapshot, client per frame, snapshot size | 3.7 ms, 1.4 ms, 2.7 KB | 2026-11-15, c25808e | `cleanup_tests.gd` |
| Reading looks on the host, 600 plain entities per snapshot | 0.5 ms | 2026-11-15, 82a0d7e | `looks_tests.gd` |
| Scene load stall: battle scene; shop scene (small / late 2 / late 4 players) | 0.3 s; 0.2 / 0.5 / 0.8 s | 2026-11-15, c00c55c | `session_lifecycle_tests.gd` |
| Shop fingerprint check (small / late 2 / late 4), with `tracked_item_effects` (without it in the same runs: 45 to 51 / 51 to 53 / 90 us) | 45 to 50 / 53 to 56 / 95 to 101 us | 2026-11-22, 294abf7 | `shop_change_tests.gd` |
| Run cache safety net, per second (small / late 2 / late 4) | 1.2 / 8 / 15 ms | 2026-11-15, 4364835 | `shop_change_tests.gd` |
| Level-up key check (late 2 / 4) | 0.16 / 0.32 ms | 2026-11-15, 4b1ca91 | `upgrades_change_tests.gd` |
| Cursor key / cursor description, two-player shop | about 16 us / 380 us | 2026-11-15, 826b3f9 | `cursor_key_tests.gd` |
| Page flip or Go: bytes per client (late 2 / 4) | 544 / 752 B | 2026-11-17, 65d6baa | `run_parts_tests.gd` |
| Lock: bytes, host check, client parse and deserialize | 4.0 / 5.0 KB, 10 / 21 ms, 3 / 12 ms | 2026-11-17, 65d6baa | `run_parts_tests.gd` |
| Paid reroll: same columns | 10.4 / 11.7 KB, 13 / 23 ms, 46 / 46 ms | 2026-11-17, 65d6baa | `run_parts_tests.gd` |
| Purchase: same columns | 30.4 / 31.9 KB, 28 / 33 ms, 39 / 56 ms | 2026-11-17, 65d6baa | `run_parts_tests.gd` |
| Level-up choice: same columns | 7.1 / 7.6 KB, 10 / 25 ms, 30 / 29 ms | 2026-11-17, 65d6baa | `run_parts_tests.gd` |
| `BATTLE_START` per client after a shop (late 2 / 4) | 3.1 / 3.3 KB, of which run 1.5 / 1.6 KB | 2026-11-17, d188ad5 | `battle_start_tests.gd` |
| With `s` and `t` split off from `c`, bytes per client (late 2 / 4): lock, paid reroll, purchase; in two runs each of the commit before | 3.1 / 4.4, 10.2 to 10.6 / 11.3 to 11.8, 30.4 to 31.2 / 31.6 to 32.0 KB; before 4.1 / 5.5, 10.8 / 12.0, 30.8 to 31.1 / 32.2 to 32.4 KB | 2026-11-22, 7ecced4 | `run_parts_tests.gd` |
| The same: a tracked value alone in the shop, under the level-up panels | 1.5 / 1.9, 1.5 / 2.1 KB; before 4.1 / 5.5, 2.1 / 2.6 KB | 2026-11-22, 7ecced4 | `run_parts_tests.gd` |
| The same: `BATTLE_START` after a shop | 2.6 to 2.7 / 2.8 to 3.0 KB, of which run 1.0 / 1.2 KB; before 3.0 to 3.1 / 3.4 KB, run 1.5 / 1.6 KB | 2026-11-22, 7ecced4 | `battle_start_tests.gd` |
| Client, `_on_battle_start` up to `change_scene` (late 2 / 4) | 87 / 95 ms | 2026-11-17, d188ad5 | `battle_start_tests.gd` |
| Host, run packed in parts as the battle scene enters (late 2 / 4) | 31 to 36 / 60 to 86 ms | 2026-11-17, d188ad5 | `battle_start_tests.gd` |
| Client time per applied level-up state: choice, reroll, crate item, new panels (late 2 players) | 40 to 45, 40 to 52, 94 to 149, 171 to 264 ms | 2026-11-17, 055222f | `upgrades_change_tests.gd` |
| The same with kept items and the gear in place, late 2 / 4 players: choice, reroll, crate item | 10 / 11, 11 / 12, 30 / 31 ms | 2026-11-21, 0d1ccb3 | `upgrades_change_tests.gd` |
| A crate item's state on a client, late 2 / 4: run parse, deserialize, apply, level-up panels (of which the gear about 11); the old way in the same run | 6.4 / 6.3, 6.8 / 6.4, 2.2 / 2.8, 14.9 / 15.0 ms; 98 / 92 ms | 2026-11-21, 0d1ccb3 | `upgrades_change_tests.gd` |
| Another player's purchase on a client's shop, late 2 / 4: run parse, deserialize, apply, shop panels (of which that player's gear in place 14 to 19); the old gear rebuild of that player alone, in the same shop | 6.1 / 7.4, 7.9 / 9.0, 1.9 / 2.7, 18 to 20 / 19 to 22 ms; 71 to 92 / 97 to 104 ms | 2026-11-22, d5db093 | `shop_gear_change_tests.gd` |
| The same for a reroll (weapons pointed at new objects only), of which shop panels | 15 to 17 / 17 to 23 ms, 5.5 to 6.5 / 5.7 to 9.4 ms | 2026-11-22, d5db093 | `shop_gear_change_tests.gd` |
| Host, a client's crate item to its answer sent (late 2 / 4): applying the intent, the stream's check (serializing the run) | 29 / 37 ms: 5.7 / 5.4, 23 / 31 ms | 2026-11-21, 0d1ccb3 | `upgrades_change_tests.gd` |
| Effect custom args per serialization (late 2 / 4) | 2.4 / 3.0 ms | 2026-11-17, cc3f561 | recorded with the commit |
| Battle scene change on a client, small two-player run | 284 ms stall, of which the mod 4.8 ms | 2026-11-17, f12aab4 | `client_report_tests.gd` |
| Damage meter, one measurement (late run, 4 players, 6 weapons each) | 0.45 ms | 2026-11-16, 677a2bf | `damage_meter_tests.gd` |
| Damage board update, 4 players with 3 sources each | 968 B | 2026-11-18, 3f5da8f | recorded with the commit |
| Crowded late wave: 3 players with 6 pistols, a bullet hell, 180 enemies alive (the cap of endless wave 30 for 3 players). Entities, snapshot size, per client, host per snapshot, client mirror per frame, client parse per snapshot | 210, 1.5 KB (2 packets), 43 KB/s, 2.3 ms, 0.9 ms, 0.34 ms | 2026-11-21, e6f9bc2 | `late_load_tests.gd` |
| The same with 400 enemies alive | 420, 2.7 KB (3 packets), 79 KB/s, 1.4 ms client mirror, 0.66 ms parse; the host's game itself takes 300 to 370 ms a frame | 2026-11-21, e6f9bc2 | `late_load_tests.gd` |
| The same with the damage numbers carried over and sent twice: 180 / 400 enemies, per client; events per snapshot (median) and snapshot size (median) with 400; the commit before in the same container | 43.2 / 80.3 KB/s, 24 events, 2808 B; 43.5 / 78.7 KB/s, 14 events, 2700 B | 2026-11-22, 5bc2d0e | `late_load_tests.gd` |
| The same with 180 enemies in a real window on the dev machine: host frames, client frames (mean / max) | 4.3 / 16 ms, 2.8 / 6.7 ms | 2026-11-21, e6f9bc2 | `tools\check-window.ps1 -Suites late_load` |

The purchase is not small on the wire in the test runs because every test player carries nearly
the same 250 items, so a whole run compresses across players while one `g` part alone does not. What
remains on a client after a change is mostly the changed player's `PlayerRunData.deserialize`.

Splitting `s` off `c` saves little on a reroll or purchase: `s` holds every player's offered
items, which were most of the old `c`. A part per player (`s<p>`) would carry only the rerolling
player's items; not done yet.

In the crowded wave the mirror stays small: the snapshots use a twelfth of the send rate, and the
client's mirror about 1 ms of a 16.7 ms frame. Every snapshot is two packets, so a lost
packet loses a snapshot, which the render delay rides out. The replay's first frame instances the
whole crowd at once (150 to 760 ms headless), as only a client that joins mid-wave sees. With 400
enemies it is the host's game itself that slows down.

### Findings from real sessions

| Date | Session | Finding | Consequence |
|---|---|---|---|
| 2026-11-16 | two players, wired lines, direct route, Steam ping 15 to 18 ms | 22 snapshot stalls of 0.5 to 3.3 s in 10 minutes, all within a second of a 12 s beat. Network stalls of 300 to 500 ms every 20 to 50 s. | relay-only route by default; the 600 ms stall limit (prediction and input timeout ride out the shorter stalls) |
| 2026-11-16 | the same two players, relayed via fra, 8 waves | no network stall; the relay POP changing mid-session caused none | confirms the relay default |
| 2026-11-16 | three players, 43 waves, Steam send rate 262144 B/s | in the shop at wave 42, 251211 B of reliable run state pending for each of two clients, send queue 954 ms, pings of about 1 s; backlogs of 20 to 250 KB in the shop and 55 to 76 s into battles | send rate 512 KB/s, run state in parts, backpressure, the traffic log |
| 2026-11-16 | the same session | 213 input gap lines of 200 to 847 ms, most at a battle start or shop entry; scene-change stalls of 150 to 700 ms per client | gap lines tell a client's own stall from the network; client reports |
| 2026-11-16 | the same session | 7 fingerprint misses in the shop between waves 18 and 40 | effects' custom args are settled before serializing |
| 2026-11-21 | two players, 47 waves | a client lags from the crate item to the level-up page (issue #110); one frame of 50 to 64 ms per wave end and shop, its only mark "apply 2" (the store's parse and deserialize and the panels had none) | kept items, gear in place, marks for every section's run and the level-up panels (0d1ccb3) |
| 2026-11-22 (log read) | two players, endless to wave 38 | a client's shop frames of 50 ms or more track the gear parts sent (`g`): 20 to 34 per shop from wave 33, up to 169 ms at wave 36; states with only `c` and `p` (rerolls, locks) stayed under 50 ms. The shop still rebuilt every gear element of a changed player. | shop gear in place, the "shop panels" mark (d5db093) |
| 2026-11-22 | two players, endless to wave 38 | 198 fingerprint misses, all on the level-up panels from wave 18 on, all `c.tracked_item_effects[1].item_bot_o_mine`: the Bot-O-Mine pet lays mines while the panels show | the fingerprint covers `tracked_item_effects` |
| 2026-11-17 or earlier (fix 055222f) | a real session, late endless waves | client frames of 100 to 205 ms during the level-up panels | per-player rebuild |
| 2026-11-16 or earlier (fix 1ceb422) | online session | a client crashed natively on the level-up gear page after a run change | [Freed controls under a cursor](#freed-controls-under-a-cursor) |
| 2026-11-17 or earlier (fix ec3c80b) | online endless run, wave 36 | the host crashed natively when the co-op shop opened | [Axolotl crash](#axolotl-crash) |
| 2026-11-17 or earlier (fix 736a4a2) | online endless run | the game logged "combine: no inventory element ..., the weapons row is out of sync" at shop entry | [Anvil at shop entry](#anvil-at-shop-entry) |

Not measured in a real session as of 2026-11-19: the effect of the 512 KB/s send rate (the
slow-answer lines' `rate` should read 524288 B/s).

## 13. Known gaps

As of 2026-11-23, protocol 33.

**Not mirrored in a battle**

- The bigger sprite of bonus-boosted gold.
- The music dip and the won-run animation at the wave's end.
- The brachiosaurus foot's shadow scale and position animations, and the jump-attack shadow's
  `position.x`.
- Effects done inside stripped method tracks or disconnected `animation_finished` handlers.
- A projectile's scale (the baryonyx' lasers are 0.55 on the host).
- The pressed sprite of a landmine or dart trap while something stands on it (its `Area2D` is off
  on puppets).
- Percent-damage-taken outlines (lute, diver) and the one-shot boost particles (`stats_boosted`).
- The tint of a player standing in acid or petrol (`Player._set_color_modulation`).
- A one-shot event other than a damage or heal number is lost with its snapshot (for example one
  whip lash).

**Shop and level-up panels**

- The host and the other clients still show an item popup the mouse closed on the client while
  the cursor stays on its item (only an open popup that took the cursor is mirrored).
- The meca effect a player picked on a shop item or crate item before buying or taking it is not
  shown on the other machines.
- The client's hold-to-ban depends on its own `chal_banned_items` unlock. Hold-to-ban has no mouse
  path in co-op, and a mouse click on Ban counts as a full hold (`button_up` is never emitted
  through an emulator).
- The ban animation and press sounds of the own panel are not heard (the puppet shop is muted).
- A refused buy gives no feedback on the client.
- The elite icon of a caught steal (`display_shop_icon`) is not mirrored.
- A click outside an open popup does not close it.
- After a combine on the level-up panels the client's cursor keeps its slot where the host's copy
  jumps to the new weapon, until the next `UPGRADE_FOCUS`.
- A client's next level-up page waits for the host's answer: a round trip plus the host's check
  (about 30 ms late in a run, mostly serializing the run). It cannot be shown ahead: the host rolls
  the options (`ItemService.get_upgrades`) from the player's stats after the decision.
- New panels on a client still instance every gear element (the inventory is empty, the game's
  way): one longer frame at the wave's end.
- A key tap shorter than a physics frame is lost while a panel is up (held state is polled).

**Selection screens and end of run**

- The cursor makes the round trip through the host (no local panel).
- Item-set requirements are evaluated with this machine's sets.
- The end of run shows the host's unlocked rewards.
- The weapon selection's "show character" hint (`CoopShowCharacterHint`) shows the device types
  as they were when the screen opened.

**Lobby and menus**

- A client in the shop or on the level-up panels has no way to the lobby page.
- On a keyboard Esc is both `ui_cancel` and `ui_pause`, so the press that opens the popup on a
  mirrored selection screen reaches the host as cancel first.
- The host has no lobby entry on weapon and difficulty selection.
- Kick is in the title screen's frame only.
- A client's live menu is keyboard and pad only. A spectator has none.
- Options changed by a client are written to disk only after the session.
- With a client's meter off, the host's carousel for
  that client at the end of run can stand on the damage page while the client shows the page
  before (the host does not know the client's switch).

**Progress for clients**

- Not shared: the hourglass (play time), the three species challenges (trophy hunter, clever girl,
  egg hunt) and `killed_enemies` (codex).
- Nothing is backfilled for runs played before the feature existed.

**Tested against stand-ins only**

- The mouse path of the own panels (synthetic clicks, no real mouse).
- Dismantle and the meca effect choice in the shop (no meca weapons without the DLC in the headless
  suite).
- Progress sharing is not run against Steam.
- Label widths measure 0 px headless, so the widths of the solo damage tab row and of the board in a
  four-player panel are estimates.
