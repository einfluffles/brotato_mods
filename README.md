# Brotato mods

Mods for [Brotato](https://store.steampowered.com/app/1942280/Brotato/), built on the
[Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader) (6.3.0) that the game ships.

| Mod | Id | |
|---|---|---|
| [brotato:together](mods/brotato-together) | `einfluffles-BrotatoTogether` | online co-op over Steam P2P |

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

Everything runs in a container (podman):

```sh
podman build -t brotato-modtools -f tools/Containerfile tools   # GDRE Tools, Godot 3.6 headless, gdtoolkit 3.x
tools/lint.sh                  # gdlint over mods/
tools/check.sh [mods/<folder>] # boot the game headless with each mod + its test mod
tools/package.sh [target]      # -> <target>/<name>/<name>.zip (+ preview.png), default: dist/
tools/deploy.sh <name> <workshop_item_id>     # replace the subscribed item's zip with the package
```

### Publishing

`tools/package.sh` produces one folder per mod. Upload it with the game's own `GodotWorkshopUtility.x86_64`
(in the Brotato install folder): select the zip, the preview image (first upload), tags, and the Workshop id
when updating.

The Steam build of Brotato only loads **subscribed Workshop items** (`<game>/mods` is ignored), so testing
uses a private Workshop item whose local copy `tools/deploy.sh` overwrites.

### Game code

`tools/check.sh` and reading the game need a decompiled copy in `reference/` (git-ignored — never commit game
code). Decompile your own copy:

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
with or endorsed by Blobfish. `reference/` (your own decompiled copy of the game) is git-ignored
and must never be committed or distributed.

The Workshop preview image is original artwork. Its lettering uses the font Tomson Talks (SIL Open
Font License 1.1); the font itself is not distributed.
