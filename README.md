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
  docs/, README.md
  preview.svg|png      optional Workshop preview (svg is rendered to a 1024x1024 png when packaging)
docs/brotato-hooks.md  where the game does what, and how to hook it (shared by all mods)
tools/                 containerized toolchain and scripts
```

`<mod_id>` must equal `<namespace>-<name>` from its `manifest.json` (checked when packaging). Scripts reference
their own files as `res://mods-unpacked/<mod_id>/...`.

## Toolchain

The tools run in a container that holds GDRE Tools, Godot 3.6 headless and gdtoolkit 3.x. Build it once:

```sh
podman build -t brotato-modtools -f tools/Containerfile tools
```

| Command | What it does |
|---|---|
| `tools/lint.sh` | Runs gdlint over `mods/`. |
| `tools/check.sh [mods/<folder> ...]` | Boots the game headless with each mod and its test mod (see [Tests](#tests)). |
| `tools/package.sh [target]` | Writes `<target>/<name>/<name>.zip` and `preview.png` for every mod (default target: `dist/`). |
| `tools/deploy.sh <name> <workshop_item_id>` | Replaces the subscribed Workshop item's zip with the package (see [Publishing](#publishing)). |

`tools/check.sh` uses podman, or docker when podman is missing (`CONTAINER=...` picks one).
`tools/lint.sh` and `tools/package.sh` need podman.

### Tests

`tools/check.sh` needs the decompiled game in `reference/` (see [Game code](#game-code)). It fails
when the test mod does not print `MOD-TESTS: PASS`, on any script error in mod code, and on a
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

### Publishing

`tools/package.sh` produces one folder per mod. Upload it with the game's own `GodotWorkshopUtility.x86_64`
(in the Brotato install folder): select the zip, the preview image (first upload), tags, and the Workshop id
when updating.

The Steam build of Brotato only loads **subscribed Workshop items** (`<game>/mods` is ignored). To
try a build in the real game, subscribe to a private Workshop item and overwrite its local copy
with `tools/deploy.sh`. Steam may put the uploaded version back when it updates or verifies the
item, so run the script again after that.

### Game code

`tools/check.sh` and reading the game need a decompiled copy in `reference/`. The folder is
git-ignored. Decompile your own copy:

```sh
mkdir -p reference
podman run --rm --userns=keep-id -e HOME=/tmp \
  -v "$HOME/.steam/steam/steamapps/common/Brotato:/game:ro" -v "$PWD/reference:/out:Z" \
  brotato-modtools gdre_tools --headless --recover=/game/Brotato.pck --output=/out
```

## License

[MIT](LICENSE), covering everything in this repository. Packaged mods carry a copy of the license.

Brotato and its code and assets belong to Blobfish. These mods contain none of the game's code or
assets: they hook into the game at runtime through Godot Mod Loader. This project is not affiliated
with or endorsed by Blobfish. `reference/` (your own decompiled copy of the game) must never be
committed or distributed.

The Workshop preview images are original artwork. Their lettering uses the font Tomson Talks (SIL
Open Font License 1.1); the font itself is not distributed.
