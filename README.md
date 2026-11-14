# brotato:together

Online co-op for [Brotato](https://store.steampowered.com/app/1942280/Brotato/) over Steam P2P —
as an alternative to Steam Remote Play's video stream.

**Status:** early development. Not playable yet.

## How it works

- **Host-authoritative, built on Brotato's local co-op.** The host runs the real game in local co-op mode;
  each remote player is a *virtual gamepad* whose inputs arrive over the network. All game logic
  (stats, shop, waves) runs unchanged on the host.
- **Clients render the host's game**: battle snapshots at ~30 Hz with interpolation; each player's full state
  (character, items, weapons, stats) is pushed whenever it changes and on (re)join.
- **Transport:** Steam lobbies (friends-only, overlay invites) + Steam Networking Messages via the GodotSteam
  module that ships inside Brotato. No port forwarding.

Built on the [Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader) (6.3.0) that Brotato ships.
Mod id: `einfluffles-BrotatoTogether`.

## Development

All tooling runs in a container (podman):

```sh
podman build -t brotato-modtools -f tools/Containerfile tools   # GDRE Tools + gdtoolkit 3.x
tools/lint.sh                                                    # gdlint
tools/check.sh                                                   # boot game headless + run tests
tools/build.sh                                                   # -> dist/einfluffles-BrotatoTogether.zip
WORKSHOP_ITEM_ID=<id> tools/deploy.sh                            # copy build into the subscribed item
```

The Steam build of Brotato only loads **subscribed Workshop items** (the local `mods/` folder is ignored),
so testing uses a private Workshop item whose local copy `tools/deploy.sh` overwrites.

To read the game code, decompile your own copy into `reference/` (git-ignored — never commit game code):

```sh
mkdir -p reference
podman run --rm --userns=keep-id -e HOME=/tmp \
  -v "$HOME/.steam/steam/steamapps/common/Brotato:/game:ro" -v "$PWD/reference:/out:Z" \
  brotato-modtools gdre_tools --headless --recover=/game/Brotato.pck --output=/out
```

`docs/hooks.md` maps the game scripts and functions the mod hooks into.

`tools/check.sh` boots the decompiled game headless (Godot 3.6 in the container, no Steam) with the mod and
the dev-only test mod `tests/einfluffles-TogetherTests`. It fails on any script error in mod code or any failing
test. It needs `reference/`.

### Dev hotkeys (debug overlay)

F6 host lobby · F7 Steam invite dialog · F8 leave lobby · F9 toggle overlay
