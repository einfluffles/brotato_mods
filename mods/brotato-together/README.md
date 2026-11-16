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
  direction, how long, held up or lost) and whether the connection is direct or relayed by Steam.
  Spawn markers (where the next enemies appear) and the life bars of bosses and elites are mirrored too,
  and so are explosions, screen shake, level-up / heal / material texts and the end of the wave
  (dimmed screen, "wave completed", the bonus material bag).
  Charmed, burning, cursed and boosted enemies look like they do on the host (a charmed enemy and
  its shots in the charm colour), and acid / petrol / fire puddles appear and fade with the host's.
  Clients see the host's holes on the jungle waves that have them and lose a weapon when it breaks on
  the host; your own character's prediction moves at your speed on the host (petrol, slows).
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
  own save/resume path) and mirror every player's cursor.
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
- **Selection screens / end of run:** clients see the game's own character, weapon and difficulty
  selection and end-of-run screens, showing what the host's show: the host's grid (so local
  unlocks/DLC don't matter), every player's cursor, panel and ready state, the zone, the join
  slots, and in weapon selection the character a player holds F / Y to see in their panel.
  They decide nothing there; input goes to the host. The character grid, which every cursor
  shares, scrolls after your own player's cursor only (on the host after its local players):
  the other players moving through it no longer scroll your screen.
- **Wave failed:** the retry / end-run prompt appears on clients too, with who gets to choose.
- **Sounds:** clients hear the host's sounds — battle sounds with the snapshots, menu/shop sounds as
  they happen — instead of their own mirrored screens' sounds.
- **Transport:** Steam lobbies (friends-only, overlay invites) + Steam Networking Messages via the GodotSteam
  module that ships inside Brotato. No port forwarding.
- A client never writes the host's run into its own save file and never unlocks challenges from it.
- **DLC:** a friend without one of the host's DLCs can still join: like Steam Remote Play Together, the
  host's DLC content is usable in the host's session only (the *Online co-op* page says so) and is gone again as
  soon as they leave (and while they are in their own main menu); nothing of it is saved and it never becomes their own.

Details: [`docs/implementation.md`](docs/implementation.md).

## Playing

Everyone subscribes to the Workshop item (and unsubscribes from other online/co-op mods). Then:

The mod has no menu, hotkey or overlay of its own: online play sits in the game's menus and is used
like them (mouse, keyboard, gamepad).

- **Character selection:** the run options box has an **Online** toggle under the game's *Co-op*
  toggle. Switching it on hosts a lobby (and switches co-op on); *Invite friends* (Steam overlay)
  appears below it, with the number of players in the lobby. Switching it off leaves the lobby.
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

Set in Steam: right-click *Brotato* → *Properties…* → *General* → *Launch Options*, then restart the
game.

| Option | What it does |
|---|---|
| `+bt_relay` | All online traffic goes through Steam's relay servers, never directly between the two players. |

**When to use `+bt_relay`:** everybody stands still for a second or three, again and again on a
fixed beat (about every 12 s, in battle and in the shop), while both internet lines are fine.

Steam keeps two routes to the other player, a direct one and one through its relays, uses the
better one and keeps probing the other to see whether it should switch. When both are about
equally fast, that weighing is the suspected cause of the stalls. With `+bt_relay` there is only
the relayed route and nothing to weigh. The price is the detour over Steam's nearest data center
(for two players near the same one, about the same ping as the direct route).

- Both players set it.
- It took effect when `modloader.log` says `+bt_relay: sessions go through Steam's relays only`
  and the connection lines read `relayed via …` and never `direct`.
- This is a test switch: the cause is not confirmed. If the stalls go on while relayed, the route
  is not it; please report that with both players' `modloader.log`.

## Tests

`tests/einfluffles-TogetherTests` is a dev-only mod run by `tools/check.sh` (never packaged): virtual input,
run-state round trip, a client borrowing the host's DLC (and giving it back exactly), a recorded host battle replayed on a client, shop purchase mirroring, shop locks (per slot, also after a buy; the own press shown at once), the own shop
panel running locally (intents applied or rejected on the host, nothing changed on the client), level-up/crate
panels (mirrored options, the own panel running locally with pad, keyboard and synthetic mouse events, decisions as checked intents, the crate weapon popup's combine / recycle / meca upgrade, the gear page rebuilt by the host's run changes under the own and a mirrored cursor, a cursor whose control is freed), cursor mirroring (also with another mod's extra controls on one machine only), the host's selection screens and end of run as the game's own scenes on a client (the host's grids, selections, zone, join progress, the character shown while a player holds F / Y in weapon selection; nothing decided or saved there; a client joining before anybody joined on the host), the shared character grid scrolling after each machine's own players only (host, client, local co-op), "Player N" above the join hint, shop UI sounds, the lobby
in the game's menus (the title screen's Host lobby button and player frame, kicking, a client in its own main menu
while the host is in its own, the pause menu page, the Online toggle of character selection, the
client's popup, each with keyboard / pad / FocusEmulator input and a fake Steam), the wave-failed prompt and the battle -> shop transition on clients, which screen drives a client's own
input from the level-up panels to the shop (a host pause across the change, late level-up stops, a lost device, a shop pause that ended with its shop), the Esc menu
of an online wave (host and client), and wave cleanup: object counts across several waves on host and
client, no references to freed nodes, duplicate / queued battle starts, plus what a late endless wave
costs per snapshot and per frame; a weapon breaking mid-wave, the hole layout and the host's speed in
the own-player prediction, also for a client joining mid-wave, and the own player running only while its
keys are held; input streams moving a remote player on the host one step per acked input against the
client's own prediction code (jittered: bunched packets, ticks without one, a late stop, a swapped pair, a
duplicate; one lost packet and four in a row, recovered from the redundant moves; a 450 ms gap caught up
without a release; a 1.2 s gap that releases the player and ends in a blended correction), so the
prediction needs no correction short of that, plus malformed redundancy fields and the protocol bump;
network stalls (a 400 ms snapshot gap in the replayed battle keeps the own player's
prediction and holds the world, the render delay on a good connection, through a stall, under recurring
lateness and after a long outage, gap log lines for snapshots and inputs, the session's path and what
followed a failed session).

The tests are named suites (`SUITES` in `mod_main.gd`), each passing on its own: `tools/check.sh -s <suite>`
runs one, and `shards.txt` groups them into the game processes a full check runs side by side.
