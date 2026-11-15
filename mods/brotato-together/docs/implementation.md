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
  i16 angle (+ i16 sprite x/y in 1/8 px, i16 sprite angle) [+ weapon slots, speed: see Scene
  state]; u16 entity count, types as runs
  [varint type, varint length], u16 net ids, 4-bit flags, i16 x/y per entity not resting; poses as
  [varint index, u8 count, f32 values]; u8 event count + events (damage 7-8 B, sound 5-10 B, anim
  8 B + name; protocol 11: explosion 9 B, bonus gold 3-5 B, wave end 2 B, gold boost 6 B). Parsing is strict (bounds, counts, NaN, ASCII names, no trailing bytes) → whole snapshot dropped.
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
- Snapshot time (protocol 9): `t` follows the simulation, 1/60 s per physics step
  (`BattleHost.advance_clock`), not the wall clock. Below 60 fps the engine runs several physics steps in
  one frame; stamped with `OS.get_ticks_msec()` two snapshots of one frame were a few ms apart and the
  next a whole frame later, so clients played the wave fast, slow, fast (and a second snapshot within the
  same ms was dropped as a duplicate, with its events). The clock is set back onto the wall clock when
  they differ by more than 250 ms (pause, long hitch). The client's side is unchanged (min-filtered
  offset).
- Per-node records: the host keeps `[net id, type idx, kind bits, node, quantized x / y, still count]`
  per mirrored node from the snapshot it first appears in (`BattleHost._record`), the client the kind
  bits of each puppet (`BattleClient._kind_of`). The per-snapshot and per-frame loops read those instead
  of asking every node what it is (`is` checks, type key strings, layout lookups by scene path, a sort
  with a script comparator: ids are sorted natively per type). A record is dropped when its node leaves
  the tree or is respawned, so a pooled node that comes back is a new entity as before. A puppet that
  did not move is not moved, and a plain unit's `update_animation` (facing by motion) is skipped: the
  host's facing flag decides. Measured in `cleanup_tests.gd` for a late endless wave (400 enemies, 200
  projectiles, 50 gold, 2 players): host 10.3 -> 3.7 ms per snapshot, client 4.1 -> 1.4 ms per frame;
  2.7 KB per snapshot. A fresh puppet costs ~1 ms (instancing), a pooled one ~0.1 ms.
- One net id per spawn: the id a `*_respawned` signal assigns is kept by the entity's first snapshot
  (`_fresh_ids`). Before, the first snapshot assigned a second one, so a hit landed before it targeted an
  id no client ever saw, and ids wrapped twice as fast.
- Spawn markers (`EntityBirth` / `EntityGroupBirth`, protocol 9): the visible children of
  `main._births_container` are mirrored like gold (static, so mostly `FLAG_REST`), type key
  `<scene>#birth_enemy|neutral|structure|charmed` (colour and sprite, `PuppetEntity.birth_tag`). The
  client calls the marker's own `start()` with a matching `SpawnRequest`, so it flickers and hides
  itself after the same time as the host's; with no collision layers it never finds a player on it (the
  host then moves its marker, which arrives as a teleport and restarts the puppet). Its begin / end
  sounds are the host's.
- Boss and elite health (protocol 9): `Pose.Kind.HEALTH`, one value (fraction) at the end of the base
  parts of every `Boss` scene; the client hands it to the puppet's own `on_health_updated` (which
  follows this client's "life bars on bosses" option) and builds the brachiosaurus' full-screen bar like
  `Boss.init` does. Before, every elite showed a full bar for the whole fight.
- Puppet timers: all paused, except a unit's `FlashTimer` and a `UIProgressBar`'s timer, whose timeouts
  only put the sprite's material / the bar's tint back. Paused, a hit unit stayed white until it died.
- Projectile puppets face the direction between the two snapshots around render time (not the motion
  of the last frame), stay hidden until they have two samples (a pooled puppet would sit one snapshot
  long with the rotation of its last flight) and restart their animation when reused.
- Bullet-hell waves: `main._ready` adds its own generator (a random pattern) on the client too;
  `BattleClient._freeze` frees it. The host's bullets arrive as puppets.
- Scene state (protocol 12, `sync/battle_scene.gd`, one instance per battle on each side):
  - Hole layouts: `main._ready` calls `GPESpawner.spawn_holes_full_scene` when the wave's
    `spawn_holes` is set (jungle waves 4 / 10 / 16), which instances one of five layout scenes
    (`holes_scene`; `holes_old_scene` / `holes_explorer_scene` with a map size effect) picked at random
    at `Vector2.ONE` in `_gpe_container`. `BATTLE_START` carries the host's scene path (`holes`, ""
    for none); right after the client's `_ready` its own layout is freed and the host's instanced, if
    the path is in its spawner's three lists. `ZoneService.forbidden_circles` is cleared before:
    `Hole._ready` is the only thing that adds circles and only the layout exists at that point. A
    mid-wave resync keeps the layout of the scene it has.
  - Weapons during a wave: the only way the game changes a player's weapon nodes is
    `Player.on_weapon_wanted_to_break` (the brick's `break_on_hit`, `Weapon.on_weapon_hit_something`;
    abyssal_terrors), which erases the weapon from `current_weapons` and `RunData`. Crate weapons
    and the shop add to `RunData` only, after the wave. The host remembers the instance ids of each
    player's weapons at wave start; once a player has fewer, every snapshot carries its weapons'
    wave-start slots (`PLAYER_WEAPON_SLOTS`: u8 bit count + bitmask after the weapons, popcount must
    equal the weapon count). At render time the client drops the puppet weapons whose slot is gone
    (`current_weapons`, `weapon_pos` and the client's `RunData` weapon list like the game; stats and
    effects stay the host's) before the per-weapon data is applied by index. `BATTLE_START` carries
    every player's current slots (`weapon_slots`), so a client that joins after a break, whose
    puppet is built from the shorter run, maps the same way.
  - Speed: `Player.get_move_speed()` (stats incl. temporary ones, `bonus_speed`, the decaying slow
    after hits, petrol halves it) in whole px/s as a varint after the weapons (`PLAYER_SPEED`), sent
    for 4 snapshots after it changes and every 10th otherwise, filled from the newest one by
    `Snapshot.resolve`. The client sets it as the puppet's `current_stats.speed` (bonus, slow and
    petrol zeroed), so own-player prediction and the walk animation's playback speed follow it.
  - Wire cost: nothing while no weapon broke and no speed is due (both flags live in the player
    byte); 2 B per player and speed sent (speeds below 16384 px/s), 2 B per player after a break
    (up to 8 weapons). The synthetic waves of `snapshot_tests.gd` / `looks_tests.gd` do not grow.
  - The layout shares `_gpe_container` with puddle puppets (`sync/puddles.gd`): the swap only takes
    a child whose scene is one of the spawner's layouts, and it runs before any puddle puppet
    exists; the host's puddle scan takes only `AcidPuddle` / `PetrolPuddle` / `FirePuddle`.
- One-shot events older than 250 ms when their turn comes (a stall, a scene load) are dropped, except
  animations (state).
- Lasting looks (`sync/looks.gd`, protocol 12): states the game shows for seconds or for an entity's
  life, from game logic puppets never run. One byte of bits per entity: `BURNING` (+ `BURN_RED` /
  `BURN_BLUE`, the gradient `BurningParticles._update_color` picked), `CHARMED`, `CURSED`, `BOOSTED`.
  The host reads them off what the game shows: the outline colours in `Entity._outline_colors`
  (`Utils.CHARM_COLOR` from `CharmEnemyEffectBehavior.charm`, `CURSE_COLOR` from
  `CurseEnemyEffectBehavior.init` and cursed structures / pets, `BOOST_COLOR` from `Entity.boost`
  with `show_outline`; the curse's own boost has none), `Unit._is_burning`, and for enemy shots the
  hue shift material a charmed enemy's `ShootingAttackBehavior` hands them (the game uses that shader
  for nothing else; its `hue` is not read: `get_shader_param` asks the VisualServer, null when
  headless). Plain entities cost two property reads per snapshot on the host (600 of them: 0.5 ms,
  headless). Wire: a section after
  the events, `varint count` + per entry `varint gap to the previous index + 1, u8 bits`; sent for 4
  snapshots after a change (also to plain) and, while not plain, every 10th snapshot (staggered by
  id), so a plain wave costs 1 B and a lasting look ~0.2 B per entity and snapshot. Measured
  (`looks_tests.gd`, envelope included): the synthetic waves above 448 / 968 / 2184 B -> 452 / 968 /
  2184 B (the count byte crossed `var2bytes`' 4 B padding once); a late wave with 105 burning or
  charmed enemies 2168 B plain, 2380 B in the snapshot they all change, 2189 B on average after it;
  the loopback with 5 looked entities 1.8 B per snapshot. The client keeps the last look per net id
  (`Looks.resolve`, before `Snapshot.resolve` drops entities and shifts the indices); one not
  confirmed for 45 received snapshots is plain again. Applied once per new
  snapshot through the puppet's own visual code: `Entity._set_outlines` with the charm's alpha 0.4 /
  desaturation 0.75 (a hit flash keeps its material and gets the outline back when it ends), the
  sprite's white `self_modulate`, the unit's `BurningParticles.start_emitting / stop_emitting` (no
  `burning_data`, so nothing spreads; no burning timer), the `CurseParticles` of
  `curse_enemy_effect_behavior.tscn` instanced without its script next to (not among) the effect
  behaviors, a pet's `curse_particles`, the charm material on a shot. A puppet that leaves the
  snapshots (death, pool reuse) loses its look. Not mirrored: the meca / mutant evolution looks
  (outline plus a texture swap, `MecaEnemyEffectBehavior.init`), percent-damage-taken outlines (lute,
  diver), the one-shot boost particles (`stats_boosted` -> `EffectsManager`).
- Puddles (`sync/puddles.gd`, protocol 12): acid / petrol / fire puddles (`GPESpawner`, children of
  `main._gpe_container` / `_fire_puddles_container`) are tracked like gold: static, so mostly
  `FLAG_REST`. A puddle's sprite (index into `puddle_sprites`) and target scale (`GPESpawner`'s size,
  for fire also the `fire_puddle_size` stat) are set once in `init()` and travel in the type key,
  `<scene>#puddle:<sprite>:<scale x>:<scale y>` (1/100), one type per source. The sprite's random
  rotation is the client's own (exact would cost a type per puddle or bytes per snapshot). The host
  drops a puddle from the snapshots when it starts to fade (`is_active()`: timeout, eviction); the
  client runs the puddle's own spawn tween when it appears and its `despawn()` fade before pooling
  the puppet (its despawn timer is paused, so a scene timer pools it). Puppets have no collision
  layers, monitoring off and no lifetime timer: damage, slow and ignition stay with the host's.
  Holes, dig sites and poacher zones in the same container are not puddles and are left alone.
  The puddle a fire explosion leaves (arsonist: `PlayerExplosion.start_explosion` ->
  `_spawn_fire_puddle`) is one of these on the host; the client's explosion puppet
  (`FeedbackMirror.explode`) never runs `start_explosion`, so it puts down none of its own.
  Not mirrored: the tint of a player standing in acid / petrol (`Player._set_color_modulation`).
- Not mirrored yet (found by the audit for protocol 9, most visible first): stat texts
  (`RunData.stat_added`: stats on level up, harvesting at the wave's end, turret stats), the
  bigger sprite of a bonus-boosted gold, the music dip and the won-run animation at the wave's end
  (protocol 11 mirrors explosions, screen shake, level-up / heal / gold texts, dim screen, label
  and bonus gold bag: see "One-shot feedback"), the holes the brachiosaurus foot stomps into the
  ground (`BrachiosaurusFoot._stomp` -> `GPESpawner.spawn_single_hole_at_position`, from physics
  code puppets never run; protocol 12 mirrors weapon breaks, hole layouts and the speed: see "Scene
  state"). Also: `GoTowardsBorderOppositeMovementBehavior.show_warning_arrow/line` (unused by the
  game), brachiosaurus foot shadow scale/position animations, jump-attack shadow `position.x` (reset on
  respawn only), effects done inside stripped method tracks / disconnected `animation_finished` handlers.
- Client saves/challenges are blocked while puppeting (`ProgressData` / `ChallengeService` extensions).
  Puppet mode on stashes what `ProgressData.save()` persists from the run side (`saved_run_state`,
  `last_saved_run_state`, `data`, `killed_enemies`, `killed_by_enemies`, `items_bought`); off restores it
  (`session/puppet.gd`) — the shop resume path overwrites `saved_run_state` with the host's run. Unlocks /
  difficulties only change in host-only paths (run won, `complete_challenge`); `active_update_data` is reset
  by the title screen's `RunData.reset()`.

## Wave lifetime (endless runs)

- Nothing a wave allocated may outlive it. `cleanup_tests.gd` plays six waves as the host and replays
  six as a client (battle -> shop -> battle), with the next scene replacing the battle like in a session,
  and compares `Performance` object / node / orphan node / resource counts at the same point of every
  round: after two warm-up rounds they must not move at all. It also walks the script variables of every
  mod node for references to freed objects.
- Host: the battle ends when its scene leaves the tree (`tree_exited` on `main`, `_battle_live`). The
  old check compared scenes in the next `_process`, when `_main` was already freed and `is_in_battle()`
  false: `BATTLE_END` was never sent after a normal wave, and the client's cleanup only ran when the
  next battle started. `_end_battle` drops the type table, records, ids, stats and events.
- Client: `_leave_battle` (frees the puppet pool, clears buffers and tables, `RunData.wave_in_progress`
  / `wave_timer`, emits `battle_left`) runs on `BATTLE_END`, when the puppet scene leaves the tree
  without one (`_main_id`), and when another battle's start replaces a live one. `UpgradesSync` drops
  its references to the scene's panels on `battle_left`.
- References to per-wave nodes are not kept across waves, or kept as instance ids
  (`ShopSync._seq_shop_id`, `UpgradesSync._seq_ui_id`, pause banners found by name in their scene): in
  the game's release build `is_instance_valid()` says yes again once the freed address is reused, and
  `ui == _guarded_ui` would have skipped the guard of a new wave's panels.
- `main.clean_up_room` frees `_enemy_projectiles` while the scene lives on: `BattleHost._tracked_nodes`
  checks the container with `is_instance_valid` (it called `get_children()` on the freed node 30 times
  a second until the scene changed).
- Two reliable messages can arrive in one frame after a hitch, and `change_scene` instances at once but
  swaps deferred. A `BATTLE_START` for the battle the client is in or is loading only adopts the type
  table, slot and pause (a resync mid-wave no longer reloads the scene); one for another battle while a
  scene loads is queued until that scene is ready and frozen; a scene that becomes ready after its
  battle ended is frozen all the same. Before, the second scene had no hook and ran as a real local
  battle. The shop had the same race (a second `SHOP_STATE` before the puppet shop is ready
  entered it again, unguarded and rolling its own items); a state for the shop that is loading now waits
  for it.
- Client run state: `RunStateCodec.apply` resets `RunData`'s item-count caches before
  `resume_from_state` (the game only refreshes them in add / remove item; `LinkedStats` reads them).
- No per-node hooks: `PauseControl` finds the pause menu when the current scene changes instead of a
  permanent `SceneTree.node_added` handler (one script call per spawned or pooled node, also in solo
  play).
- Logs: the Mod Loader keeps every log entry in memory. Per wave that is three lines; failed sends
  logged one each (30 - 60 per second while a peer is unreachable) and are now limited to one a second.
- `mod_main._enter_client_view` takes the previous scene out of the tree before the view becomes the
  current scene, like `change_scene` does.
- Open: the host's shop check serializes the whole run to JSON every 0.1 s (`ShopSync._send_if_changed`),
  which grows with the items of a long run; not measured yet.

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
  - Keyboard and mouse: `ShopLocal.guard` adds a `LocalPanel` (see the level-up panels) as the puppet
    shop's last child (after `FocusEmulator1..4`), with every `CoopShopPlayerContainer` as `panels`.
    The own panel is set while the local buttons drive it (`take_over`; unset on stop, leaving, a
    host pause, and moved on another slot); `blocked` follows the F9 panel in `ShopLocal.process`.
    After a type change `ShopLocal` calls the container's `_set_focus_neighbours` (the game runs it
    in `_ready` and on a page change only) and, if the cursor sat on an arrow that became a glyph,
    puts it where `_set_focus_after_carousel_index_change` would: `_get_default_focus_control` on
    the shop page, Go on the stats pages. The item popup fits as it is: a focused popup keeps the
    mouse inside (`_focused`), and its hold-to-recycle ends on the device's `ui_accept` release
    that LocalPanel sends with the mouse button. Hold-to-ban has no mouse path in co-op (the ban
    button is hidden; the shortcut is a key). Shop specific: while the own Go flag is set or a
    "go 1" is on its way, and the cursor rests on Go, hover leaves the cursor there
    (`LocalPanel.hold_cursor`; a click still moves it): the game clears the flag when the cursor
    leaves Go, so a drifting mouse would take it back. The slot type survives state updates (only
    `fill_puppet_slots` at shop entry resets it, before the panel is set), so rebuilt gear and
    shop items read the right device; `CoopShopHint`s also get the panel's player (the game skips
    the popup's steal hint, which showed player 0's device).
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
    | meca upgrade (popup) | `item_meca_upgrade_selected` loses `BaseShop`'s handler, the upgrade button loses the popup's own roll (`_on_UpgradeButton_pressed`) | "meca_roll": `MecaChoice.roll` into the host's copy of the player's popup, sent back in `SHOP_STATE.mecas`; "meca" (option index): `MecaChoice.take`, then the popup's `item_meca_upgrade_selected` with the remembered roll (see "Meca upgrade" below) |
    | endless (player 1, wave 20) | `EndlessButton.toggled` loses the panel's handler | sets `pressed` on the host's button (its `toggled` sets `RunData.is_endless_run`); mirrored back with `set_pressed_no_signal` |

    The own panel's signals go to `SHOP_INTENT`; on the other panels nothing listens, so a mouse click
    there is dead. A control this list does not know (another mod's button, e.g. Damage Meter's summary
    button next to reroll) keeps its own handler and can show things, but every way into the run is cut.
    A cursor on it is only mirrored where that control exists; the other cursors are not shifted by it
    (see Cursors).
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
    `UpgradesSync` resets every frame outside a battle). `SHOP_FOCUS` (`shop_id, page, target`; since
    protocol 10 the cursor is a cursor target, see Cursors, restricted to the sender's own shop anchors)
    puts the remote cursor and page on the host's copy, from where `FocusSync` and `pages` carry them to
    the other clients. Cosmetic: a target that does not resolve (a control only one side has) or is not
    visible is ignored. Absent players and the pause hand-over
    work as before; while the host is paused (`SHOP_PAUSE`) the client's local buttons are off.
  - Differences from local co-op: with a steal left, the select shortcut steals and locks in one press;
    the host applies the steal, which makes the lock stale (the game itself would lock the stolen item).
    A second press made before the host's answer arrived (two quick buys) is dropped as stale.
  - Open: the host and the other clients do not see the own panel's focused inventory popup (cursor on its buttons is not
    visible on the host's copy); the client's hold-to-ban depends on its own `chal_banned_items` unlock
    and the ban animation / press sounds of the own panel are not heard (the puppet shop is muted; the
    host's sounds for the applied decision are); no feedback on the client for a refused buy (the host's
    gold label shakes); dismantle and the meca effect choice
    are only tested against stand-ins (no meca weapons without the DLC in the headless suite; the meca
    upgrade runs on the DLC's data, switched on for its checks, with signal presses in the shop popup);
    none of this has run between two real machines yet.
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
    leave as `UPGRADE_INTENT` kinds `weapon_combine` / `weapon_discard` / `weapon_meca_roll` /
    `weapon_meca` with `weapon` (slot in `RunData.get_player_weapons`) and `id` (its `my_id`); after
    combine / recycle / meca pick the popup closes like after a cancel (`_on_weapon_cancel_button_pressed`)
    and the weapons change when the host answers. The host checks revision, `_weapons_inventory_enabled`,
    slot and id, calls the game's handler (`UpgradesUI._on_weapon_combine_button_pressed` /
    `_on_weapon_discard_button_pressed` / `_on_weapon_meca_upgrade_selected`) and counts the intent as
    applied only if the weapons changed (the game refuses locked weapons or a missing partner itself). The
    player's weapons are part of the panel revision, so a second press is stale. Meca upgrade: see below.
  - Meca upgrade (protocol 10; `sync/meca_choice.gd`, the same for the crate weapon popup and the shop's
    item popup). Game rule: `ItemPopup._get_upgrade_preview` rolls the two stat options
    (`DLC2Data.meca_item`) when the upgrade button is hovered or pressed and keeps that roll per weapon
    object in `_upgrade_preview_cache` for the popup's lifetime (the scene); it is never cleared, so
    closing and reopening the popup shows the same two options, and while choosing there is no cancel
    (`_on_CancelButton_pressed` returns, `CoopItemPopup._input` has none). Now:
    - Client: every popup's upgrade button loses `_on_UpgradeButton_pressed` (no local roll to pick from);
      the own popup's goes to `MecaChoice` instead: when `can_meca_upgrade` it sends `weapon_meca_roll` /
      shop "meca_roll" (slot + `my_id`, panel revision) and the popup keeps its normal buttons (Cancel
      closes it). The host's rolls arrive in the state (`mecas`); if the popup is still open on that
      weapon, the preview is built like `meca_item` builds it without rolling (`do_not_add_effect`) plus
      two `EffectOption`s from the host's key hashes and values, put into the popup's cache, and the
      game's own `_on_UpgradeButton_pressed` shows it (preview, icons, "+n", focus on the first option).
      A roll already in the state is shown at once without asking. The pick (effect button + the popup's
      `item_meca_upgrade_selected`, in either order) leaves as `weapon_meca` (`meca`: 0 / 1) / shop
      "meca" (`arg`: 0 / 1). The hover preview still rolls locally (display only: the options are not
      drawn there).
    - Host: the roll goes into the host's copy of that player's popup cache, the game's own memory, with
      the game's code (`MecaChoice.roll`: an existing roll is returned, so asking again or reopening never
      rerolls, as in the local game). Checks: the player's weapon by slot + id, DLC active,
      `has_meca_upgrade_ui`, `can_weapon_be_mechanized`, cost > 0 and the parts, the revision, not paused
      (shop) and `_weapons_inventory_enabled` (crate). A roll does not change the revision. An unpicked
      roll stays remembered until the scene ends. The state sends per player
      `[[weapon slot, my_id, stat key hash, value, stat key hash, value]]` (also on `peer_ready`, part of
      the change key). A pick needs a remembered roll for that weapon, an int index 0 / 1, a matching
      revision and the parts; the roll is then forgotten and
      `change_effect_option_to_modular_effect(roll, index)` goes to the game's handler (crate:
      `UpgradesUI._on_weapon_meca_upgrade_selected`; shop: the popup's `item_meca_upgrade_selected` ->
      `BaseShop._on_item_meca_upgrade_selected`), which spends the parts. Anything else is dropped, so a
      client can only get one of the two options the host rolled and showed it.
  - Host: `UPGRADES_STATE` carries a revision per player (`seqs`: bumped when the panel shows something
    new, keyed on the entry, the option being processed, the item instance and the reroll count, so the same
    crate item twice still counts) and the carousel page (`pages`). `host_apply_intent` drops an intent whose
    revision or option id doesn't match the sender's panel, then calls the container's own handler
    (`_on_choose_button_pressed`, `_on_RerollButton_pressed`, `_on_TakeButton_pressed` after setting
    `_meca_effect_choice_selected`, `_on_DiscardButton_pressed`, `_on_BanButton_pressed`). While the panels
    are visible (and the game isn't paused: the pause menu is the host's) `InputSync.blocked_buttons` keeps
    every remote button but pause off the virtual devices, so a remote accept can't also press the host's
    copy.
  - Presence: the client reports its page and cursor (`UPGRADE_FOCUS`, `battle_id, page, target`: a
    cursor target restricted to its own panel's anchors since protocol 10, see Cursors; on change); the
    host applies them to its copy, from where `FocusSync` and `pages` carry them
    to the other clients. Cosmetic: decisions never depend on it.
  - The client rebuilds a panel only when its revision or entry changed, and re-applies the run state only
    when its bytes changed (a rebuild of the own panel would fight the local cursor).
  - Keyboard and mouse (`sync/local_panel.gd`, a node `UpgradesSync` adds as the puppet `UpgradesUI`'s
    last child; written against "the own panel + its emulator", the shop uses it too, see above).
    Why a node there: a `FocusEmulator` with a cursor marks every event that is not a co-op action
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
      (the arrows are named scene nodes, the same in both layouts). Cosmetic only.
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
    popup's combine, recycle hold, cancel and meca upgrade are driven through its real buttons by
    synthetic clicks).
- **Cursors** (`sync/focus_sync.gd`, `ui/focus_targets.gd`; protocol 10): every `FocusEmulator` in the
  scene; `FOCUS` = `scene, cursors [[player, menu, control]]`, applied through the `focused_control` setter.
  Until protocol 9 emulator and control were child-index paths from the scene root, which broke as soon as
  the trees differed: Damage Meter adds a summary button next to the shop's reroll button, and with it on
  one machine only every later index was off by one. Now nothing visible travels as a tree position:
  - Emulator: its `player_index` among the `FocusEmulator` children of its menu (the node they hang
    under: the shop scene root, `UpgradesUI`, `PauseMenu`, `RetryWave`, ...; `menu` is that node's
    target). A menu with a single emulator takes it whatever its index (who holds the pause menu or the
    retry prompt is mirrored elsewhere).
  - Control (also `SHOP_FOCUS` / `UPGRADE_FOCUS`): a cursor target `[anchor, player, index, steps]`.
    `anchor` is the nearest of the player's parts the game hands out through its own accessors:
    `shop_item` (k in `_get_shop_items_container(p)._shop_items`), `shop_reroll`, `shop_go`, `shop_popup`,
    `shop_gear`, `shop_panel` (`CoopShop._get_*`), `up_option` (k in `_get_upgrade_uis()`), `up_reroll`,
    `up_popup`, `up_weapons` (crate weapons list), `up_gear`, `up_panel` (`UpgradesUI._get_player_container`,
    from main through `_coop_upgrades_ui`); else `scene` (the generic fallback: pause menu, retry prompt,
    end of run, any screen not special-cased). `steps` lead from the anchor to the control: a node from a
    scene file (it has an `owner`) by its name, a node added by code (no owner, generated "@Name@123"
    names differ between machines: inventory elements, other mods' nodes) as `[script path or class, k]`,
    the k-th such sibling of that type, nodes queued for deletion not counted. So an extra node only one
    side has shifts nothing unless it is added by code into a list of nodes of its own type (another
    inventory element). The own-panel messages only accept that player's anchors, never `scene`.
  - Network data is checked (types, anchor names, player 0..3, index and step counts, name lengths;
    steps match child names, never parse paths). A target that does not resolve (a control only one side
    has) is ignored, as before: the latest message per scene stays pending (10 s) until every cursor
    resolves to a visible control (scene still loading, retry prompt not shown yet) and is retried every
    frame. `ui/scene_paths.gd` only finds the emulators now (FocusSync, MenuSync, CoopSelection).
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
- Protocol 11 (`sync/feedback_mirror.gd`, one instance per battle on each side, no node references):
  - Explosions (`WeaponService.explode`: rockets, grenades, landmines, exploding melee hits, bonk
    dog; two scenes, `explosion.tscn` is announced with BATTLE_START): the host finds new ones among
    the children of `main._explosions` at each snapshot (the pool takes finished ones out; a node
    whose "explode" restarted was pooled and reused in between) and sends `EVENT_EXPLOSION` [scene
    type, position, scale (incl. the explosion size stat), smoke amount]. The client takes a node
    from main's pool like the game, puppetizes it (no physics: its first physics frame would play
    the sound; hitbox areas off and disabled: the hits arrive as damage events), sets this player's
    `explosion_opacity` and plays "explode" from the start (the flash lasts 0.05 s, so not from the
    host's position); its method tracks (smoke, hitbox off) are harmless, and `end_explosion` pools
    it when the animation ends. Fog waves get their light (`FogViewport._on_spawn_explosion`).
  - State, sent on change, repeated for 4 snapshots and every 15th, ranked like animations and kept
    after a stall; an older copy arriving late is ignored: `EVENT_BONUS_GOLD` [`RunData.bonus_gold`,
    label visible] (it shrinks during the wave as bonus-boosted gold drops, grows at the end) and,
    once `main._cleaning_up`, `EVENT_WAVE_END` [failed / lost / won, label showing]. The client dims
    (`UIDimScreen.dim`), stops the floating texts' and effects' gold feedback (their own
    `clean_up_room`), fades the ambient sound, and starts / hides `WaveClearedLabel` with the host's
    (it starts late on a won run and is hidden before the level-up panels). Its typing sounds are
    the host's.
  - `EVENT_GOLD_BOOST` [position, boost]: the "x2" `FloatingTextManager.on_gold_picked_up` shows for
    gold dropped while bonus gold is left or doubled by the metal detector. The host hooks
    `picked_up` of mirrored gold and reads `boosted` in its handler: Godot 3 calls a signal's
    targets in order of instance id and the per-battle helper is made after main, so main's
    handler has doubled it already, and `Gold.pickup` resets it right after the signal.
  - Derived on the client, no bytes: screen shake (`Screenshaker._on_player_took_damage` for
    players, `_on_unit_took_damage` for enemies and neutrals, called with each damage event, which
    already leaves out `hide_feedback` hits; this client's screenshake option applies); level-up
    and heal texts from the host's player stats compared with its previous ones (a heal and a hit
    within one snapshot show as their sum, a heal that also raised max health shows nothing; they
    follow the newest snapshot, ~100 ms before the interpolated world); the gold pickup sparkle where
    a gold puppet vanished from the snapshots (`main.on_gold_picked_up` is the only way out of
    `_active_golds`), not after the wave's end.
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
  `game_lost_focus` connection. Host, shop: a remote pause hands the menu to the first local player; the
  pauser resumes with pause (main page only). `BATTLE_PAUSE` / `SHOP_PAUSE` carry who paused ("Paused by ...").
- Live menu (protocol 9; `extensions/ui/pause_menu.gd`, see docs/brotato-hooks.md §5): during a wave
  (until `main._end_wave_timer_timedout`) the menu opens without pausing.
  - Host with at least one peer: `PauseControl.host_update` sets `menu.live` every frame and keeps the
    pause bit off the remote devices for the whole battle scene (`InputSync.blocked_by["battle"]`), so
    only a local player opens it, through the game's own polling. The owner's
    `PlayerMovementBehavior.device` is parked on `VirtualDevices.IDLE` (a device nobody presses) while
    the menu is open: its buttons move the cursor, not the character; weapons go on firing. Focus loss
    does nothing in live mode. Restart / end run / quit work as in the game.
  - Client: `PauseControl.client_update` polls the release of its own `ui_pause` (armed by a press that
    was the game's: the F9 panel releases the actions of the keys it takes) and opens the puppet scene's
    menu for its own slot (`open_live`). `InputSync.set_local_menu` feeds the local buttons into the own
    slot's device through a second `RemoteButtons` / `PressCounter` and sends the host a neutral `INPUT`
    (no move, no aim, no buttons, counters unchanged; when the menu closes the counters resume from
    what is held, so nothing counts as a press). Restart / end run are disabled, Quit closes the menu
    and opens the F9 panel's leave confirmation.
  - The menu closes when the wave ends on that machine (level-up panels, retry prompt, `BATTLE_END`).
  - Open: the client's menu is keyboard / pad only (the emulator takes the mouse, as on every co-op
    screen); a spectator has none; options changed by a client are only written to disk after the
    session (saves are blocked while puppeting); none of this has run between two real machines yet.
- Absent players (`sync/absent_players.gd`): after 20 s without messages (stale or left), the host makes the
  player's pending choice the game's way: first level-up option, crate take (recycle if it can't be taken),
  shop Go. Listed in the F9 panel / pill; a returning player just plays on.
