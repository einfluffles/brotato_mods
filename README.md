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
| `tools\check-window.ps1 [-Mod mods\<folder>] [-Suites <suite>[,...]]` | Windows: runs a mod's tests in a real game window, with graphics and audio (see [With real graphics](#with-real-graphics)). |
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

#### With real graphics

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
- The full log of the last run is `%LOCALAPPDATA%\brotato-modtools\check-window.log`. Like
  `tools/check.sh`, a run fails on script errors in mod code and on game-script errors while the
  tests run.
- The test copy's logs are deleted before each run: the game reads the last one at boot and, when
  an error in it names `mods-unpacked`, turns all mods off ("Recovering from unexpected error in
  mod ...").
- Frames are much shorter than headless. A test that waits a few frames for something that takes
  real time (the game's buttons ignore a second press within 0.05 s) can pass headless and fail
  here.
- Times are this machine's. Compare them with each other (one scene against another, a frame
  against the next), not with what a player's log shows.

Example: brotato:together's `wave_start` suite showed this way that instancing an enemy waits for the
GPU once per frame (its burning particles), which the headless run could not show.

### Publishing

`tools/package.sh` produces one folder per mod. Upload it with the game's own `GodotWorkshopUtility.x86_64`
(in the Brotato install folder): select the zip, the preview image (first upload), tags, and the Workshop id
when updating.

As the change note, paste the mod's `CHANGELOG.md` section *Unreleased*, then rename that section
to the upload's date and time and start a new empty *Unreleased* above it.

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
