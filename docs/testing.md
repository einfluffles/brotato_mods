# Testing

How the mods' tests run: headless in the toolchain container (`tools/check.sh`), and in a real game
window on Windows (`tools\check-window.ps1`). Both need the decompiled game in `reference/`
([Game code](game-code.md)).

## Headless

`tools/check.sh [mods/<folder> ...]` boots the game headless with each mod and its test mod. It
fails when the test mod does not print `MOD-TESTS: PASS`, on any script error in mod code, and on a
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
- The scripts use podman, or docker when podman is missing (`CONTAINER=...` picks one).

## With real graphics

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
- The full log of the last run is `%LOCALAPPDATA%\brotato-modtools\check-window.log`, its errors
  (Godot prints them to stderr) `check-window.err.log` next to it. A run fails on every script
  error except the missing Steam's, and on every engine error not listed in `$KnownErrors` at the
  top of the script (Steam, the deleted logs, the engine's reports at exit). That is stricter than
  `tools/check.sh`: an error at boot that names no mod (issue #91) fails it too.
- The test copy's logs are deleted before each run: the game reads the last one at boot and, when
  an error in it names `mods-unpacked`, turns all mods off ("Recovering from unexpected error in
  mod ...").
- Frames are much shorter than headless. A test that waits a few frames for something that takes
  real time (the game's buttons ignore a second press within 0.05 s) can pass headless and fail
  here.
- Times are this machine's. Compare them with each other (one scene against another, a frame
  against the next), not with what a player's log shows.

Example: brotato:together's `wave_start` suite showed this way that instancing an enemy waits for
the GPU once per frame (its burning particles), which the headless run could not show.
