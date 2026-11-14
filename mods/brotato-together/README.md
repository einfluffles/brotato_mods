# brotato:together

Online co-op for [Brotato](https://store.steampowered.com/app/1942280/Brotato/) over Steam P2P —
instead of Steam Remote Play's video stream.

**Status:** early development; first sessions over Steam with friends work. Expect rough edges — please report them with `modloader.log`.

Mod id: `einfluffles-BrotatoTogether` · source: [`src/einfluffles-BrotatoTogether`](src/einfluffles-BrotatoTogether)

## How it works

- **Host-authoritative, built on Brotato's local co-op.** The host runs the real game in local co-op mode;
  each remote player is a *virtual gamepad* whose inputs arrive over the network. All game logic
  (stats, shop, waves) runs unchanged on the host.
- **Battles:** clients load the real battle scene with its simulation frozen and render the host's 30 Hz
  snapshots with interpolation (~100 ms behind); your own character is predicted locally and reconciled.
- **Shop, level-ups, crates:** clients load the real screens with the host's rolled options (via the game's
  own save/resume path) and mirror every player's cursor.
- **Selection screens / end of run:** the host's selection grid (built from the host's element list,
  so local unlocks/DLC don't matter) with every player's cursor and ready state, plus per-player
  cards of what each cursor is on.
- **Wave failed:** the retry / end-run prompt appears on clients too, with who gets to choose.
- **Sounds:** clients hear the host's sounds — battle sounds with the snapshots, menu/shop sounds as
  they happen — instead of their own mirrored screens' sounds.
- **Transport:** Steam lobbies (friends-only, overlay invites) + Steam Networking Messages via the GodotSteam
  module that ships inside Brotato. No port forwarding.
- A client never writes the host's run into its own save file and never unlocks challenges from it.

Details: [`docs/implementation.md`](docs/implementation.md).

## Playing

Everyone subscribes to the Workshop item (and unsubscribes from other online/co-op mods). Then:

Press **F9** (gamepad: **hold Select/View** for half a second) to open the brotato:together menu:
*Host lobby*, *Invite friends* (Steam overlay), *Leave lobby*, plus connection details. A small
status pill at the bottom of the screen shows the role, player count and ping. F9 and Select are
the only inputs the mod uses — the game binds neither (F8 is the game's bug reporter).

In the menu: mouse, or arrows / d-pad / stick to pick a button, Enter / Space / A to press it,
Esc / B to go back or close (F9 / Select close it too). While it is open the game gets none of
your keyboard/gamepad input (a client sends neutral input to the host) and the mouse cursor
stays visible.

The host opens co-op character selection; remote players hold *accept* to join like local players.

## Tests

`tests/einfluffles-TogetherTests` is a dev-only mod run by `tools/check.sh` (never packaged): virtual input,
run-state round trip, a recorded host battle replayed on a client, shop purchase mirroring, level-up/crate
panels, cursor mirroring, character-selection cards and grid, shop UI sounds, F9 panel
keyboard/pad input, the wave-failed prompt and the battle -> shop transition on clients.
