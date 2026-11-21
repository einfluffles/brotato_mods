# brotato:together changelog

What each update of the [Workshop item](https://steamcommunity.com/sharedfiles/filedetails/?id=3839693385)
changed, newest first. Headings from the release pipeline on are the time of the release PR in
UTC ("UTC" after the time, [Releasing](../../docs/releasing.md)); older ones are the Workshop's
upload times in US Pacific time (UTC-8).

Entries up to 2026-11-18 were reconstructed on 2026-11-19 from the merges into `main` before each
upload; three of them are marked where the upload may have differed.

## Unreleased

- A cursed Molotov no longer fills the game's log with `Node not found` errors on every throw.
- No more "Node not found" errors in the host's log when an online player's gear changes on the
  level-up panel (a crate weapon combined or recycled, a crate item traded to them).
- Co-op shop, level-up and end-of-run panels: an item's details open right against the item, with
  no gap over the next item, so a client's mouse can move straight from a shop item into its
  details.
- End-of-run screen on a client: the mouse works for looking. Hover an item or a stat for its
  details, click the arrows to turn a panel's page, scroll your own panel with the wheel. Restart,
  new run and exit stay with the host. On the host, the wheel now scrolls the keyboard player's
  panel there too.
- On a client, walking along the edge of the map is as fast as on the host. Before, your character
  rushed ahead along it and was pulled back when you stopped or left it.

## 2026-11-21 13:43 UTC

- Shop, level-up and end-of-run panels show each player's key hints for the device that player
  really uses, for everyone: online players on keyboard and mouse no longer get controller buttons,
  and the hints follow a switch between pad and keyboard. The lock and ban keys on shop items now
  show the panel's own player's keys.
- Small wording changes in the lobby page and the client's status line.
- The host's log says what a client's slowest frame was spent on, to track down hitches at the
  start of later waves.
- Gold flies to you and is collected the moment you reach it on a client, also when running fast.
  Before, it waited for the host, then flew after you and vanished behind you.
- Running fast on a client with a low frame rate no longer skips fruit and crates beside your path.
- Clients prepare the wave's enemies while the battle loads, instead of stuttering when they first
  appear in later waves.
- No more `Can't call non-static function 'duplicate'` error in the game's log at startup.
- Shop and level-up panels on a client: an item's details close when the mouse moves out of them.
- On a client, other players block you right away instead of letting you walk through them and
  pulling you back.
- On a client with a screen faster than 60 Hz, your character and the camera move smoothly
  together; at the edge of the map your character no longer shakes.

## 2026-11-18 14:51

Re-upload of the previous update (unconfirmed: nothing new was merged in the two minutes between).

## 2026-11-18 14:49

- Everybody sees everybody's scrolling in the shop, level-up panels and menus.
- Your own pickups (fruit, crates) are taken the moment you reach them on a client.
- A Veteran who died stays visible on clients in the next wave.
- Tardigrade: clients see the hit protection counter and the life bar tint.
- Shop: another player's cursor stays where they put it after a recycle or combine.
- For other mods: decisions on the level-up and crate panels reach the host (used by BrotatoTrade).
- Needs everybody on this update (protocol 30).

## 2026-11-18 11:47

- Fix: the game no longer crashes in co-op when one player owns an Axolotl.
- Damage meter: more damage sources per wave, one per line, cleaner HUD row and shop board.
- Jungle holes stop a client's own character the same way as on the host.
- Shop popup on a client: the mouse can scroll it, and a click no longer buys the item below it.
- Shop: the Anvil upgrade works, and the weapon slot label updates right away.
- The host's pause shows a real pause screen on clients; presses made meanwhile are dropped.
- Clients stop predicting their own character when the wave ends.
- The join wheel fills smoothly on a client.

## 2026-11-17 12:07

- Damage meter: cleaner look, short numbers, DPS and biggest hit; in the shop and at the end of
  the run it is a page of its own (LB / RB).
- Character selection: Co-op Off / Local / Online in the run options, and Invite friends in a
  free player slot.
- Faster screens on a slow connection: each client gets only the parts of the run it lacks, and a
  newer shop or level-up state replaces one still waiting to be sent.
- Steam may send up to 1 MB/s per session (was 256 KB/s).
- Clients report their frame times and stalls into the host's log, for bug reports.
- For other mods: shop decisions reach the host (used by BrotatoTrade).

## 2026-11-16 14:07

(Unconfirmed: the damage meter and the shared progress may have come with the 2026-11-17 update instead.)

- Damage meter: each player's damage at their life bar, and a board in the shop for the player
  looking at it; can be turned off in Options > Gameplay.
- Clients earn what the run earns: challenges with their achievements and unlocks, danger levels
  and lifetime counters go into each player's own save.
- Client fixes: HUD pickups, stat texts, evolved enemies, steady shot angles, bone dice text,
  whip and flail lash.

## 2026-11-16 11:39

- Sessions go through Steam's relays only by default; launch option +bt_direct turns it off.
- Fix: a client no longer crashes on its own gear page in the level-up panels.
- Scrolling with the right stick and the mouse wheel: each player scrolls only their own panel.
- Co-op character selection: the colour hint sits at the top right and no longer makes the grid
  scroll.

## 2026-11-16 10:01

- Lobby in the main menu: host without leaving the menus, a player frame with Kick, clients stay
  in their own main menu until the run starts.
- Smoother own character on a client: a lost packet or a stall up to 600 ms no longer pulls it
  back, and it stops on the frame you let go.
- Cursor keys in your own shop and level-up panel no longer move your character; the right stick
  scrolls there.
- Short network stalls are ridden out instead of freezing the picture.
- Selection screens: each machine scrolls its own grid, "Player N" sits above the join hint,
  F / Y shows the character on clients.
- A level-up pick made while the host is paused waits for the resume.

## 2026-11-15 13:47

- Online play moved into the game's own menus: an Online toggle and Invite friends in character
  selection; the F9 panel and the status pill are gone.
- Clients see the game's own selection screens and end of run.
- Shop locks show on the right slot after a buy, and your own lock shows at once.
- Ping no longer includes the games' frame time, so it shows the real network delay.

## 2026-11-15 06:44

- Clients see explosions, screen shake, heal and level-up texts, and the end of the wave.
- Clients see charmed, cursed, boosted and burning enemies, and acid, petrol and fire puddles.
- Weapon breaks during a wave, the hole layout and the current speed reach clients.
- Shop, level-up panels, menus and cursors travel as one ordered stream: fewer mismatched
  screens after a hiccup.
- A remote player who paused can resume in the shop.

## 2026-11-15 04:43

- Co-op character selection (unconfirmed: may already have been in the 2026-11-14 15:45 update): join hints, picking a colour (F / Y), locked characters shown.
- Esc during an online wave opens your own menu over the running game.
- Wave sync: spawn markers, boss and elite life bars, projectiles facing their flight.
- Shop: keyboard and mouse for your own panel.
- Meca upgrade: the host rolls the two options, you pick one.

## 2026-11-14 15:45

- Your own level-up, crate and shop panels run on your machine and react at once; the host checks
  each decision.
- Crate weapon popup on a client: combine, recycle and meca upgrade.
- Level-up panel: keyboard page keys and the mouse work for your own panel.
- Steam's Join button only shows while you are in a lobby with a free slot.

## 2026-11-14 11:54

- Clients without the host's DLCs can join.

## 2026-11-14 11:20

- Fix: no startup crash next to the Damage Meter mod.

## 2026-11-14 10:59

- Clients see enemy animations, turret aim and the host's menu sounds.
- Smaller battle snapshots and smoother clients.
- F9 menu replaces the F6 to F9 hotkeys (F8 is the game's bug reporter).

## 2026-11-14 08:23

First release: online co-op for up to 4 players over Steam, built on the game's local co-op.
