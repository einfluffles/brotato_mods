# brotato:together — implementation notes

How the mod uses the hooks in [`docs/brotato-hooks.md`](../../../docs/brotato-hooks.md).

## Battle mirror

- Run state travels the save-file path: `ProgressData.get_run_state()` → `ProgressDataLoaderV3.serialize_run_state`
  → `JSON.print` → zstd; client: `JSON.parse` → `deserialize_run_state` → `RunData.resume_from_state`.
  The JSON step is required: the deserializers expect string keys / float numbers (~5 KB for 2 players).
- Client loads `main.tscn` itself; `SceneTree.node_added` (connected only from BATTLE_START until the scene
  is ready — no handler for every node otherwise, also in the shop) + the scene's `ready` signal freeze it right after
  `main._ready()` (before the first physics frame): `main.set_process(false)` (pause/aim),
  wave manager / entity spawner / effect behaviors / stats manager processing off, every Timer `timeout`
  connected to main disconnected (`get_incoming_connections()`), players puppetized.
- `main.tscn` spawns players from `CoopService.connected_players` → client fills one slot per host player.
- Net ids (u16, wrapping, skipping ids alive in the last snapshot): `EntitySpawner.*_respawned` signals (fired
  on every spawn incl. pool reuse) + "absent from last snapshot ⇒ new id" + the id is dropped on
  `tree_exiting` (pools take nodes out of the tree; the game's pools are LIFO, so a projectile/gold can be
  pooled and reused between two snapshots). Clients snap instead of lerping when an entity moves faster than
  6000 px/s, and respawn when an id comes back with another type. Type = node `filename`, sent once per
  battle (TYPE_DEF); the wave's unit scenes, the players' projectile scenes and gold are announced with
  BATTLE_START so clients `load()` them while the scene loads, not mid-wave.
- Snapshot wire format (`sync/snapshot.gd`, since protocol 4): hand-packed bytes, little endian. u32 battle id,
  u32 host msec, u16 wave time (1/100 s); per player u8 flags, i16 x/y (0.5 px), varint input ack,
  [zigzag varints health/max health/gold, varint level, f32 xp], u8 weapon count + "sprite moved" bitmask,
  i16 angle (+ i16 sprite x/y in 1/8 px, i16 sprite angle); u16 entity count, types as runs
  [varint type, varint length], u16 net ids, 4-bit flags, i16 x/y per entity not resting; poses as
  [varint index, u8 count, f32 values]; u8 event count + events (damage 7-8 B, sound 5-10 B, anim
  8 B + name). Parsing is strict (bounds, counts, NaN, ASCII names, no trailing bytes) → whole snapshot dropped.
  Sparse data: `FLAG_REST` entities (unmoved for 4 snapshots: gold, structures, idle units) leave out their
  position except every 15th snapshot (staggered by id); player HUD stats only for 4 snapshots after a
  change and every 10th. The client fills both from earlier snapshots (`Snapshot.resolve`, which also builds
  the id → index map used for interpolation) and skips a resting entity it never saw until its refresh.
  Events are capped at 48 per snapshot (`Snapshot.select_events`: duplicate sounds go first, then enemy
  damage numbers, sounds, player damage; animations last). Sizes incl. message envelope (synthetic waves in
  `snapshot_tests.gd`; protocol 3 → 4): small, 45 entities + 8 events 1676 → 448 B; mid, 136 entities +
  11 events 3512 → 968 B; late, 300 entities + 44 events 8300 → 2184 B (still 2 Steam fragments). The
  real 6 s wave-3 loopback: largest snapshot 768 → 192 B.
- Own-player prediction replays at most the last 30 un-acked inputs (0.5 s) and none while the host paused
  or when the newest snapshot arrived more than 250 ms ago (stall): the player stays with the frozen world.
- Client puppets of non-Entity scenes (projectiles, gold, consumables) are pooled per type like the game's
  Entity pool (out of the tree; freed when the battle state resets).
- Boss parts: clients spawn in snapshot order and the host lists `bosses` first; a `BrachiosaurusFoot` waits
  until a "Brachiosaurus" puppet exists (its `_ready` finds it by name). Extensions skip, while puppeting,
  the foot's `shoot()` and `StayEdgesOfMapMovementBehavior.move_away()` (called by the foot's `_ready` on its
  boss; needs `init()`, which puppets never run).
- Puppet = `propagate_call("set_physics_process", [false])`, body `MODE_STATIC`, no collision layers,
  all Area2D monitoring off; idle processing (AnimationPlayers) stays on. `update_animation(motion)` is called
  with the interpolated motion for walk animation; facing comes from the host afterwards.
- Per-entity flags (4 bits each, packed; the 4th is `FLAG_REST`): `sprite.scale.x < 0` (facing; behaviors turn units toward their
  target and knockback would otherwise flip puppets), `!visible` (stampede dinos hide before charging) and
  `sprite.flip_h` (`JumpAttackBehavior` turns the sprite toward its landing spot and never resets it).
- Poses (`sync/pose.gd`): parts that physics code turns, sent sparsely only for scenes that have them,
  interpolated with `lerp_angle`. Turrets don't rotate in this game (`Turret.shoot` only aims projectiles).
  Found: `GoTowardsBorderOppositeMovementBehavior` rotates the whole unit (oviraptor, iguanodon); `Pivot`
  children (predator, giant, jellyfish) spin rings of `EnemyProjectileRotating`, whose `position.x` grows
  outwards first; `CatlingGun._orient_gun` sets `rotation` + `scale.y` of `%Gun_pivot_l/r` and their draw
  order; `EnemyLaser(Follow)` never moves, so its `rotation` (aim) and the beam/aura sprites' `visible`
  (one bitmask value) are sent; `BrachiosaurusFoot`: shadow/foot/release sprite `visible` + foot `flip_h`.
  Layout = per-scene list of (node path, kind), derived from a pristine `instance()` of the scene (never from
  a live one: a puppet's `die()` frees its `Pivot` via `Pivot._on_Enemy_died`), cached per scene path.
- Pose groups: at most one per scene, appended to the base values only while active; the value count tells
  the client. `PIVOTS`: `Eel`/`Tyranosaurus`/`Brachiosaurus.on_state_changed(1)` add a `pivots_scene`
  instance (16 `Pivot`s + 16 bullets, 32 values); the host checks `entity.pivots`, the client instances the
  same scene with the same name on its puppet (puppetized, `entity.pivots` set so its `die()` frees the
  bullets). The ring bullets are children of the boss, not of `_enemy_projectiles`, so they aren't also
  tracked as projectiles. `JUMP`: while `%Land_shadow_warning` is visible, its local position + `%Shadow`
  height/scale (the body flies, the shadow stays on the ground). `WARNING_LINE`: while
  `WarningChargingAttackBehavior._warning_line` is visible, its angle (client parents the behavior's own
  `Line2D`, which `init()` would have done, and rebuilds the points like `show_warning`).
- No values for a scene with base parts = the host's are gone (pooled entity without its `Pivot`): the client
  hides its pivots; with values it re-creates missing `Pivot` children from a pristine instance (reused
  puppets) and shows them. Stampede dinos: the client shakes its grass (`main._shake_zone_sprites`) when one
  spawns, like `get_movement` does on the host (no bytes).
- Animations (`sync/anim_mirror.gd`): physics code / behaviors start most non-idle animations (turret
  "shoot", enemy "shoot" wind-ups and charges, jump attacks, brachiosaurus foot stomps, pet states like
  the catling gun's "enter_in_mad_mode"/"idle_attack"). Host: `EVENT_ANIM` [net id, name, position, speed]
  when an entity's `_animation_player.current_animation` changes or a non-looping one restarts; nothing
  for entities in their `autoplay` animation; re-sent ~1/s while away from it (snapshots are unreliable).
  Client: replayed at render time under the same name (the game's `update_animation` guards check names),
  whitelisted by the puppet's own `has_animation`; "death*"/"RESET" never. Animations with method tracks
  (`shoot()`/`start_shoot()` spawn projectiles) are swapped on the puppet for a cached copy with those
  tracks removed (`Animation.duplicate` + `remove_track`; the shared original stays intact). Every entity
  puppet loses the game's own `animation_finished` handlers at spawn (turret cooldown needs stats; attack
  behaviors have no `_parent` on puppets — a dying puppet spitter errored).
  Projectile puppets play their autoplay animation without method tracks too (`AnimMirror.strip_projectile`):
  the enemy pillar's (abyss enemies, colossus) "shoot" ends in `stop()`, which pooled it by a `pool_id` meta
  clients don't have (script errors).
- Not mirrored yet: `GoTowardsBorderOppositeMovementBehavior.show_warning_arrow/line` (unused by the
  game), brachiosaurus foot shadow scale/position animations, jump-attack shadow `position.x` (reset on
  respawn only), effects done inside stripped method tracks / disconnected `animation_finished` handlers.
- Client saves/challenges are blocked while puppeting (`ProgressData` / `ChallengeService` extensions).
  Puppet mode on stashes what `ProgressData.save()` persists from the run side (`saved_run_state`,
  `last_saved_run_state`, `data`, `killed_enemies`, `killed_by_enemies`, `items_bought`); off restores it
  (`session/puppet.gd`) — the shop resume path overwrites `saved_run_state` with the host's run. Unlocks /
  difficulties only change in host-only paths (run won, `complete_challenge`); `active_update_data` is reset
  by the title screen's `RunData.reset()`.

## Session lifecycle

- Handshake (`session/session.gd`): the client resends HELLO every second until WELCOME (the host's
  session-request check / member list can lag behind the join, and a message from a not-yet-member is
  dropped). The host answers every HELLO; a repeated HELLO from a ready peer means it missed WELCOME and what
  followed, so it gets a full resync. The transport accepts a member's message session when it enters the
  lobby and refreshes the member list for unknown senders.
- Full resync = `peer_ready` re-emitted (every sync module resends its whole state on it), at most once per
  second per peer. Queued when a reliable send fails (`sendMessageToUser`'s EResult != 1, logged as a
  warning); unreliable failures are only logged at debug level.
- Join compatibility (`session/compat.gd`, HELLO): protocol, game version (`ProgressData.VERSION`), mod
  version (manifest) must match. Rejections carry a reason that the client shows in the F9 menu. DLC never
  rejects (protocol 5 / 0.2.1).
- Host DLC on clients (`session/dlc_borrow.gd`), like Steam Remote Play Together: all DLC content ships in
  the base `Brotato.pck`; ownership only decides registration (`ProgressData.available_dlc_ids`, from which
  `ItemService.items/characters/weapons` are rebuilt, and `DLCData.add_resources()`: backgrounds, title
  backgrounds, enemy data, effect scripts). Found without the host's DLC: `deserialize_run_state` /
  `PlayerRunData.deserialize` drop DLC characters, items, weapons, shop/locked items (`get_element_safe` ->
  null), item/player effects with DLC effect scripts, and the DLC background (falls back to the first);
  selection grids / item cards ("?"), level-up/crate panels and the shop can't find DLC ids. Not
  ownership-related: zones (`ZoneService.zones` lists all), enemy/boss scenes (loaded by path),
  `get_dlc_data_by_id`, the run's `enabled_dlcs` / `active_update_data_ids` (from the host's run state).
  DLC drops (poisoned / meca / mutant / mutation fruit, meca parts) were never in `ItemService.consumables`,
  even for owners: `BattleClient._find_consumable` also reads them from every `DLCData`.
- WELCOME carries the host's own DLCs; on the first accepted WELCOME (before `peer_ready`) the client
  borrows the ones it lacks (only ids in `ProgressData.dlc_ids`): stashes `available_dlc_ids`,
  `active_update_data`, the unlock lists `save()` writes, `ItemService._tiers_data` and its id lookups;
  appends the ids, `add_resources()` in `update_data_list` order, invalidates the item lists. Revert
  (`remove_resources()` in reverse, stash restored in place, borrowed music tracks dropped from
  `MusicManager.shuffled_tracks`) runs on `lobby_left` (every way out of client mode: Leave, host left /
  timed out, rejection, joining another lobby, F9 *Host lobby*, which leaves first) and `lobby_ready`, before
  the title screen loads; `Session._process` reverts if borrowed DLC exists without a welcomed client
  role. While borrowed, saves and challenges are blocked like puppet mode (`Puppet.blocks_progress()`);
  HELLO / WELCOME report only owned DLC. The F9 details show "Using the host's DLC for this session: …".
  Challenges of a borrowed DLC aren't loaded (the client never completes challenges; the end-of-run view
  is the host's).
- Leaving is role-aware (`transport.was_host`). Client: puppet mode off (own run restored), puppet slots
  cleared, title screen. Host mid-run: the run goes on and remote players' co-op slots stay, idle (as with a
  local pad unplugged mid-run); their steam id -> device mapping is kept, so they get their own characters
  back when they join the host's next lobby. Shop / level-ups wait for them (game rule). Before the run
  (players can still join) their slots are freed.
- F9 *Leave lobby* mid-run needs a second click; a Steam invite accepted mid-run waits for *Join invite*
  (outside a run it is taken right away, closing the menu declines it).

## Menus

- **Shop** (`sync/shop_sync.gd`): run state via `ProgressData.get_run_state(shop_items, reroll_count,
  paid_reroll_count, initial_free_rerolls, free_rerolls, item_steals)` (the shop's own save args) + per-slot
  `active` layout + `_player_pressed_go_button`. Client enters through the resume path
  (`ProgressData.saved_run_state`, `RunData.resumed_from_state_in_shop = true`, `shop_effects_checked = true`)
  so `BaseShop._ready` rolls nothing; updates re-run the per-player part of `BaseShop._ready`
  (`set_weapons_data/items_data`, `_update_stats`, gold label, reroll price via `ItemService.get_reroll_price`,
  `ShopItem.set_shop_item/activate/deactivate`, `_update_visual_locks`, checkmarks). Client disconnects
  `BaseShop._on_tree_exited` (rolls curses on locked items). The host checks every 0.1 s by comparing the
  run state's JSON text (+ slots, Go flags, revisions, pages); zstd only runs when something changed.
  Since protocol 8 the state also carries per player a panel revision (`seqs`) and the carousel page
  (`pages`), and for each client its own player index (`you`, so the message is sent per peer). The client
  rebuilds per player and per part: `ShopSync.player_keys` cuts the sent run state (before it is
  deserialized) into the player's whole data, its gear (weapons / items) and its offered items, as text.
  A player whose data did not change keeps its `PlayerRunData` object across `resume_from_state` (the
  panel's gear elements and popup hold those objects), gear elements are only replaced when the gear
  changed (the cursor is taken off them first and put back on the element at the same index: a
  `FocusEmulator` must never keep a control that is about to be freed), shop item nodes only when the
  player's data, offered items or slot layout changed. The same run bytes again (only a Go flag, a page
  or a revision differs) skip `resume_from_state` altogether.
- **Own shop panel runs on the client** (protocol 8; second screen of the "local view, decisions to the
  host" model). Files: `sync/shop_local.gd` (client), `sync/shop_intents.gd` (host),
  `extensions/ui/shop_item.gd`.
  - Client, own slot: as for the level-up panels, `InputSync.set_local_device` feeds the local buttons
    into the own slot's device and `FocusSync.local_emulators` keeps the host's cursor off the own
    emulator. The shop scene processes input by itself, so cursor, carousel pages, item popup, inventory
    browsing, the hold-to-ban bar (`ShopItem._on_BanButton_button_down`), the hold-to-recycle bar and a
    meca item's effect choice (`effect_choice_selected`) run locally.
  - Guard, every client and every player's panel (`ShopLocal.guard`). The cuts sit where the mutation is,
    which is below `BaseShop` in places:

    | Action | Cut on the client | Host applies |
    |---|---|---|
    | buy | `ShopItem.buy_button_pressed` loses `ShopItemsContainer.on_shop_item_buy_button_pressed` (gold check, `deactivate`, buy delay, `shop_item_bought`) | sets `effect_choice_selected` for a meca item, then presses the item's buy button (`FocusEmulatorSignal.emit(button, "pressed", p)`, what a FocusEmulator does) |
    | steal | `steal_button_pressed` loses the container's handler; `BaseShop._input` calls `ShopItem.steal_item()`, which ends in that signal | `ShopItem.steal_item()` when `_item_steals[p] > 0` |
    | lock / unlock | `ShopItem.change_lock_status` writes `RunData` and is called directly by `BaseShop._input`: a script extension emits `lock_requested` instead while puppeting | `change_lock_status(wanted)` when the item `is_lockable` and is not already in that state |
    | ban | `ban_item_pressed` loses the container's handler (`ShopItem.ban_item` spends the token); the hold loop, `_release_BanButton` and the ban animation stay local and end in that signal | emits the item's `ban_item_pressed` when its ban button is enabled (the container checks the token) |
    | dismantle | `dismantle_button_pressed` loses the container's handler; `BaseShop._on_ban_shortcut_released` ends in it | `ShopItem._on_DismantleButton_pressed()` when `BaseShop._can_dismantle_with_shortcut` |
    | reroll | reroll button `pressed` loses `BaseShop._on_RerollButton_pressed` | presses the reroll button |
    | Go | Go button `pressed` loses `BaseShop._on_GoButton_pressed` (starts the next wave when all are ready) | presses the Go button, or `_clear_go_button_pressed` |
    | combine / recycle | item popup `item_combine_button_pressed` / `item_discard_button_pressed` lose `BaseShop`'s handlers | emits the popup's signal with the host's weapon object |
    | meca upgrade (popup) | `item_meca_upgrade_selected` loses `BaseShop`'s handler and the upgrade button is taken out (`_upgrade_button = null`, which the popup treats as "no meca upgrade") | not sent: `DLC2Data.meca_item` rolls the two options when the button is pressed, so the client's options would not be the host's |
    | endless (player 1, wave 20) | `EndlessButton.toggled` loses the panel's handler | sets `pressed` on the host's button (its `toggled` sets `RunData.is_endless_run`); mirrored back with `set_pressed_no_signal` |

    The own panel's signals go to `SHOP_INTENT`; on the other panels nothing listens, so a mouse click
    there is dead. A control this list does not know (another mod's button, e.g. Damage Meter's summary
    button next to reroll) keeps its own handler and can show things, but every way into the run is cut.
    The view half of a cut handler is called where the panel needs it: `give_focus_to_mecha_choice` before
    a meca buy without a choice, `BaseShop._on_item_cancel_button_pressed` (close the popup, cursor back on
    the weapon) after combine / recycle.
  - `SHOP_INTENT` = `shop_id, seq, kind, slot, id, arg`. `slot` + `id` name the target by place and by
    identity (shop item node index + `my_id`, or index in the weapons list + `my_id`); the host takes the
    node at the slot when it holds that id, else any node that does, else drops the intent. `seq` is the
    sender's panel revision: the host bumps it when the panel offers something new (offered item
    instances per node, reroll count, weapon instances; locks and gold are not part of it) and at once
    when it applies a press, because buy and steal run deferred in the game. "go", "endless" and "lock"
    carry the wanted state and are applied at most once; "go" and "endless" ignore the revision. Nothing
    is applied while the host's tree is paused. After an applied intent the state goes out in the next
    frame (once the deferred handlers ran), not at the next 0.1 s check. `ShopItemsContainer` ignores
    presses for 0.05 s after a buy, steal or dismantle, for an intent as for a local press.
    `_settle_host_cursor` runs deferred after every applied intent: the game's combine handler moves the
    cursor with deferred `grab_focus` calls, one of them onto an element it already queued for deletion
    (it relies on a later call that a visible mouse skips), and a `FocusEmulator` that keeps a freed
    control errors on its next move.
  - Go: the client keeps no flag of its own. Its press sends "go"; the checkmark appears when the host's
    state has it. The game clears the flag itself when the cursor leaves the button, on cancel and on the
    triggers (`_on_GoButton_focus_exited`, `BaseShop._input`): `ShopLocal.process` sends "go 0" when the
    local flag is gone while the host still has it, and clears a ready flag that arrives while the cursor
    is not on Go (the press reached the host after the cursor had left; also an absent player's automatic
    Go when that player comes back).
  - Host: `InputSync.blocked_by["shop"]` keeps every remote button but pause off the virtual devices while
    the shop runs and the tree is not paused (`blocked_by` is OR-ed with `blocked_buttons`, which
    `UpgradesSync` resets every frame outside a battle). `SHOP_FOCUS` (`shop_id, page, path` inside the
    sender's `CoopShopPlayerContainer`) puts the remote cursor and page on the host's copy, from where
    `FocusSync` and `pages` carry them to the other clients. Cosmetic: a path that does not resolve (a mod
    added a control on one side only) or is not visible is ignored. Absent players and the pause hand-over
    work as before; while the host is paused (`SHOP_PAUSE`) the client's local buttons are off.
  - Differences from local co-op: with a steal left, the select shortcut steals and locks in one press;
    the host applies the steal, which makes the lock stale (the game itself would lock the stolen item).
    A second press made before the host's answer arrived (two quick buys) is dropped as stale.
  - Open: the inventory popup's meca upgrade (needs the host's rolled options on the client); the host and
    the other clients do not see the own panel's focused inventory popup (cursor on its buttons is not
    visible on the host's copy); the client's hold-to-ban depends on its own `chal_banned_items` unlock
    and the ban animation / press sounds of the own panel are not heard (the puppet shop is muted; the
    host's sounds for the applied decision are); no feedback on the client for a refused buy (the host's
    gold label shakes); a keyboard client is still typed as a gamepad; dismantle and the meca effect choice
    are only tested against stand-ins (no meca weapons without the DLC in the headless suite); none of
    this has run between two real machines yet.
- **Level-up / crate panels** (`sync/upgrades_sync.gd`): per player container state from `_old_upgrades`,
  `_level`, `_reroll_price`, `_item_data`, `_checkmark_group`; client re-implements
  `show_upgrades_for_level` without `ItemService.get_upgrades` and uses `show_item` for crates (item rebuilt
  from `ItemService` base + `deserialize_and_merge`).
- **Own level-up / crate panel runs on the client** (protocol 6; first screen of the "local view, decisions
  to the host" model, the shop followed with protocol 8). Each `CoopUpgradesUIPlayerContainer` is a
  `Carousel` with three pages (upgrades / gear / stats, switched with the triggers) and a per-player item
  popup toggle (`CoopItemPopup._input`, `ui_info`): view state that only existed on the host, so a remote
  player who flipped the page lost its cursor on its own screen. Now:
  - Client, own slot: `InputSync.set_local_device` feeds the local buttons into the own slot's device
    through a `RemoteButtons` (the host's code path: counted edges, echo; pause excluded), and
    `Utils.set_process_input_where_defined(ui, true)` turns the panel's `_input` on
    (`main._on_EndWaveTimer_timeout` does that on the host and never runs on a puppet). The own
    `FocusEmulator`, carousel, popup and description scroll then work as in local co-op, with no round trip.
    `FocusSync.local_emulators` keeps the host's cursor off that emulator.
  - Guard, every client and every container: the four decision signals lose `UpgradesUI`'s handlers
    (`choose_button_pressed`, `item_take/discard/ban_button_pressed`), the reroll button loses
    `_on_RerollButton_pressed` (removes gold, rolls), the crate weapon popup loses combine / discard / meca
    upgrade (`UpgradesUI._on_weapon_*`, which call `RunData` directly). The own container's signals, and
    its popup's, go to `UPGRADE_INTENT` instead. The container-local part still runs (press delay,
    meca choice, the hold-to-ban loop with its progress bar). Mouse clicks on the own panel end in the
    same signals (see keyboard and mouse below).
  - Crate weapon popup (protocol 7; characters whose crates give weapons, `effect_crate_give_weapon`):
    `UpgradesUI._setup_weapons_inventory` runs in the puppet's `_ready` too (the run state is applied
    before the scene loads), but only the host's `_show_next_player_options` fills the list, so the client
    calls `_refresh_weapons_inventory` for every panel it rebuilds and whenever the run state changed (new
    weapon objects). A cursor in the list keeps its slot. The own popup's combine / recycle / meca upgrade
    leave as `UPGRADE_INTENT` kinds `weapon_combine` / `weapon_discard` / `weapon_meca` with `weapon` (slot
    in `RunData.get_player_weapons`) and `id` (its `my_id`); the popup then closes like after a cancel
    (`_on_weapon_cancel_button_pressed`) and the weapons change when the host answers. The host checks
    revision, `_weapons_inventory_enabled`, slot and id, calls the game's handler
    (`UpgradesUI._on_weapon_combine_button_pressed` / `_on_weapon_discard_button_pressed`) and counts the
    intent as applied only if the weapons changed (the game refuses locked weapons or a missing partner
    itself). The player's weapons are part of the panel revision, so a second press is stale. Meca
    upgrade: the popup rolls its two stat options where it runs (`DLC2Data.meca_item`), so the client sends the stat it picked (`stat`, key hash; read from the popup
    on `meca_upgrade_choice_toggled`, picked by the effect button pressed). The host takes it only if it is
    in `_get_allowed_meca_stats` for that player and the parts suffice, sets it on a freshly rolled
    `meca_item` option with `get_meca_stat_value` and hands the result to
    `_on_weapon_meca_upgrade_selected`. So a modified client could pick any stat the game allows that
    player, not only the two it was shown; amount and cost are the host's.
  - Host: `UPGRADES_STATE` carries a revision per player (`seqs`: bumped when the panel shows something
    new, keyed on the entry, the option being processed, the item instance and the reroll count, so the same
    crate item twice still counts) and the carousel page (`pages`). `host_apply_intent` drops an intent whose
    revision or option id doesn't match the sender's panel, then calls the container's own handler
    (`_on_choose_button_pressed`, `_on_RerollButton_pressed`, `_on_TakeButton_pressed` after setting
    `_meca_effect_choice_selected`, `_on_DiscardButton_pressed`, `_on_BanButton_pressed`). While the panels
    are visible (and the game isn't paused: the pause menu is the host's) `InputSync.blocked_buttons` keeps
    every remote button but pause off the virtual devices, so a remote accept can't also press the host's
    copy.
  - Presence: the client reports its page and cursor (`UPGRADE_FOCUS`, child-index path inside its own
    container, on change); the host applies them to its copy, from where `FocusSync` and `pages` carry them
    to the other clients. Cosmetic: decisions never depend on it.
  - The client rebuilds a panel only when its revision or entry changed, and re-applies the run state only
    when its bytes changed (a rebuild of the own panel would fight the local cursor).
  - Keyboard and mouse (`sync/local_panel.gd`, a node `UpgradesSync` adds as the puppet `UpgradesUI`'s
    last child; written against "the own panel + its emulator", so another client-run screen can use
    it). Why a node there: a `FocusEmulator` with a cursor marks every event that is not a co-op action
    as handled, so on a co-op screen the mouse never reaches the GUI and `InputService` (an autoload,
    last in `_input` order) never sees which device is in use. `_input` runs in reverse tree order, so
    a node after the emulators sees every event first.
    - Device: puppet slots are typed `GAMEPAD_XBOX` (`VirtualDevices.fill_puppet_slots`). A keyboard has
      no `ltrigger` / `rtrigger` binding and `Carousel` disables its arrows for a gamepad, so a keyboard
      player could not change page. The client's own slot now takes the `PlayerType` of what its player
      used last (`VirtualDevices.set_slot_type`): from `InputService.using_gamepad` when the panel
      starts, then from the events (key, mouse button, mouse motion faster than 1000 px/s as in
      `UIService._check_input`, pad button, stick past the deadzone; the pad's brand from its name).
      The game fixes the type when a co-op player joins and has no switch for it, so
      `LocalPanel.refresh_player_type` redoes what `_ready` did: the carousel's arrows (textures from
      the scene it was instanced from, since `Carousel` overwrites them with trigger glyphs and keeps
      no copy; then its `index` setter), `InputIcon`s (also given the panel's player: the game leaves
      them on player 0) and `CoopShopHint`s. `UpgradesSync` then calls the container's
      `_set_focus_neighbours` and `focus()` if the cursor sat on an arrow that became a glyph. The slot's
      device id does not change, so `RemoteButtons` feeds it as before. Other slots stay gamepads.
    - What reads the type on a puppet: `Carousel`, the key glyphs, and aim (`Utils.is_player_using_gamepad`
      in `weapon.gd` / `main.gd`, both behind `Utils.is_manual_aim`, which our extension answers for
      virtual devices and which is never set on a client). So the type only matters on panels; the next
      `fill_puppet_slots` (battle start, shop) resets it.
    - Host: unchanged, a remote player stays a gamepad there (stick aim and `Utils.is_manual_aim` depend
      on it) and its type is not sent. The host and the other clients therefore draw a keyboard
      player's page arrows as trigger glyphs, and show its cursor on one when it is there
      (`UPGRADE_FOCUS` paths are child indices, the same in both layouts). Cosmetic only.
    - Mouse: motion over a focusable control of the own panel sets the own emulator's
      `focused_control` (once per frame; the setter emits the focus signals as that player, so popups
      follow); a left click runs the emulator's own accept on it (`_handle_input` with an
      `ui_accept_<device>` action event), so the press carries the player index. A native GUI press
      could not: `PopupManager` books a press without `FocusEmulatorSignal` on player 0, and
      `CoopUpgradesUIPlayerContainer` holds a plain `Control` (the popup's parent, mouse filter stop)
      over all of its content, so the GUI never hits a button there anyway. The hit test therefore asks
      what the emulator could focus, not what the GUI would hit: of the visible, enabled `FOCUS_ALL`
      controls under the pointer the last in tree order (drawn on top), with clipping parents cutting
      their children; a popup's non-focusable background does not cover a button behind it. Every
      mouse event over any player's panel is marked handled, also when no panel is local, so another
      player's panel never reacts. While the F9 panel is open (`InputSync.local_input_blocked`) the
      node does nothing. A popup that took the cursor (`ItemPopup._focused`, the crate weapon popup after
      a press on a weapon) keeps the mouse too: while it is open only its own buttons are hit, as its
      focus neighbours do for the keys. A mouse press stands for an accept that is held until the
      button comes up: `LocalPanel` then sends the release of `ui_accept_<device>`, which is what
      ends the popup's hold-to-recycle (`handle_recycle_hold_release`); without it one click would
      count as a full hold.
  - Open: no mouse wheel on the own panel (`ItemDescription._input` scrolls on the wheel, but it comes
    after the emulators and `LocalPanel` in `_input` order; a keyboard player has no right stick
    either, as in local co-op), a click outside an open popup does not close it (its Cancel button
    does), a mouse click on Ban counts as a full hold, like accept on that button in local co-op (only
    the ban key can be let go; `button_up` is never emitted through an emulator), the client's
    hold-to-ban depends on its own `chal_banned_items` unlock, after a combine the client's cursor
    keeps its slot where the host's copy jumps to the new weapon (until the next `UPGRADE_FOCUS`), a
    key tap shorter than a physics frame is lost while a panel is up (the emulators handle the event
    before `InputSync._input` can count it; held state is polled), and none of this has run between
    two real machines yet (headless tests only: no real mouse, keyboard or pad; the crate weapon
    popup's combine, recycle hold and cancel are driven through its real buttons by synthetic clicks,
    its meca upgrade only through its signals).
- **Cursors** (`sync/focus_sync.gd`): every `FocusEmulator` in the scene; emulator + focused control sent as
  child-index paths from the scene root (`ui/scene_paths.gd`), applied through the `focused_control` setter.
  The latest message per scene stays pending (10 s) until every cursor resolves to a visible control
  (scene still loading, retry prompt not shown yet) and is retried every frame.
- **Selection screens / end of run** (`sync/menu_sync.gd` + `ui/client_view.gd`): grids depend on local
  unlocks/DLC (`ProgressData.characters_unlocked`, `available_dlc_ids`, weapon unlock filtering) and the scenes
  run join/selection logic (`CoopService.listening_for_inputs`, `_selections_completed_timer` → `change_scene`),
  so they are not run on the client. Instead the host sends its grids (`BaseSelection._get_inventories()`,
  visible ones: columns + ordered `[my_id, random/special/locked flags]`, only when they change) and each
  cursor as `[inventory, element index]`; `ui/selection_grid.gd` draws them with ids looked up in
  `ItemService` (unknown ids → "?") and per-player colour borders (thicker when `_has_player_selected`),
  plus `ItemPanelUI` cards for the item under each cursor.
- **Co-op character selection UX** (`ui/coop_selection.gd`, `extensions/singletons/coop_service.gd`,
  protocol 9). Found in the game: `CoopJoinPanel1..4` (`coop_join_panel.gd :: update_indicators`) show
  the `COOP_HOLD_TO_JOIN` hint ("Hold {0} or {1} to join", A / Space glyphs) only in the *next* free slot
  and not at all before the first player joined (then only the big `%CoopJoinInstructions`).
  `CoopSelection._process` sets `instructions_visible` on every free, non-connecting slot while
  `CoopService.listening_for_inputs`, and adds a "Player N" label (`COOP_PLAYER`) in the slot colour.
- **Player colours**: every colour use in the game goes through `CoopService.player_colors[slot]` /
  `get_player_color` (focus emulator borders, `ItemPanelUI` / `LockedPanel` / `CharacterPanelUI`, shop /
  upgrade / end-run containers, `coop_player_label`, HUD `player_ui_elements`, `Player.update_highlight`,
  pets / turrets / poacher zone, `ui_dim_screen`). The extension keeps a palette (the game's 4 colours,
  read at startup, + 4 extra pastels), picks per remapped device, and rewrites `player_colors` on
  `connected_players_updated` and on every pick: picks first in slot order, then each slot its default
  colour if free, else the first free one (never two equal). `ui_info` (F / Y, unused on this screen;
  remote players send it as a button) cycles to the next free colour; `CoopSelection` restyles what is on
  screen (focus styles, panels, locked panels, join progress). A hint row ("[F] / [Y] Change
  colour", the game's glyphs) is added under the title. Colours travel as palette indices (`colors`) in
  MENU_STATE, BATTLE_START and SHOP_STATE; the client validates them (one distinct palette index per slot)
  and mirrors them until it leaves the lobby (`bt_clear_remote_colors`). Nothing is saved.
- **Locked characters**: the host's screen already shows the game's `LockedPanel` (challenge text via
  `ChallengeService.find_challenge_from_reward`, or the item-set requirement) instead of the panel; only
  the client cards showed the description. MENU_STATE player entries now carry the host LockedPanel text
  and "locked by a challenge"; the client card shows a `LockedPanel` with its own (localised) challenge
  text, else the host's text. Free slots appear as client cards with the same join hint and the hold
  progress (`join`), the colour hint shows once the client has a slot.
- **Wave failed** (`sync/retry_sync.gd`): `main.gd :: _on_EndWaveTimer_timeout` shows `UI/RetryWave`, which
  never runs on the puppet (timer callbacks disconnected). Host sends `RETRY_PROMPT` (visible, its
  `settings.retry_wave`, `RunData.retries`, deciding player = the prompt's `FocusEmulator` index 0 + name);
  the client shows its copy with `confirm/cancel_button_pressed = true` (local clicks do nothing) and a
  "waiting for Pn" line. FocusSync mirrors the cursor.
- **Battle → next screen**: on `BATTLE_END` the client keeps the frozen battle (muted) until the shop / next
  battle / menu state replaces it (fallback to the client view after 2 s); the view only says "Waiting for
  the host" after 1.5 s.
- **F9 panel input** (`ui/together_menu.gd`, `ui/menu_input_guard.gd`): `_input` runs in reverse tree order, so
  while open a guard node kept as the root's last child sees key/pad events first, marks them handled (scene,
  FocusEmulators, `CoopService`, GUI never see them) and `Input.action_release`s what they pressed (polling
  stays neutral); after closing it also swallows the releases of keys pressed while open (the game pauses /
  goes back on release). Mouse events pass; `InputService._input` hides the cursor on every event in co-op,
  so the panel shows it again in `_input`/`_process`. Pad: hold `JOY_SELECT` (unbound in the game's InputMap).
  Clients send neutral `INPUT` while it is open (`InputSync.local_input_blocked`). `ask_confirm()` = Yes/No
  sub-state.
- Puppet pitfalls found by tests: `Enemy.respawn()` → `update_target()` needs a spawner (use a visual revive);
  `PlayerProjectile.shoot()` needs weapon stats; enemy scenes have internal Timers (pause them).

## One-shot feedback (damage numbers, hit flashes, sounds)

- Snapshots carry an `events` list (see `sync/snapshot.gd`), queued on the client and fired when render time
  reaches the snapshot, so feedback lines up with the interpolated visuals.
- Damage: the host connects to every mirrored unit's `took_damage` (players with a bound
  `-(player_index + 1)` target); the client calls the same handlers main.gd uses —
  `FloatingTextManager._on_unit_took_damage`, `EffectsManager._on_unit_took_damage` — with a hitbox-less
  `TakeDamageArgs`, plus `Unit.flash()`.
- Sounds: extensions of `SoundManager.play/playSingle` and `SoundManager2D.play` route through
  `session/sound_relay.gd`. The host records only sounds the game queues (stream path via the per-battle type
  table): not when all players are busy / the queue is full (`SoundManagerParent.MAX_SOUNDS`) without
  `always_play`, nor `playSingle` within its cooldown (detected after the call: `can_play_sound` stamps
  `_last_played` only when it passes). Clients replay `playSingle` sounds as `playSingle` (cooldown minus
  0.1 s for snapshot timing) and pass `always_play` on. A client in a battle drops locally triggered sounds
  (e.g. step sounds from puppet walk animations, which are method tracks) and plays only replays.
- Outside battle (shop, selection screens, end of run) `sync/ui_sounds.gd` is the host's sink instead: sounds
  are batched per frame and sent as `UI_SOUNDS` (reliable; `res://` path, volume, pitch, position). The
  level-up/crate panels live in `main.tscn`, so their sounds already travel with the battle snapshots. The
  client checks paths like `BattleClient._define_type` (`SoundRelay.is_sound_path` + `ResourceLoader.exists`
  + `AudioStream`) and clamps volume/pitch. The puppet shop is muted (`ShopSync`, from `node_added` while it
  loads) until it leaves the tree (mirrored state and cursors would replay e.g. button focus sounds); ClientView isn't mirrored and
  stays audible. Sounds played while the host's tree is paused (pause menu) aren't recorded. UI pages that
  play their own `AudioStreamPlayer` (profile, codex, item sets) bypass SoundManager; they're host-only.

## Remote input, pause, absent players

- `INPUT` (unreliable, every physics frame): held mask + a 4-bit press counter per button
  (`sync/press_counter.gd`) + aim flags. Host (`sync/remote_buttons.gd`): a press needs a counted edge (a
  button still held after the 300 ms timeout release or at rejoin does nothing until released), a tap lost in
  a loss burst is replayed once, `ui_pause` is never held (delivered as press+release on the client's release,
  so timeouts/disconnects can't pause), held menu directions repeat like the game's pad echo (following
  `set_gamepad_echo_processing`).
- Client mode (`VirtualDevices.set_client_mode`): the client's InputService tracks pad vs. mouse like solo
  play, shows the mouse when it moves and doesn't emulate echo actions; the left stick is sent as menu
  directions.
- Aim (`sync/local_aim.gd`): the client's own `manual_aim` / `manual_aim_on_mouse_press` and device decide;
  mouse users send the direction from their predicted player to the mouse as the stick. Host: `Utils`
  extension answers `is_manual_aim` for virtual devices from that flag.
- Pause (`sync/pause_control.gd`): client puppet battle/shop get `PauseMenu.enabled = false` and lose the
  `game_lost_focus` connection. Host: a remote pause hands the menu to the first local player; the pauser
  resumes with pause (main page only). `BATTLE_PAUSE` / `SHOP_PAUSE` carry who paused ("Paused by …").
- Absent players (`sync/absent_players.gd`): after 20 s without messages (stale or left), the host makes the
  player's pending choice the game's way: first level-up option, crate take (recycle if it can't be taken),
  shop Go. Listed in the F9 panel / pill; a returning player just plays on.
