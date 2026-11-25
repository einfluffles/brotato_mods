# Releasing

A release goes from a reviewed changelog to a tagged GitHub Release, and from there to the
Workshop with steamcmd on the maintainer's PC. GitHub holds no Steam credentials, and the tests
(which need `reference/`, see [Game code](game-code.md)) run only on the maintainer's PC.

## Steps

1. **CI** (`.github/workflows/build.yml`) runs on every push and pull request: the tests of the
   changelog tool and of the zip guard, shellcheck, `tools/lint.sh`, `tools/package.sh` and the
   zip guard on what it packaged (see Notes). The packaged `dist/` is the run's artifact `dist`.
2. **Release PR**: run the workflow *Release PR* (Actions tab) for the mod. It turns the mod's
   `## Unreleased` in `CHANGELOG.md` into `## <YYYY-MM-DD HH:MM> UTC` under a new empty
   *Unreleased* (`tools/changelog.py cut`, which fails when *Unreleased* is empty) and opens a PR
   from `bot/release-<mod>-<YYYYMMDD-HHMM>`. A PR opened by Actions starts no CI run of its own;
   it changes the changelog only. Review and merge it.
3. **Local check** on the merge commit: `git switch main && git pull`, then
   `tools/local-check.sh mods/<mod>`. It refuses a dirty tree and a HEAD that is not pushed, runs
   gdlint and `tools/check.sh`, and on success sets the commit status `local-check` on that
   commit. From Git Bash on Windows, without podman or docker there, lint and tests run in WSL.
   `-n` runs everything but setting the status.
4. **Tag** the merge commit `<mod>/<YYYY-MM-DD-HHMM>` with the time of the changelog heading and
   push it: `git tag brotato-together/2026-11-21-1305 && git push origin brotato-together/2026-11-21-1305`
   (the release PR's description has the exact commands). The workflow *Release*
   (`.github/workflows/release.yml`) checks that the commit is on `main`, has `local-check` =
   success for that mod, and that the changelog's newest section is the tag's time with
   *Unreleased* empty. It packages the mod and creates the GitHub Release with `<Name>.zip`,
   `<Name>.zip.sha256`, `changenote.txt` (the section as Steam BBCode) and `<Name>-preview.png`
   (the Workshop preview `tools/package.sh` renders from `preview.svg`, when the mod has one). A
   failed check can be fixed and the workflow re-run.
5. **Try it**: `tools/release.sh <mod> <tag> local` downloads the release, checks the hash and
   puts exactly that zip into this PC's copy of the subscribed item, as `tools/deploy.sh` does
   (`BROTATO_WORKSHOP_DIR`, see below). Start the game and check the mod. Nobody else gets it yet.
6. **Workshop**: close the game, then `tools/release.sh <mod> <tag> live` downloads and checks the
   release again, shows what it will upload and asks, then runs
   `steamcmd +login "$STEAM_USER" +workshop_build_item <vdf> +quit` for the item of
   `mods/<mod>/workshop.json`. The upload's content is a folder that holds only the zip (the Mod
   Loader loads every `.zip` in an item's folder), and the change note is `changenote.txt`. Title,
   description, preview and visibility stay as on the item's page. `-y` skips the question,
   `--dry-run` does everything but steamcmd, `--from-dir DIR` takes the three files from DIR.
7. **Rollback**: `tools/release.sh <mod> <previous tag> live` uploads the previous release again.

## One-time setup

- steamcmd: install it ([Valve's page](https://developer.valvesoftware.com/wiki/SteamCMD); on
  Windows release.sh finds it in `%LOCALAPPDATA%\steamcmd\steamcmd.exe` without further setup),
  log in once by hand with a Steam account that owns the Workshop items or is a contributor on
  them (`steamcmd +login <account> +quit`, with Steam Guard) so the login is cached, and set
  `STEAM_USER` to that account. `STEAMCMD` is the path of steamcmd when it is somewhere else.
  release.sh never takes a password.
- `BROTATO_WORKSHOP_DIR` for `local` (and `tools/deploy.sh`): the Workshop content folder of app
  1942280, e.g. `/f/SteamLibrary/steamapps/workshop/content/1942280` in Git Bash. Subscribe to the
  mod's item so its folder exists.
- GitHub `gh` logged in on the maintainer's PC (local-check.sh and release.sh use it).
- Repository settings, set by an admin: *Actions, General: Allow GitHub Actions to create and
  approve pull requests* (for the release PR); a tag ruleset that lets only maintainers create,
  update or delete `brotato-*/*` tags; *Actions, General: Require approval for all outside
  collaborators* for workflows from forks.

## Notes

- **Zip guard** (`tools/zip_guard.py`). `zips dist` reads every packaged zip and
  fails on any entry but the folder `mods-unpacked/` and one `mods-unpacked/<mod_id>/` of a mod
  of this repo (with its `manifest.json`), and in any file of a zip on: a network class name
  (sockets: `NetworkedMultiplayerENet`, `PacketPeerUDP`, `StreamPeerTCP`, `TCP_Server`,
  `UDPServer`, `WebSocket...`; HTTP and TLS: `HTTPRequest`, `HTTPClient`, `StreamPeerSSL`,
  `PacketPeerDTLS`, `DTLSServer`; `WebRTC...`, `UPNP`, `UPNPDevice`), a native or binary file
  (`.dll`, `.so`, `.dylib`, `.gdnlib`, `.gdns`, `.pck`, `.gdc`, `.exe`), and a mention of the
  local-play dev mod (`einfluffles-TogetherLocal`, `BT_LOCAL_...`). `tools/lint.sh` runs the same
  file checks over `mods/*/src` (`zip_guard.py src`). The mods talk through Steam only; tools
  that need sockets (such as a local-play dev mod) live outside `src/` and must never reach a
  Workshop zip. Its tests: `python3 tools/test_zip_guard.py`.
  Locally: `tools/package.sh && python3 -I tools/zip_guard.py zips dist`.
- **Contributors can upload.** A Workshop item's contributor uploads with steamcmd like its owner
  (first done 2026-11-21 for both items). The update shows the contributor's name.
- **The Steam app disconnects during an upload.** steamcmd logs in with the same account, and Steam
  keeps one client session per account: the app on the same PC loses its connection until
  steamcmd quits and reconnects by itself. A running game or voice chat drops with it.
- **Without the repository setting above**, the *Release PR* workflow pushes its branch but cannot
  open the PR ("GitHub Actions is not permitted to create or approve pull requests"). Open it by
  hand from `bot/release-<mod>-<YYYYMMDD-HHMM>`.
- **Change notes** are plain "- " lines with inline BBCode (`[b]`, `[i]`, `[url]`). Steam draws a
  `[list]` outside the note's box. steamcmd reads VDF values without escapes, so release.sh turns
  double quotes into single quotes.

## Trying a build in the game

The Steam build of Brotato only loads **subscribed Workshop items** (`<game>/mods` is ignored). To
try a local build in the real game, run `tools/package.sh`, subscribe to the mod's Workshop item
and overwrite its local copy with `tools/deploy.sh <name> <item id>` (a released build:
`tools/release.sh <mod> <tag> local`). Steam may put the uploaded version back when it updates or
verifies the item, so run the script again after that.
