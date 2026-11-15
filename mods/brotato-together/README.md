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
  Spawn markers (where the next enemies appear) and the life bars of bosses and elites are mirrored too.
- **Esc during a wave opens the menu without pausing:** the wave runs on for everybody. The host
  gets the game's menu (its character stands still meanwhile), a client its own copy for options and
  the codex; restart / end run stay with the host, and a client's *Quit* asks to leave the lobby.
- **Shop, level-ups, crates:** clients load the real screens with the host's rolled options (via the game's
  own save/resume path) and mirror every player's cursor.
- **Your own level-up / crate panel runs on your machine:** cursor, pages (upgrades / gear / stats) and
  item popups react at once; only the decision (choose, reroll, take, recycle, ban) goes to the host,
  which checks it against what your panel shows and applies it. It follows the device you use: with a
  pad the triggers switch pages, on the keyboard the page arrows take the cursor, and the mouse moves
  and clicks your own cursor (other players' panels ignore it).
- **Your own shop panel runs on your machine too:** cursor, pages, item popups, inventory browsing, the
  hold-to-ban bar and a meca item's effect choice are local. Buy, reroll, lock / unlock, steal, ban,
  dismantle, Go, combine and recycle go to the host, which applies them with the game's own rules when
  they still match your panel. Not yet possible for a remote player: the inventory popup's meca upgrade.
  The shop does not follow the keyboard and mouse yet the way the level-up panel does.
- **Selection screens / end of run:** the host's selection grid (built from the host's element list,
  so local unlocks/DLC don't matter) with every player's cursor and ready state, plus per-player
  cards of what each cursor is on.
- **Wave failed:** the retry / end-run prompt appears on clients too, with who gets to choose.
- **Sounds:** clients hear the host's sounds — battle sounds with the snapshots, menu/shop sounds as
  they happen — instead of their own mirrored screens' sounds.
- **Transport:** Steam lobbies (friends-only, overlay invites) + Steam Networking Messages via the GodotSteam
  module that ships inside Brotato. No port forwarding.
- A client never writes the host's run into its own save file and never unlocks challenges from it.
- **DLC:** a friend without one of the host's DLCs can still join: like Steam Remote Play Together, the
  host's DLC content is usable in the host's session only (the F9 menu says so) and is gone again as
  soon as they leave; nothing of it is saved and it never becomes their own.

Details: [`docs/implementation.md`](docs/implementation.md).

## Playing

Everyone subscribes to the Workshop item (and unsubscribes from other online/co-op mods). Then:

Press **F9** (gamepad: **hold Select/View** for half a second) to open the brotato:together menu:
*Host lobby*, *Invite friends* (Steam overlay), *Leave lobby* (asks Yes / No mid-run), plus connection details. A small
status pill at the bottom of the screen shows the role, player count and ping. F9 and Select are
the only inputs the mod uses — the game binds neither (F8 is the game's bug reporter).

In the menu: mouse, or arrows / d-pad / stick to pick a button, Enter / Space / A to press it,
Esc / B to go back or close (F9 / Select close it too). While it is open the game gets none of
your keyboard/gamepad input (a client sends neutral input to the host) and the mouse cursor
stays visible.

The host opens co-op character selection; remote players hold *accept* to join like local players.

A wave never pauses while friends are connected (Esc opens the menu over the running game, see
above; losing window focus pauses nothing either). In the shop anyone can pause: the host operates
the pause menu, and whoever paused can resume with pause again. During the level-up / crate panels
only the host's own players can pause. A host with nobody connected pauses as always.
Aiming follows each player's own manual-aim setting (mouse or right stick). If a player drops and
doesn't come back within 20 s, the host makes their level-up / crate / shop choices so the run goes on.

## Tests

`tests/einfluffles-TogetherTests` is a dev-only mod run by `tools/check.sh` (never packaged): virtual input,
run-state round trip, a client borrowing the host's DLC (and giving it back exactly), a recorded host battle replayed on a client, shop purchase mirroring, the own shop
panel running locally (intents applied or rejected on the host, nothing changed on the client), level-up/crate
panels (mirrored options, the own panel running locally with pad, keyboard and synthetic mouse events, decisions as checked intents, the crate weapon popup's combine / recycle / meca upgrade), cursor mirroring, character-selection cards and grid, shop UI sounds, F9 panel
keyboard/pad input, the wave-failed prompt and the battle -> shop transition on clients, the Esc menu
of an online wave (host and client), and wave cleanup: object counts across several waves on host and
client, no references to freed nodes, duplicate / queued battle starts, plus what a late endless wave
costs per snapshot and per frame.
