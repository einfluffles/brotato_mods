# Brotato mods

Mods for [Brotato](https://store.steampowered.com/app/1942280/Brotato/), built on the
[Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader) (6.3.0) that the game ships.

| Mod | Id | What it does |
|---|---|---|
| [brotato:together](mods/brotato-together) | `einfluffles-BrotatoTogether` | Online co-op through Steam's networking, in place of Steam Remote Play's video stream. |
| [brotato:trade](mods/brotato-trade) | `einfluffles-BrotatoTrade` | Give, pass on or buy items and weapons for other players in co-op. |

Each mod's README says how to play it, what it does not do yet and what its tests cover.

## Layout

```
mods/<folder>/
  src/<mod_id>/        everything that ships (manifest.json, mod_main.gd, ...)
  tests/<test_mod_id>/ dev-only headless test mod (never packaged)
  dev/<dev_mod_id>/    optional dev-only mods the tests load too, e.g. local play (never packaged)
  docs/, README.md, CHANGELOG.md, workshop.json
  preview.svg|png      optional Workshop preview (svg is rendered to a 1024x1024 png when packaging)
docs/                  shared docs: testing, releasing, game code, brotato-hooks.md (where the game
                       does what, and how to hook it)
tools/                 containerized toolchain and scripts
```

`<mod_id>` must equal `<namespace>-<name>` from its `manifest.json` (checked when packaging).
Scripts reference their own files as `res://mods-unpacked/<mod_id>/...`.

## Toolchain

The tools run in a container that holds GDRE Tools, Godot 3.6 headless and gdtoolkit 3.x. Build it
once (the scripts use podman, or docker when podman is missing; `CONTAINER=...` picks one):

```sh
podman build -t brotato-modtools -f tools/Containerfile tools   # or: docker build ...
```

| Command | What it does |
|---|---|
| `tools/lint.sh` | Runs gdlint over `mods/`. |
| `tools/check.sh [mods/<folder> ...]` | Boots the game headless with each mod and its test mod ([Testing](docs/testing.md)). |
| `tools\check-window.ps1 [-Mod mods\<folder>] [-Suites <suite>[,...]]` | Windows: runs a mod's tests in a real game window, with graphics and audio ([Testing](docs/testing.md#with-real-graphics)). |
| `tools\play-local.ps1 [-Clients 1..3]` | Windows: brotato:together as a host and clients in game windows on this PC, connected without Steam ([Play locally](docs/testing.md#play-locally)). |
| `tools/package.sh [target]` | Writes `<target>/<name>/<name>.zip` and `preview.png` for every mod (default target: `dist/`). |
| `tools/deploy.sh <name> <workshop_item_id>` | Replaces the subscribed Workshop item's zip with the package ([Releasing](docs/releasing.md#trying-a-build-in-the-game)). |
| `tools/local-check.sh [mods/<folder> ...]` | Lint and tests on a clean, pushed HEAD, then marks the commit on GitHub ([Releasing](docs/releasing.md)). |
| `tools/release.sh <mod> <tag> local\|live` | Installs a GitHub Release locally to try it, or uploads it to the mod's Workshop item with steamcmd ([Releasing](docs/releasing.md)). |

The tests and reading the game need your own decompiled copy of the game in `reference/`
([Game code](docs/game-code.md)).

## License

[MIT](LICENSE), covering everything in this repository. Packaged mods carry a copy of the license.

Brotato and its code and assets belong to Blobfish. These mods contain none of the game's code or
assets: they hook into the game at runtime through Godot Mod Loader. This project is not affiliated
with or endorsed by Blobfish. `reference/` (your own decompiled copy of the game) must never be
committed or distributed.

The Workshop preview images are original artwork. Their lettering uses the font Tomson Talks (SIL
Open Font License 1.1); the font itself is not distributed.
