# brotato:together

Online co-op for [Brotato](https://store.steampowered.com/app/1942280/Brotato/) over Steam P2P —
instead of Steam Remote Play's video stream.

**Status:** early development; first sessions over Steam with friends work. Expect rough edges — please report them with `modloader.log`.

Mod id: `einfluffles-BrotatoTogether` · source: [`src/einfluffles-BrotatoTogether`](src/einfluffles-BrotatoTogether) · license: [MIT](../../LICENSE)

## How it works

- **Host-authoritative, built on Brotato's local co-op.** The host runs the real game in local co-op mode;
  each remote player is a *virtual gamepad* whose inputs arrive over the network. All game logic
  (stats, shop, waves) runs unchanged on the host.
- **Battles:** clients load the real battle scene with its simulation frozen and render the host's 30 Hz
  snapshots with interpolation (~100 ms behind); your own character is predicted locally and reconciled.
  Short network stalls (up to about half a second) are ridden out: your character keeps moving, and the
  world holds and then catches up smoothly instead of jumping. `modloader.log` names each stall (which
  direction, how long, and whether the other game stalled itself or the messages were held up or lost
  on the way) and whether the connection is direct or relayed by Steam; when Steam's send queue holds
  4 KB or more it also names what was sent reliably in the last two seconds (message types and
  sizes), and a single message over 32 KB or a queue over 64 KB gets a log line of its own.
  Each client also reports into the host's `modloader.log`: how smooth its frames were (every 10 s
  when a frame took 50 ms or more, else once a minute; in battle with what mirroring the host's world
  cost), how long it stalled when a screen changed and how much of that was the mod, and how often
  and how far its own character was corrected. At most 8 lines a minute per client.
  Spawn markers (where the next enemies appear) and the life bars of bosses and elites are mirrored too,
  and so are explosions, screen shake, level-up / heal / material texts, the icon and number over
  a character whose stat changed (evolution, a mutation fruit, an item's gain), the crates a player
  has picked up (the icons next to the level-ups in the HUD) and the end of the wave
  (dimmed screen, "wave completed", the bonus material bag).
  The whip and the flail lash out on clients like on the host.
  In the shop, the stat a reroll gives (bone dice) shows over that player's reroll button.
  Charmed, burning, cursed, boosted, meca and mutant enemies look like they do on the host (a
  charmed enemy and its shots in the charm colour, an evolved one with its outline and sprite),
  shots point the way they do on the host, and acid / petrol / fire puddles appear and fade with
  the host's.
  Clients see the host's holes on the jungle waves that have them and the ones the brachiosaurus'
  foot stomps, and lose a weapon when it breaks on the host; your own character's prediction moves
  at your speed on the host (petrol, slows) and stops at holes like on the host.
  The host moves a remote player by exactly one of their inputs per physics tick (bunched packets
  wait in a short queue, a tick without one stands still) and acks the input it moved with, so the
  prediction agrees with the host while running and stopping despite network jitter. Each input
  packet also carries the last few movements, so a lost packet costs no step; after a network
  stall of up to 600 ms the host catches up on the steps you already saw (at most twice your speed)
  instead of pulling you back, and only a longer one ends in a small, smoothed correction.
- **Esc during a wave opens the menu without pausing:** the wave runs on for everybody. The host
  gets the game's menu (its character stands still meanwhile), a client its own copy for options and
  the codex; restart / end run stay with the host, and a client's *Quit* asks to leave the lobby.
- **Shop, level-ups, crates:** clients load the real screens with the host's rolled options (via the game's
  own save/resume path) and mirror every player's cursor. The run state travels in parts (the common
  part, and per player its weapons and items and the rest) and each client gets only the parts it
  lacks: a page flip or a Go no longer resends the whole run (in a late 4-player test run 0.75 KB
  instead of 30 KB per client), a level-up choice only that player's part (7.6 KB), and a client only
  parses and rebuilds the players that changed (a level-up choice: 29 instead of 150 ms there). The
  next wave's start does the same: after the shop it sends only the common part (3.3 instead of
  30 KB per client in that run), and a client's run work before it loads the battle drops from
  about 145 to 4 ms; a player who starts the wave hurt (weird ghost, hourglass) is no longer healed
  on clients. The
  level-up / crate panels then redo only that player's stats, and its gear page only when its items or
  weapons changed: a level-up choice or reroll applies in about 40 instead of 320 to 365 ms there, a
  crate item in about 110 instead of 300 to 345 ms (these panels were where clients dropped to 5 to
  8 FPS). A purchase still sends that player's whole item list (about as much as before). While
  Steam still has more than 24 KB queued for a client, the host does not pile the next shop or panel
  state on top: that client gets the newest state once the queue has room (at most 2 s later), one
  message for every change it missed (three quick changes in a test run: 13.8 KB instead of
  21.9 KB). When the shop or the panels close, the host logs what they sent (`modloader.log`:
  "Shop 12: 28 states, ...", and "Shop state held 3 times for <name>, longest ... ms" for each
  client it held). A change of the run its quick check did not see still goes out within 1 s, and
  the warning names what changed ("shop run state changed without a change of its fingerprint:
  p0.effects.stat_max_hp; sent"): please include such lines in a report. (The misses earlier
  sessions logged late in a run came from item descriptions shown on the host, which changed how
  the game saves those items; they no longer do.)
- **Your own level-up / crate panel runs on your machine:** cursor, pages (upgrades / gear / stats) and
  item popups react at once; only the decision (choose, reroll, take, recycle, ban) goes to the host,
  which checks it against what your panel shows and applies it. It follows the device you use: with a
  pad the triggers switch pages, on the keyboard the page arrows take the cursor, and the mouse moves
  and clicks your own cursor (other players' panels ignore it). Your character stands still meanwhile:
  the keys and stick that move the cursor are not sent as movement. The right stick scrolls item
  descriptions and the stats sheet on your own screen (it only scrolled the host's copy before).
- **Your own shop panel runs on your machine too:** cursor, pages, item popups, inventory browsing, the
  hold-to-ban bar and a meca item's effect choice are local. Buy, reroll, lock / unlock, steal, ban,
  dismantle, Go, combine and recycle go to the host, which applies them with the game's own rules when
  they still match your panel. The inventory popup's meca upgrade shows the two options the host rolled
  and sends the one you pick.
  The shop does not follow the keyboard and mouse yet the way the level-up panel does.
  Each of these screens claims your slot's input for itself, so a level-up panel that stops late
  never switches off your shop panel, and the shop panel takes its input back if anything else did
  (both written to the log).
  Other mods can add shop decisions of their own that reach the host the same way
  ([brotato:trade](../brotato-trade) does, for giving items and weapons to other players).
- **Two fixes in the game's own shop** (online, local co-op and solo): an item that adds a weapon
  slot (Cybernetic Arm) shows in "WEAPONS (n/m)" as soon as it is bought, not only in the next
  shop (the slot itself could always be used at once, also by a client and in the next wave).
  The Anvil's weapon upgrade at shop entry no longer builds a weapon in the still empty weapons
  row and frees it again ("combine: no inventory element for ..., the weapons row is out of sync"
  in the log, and a cursor sent to a control that was being freed).
- **Axolotl crash fixed** (DLC 1, online and local co-op): once a player had bought an Axolotl,
  the next Axolotl offered to another player (in the shop or a crate) made the game forget which
  stats the bought one had swapped, and showing its text closed the game without an error. Its
  text now names
  that player's own highest and lowest stats, and `modloader.log` gets a warning
  (`einfluffles-BrotatoTogether:Axolotl`) with what was found: please include it in a report.
- **Damage meter:** during a wave, two lines at each player's life bar show what that player
  has dealt in the wave, the damage per second, the two strongest weapons or items and the
  biggest single hit. Big numbers stay short (12.3K, 4.57M, 7.89B). In the co-op shop and at
  the end of a co-op run, each player's panel has a fourth page, **Damage**, after the shop and
  the two stats pages: LB / RB (or the arrows) lead there like to the stats. In the solo shop
  and at the end of a solo run it is a third tab in the stats panel (LB / RB cycle through
  Primary, Secondary and Damage). The page shows the wave before (at the end of a run: the
  last wave): total, damage per second, biggest hit with the weapon or item that dealt it, and
  every source with name, a bar, number and share. Nothing pauses and nobody else is held up;
  the others see who looks at their damage page, like at their stats. The host measures (from
  the game's own counters) and every client shows the host's numbers. In co-op the row and the
  page also show each player's share of the team's damage. It also works offline.
  **Options → Gameplay → Damage meter** switches it off or on for
  your machine (kept in the Mod Loader's config; the game has no settings screen for mods). After the [Damage Meter](https://steamcommunity.com/sharedfiles/filedetails/?id=3578347192)
  mod by Oudstand, which is no longer needed next to this mod (with both, each shows its own).
  Not taken over: its other options and the separate entry for charmed enemies.
- **Selection screens / end of run:** clients see the game's own character, weapon and difficulty
  selection and end-of-run screens, showing what the host's show: the host's grid (so local
  unlocks/DLC don't matter), every player's cursor, panel and ready state, the zone, the join
  slots, and in weapon selection the character a player holds F / Y to see in their panel.
  They decide nothing there; input goes to the host. The character grid, which every cursor
  shares, scrolls after your own player's cursor only (on the host after its local players):
  the other players moving through it no longer scroll your screen. Your right stick scrolls
  your own panel's description there (on a client too, at once), and the other players' panels
  show where their players scrolled them on the host.
- **Mouse wheel:** on the selection screens, in the shop and in the level-up / crate panels the
  wheel scrolls what is under the pointer in your own panel (description, stats, item lists, the
  character grid), on the host for its keyboard player and on a client for its own player. It
  never scrolls another player's panel; in local co-op without a lobby it scrolls the keyboard
  player's panel only (the game turns the wheel off on co-op screens).
- **Wave failed:** the retry / end-run prompt appears on clients too, with who gets to choose.
- **Sounds:** clients hear the host's sounds — battle sounds with the snapshots, menu/shop sounds as
  they happen — instead of their own mirrored screens' sounds.
- **Transport:** Steam lobbies (friends-only, overlay invites) + Steam Networking Messages via the GodotSteam
  module that ships inside Brotato. No port forwarding.
- A client never writes the host's run into its own save file and never unlocks challenges from it.
- **DLC:** a friend without one of the host's DLCs can still join: like Steam Remote Play Together, the
  host's DLC content is usable in the host's session only (the *Online co-op* page says so) and is gone again as
  soon as they leave (and while they are in their own main menu); the content never becomes their own.
- **Progress counts for everyone:** what a run earns goes into every player's own save, like in
  local co-op: challenges (with their Steam achievements and the characters, items and weapons
  they unlock), the danger levels a won run opens, and the lifetime counters (enemies killed,
  materials collected, ...), which every player counts for themselves. A reward that belongs to
  a DLC you only have from the host is recorded as unlocked too; the game offers it once you
  own the DLC. Not yet shared: the species challenges of Primal Dread (trophy hunter, clever
  girl, egg hunt) and the codex's kill counts.

Details: [`docs/implementation.md`](docs/implementation.md).

## Playing

Everyone subscribes to the Workshop item (and unsubscribes from other online/co-op mods). Then:

The mod has no menu, hotkey or overlay of its own: online play sits in the game's menus and is used
like them (mouse, keyboard, gamepad).

- **Character selection:** the run options box's Co-op row has three values: *Off* (solo),
  *Local* (the game's co-op) and *Online* (co-op and a lobby you host). It is a dropdown like the
  zone's above it, in the place of the game's Co-op toggle, so the screen keeps its layout.
  Choosing *Off* or *Local* while online leaves the lobby. While you host, the player slot the
  next player takes shows *Invite friends* (Steam overlay) and the number of players in the lobby,
  under "Hold ... to join"; with keyboard or pad, player 1 gets there with left from the Co-op row.
- **Main menu → Host lobby** (below *Start*) opens a lobby without leaving the main menu: you can
  still go through options, the codex and the other pages while it is up. A small frame next to the
  buttons lists who is in the lobby (with ping), and the button becomes *Invite friends*. As the
  host you have **Kick** behind every other player's name and *Leave lobby* under the list. A
  kicked player is told so and can join again once invited again.
- **Joining a lobby whose host is in the main menu** leaves you in your own main menu, with the
  same frame. *Start* and *Continue* are off for you and the button reads *Leave lobby*: the host
  starts or continues, and everybody in the lobby is taken into that screen. *Start* with a lobby
  open leads to a co-op run. When the host returns to its main menu, so do you to yours.
- **Pause menu → Online co-op** during a run (host and client): a page with *Host lobby*, *Invite
  friends*, *Leave lobby* and the connection details (role, every player with state and ping,
  players who are away, the last error). Leaving in the middle of a run asks first.
- **As a client on the host's screens outside a wave** (selection screens, waiting for the host to
  resume a run) there is no pause menu: **Esc / Start** opens the same page as a popup. While it
  is open the game gets none of your keyboard/gamepad input (the host sees you letting go of
  everything).
- Friends join through the Steam invite or *Join game* in the friends list. An invite you accept in
  the middle of a run opens the page with *Join invite* instead of dropping your run.
- If a lobby fails (not created, join refused, host gone), the reason shows in the main menu's
  error line and on the page.

The host opens co-op character selection; remote players hold *accept* (Space / Enter / A) to join
like local players. Every free slot shows "Player N" at its top and the game's hold-to-join hint, on
the host and on clients. In character selection each player can change their colour with **F** (keyboard) /
**Y** (gamepad; Triangle on PlayStation pads), cycling through 8 colours and skipping colours other
players already have. The colour is used everywhere the game uses player colours (cursor, panels,
HUD, player highlight) and clients see the same colours. Nothing is saved; players who don't pick keep
the game's colours. A locked character under a cursor shows how to unlock it (on clients too).

A wave never pauses while friends are connected (Esc opens the menu over the running game, see
above; losing window focus pauses nothing either). In the shop anyone can pause: the host operates
the pause menu, and whoever paused can resume with pause again. During the level-up / crate panels
only the host's own players can pause; a client's own panel keeps running meanwhile, and a choice
made there waits on the host until it resumes (it used to end the panels inside the pause, and the
shop then came up paused with no menu, so every client's own shop panel stayed dead until the host
paused and resumed again). A host with nobody connected pauses as always.
Aiming follows each player's own manual-aim setting (mouse or right stick). If a player drops and
doesn't come back within 20 s, the host makes their level-up / crate / shop choices so the run goes on.

## Launch options

Online traffic goes through Steam's relay servers only, never directly between the players. No
launch option is needed for that.

To change it, set a launch option in Steam: right-click *Brotato* → *Properties…* → *General* →
*Launch Options*, then restart the game.

| Option | What it does |
|---|---|
| `+bt_direct` | Lets Steam connect the players directly again when it finds that better (Steam's own default). |
| `+bt_relay` | Nothing any more: relay-only is the default. Still accepted, and the log says it is no longer needed. |

If both are set, `+bt_direct` wins (it is the only one that changes anything).

**Why relay-only:** Steam keeps two routes to the other player, a direct one and one through its
relays, uses the better one and keeps probing the other to see whether it should switch. With both
routes, sessions had stalls of 0.2 to 3.3 s on a fixed beat (about every 12 s, in battle and in the
shop, both directions) while both internet lines were fine. Through the relay only, the same two
players played 8 waves (about 10 minutes) without a single network stall, where they had one every
20 to 50 s before; Steam switching between relay data centers during the session caused no stall
either. The price is the detour over Steam's nearest data center (for two players near the same
one, about the same ping as the direct route).

- **Both players should run this version.** An older build still offers Steam the direct route, and
  whether relay-only on one side alone keeps it from forming is not tested. Older and newer builds
  still play together. When a connection comes up direct anyway, `modloader.log` warns once per
  player: `Connection to … is direct although relay-only is on here`.
- **When to use `+bt_direct`:** a player far from any Steam relay data center (the ping through the
  relay is much worse than it should be), a connection that never comes up while the log says
  `no relay reachable from here` (relay-only has no direct route to fall back on), or for testing.
  Both players set it.
- `modloader.log` says at startup which mode is on and why:
  `Route: sessions go through Steam's relays only (default; …)` or
  `Route: Steam may connect directly (launch option +bt_direct)`. If Steam refuses the setting, or
  the game's GodotSteam cannot set it, a warning says so and Steam picks the route itself. While
  relayed, the connection lines read `relayed via …` and never `direct`.

**Send rate:** the mod lets Steam send up to 512 KB/s per player instead of Steam's default 256 KB/s,
with no launch option needed. Steam paces everything at that rate, so a large update (the whole run,
for example 250 KB in the shop late in a run) used to hold up everything behind it for almost a
second; at 512 KB/s it takes half of that, and far less since the run travels in parts. The rate only matters while data is waiting.
The host's setting is the one that counts, so a host running this version already helps.
`modloader.log` says at startup `Send rate: up to 512 KB/s (Steam's default is 256)`, or warns
that Steam's default stays if Steam refuses the setting.

## Tests

`tests/einfluffles-TogetherTests` is a dev-only mod run by `tools/check.sh` (never packaged): virtual input,
run-state round trip, a client borrowing the host's DLC (and giving it back exactly), a recorded host battle replayed on a client, shop purchase mirroring, the weapons row of the shop (the Anvil at shop entry co-op and solo, a new weapon slot in the label at once, a remote player buying into it, a 7th weapon on a client's puppet), the run state in parts (which parts each change sends, the client building the same run from
them, resyncs, a body replaced while pending, a missing part, a client held while Steam's queue to it is full getting the union of what it missed; a wave's start after the shop carrying only the common part, the client's run then the host's, a start queued while a scene loads), shop locks (per slot, also after a buy; the own press shown at once), the own shop
panel running locally (intents applied or rejected on the host, nothing changed on the client), another mod's shop intent (registered, applied once, sent from the own panel only), level-up/crate
panels (mirrored options, the own panel running locally with pad, keyboard and synthetic mouse events, decisions as checked intents, the crate weapon popup's combine / recycle / meca upgrade, the gear page rebuilt by the host's run changes under the own and a mirrored cursor, a cursor whose control is freed), cursor mirroring (also with another mod's extra controls on one machine only), the host's selection screens and end of run as the game's own scenes on a client (the host's grids, selections, zone, join progress, the character shown while a player holds F / Y in weapon selection; nothing decided or saved there; a client joining before anybody joined on the host), the shared character grid scrolling after each machine's own players only (host, client, local co-op), the mouse wheel scrolling only the mouse player's own panel (shop, level-up, character selection; host and client) and the right stick in character selection (own panel, mirrored positions on a client), "Player N" above the join hint, shop UI sounds, the lobby
in the game's menus (the title screen's Host lobby button and player frame, kicking, a client in its own main menu
while the host is in its own, the pause menu page, the Co-op row and the slot invite of character selection (and that they
move nothing in the layout), the client's popup, each with keyboard / pad / FocusEmulator input and a fake Steam), the wave-failed prompt and the battle -> shop transition on clients, which screen drives a client's own
input from the level-up panels to the shop (a host pause across the change, late level-up stops, a lost device, a shop pause that ended with its shop), the Esc menu
of an online wave (host and client), and wave cleanup: object counts across several waves on host and
client, no references to freed nodes, duplicate / queued battle starts, plus what a late endless wave
costs per snapshot and per frame; a weapon breaking mid-wave, the hole layout, a stomped hole, the host's
speed in the own-player prediction and that prediction walking into holes where the host's player stops,
also for a client joining mid-wave, and the own player running only while its
keys are held; input streams moving a remote player on the host one step per acked input against the
client's own prediction code (jittered: bunched packets, ticks without one, a late stop, a swapped pair, a
duplicate; one lost packet and four in a row, recovered from the redundant moves; a 450 ms gap caught up
without a release; a 1.2 s gap that releases the player and ends in a blended correction), so the
prediction needs no correction short of that, plus malformed redundancy fields and the protocol bump;
network stalls (a 400 ms snapshot gap in the replayed battle keeps the own player's
prediction and holds the world, the render delay on a good connection, through a stall, under recurring
lateness and after a long outage, gap log lines for snapshots and inputs, the session's path and what
followed a failed session);
the reliable traffic named in the log (labels with their counts and bytes, the two-second window, the
queue size from which slow answer and gap lines name it, the rate limit of the burst line, nothing kept
after a peer left);
a client's reports to the host's log (frame windows from fed frame times, a scene change's stall with
the mod's share in it, corrections over a step; the host's lines, malformed reports dropped, the line
budget; a replayed battle's real stall and mirror cost);
the Axolotl's text in the state the game's own roll leaves its shared effect in during co-op (the
shop's description of the offer, the owner's item, broken saved states; a normal Axolotl keeps the
game's text).

The tests are named suites (`SUITES` in `mod_main.gd`), each passing on its own: `tools/check.sh -s <suite>`
runs one, and `shards.txt` groups them into the game processes a full check runs side by side.
