# brotato:together — implementation notes

How the mod uses the hooks in [`docs/brotato-hooks.md`](../../../docs/brotato-hooks.md).

## Battle mirror

- Run state travels the save-file path: `ProgressData.get_run_state()` → `ProgressDataLoaderV3.serialize_run_state`
  → `JSON.print` → zstd; client: `JSON.parse` → `deserialize_run_state` → `RunData.resume_from_state`.
  The JSON step is required: the deserializers expect string keys / float numbers (~5 KB for 2 players).
- Client loads `main.tscn` itself; `SceneTree.node_added` + the scene's `ready` signal freeze it right after
  `main._ready()` (before the first physics frame): `main.set_process(false)` (pause/aim),
  wave manager / entity spawner / effect behaviors / stats manager processing off, every Timer `timeout`
  connected to main disconnected (`get_incoming_connections()`), players puppetized.
- `main.tscn` spawns players from `CoopService.connected_players` → client fills one slot per host player.
- Net ids: `EntitySpawner.*_respawned` signals (fired on every spawn incl. pool reuse) + "absent from last
  snapshot ⇒ new id" for gold/consumables. Type = node `filename`, sent once per battle (TYPE_DEF).
- Puppet = `propagate_call("set_physics_process", [false])`, body `MODE_STATIC`, no collision layers,
  all Area2D monitoring off; idle processing (AnimationPlayers) stays on. `update_animation(motion)` is called
  with the interpolated motion for facing/walk animation.
- Client saves/challenges are blocked while puppeting (`ProgressData` / `ChallengeService` extensions).

## Menus

- **Shop** (`sync/shop_sync.gd`): run state via `ProgressData.get_run_state(shop_items, reroll_count,
  paid_reroll_count, initial_free_rerolls, free_rerolls, item_steals)` (the shop's own save args) + per-slot
  `active` layout + `_player_pressed_go_button`. Client enters through the resume path
  (`ProgressData.saved_run_state`, `RunData.resumed_from_state_in_shop = true`, `shop_effects_checked = true`)
  so `BaseShop._ready` rolls nothing; updates re-run the per-player part of `BaseShop._ready`
  (`set_weapons_data/items_data`, `_update_stats`, gold label, reroll price via `ItemService.get_reroll_price`,
  `ShopItem.set_shop_item/activate/deactivate`, `_update_visual_locks`, checkmarks). Client disconnects
  `BaseShop._on_tree_exited` (rolls curses on locked items).
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
  `session/sound_relay.gd`. The host records every sound (stream path via the per-battle type table); a client
  in a battle drops locally triggered sounds (e.g. step sounds from puppet walk animations, which are method
  tracks) and plays only replays.
