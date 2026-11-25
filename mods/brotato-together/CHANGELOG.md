# brotato:together changelog

What each update of the [Workshop item](https://steamcommunity.com/sharedfiles/filedetails/?id=3839693385)
changed, newest first. Headings from the release pipeline on are the time of the release PR in
UTC ("UTC" after the time, [Releasing](../../docs/releasing.md)); older ones are the Workshop's
upload times in US Pacific time (UTC-8).

Entries up to 2026-11-18 were reconstructed on 2026-11-19 from the merges into `main` before each
upload; three of them are marked where the upload may have differed.

## Unreleased

- Online co-op: the host refuses a join when the players run different mods, or other versions of
  them, also mods that only change the interface. The joining player's *Online co-op* page names
  the mods that differ on both sides. Before, such a player could join and the run broke.
- Needs everybody on this update (protocol 34).

## 2026-11-25 20:42 UTC

- Languages: the mod's texts now follow the game's language, in all 13 of the game's languages.
  Corrections from players are welcome (see the README's Languages section).
- Online co-op: when the host continues a saved co-op run, clients now see the resume screen (the
  saved character, gear and gold) instead of the waiting screen. A player who leaves that screen
  no longer skips a saved character or opens the shop early.
- Online co-op: a client's level-up could stay empty when the run held an invalid number (for
  example a stat divided by 0). The client now keeps showing its panels.
- Online co-op: the builder's turret looked about twice as big on clients and always had its first
  level's look.
- Online co-op: closing the game as a client during a wave could turn the mod off at the next
  start.
- Online co-op: with Steam not running or not logged on, online co-op is now turned off with a
  hint instead of waiting for a lobby that never comes.
- A few English texts read differently, for example "Player 2" instead of "P2" in the retry
  prompt.
- Needs everybody on this update (protocol 33).

## 2026-11-23 19:30 UTC

- Online co-op: the host joins first in character selection. A remote player's hold to join counts
  only once a player of the host's machine has joined. Before, a client who held first took slot 1.
- Character and weapon selection: once you have picked, your cursor stays on your pick until you
  cancel or the game goes on. Before, it could wander off while you were ready, and accept on
  another character changed your pick. A player who leaves character selection takes the pick
  along, so whoever gets the slot next starts free.
- Online co-op: at the end of a wave a client's own character stays where it stands. Before, it
  glided a step or two back to where the host had it.
- Shop, client: Esc opens your own pause menu over your shop, with the options, as in a wave.
  Nothing pauses for the others, and your panel waits while the menu is open. Before, a client's
  Esc paused everyone and the host's player operated the menu, so a client could not reach its own
  options there.
- Damage meter: the switch is now only about your own screens. A host with the meter off no longer
  takes the damage page away from the clients' panels.

## 2026-11-23 17:30 UTC

- Damage meter: the biggest hit is now the biggest number you saw above an enemy, a killing
  blow's whole damage. Before, a killing blow counted only the health that was left, so a crit
  of 300 on an enemy with 50 health left showed as 50. The total still counts only the health
  your hits took.
- Damage meter: in a crowded wave the game removes enemies to keep their number down, and a
  bullet already on its way can still hit one. That hit now counts the health the enemy had left,
  as the game's own damage count for the weapon does. Before, such a hit could make the total jump
  to the weapons' counts.
- Damage meter: the host's log has a line per wave with each player's total, rows, biggest hit
  and kills next to the health all enemies lost, to check the meter against.
- Playing Baby online: the level-up screen now shows Baby's weapon slot option on every client.
  Before, a client saw Baby's level-up panel empty, and a client playing Baby could not choose
  anything there, so the run stayed on the level-up screen until that player left.
- Captain and Barnacle online: a client's level-up panels now show the bigger values these give to
  level-up options. Before, a client showed the normal values for that player's options, although
  the bigger ones were applied.
- Player colours stay picked for as long as you are in the lobby: a new run starts with everyone's
  colour from the run before, also when you join into another slot or the host plays on another
  controller, and nobody else can take your colour while you have not joined yet. Dropping out
  mid-run and rejoining keeps your colour. Leaving the lobby before the run drops it. Once the host
  closes the lobby, a colour lasts only while its player keeps their slot: the next run starts with
  the game's colours, unless the host opens a new lobby before it.
- Player colours on the character selection no longer change because someone else joins or
  leaves: when a player who picked a colour comes back into the lobby, the others keep theirs and
  the returning player gets their colour if it is free, else a free one. A couch player who joined
  before the host keeps the colour they see when the host joins (the host gets theirs back next
  run), and a host who picked on the keyboard and changes colour on a gamepad can now go back to
  the keyboard colour.
- Magma Boots on a client: another player's trail now shows all of its fire puddles. Before, once
  the first puddles had burnt out, only one at a time flashed up for a moment.
- Acid and petrol puddles on a client no longer go invisible. Before, a puddle that came after
  earlier ones had gone could stay invisible while it still hurt or slowed your character.

## 2026-11-22 17:57 UTC

- Co-op shop and level-up panels: the weapon or item another player has selected in their gear is
  now the one you see highlighted. Before, it was sometimes the item next to it, and stayed wrong
  until that player moved again, for example when an item came into their gear (a purchase, a
  combine, a trade) while their cursor rested there, on the host's screen and on a client's alike.
- Damage meter: the end of run shows the whole run instead of the last wave: the total, share,
  damage per second and biggest hit over all waves, the ten strongest sources (a weapon's tiers
  as one row), and the kills and the damage each player took. A wave that was retried counts
  once. The shop still shows the wave before it.
- Damage meter: the total is now the health your hits took from the enemies. Before, Giant Belt,
  Greek Fire and Scared Sausage counted their bonus a second time on top of the weapon that dealt
  it, so a Giant Belt crit build showed far more than it dealt. Those items still have their row,
  marked "included", and their damage is no longer added to the shares. A killing blow counts
  only the health that was left, also for the biggest hit.
- Damage meter: a weapon combined or recycled on the level-up or crate panels keeps the damage it
  dealt in that wave on the shop's board, and the board after a retry no longer shows zeros. The
  meter now takes the wave's last measurement when the wave ends, before those panels.
- Damage meter: the builder's turret and the chef's consumable explosions are counted. An "Other"
  row holds what the ten rows leave out, so the shares add up to 100%.
- Damage meter: a run started or resumed later no longer shows the board of the run before.
- Damage numbers on a client: a big hit, such as an explosion in a crowd, shows all of its numbers,
  crits and kills first. Before, a client lost more than half of them, with their hit flash and
  blood. Numbers no longer go missing when the network loses a packet, a hit on an enemy right as
  it spawns shows its number, and pets (dino egg, scapegoat) no longer show a "1" when hit: the
  game shows none.
- Heal numbers on a client are the real heals: a hit and a heal at the same moment show both
  numbers, not their difference, and a heal no longer goes missing next to a bigger hit.
- Burn ticks on a client make the small hit effect the host shows, not a full one, and the
  brachiosaurus' damage numbers appear where the host shows them.
- Needs everybody on this update (protocol 32).

## 2026-11-22 11:57 UTC

- Archaeologist dig sites on a client are where the host has them, and you see them dug: the
  dirt fills as the host's progress, with the particles, the squash when someone steps in and the
  digging sound. Before, a client had its own dig sites in other places that never moved.
- Co-op shop on a client: a menu you have open on your own item or weapon (its buttons, or the
  player list of brotato:trade) stays open when your gear changes meanwhile, for example when
  another player trades you something. Before, it closed and threw your cursor out. It only closes
  when the item it is about is gone. A purchase of yours that the host confirms late no longer
  pulls your cursor out of an open menu either.
- Co-op shop on a client: late in a run, buying, combining or recycling (by anyone) no longer
  makes the shop hitch. Only what changed in that player's gear is redrawn, not all of it.
- Co-op shop on a client: a weapon's open menu shows Combine as soon as a second copy of that
  weapon arrives (bought or traded to you), and drops it when the copy goes. Before, you had to
  close and reopen the menu.
- Co-op shop and level-up panels: everyone sees the menus the other players have open. A
  weapon's popup with Combine, Recycle and Upgrade, the meca upgrade's two options and
  brotato:trade's player lists now show on every screen, not only on the screen of the player who
  opened them.
- Online lobby menu opened over the shop or the level-up panels on a client: it keeps its
  selected button when another player moves or opens a menu. Before, accept did nothing and the
  next arrow jumped to the first button.
- The host's log no longer fills with "run state changed without a change of its fingerprint"
  warnings during the level-up panels when a player has Bot-O-Mine (its pet keeps laying mines
  there). The new mine count now reaches the clients at once instead of up to a second later.
- Less data goes to the clients in the shop and on the level-up panels late in a run: a lock or a
  changed item counter (such as Bot-O-Mine's mines) no longer resends the run's common data, about
  1 to 2.5 KB less each.
- Needs everybody on this update (protocol 31).

## 2026-11-21 21:08 UTC

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
- Level-up screen on a client: taking or recycling a crate item, choosing and rerolling no longer
  hitch late in a run. The next page shows about three times sooner after the host answers.

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
