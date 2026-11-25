# brotato:together

Online co-op for [Brotato](https://store.steampowered.com/app/1942280/Brotato/) through Steam's
networking, in place of Steam Remote Play's video stream. Every player runs the game on their own
machine, and their own character and menus react at once.

**Status (2026-11-23, protocol 33):** early development. Sessions over Steam with friends work;
the sessions measured in the implementation notes were played on 2026-11-16. Expect rough edges
and please report them (see [Reporting problems](#reporting-problems)).

Mod id: `einfluffles-BrotatoTogether` · source: [`src/einfluffles-BrotatoTogether`](src/einfluffles-BrotatoTogether) · license: [MIT](../../LICENSE) · changes: [CHANGELOG.md](CHANGELOG.md)

## Requirements

- The Steam version of Brotato. The game ships the Mod Loader, and no port forwarding is needed.
- Every player subscribes to the mod's Workshop item and unsubscribes from other online co-op
  mods.
- Every player needs the same game version, the same version of the mod and the same protocol
  (30 on 2026-11-18). The host refuses a join that differs, and the *Online co-op* page of the
  player who tried shows the reason.
- A lobby holds up to 4 players and is open to Steam friends only.
- Clients do not need the host's DLCs (see [Features](#features)).

## Playing

The mod has no menu, hotkey or overlay of its own. Online play sits in the game's menus and is
used like them, with mouse, keyboard or gamepad.

### Opening and joining a lobby

- **Character selection:** the Co-op row of the run options box has three values: *Off* (solo),
  *Local* (the game's co-op) and *Online* (co-op and a lobby that you host). It is a dropdown like
  the zone's above it and takes the place of the game's Co-op toggle, so the screen keeps its
  layout. Choosing *Off* or *Local* while online leaves the lobby. While you host, the slot that
  the next player takes shows *Invite friends* (the Steam overlay) and the number of players in
  the lobby. With keyboard or pad, player 1 gets there with left from the Co-op row.
- **Main menu, Host lobby** (below *Start*) opens a lobby without leaving the main menu, so you
  can still use the options, the codex and the other pages. A small frame next to the buttons
  lists who is in the lobby, with ping, and the button becomes *Invite friends*. The host has
  **Kick** behind every other player's name and *Leave lobby* under the list. A kicked player is
  told so and can join again after a new invite. *Start* with a lobby open leads to a co-op run.
- **Joining:** friends join through the Steam invite or *Join game* in the friends list. An
  invite that you accept in the middle of a run opens the *Online co-op* page with *Join invite*
  and leaves your run alone until you press it.
- **Joining a host who is in the main menu** leaves you in your own main menu, with the same
  frame. *Start* and *Continue* are off for you and the button reads *Leave lobby*. When the host
  starts or continues, everybody in the lobby is taken into that screen. When the host returns to
  its main menu, you return to yours.
- **Pause menu, Online co-op** (host and client, during a run) is a page with *Host lobby*,
  *Invite friends*, *Leave lobby* and the connection details: your role, every player with state
  and ping, players who are away, and the last error. Leaving in the middle of a run asks first.
- **A client on the host's screens outside a wave** (the selection screens, the co-op resume
  screen) has no pause menu. **Esc / Start** opens the same page as a popup. While it is
  open, the game gets none of your keyboard or gamepad input.
- If a lobby fails (not created, join refused, host gone), the reason shows in the main menu's
  error line and on the page.

### In a run

- **Joining the run:** the host opens co-op character selection. Remote players hold *accept*
  (Space / Enter / A) to join, like local players. The host joins first: a remote player's hold
  counts only once a player of the host's machine is in, so the host's player starts in slot 1.
  The co-op resume screen is not held back, since there the slots decide who gets which saved
  character. A player who leaves the resume screen gives their saved character back for the next
  one to join, and the shop opens only once every saved character has a player. Every free slot
  shows "Player N" and the game's hold-to-join hint, on the host and on clients.
- **Locking in:** once you have picked your character (or weapon), your cursor stays on it until
  you cancel or everybody is ready and the game goes on. A player who leaves character selection
  takes the pick along: whoever gets that slot next starts free.
- **Colours:** in character selection each player changes their colour with **F** (keyboard) or
  **Y** (gamepad; Triangle on PlayStation pads). It cycles through 8 colours and skips those that
  other players have. The colour is used wherever the game uses player colours (cursor, panels,
  HUD, player highlight), and clients see the same colours. In a lobby your colour stays yours
  while you are in it: every new run starts with it, whatever slot you join into, and nobody else
  online can pick it meanwhile (players on the same machine can, so the host can switch device).
  A drop mid-run keeps it for your rejoin. Once the host closes the lobby, a colour lasts only
  while its player keeps their slot: the next run starts with the game's colours, unless the host
  opens a new lobby before it. Nothing is saved; a player who does not pick gets the game's
  colour, or a free one. A player's colour does not change while they keep their slot, whoever
  joins or leaves.
- A locked character under a cursor shows how to unlock it, on clients too.
- **Aiming** follows each player's own manual-aim setting (mouse or right stick).
- **A player who drops:** if they do not come back within 20 s, the host makes their level-up,
  crate and shop choices so that the run goes on.

### Pausing

| Where | What happens |
|---|---|
| Wave, with friends connected | Nothing pauses, also not when a window loses focus. Esc opens the menu over the running wave. The host gets the game's menu, and its character stands still meanwhile. A client gets its own copy for the options and the codex. Restart and end run stay with the host, and a client's *Quit* asks to leave the lobby. |
| Shop | The host's pause pauses everyone, and clients see who paused. A client's Esc opens its own menu over its shop (options, codex, *Online co-op*), as in a wave: nothing pauses, and its panel waits while the menu is open. |
| Level-up / crate panels | Only the host's own players can pause. A client's own panel keeps running, and a choice made there waits until the host resumes. |
| Host with nobody connected | The game pauses as always. |

## Features

- **The whole run online:** clients see the game's own character, weapon and difficulty
  selection, the waves, the level-up / crate panels, the shop and the end of the run, each
  showing what the host's screen shows. The selection grids are the host's, so a client's own
  unlocks and DLCs do not matter.
- **Your own character reacts at once.** It is moved on your machine and corrected by the host
  only when the two disagree. Picking up a fruit or a crate shows at once as well.
- **Your own shop and level-up / crate panels run on your machine:** the cursor, the pages, item
  popups, inventory browsing and the hold-to-ban bar react without a round trip. Only a decision
  (buy, reroll, lock, steal, ban, combine, recycle, Go, choose, take and so on) goes to the host,
  which applies it with the game's own rules. Your character stands still while a panel is open.
- **Pad, keyboard and mouse:** these panels follow the device you use. With a pad the triggers
  switch pages, on the keyboard the page arrows take the cursor, and the mouse moves and clicks
  your own cursor. Other players' panels ignore your mouse.
- **Scrolling:** the mouse wheel scrolls what is under the pointer in your own panel
  (descriptions, the stats sheet, item lists, the character grid), and the right stick scrolls
  your descriptions and stats. Neither scrolls another player's panel. The character grid, which
  all cursors share, follows only your own cursor. Every panel shows how far its player has
  scrolled it, on the host and on every client. In local co-op without a lobby the wheel scrolls
  the keyboard player's panel (the unmodded game turns the wheel off on co-op screens).
- **What a wave shows on clients:** what the host shows, among it spawn markers, boss and elite
  life bars, explosions and screen shake, floating texts, the looks of charmed, burning, cursed
  or mutant enemies, puddles, holes, breaking weapons and the end of the wave. The wave-failed
  prompt appears on clients too and names who gets to choose.
- **Sounds:** clients hear the host's battle, menu and shop sounds, not those of their own
  mirrored screens.
- **Damage meter:** during a wave, a block at each player's life bar shows that player's damage,
  the damage per second, the strongest sources and the biggest hit. The co-op shop and the end of
  a co-op run have a **Damage** page per player (LB / RB or the arrows, after the stats pages):
  the shop's for the wave before, the end of run's for the whole run, with each player's kills and
  damage taken. The solo shop and the end of a solo run have it as a third tab of the stats panel.
  The total is the health your hits took, the biggest hit the biggest number your hits showed
  above an enemy (a killing blow's whole damage); items whose bonus a weapon's row already holds (Giant
  Belt, Greek Fire, Scared Sausage) show as "included", and an "Other" row holds the rest. In co-op
  it also shows each player's share of the team's damage. Nobody is held up
  while a player looks at it. It also works offline. **Options, Gameplay, Damage meter** switches
  it on or off for your machine: your HUD and your own panel's page. Other players' panels show
  what those players see. The choice is kept in the Mod Loader's config, because the game
  has no settings screen for mods. It is modelled on the
  [Damage Meter](https://steamcommunity.com/sharedfiles/filedetails/?id=3578347192) mod by
  Oudstand, which is not needed next to this mod (with both, each shows its own). That mod's
  other options and its separate entry for charmed enemies are not part of this one.
- **DLC:** a friend without one of the host's DLCs can still join. As with Steam Remote Play
  Together, the host's DLC content is usable in the host's session only (the *Online co-op* page
  says so). It is gone when the friend leaves and never becomes their own.
- **Progress counts for everyone:** what a run earns goes into every player's own save, as in
  local co-op: challenges (with their Steam achievements and the characters, items and weapons
  they unlock), the danger levels that a won run opens, and the lifetime counters such as enemies
  killed and materials collected. A reward that belongs to a DLC you only have from the host is
  recorded as unlocked, and the game offers it once you own the DLC. A client never writes the
  host's run into its own save file.
- **Fixes to the game itself**, which also apply offline:
  - An item that adds a weapon slot (Cybernetic Arm) shows in "WEAPONS (n/m)" as soon as it is
    bought, in co-op and solo. In the unmodded game the label follows in the next shop.
  - The Anvil's weapon upgrade at shop entry leaves the weapons row in step with the run, in
    co-op and solo.
  - In co-op with DLC 1, the unmodded game closes without an error when one player owns an Axolotl and
    the text of an Axolotl offered to another player is shown. With the mod, that text names the
    player's own highest and lowest stats, and `modloader.log` gets a warning
    (`einfluffles-BrotatoTogether:Axolotl`).
- **Other mods** can add shop and level-up / crate decisions of their own that reach the host
  the same way. [brotato:trade](../brotato-trade) does.

## Launch options

Online traffic goes through Steam's relay servers only, never directly between the players. No
launch option is needed for that.

To change it, set a launch option in Steam (right-click *Brotato*, *Properties*, *General*,
*Launch Options*) and restart the game.

| Option | What it does |
|---|---|
| `+bt_direct` | Lets Steam connect the players directly when it finds that better (Steam's own default). |

`+bt_relay`, the former opt-in to relays, is still accepted and changes nothing.

- **Why relays only:** with both routes open, Steam's probing of the other route caused stalls of
  0.2 to 3.3 s about every 12 s. With relays only, the same two players had none (measured on
  2026-11-16; details in [`docs/implementation.md`](docs/implementation.md)). The
  price is the detour over Steam's nearest data center.
- **When to use `+bt_direct`:** a player is far from any Steam relay data center (the ping through
  the relay is much worse than it should be), or a connection never comes up while the log says
  `no relay reachable from here`. Both players set it.
- **Send rate:** the mod lets Steam send up to 512 KB/s per player, where Steam's default is
  256 KB/s. The rate matters only while data is waiting, and the host's setting is the one that
  counts.

## Languages

The mod's own texts follow the game's language (*Options*, also when you change it in a running
game), in all 13 of the game's languages: English, French, Simplified Chinese, Japanese, Korean,
Traditional Chinese, Russian, Polish, Spanish, Portuguese, German, Turkish and Italian. They use
the game's own words where it has them (co-op, player, wave, pause, damage). Where the game has
none (lobby, host, kick, invite), they follow the usual wording of Steam in that language. The
translations other than German are drafts: corrections from players of those languages are very
welcome.

The texts are in [`src/einfluffles-BrotatoTogether/translations.csv`](src/einfluffles-BrotatoTogether/translations.csv):
one row per text, one column per language in the game's order
(`key,en,fr,zh,ja,ko,zh_TW,ru,pl,es,pt,de,tr,it`), UTF-8, a cell with a comma in double quotes.
Corrections are welcome as a pull request that changes only that file. Keep the key and every
placeholder of the English text (`{0}`, `{1}`), and keep a text about as short as the English
one: the menus have little room. The `l10n` suite checks the file (every cell filled, the same
placeholders as English, every character in the game's fonts), and the language sweeps of the
`l10n`, `damage` and `lobby_menu` suites check that the texts fit their screens in every
language. How it works: [`docs/implementation.md`](docs/implementation.md#localization).

## Limitations

As of 2026-11-23 (protocol 33):

- Not shared with clients yet: the species challenges of Primal Dread (trophy hunter, clever
  girl, egg hunt) and the codex's kill counts.
- Not tested: whether `+bt_direct` on one side alone changes the route (see
  [Launch options](#launch-options)).
- The host can kick a player only from the main menu's lobby frame. The *Online co-op* page of
  the pause menu has no *Kick*.
- [`docs/implementation.md`](docs/implementation.md) records further open points of single
  screens.

## Reporting problems

Please send the **host's** `modloader.log` (`user://logs/modloader.log`). It holds the most:

- At startup it states the route (`Route: ...`) and the send rate (`Send rate: ...`), or warns
  when Steam refused one of the settings.
- It names each network stall (direction, length, and whether the other game stalled or the
  messages were held up), the connection's path (`relayed via ...` or `direct`) and what was sent
  when Steam's send queue filled up.
- Each client reports into it: how smooth its frames were, how long it stalled when a screen
  changed, and how often its own character was corrected.
- Warnings worth pointing out in a report: `... run state changed without a change of its
  fingerprint: ...`, `... state held ... times for ...`, `Connection to ... is direct although
  relay-only is on here` and the Axolotl warning named above.

## How it works

- **The host runs the real game in local co-op mode.** Each remote player is a virtual gamepad
  whose inputs arrive over the network. All game logic (stats, shop, waves) runs unchanged on the
  host.
- **Battles:** a client loads the real battle scene with its simulation frozen and shows the
  host's snapshots (30 per second) about 100 ms behind. Its own character is predicted locally.
  Network stalls of up to about half a second are bridged: the own character keeps moving, and
  the world holds and then catches up.
- **Shop, level-ups, crates:** a client loads the real screens with the options the host rolled,
  through the game's own save and resume path, and mirrors every player's cursor. The run state
  travels in parts, and each client gets only the parts it lacks.
- **Decisions:** a client's own panel sends each decision to the host, which checks it against
  what that panel shows and then applies it.
- **Transport:** Steam lobbies and Steam Networking Messages, through the GodotSteam module that
  ships inside Brotato.

The mechanisms, the wire format and the measurements are in
[`docs/implementation.md`](docs/implementation.md). The game-side hooks are mapped in
[`docs/brotato-hooks.md`](../../docs/brotato-hooks.md).

## Tests

`tests/einfluffles-TogetherTests` is a dev-only test mod that is never packaged. Run it with
`tools/check.sh mods/brotato-together`, or one suite with `tools/check.sh -s <suite>`. Every suite
passes on its own. [Testing](../../docs/testing.md) explains how a check runs.

The checks also load `dev/einfluffles-TogetherLocal`, the dev-only local-play mod (never packaged
either, [Local play](docs/implementation.md#local-play-dev-mod)). The `emulator` suites use its
Steam stand-in. To play host and client in two windows on one PC: `tools\play-local.ps1`
([Play locally](../../docs/testing.md#play-locally)).

The suites are the entries of `SUITES` in the test mod's `mod_main.gd`:

| Suite | What it covers |
|---|---|
| `core` | Virtual input devices and remote input reaching the game, the snapshot wire format, the session lifecycle on a fake Steam, a client borrowing the host's DLC, the run-state round trip. |
| `battle_loopback` | A real host battle replayed on a client, the own-player prediction, the level-up / crate panels (mirrored, the own panel with pad, keyboard and mouse, decisions checked by the host), a 400 ms snapshot gap. |
| `input_ack` | A remote player moved one step per acknowledged input against the client's prediction, with jitter, lost packets and gaps; the own player standing still at the wave's end. |
| `pose_mirror` | Parts the game turns in physics code (a bullet ring, a gun's aim, a dino's heading), facing and hidden flags. |
| `anim_mirror` | Animations the game starts from physics code (a turret, a catling gun, a spitter), played on puppets without their side effects. |
| `runtime_parts` | Parts the game adds, frees or shows during a wave. |
| `battle_perf` | Net ids of pooled nodes that are reused, the sounds the host records, the brachiosaurus and its foot on a client, the client's puppet pool. |
| `bullet_hell_left`, `bullet_hell_top`, `bullet_hell_bottom` | Every visible enemy bullet of a bullet-hell wave is in the snapshot and mirrored (one suite per variant). |
| `menu_ux` | The wave-failed prompt and its cursor on clients, the change from the battle to the next screen. |
| `shop_loopback` | The host's real co-op shop and a purchase mirrored on a client with cursor and sounds, the weapons row (Anvil at shop entry, a new weapon slot). |
| `local_shop` | The own shop panel on a client, decisions applied or refused by the host, locks, the meca upgrade, the reroll's stat text, another mod's decision, the mouse on the item popup, the own popup kept open through a gear change, the wheel, the client's own pause menu (also when the shop goes with it open). |
| `local_device` | Which screen drives a client's own input from the level-up panels to the shop, with a host pause across the change. |
| `pause_input` | Remote button presses, timeouts and pause, menu echo, the own aim setting, who owns the pause menu, absent players. |
| `live_menu` | The Esc menu over a running online wave, on the host and on a client. |
| `cleanup_host` | Object counts over several waves played as the host. |
| `cleanup_client` | Object counts over one wave replayed several times as a client, with the shop in between. |
| `cleanup_misc` | Battle starts and shop states that arrive together, and what a late endless wave costs. |
| `feedback` | Explosions, floating texts, stat icons, picked-up crates, tardigrade charges, the end of the wave, the whip's and flail's lash. |
| `hit_numbers` | Damage and heal numbers on a client: 80 hits in one tick, a flood of hits that fills the host's queue, a hit in an enemy's spawn tick, a hit on a pet, a hit and a heal in one snapshot, a lost snapshot, burn ticks and hits on a unit with an aim shape. |
| `looks` | Charmed, burning, cursed, boosted, meca and mutant looks, puddles, projectile angles. |
| `damage` | The damage meter: counting, the row in the wave, the pages, the switch (this machine's players only). |
| `damage_run` | The damage meter in real waves: the total against the health lost with Giant Belt, Scared Sausage and Greek Fire, in a crowded wave past the game's cap on enemies and for a hit on an enemy the cap removed, the end of the wave before its panels, the run stats over waves, retries and new runs. |
| `battle_scene` | A breaking weapon, the hole layout, a stomped hole, the host's speed in the own-player prediction, walking into holes. |
| `puddle_reuse` | Trails of fire (another player's magma boots), acid and petrol puddles on a client, also once the puddle puppets come back from the pool. |
| `dead_player` | A player who died stays visible when the next wave starts him at 0 health. |
| `selection` | The host's selection screens, end of run and co-op resume screen on a client, colours and join hints, the shared character grid, wheel and right stick, a locked-in cursor and a player who leaves after the pick, the host's player joining first. |
| `state_stream` | The state stream on a fake session: change keys, resyncs, states held for a full send queue, malformed messages. |
| `shop_change` | Change detection of the shop's run state and what a check costs. |
| `run_parts` | The run state in parts: which parts each change sends, the client building the same run, resyncs. |
| `battle_start` | A wave's start sending only the run parts a client lacks. |
| `cursor_key` | The change key of the cursors on the co-op shop. |
| `focus_targets` | A cursor's gear element named by the item it shows: found again on a row ordered otherwise or with an element more or less, cursed copies and alike weapons told apart, nothing when the item is gone, locked elements and grids by place, malformed targets from the network rejected. |
| `upgrades_change` | Change detection of the run state of the level-up / crate panels. |
| `upgrades_popup` | A remote player's open popup on the host's level-up / crate panels: the lobby popup keeps its focus, a client that leaves takes it off. |
| `lobby_menu` | The lobby in the game's menus on a fake Steam: title screen, kicking, the Co-op row and slot invite of character selection (also switched to German), the client's popup, the pause menu page. |
| `network_stalls` | The render delay through stalls, the log lines for gaps, the session's path. |
| `traffic` | The reliable traffic that the log names. |
| `emulator` | The local-play dev mod's Steam stand-in (`dev/einfluffles-TogetherLocal`) on the in-process wire: fake ids, lobbies, sessions, send results, pacing, latency, loss, reordering, stalls, failures, connection info; the dev mod staying inert outside local play. |
| `emulator_transport` | The real transport and session of a host and two clients on that stand-in: hosting, joining, the handshake, messages both ways, send results and the full resync, leaving, kicking, a game that is gone, a failed session and its restart, another version's lobby. |
| `emulator_wire` | The wire between local-play game processes (`wire_tcp.gd`) with real sockets on 127.0.0.1: framing, the handshake and its token, the host's lobbies reaching the clients, a join, messages both ways (300 KB in one), a client reaching another through the host, a client and the host leaving; every dev mod script compiles. |
| `progress` | What the host's run earns for a client's own save. |
| `client_report` | A client's frame, stall and correction reports and the host's log lines for them. |
| `axolotl` | The Axolotl's text in the state the game's own roll leaves in co-op, and the Mod Loader's backup of every extended game script. |
| `own_pickups` | The own player's pickups shown at once on a client. |
| `l10n` | The mod's texts in the game's languages: `translations.csv` (header, keys, placeholders), its loader, the game's keys the mod uses, the title screen's lobby frame, the lobby page, the client's waiting screen, the pause banner, the options' damage meter switch and the damage board switched from English to German (character selection: `lobby_menu`). |
