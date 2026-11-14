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
- Snapshot wire format (`sync/snapshot.gd`, protocol 4): hand-packed bytes, little endian. u32 battle id,
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
  damage numbers, sounds, player damage; animations last). Sizes incl. envelope, synthetic waves (test
  `snapshot_tests.gd`): small ~40 entities / mid ~140 / late ~300: see the test output; mid is well under
  the ~1200 B Steam MTU.
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
- Not mirrored yet: `GoTowardsBorderOppositeMovementBehavior.show_warning_arrow/line` (unused by the
  game), brachiosaurus foot shadow scale/position animations, jump-attack shadow `position.x` (reset on
  respawn only), effects done inside stripped method tracks / disconnected `animation_finished` handlers.
- Client saves/challenges are blocked while puppeting (`ProgressData` / `ChallengeService` extensions).

## Menus

- **Shop** (`sync/shop_sync.gd`): run state via `ProgressData.get_run_state(shop_items, reroll_count,
  paid_reroll_count, initial_free_rerolls, free_rerolls, item_steals)` (the shop's own save args) + per-slot
  `active` layout + `_player_pressed_go_button`. Client enters through the resume path
  (`ProgressData.saved_run_state`, `RunData.resumed_from_state_in_shop = true`, `shop_effects_checked = true`)
  so `BaseShop._ready` rolls nothing; updates re-run the per-player part of `BaseShop._ready`
  (`set_weapons_data/items_data`, `_update_stats`, gold label, reroll price via `ItemService.get_reroll_price`,
  `ShopItem.set_shop_item/activate/deactivate`, `_update_visual_locks`, checkmarks). Client disconnects
  `BaseShop._on_tree_exited` (rolls curses on locked items). The host checks every 0.1 s by comparing the
  run state's JSON text (+ slots, Go flags); zstd only runs when something changed.
- **Level-up / crate panels** (`sync/upgrades_sync.gd`): per player container state from `_old_upgrades`,
  `_level`, `_reroll_price`, `_item_data`, `_checkmark_group`; client re-implements
  `show_upgrades_for_level` without `ItemService.get_upgrades` and uses `show_item` for crates (item rebuilt
  from `ItemService` base + `deserialize_and_merge`).
- **Cursors** (`sync/focus_sync.gd`): every `FocusEmulator` in the scene; emulator + focused control sent as
  child-index paths from the scene root (`ui/scene_paths.gd`), applied through the `focused_control` setter.
- **Selection screens / end of run** (`sync/menu_sync.gd` + `ui/client_view.gd`): grids depend on local
  unlocks/DLC (`ProgressData.characters_unlocked`, `available_dlc_ids`, weapon unlock filtering), so the client
  shows `ItemPanelUI` cards for the item id under each cursor + `_has_player_selected` instead.
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
