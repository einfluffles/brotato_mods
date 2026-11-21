# Game code

`tools/check.sh`, `tools\check-window.ps1` and reading the game need a decompiled copy in
`reference/`. The folder is git-ignored. Decompile your own copy with the toolchain image
([README](../README.md#toolchain)):

```sh
mkdir -p reference
podman run --rm --userns=keep-id -e HOME=/tmp \
  -v "$HOME/.steam/steam/steamapps/common/Brotato:/game:ro" -v "$PWD/reference:/out:Z" \
  brotato-modtools gdre_tools --headless --recover=/game/Brotato.pck --output=/out
```

`reference/` is the game's own code and assets: never commit, upload or distribute it, not even as a
CI artifact or cache. [brotato-hooks.md](brotato-hooks.md) maps where the game does what.
