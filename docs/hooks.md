# Hook map (Brotato, Godot 3.7, Mod Loader 6.3.0)

Paths are `res://` paths into the decompiled game (`reference/`, not committed). Line numbers refer to the
decompiled sources at the time of writing and will drift between game versions — search by function name.

## 1. Co-op slots and devices — `singletons/coop_service.gd`

- `connected_players: Array` — entry `[remapped_device, PlayerType]`, slot index = array position.
- Remapped device ids: `0..7` (`REMAP_END = 8`); `6` = joypad 0, `7` = keyboard/mouse; `8..11` reserved for
  the game's own debug devices (`FIRST_DEBUG_DEVICE_ID`, `DEBUG_DEVICE_COUNT`).
  **Virtual (networked) devices therefore use ids `12..15`** to avoid every existing range.
- `_add_player(device, player_type)` / `_remove_player(device)` — called directly by the game itself
  (Switch, Streamplay, `coop_resume.gd`), so calling them for virtual players is in-pattern.
- `get_max_players()` → 4. `RunData.is_coop_run`, `RunData.set_coop_run()`, `RunData.get_player_count()`.
- Join screen: `ui/menus/run/character_selection.gd` (`_play_mode_init`, `_on_connected_players_updated`).
- Gameplay binding: `global/entity_spawner.gd` sets
  `player._movement_behavior.device = CoopService.connected_players[player_index][0]`.

## 2. Gameplay input

- **Movement:** `entities/units/movement_behaviors/player_movement_behavior.gd :: get_movement()` — one node
  per player with a `device` field. In co-op reads `Input.get_vector("<analog_|button_>move_*_<device>")`.
  → *Hook*: extension overrides `get_movement()`; if `device` is a virtual device, return the networked vector.
- **Aim:** `singletons/utils.gd :: get_player_rjoy_vector(player_index)` (zero unless the player is a gamepad
  type); `main.gd :: _physics_process` copies it into `player.gamepad_attack_vector` when non-zero;
  `weapons/weapon.gd` uses it for gamepad players. `Utils.is_manual_aim(i)` depends on settings + gamepad use.
  → Register virtual players as `PlayerType.GAMEPAD_XBOX` so rjoy aim applies.
  → *Hook*: `Utils.get_player_rjoy_vector` (note: also used for UI scrolling).
- Mouse aim/move is effectively disabled in co-op (`InputService` hides the mouse when player count > 1).

## 3. UI input per player

- Every co-op screen has `FocusEmulator1..4` nodes (`Utils.get_focus_emulator(i)`), script
  `ui/menus/global/focus_emulator.gd`; each takes its `_device` from `connected_players`.
  It reacts to suffixed actions `ui_accept_<dev>`, `ui_left_<dev>` … and additionally checks
  `Input.is_action_pressed("ui_left_<dev>")` for navigation.
- Screen-level actions (`ui_select`, `ui_ban`, `ui_cancel`, `ltrigger`, `rtrigger`, `ui_pause`) go through
  `Utils.is_player_action_pressed/released(event, i, action)` → checks `"%s_%s" % [action, device]`.
  Users: `base_shop.gd`, `base_selection.gd`, `weapon_selection.gd`, `upgrades_ui_player_container.gd`,
  `item_popup.gd`, `coop_item_popup.gd`, `carousel.gd`.
- **Injection:** `Input.parse_input_event(InputEventAction{action="ui_accept_<vdev>", pressed=…, device=<vdev>})`
  — `device` must be set: `CoopService._input` treats device 0 as the keyboard. Parsed events are buffered
  and flushed by the platform once per frame, so `Input.is_action_pressed` updates on the next frame (the
  headless platform never flushes — tests call `Input.flush_buffered_events()`). The game
  does the same in `InputService._emulate_action`. Do **not** synthesize raw joypad events: base actions have
  device `-1` joypad events, so a fake joypad event would also fire global `ui_cancel` etc.

## 4. InputMap actions for virtual devices

- `InputService._copy_device_actions()` builds `<action>_<0..7>`; `enable/disable_gamepad_movement` call
  `InputMap.load_from_globals()`, which **wipes custom actions**.
  → *Hook*: extension of `singletons/input_service.gd` re-adds `<base>_<vdev>` actions for all bases
  (`ui_accept/select/cancel/info/pause/ban/left/right/up/down`, `ltrigger/rtrigger`, `analog_move_*`,
  `button_move_*`, `rjoy_*`) after every `_copy_device_actions()`. Actions have no events; they're driven by
  `Input.action_press/action_release` and `InputEventAction`.

## 5. Pause

- In wave: `main.gd :: _check_for_pause` — any player's `ui_pause_<dev>` release pauses (`PauseMenu.pause(i)`).
- Shop: `base_shop.gd :: _is_pause_requested`. Pause menu: `ui/menus/ingame/pause_menu.gd`.
- Policy: forward remote `ui_pause` only if host allows it (default: remote players can pause, host-only quit).

## 6. Mod loading (Steam build)

- Mod Loader 6.3.0, options profile `steam` → `enable_mods = true`, `steam_workshop_enabled = true`.
- `addons/mod_loader/mod_loader.gd :: _load_mod_zips()` — with workshop enabled, **only subscribed Workshop
  items** are loaded (`internal/third_party/steam.gd :: load_steam_workshop_zips`, filtered by
  `Platform.get_subscribed_mods()`). `<game>/mods` and `--mods-path` are ignored on Steam.
  → Dev loop: private Workshop item + overwrite its local zip (`tools/deploy.sh`).
- `mod_main.gd` is instantiated with no `_init` args and added as a child of the `ModLoader` autoload
  (survives scene changes). Script extensions are applied after all mods' `_init`.
- Logs: `user://logs/modloader.log` (≈ `~/.local/share/Brotato/logs/`, to verify).
- Built-in mods menu (`ui/menus/pages/mods/menu_mods.gd`) is read-only.

## 7. Steam / GodotSteam — `singletons/platforms/steam.gd`

- `Platform` autoload → `SteamPlatform` when `OS.has_feature("steam")`. Singleton fetched via
  `Engine.get_singleton("Steam")` (never the bare `Steam` identifier) → object at `Platform._platform_impl.steam`.
- `steamInitEx(1942280, true)` — 2nd arg is GodotSteam's embed_callbacks (to verify at runtime: signals fire
  without us calling `run_callbacks()`).
- Local id: `Platform._platform_impl.steam_id` (int). Game uses no lobby / networking / rich presence / persona APIs.

## 8. Scene flow (co-op run)

`ui/menus/pages/main_menu.gd :: _on_StartButton_pressed` → `ui/menus/run/character_selection.tscn`
(`_on_selections_completed` → `RunData.add_character`) → `ui/menus/run/weapon_selection.tscn`
→ `ui/menus/run/difficulty_selection/difficulty_selection.tscn` (`_on_element_pressed` → `main.tscn`)
→ `main.gd :: _on_EndWaveTimer_timeout` → `ui/menus/ingame/coop_upgrades_ui.tscn` (level-ups + crates)
→ `RunData.get_shop_scene_path()` = `coop_shop.tscn` → `base_shop.gd :: _on_GoButton_pressed` (all players)
→ `main.tscn` … → `coop_end_run.tscn`. Scene paths: `singletons/menu_data.gd`.

## 9. Where player state changes are *applied* (host side)

| Action | Applied in |
|---|---|
| Buy / steal | `base_shop.gd :: on_shop_item_bought` → `RunData.remove_currency` + `buy_item` (`RunData.add_item_triggering_stat_gain_effects`) / `buy_weapon` (`RunData.add_weapon`) |
| Lock | `shop_item.gd :: change_lock_status` → `RunData.lock_player_shop_item` / `unlock_player_shop_item` |
| Reroll | `base_shop.gd :: _on_RerollButton_pressed` → `fill_shop_items` → `ItemService.get_player_shop_items` |
| Combine / recycle | `RunData.combine_weapon` / `RunData.recycle_weapon` |
| Level-up pick | `main.gd :: on_upgrade_selected` → `RunData.add_upgrade` |
| Crate | `main.gd :: on_item_box_take_button_pressed` / `_discard_` / `_ban_` |
| Go | `base_shop.gd :: _on_GoButton_pressed` (waits for all players) |

RNG is unseeded (`Utils._rng.randomize()`), so shops/upgrades **must** be rolled on the host only.

## 10. Per-player state — full-state sync

- `RunData.players_data[i]` : `PlayerRunData` (`singletons/player_run_data.gd`, `extends Reference`).
  Fields: `current_character`, `current_health`, `current_level`, `current_xp`, `gold` (= materials), `weapons`,
  `items`, `effects` (all stats, **int-hash keys** `Keys.*_hash`), sets, upgrades, bans …
- **Reuse the save-game path:** `PlayerRunData.serialize() -> Dictionary` / `PlayerRunData.new().deserialize(d)`.
  Client apply: replace `players_data[i]`, then `LinkedStats.reset_player(i)`, `Utils.reset_stat_cache(i)`,
  `RunData.reset_run_caches()`.
- Whole run: `RunData.get_state()` / `RunData.resume_from_state(state)` (wave, zone, difficulty, …) — used for
  join/rejoin resync.
- **No single "state changed" signal**: `add_item`, `remove_item`, `add_weapon`, `remove_weapon`,
  `apply_item_effects` emit nothing. → Host detects changes by hashing `serialize()` output per player
  (cheap enough at a few Hz outside battle; in battle only gold/xp/hp change often).
- Stats: `Utils.get_stat(hash, i)` = `RunData.get_stat` + `TempStats` + `LinkedStats`, cached per player.
  Weapon slots = `effects[Keys.weapon_slot_hash]` (default 6). `RunData.stats_updated(i)` fires for
  add_stat/remove_stat/temp/linked changes only.
- Weapon nodes are created once per wave in `Player.apply_items_effects()` (`entities/units/player/player.gd`)
  → a mid-wave weapon change needs an explicit re-apply on the client (this is the "7th slot only next wave" bug).

## 11. Battlefield entities

- No gameplay groups and **no stable entity ids** — everything is pooled (`main.gd :: get_node_from_pool` /
  `add_node_to_pool`, `Entity.free_entity()`). → Assign our own net id in `EntitySpawner.spawn_entity`
  (covers first spawn and respawn from pool); type = scene `filename` + `enemy_id`.
- `global/entity_spawner.gd`: `enemies`, `bosses`, `neutrals`, `structures`, `pets`, `get_all_enemies()`;
  spawn flow `on_group_spawn_timing_reached` → births → `spawn_entity`; signals `enemy_spawned`, `*_respawned`.
- `main.gd` containers: `%Entities` (YSort), `%PlayerProjectiles`, `%EnemyProjectiles`, `%Materials`
  (`_active_golds`, `spawn_gold`, `on_gold_picked_up`), `%Consumables` (`_consumables`), `%Births`.
- Players spawned in `EntitySpawner.init()`; `main.gd :: _on_EntitySpawner_players_spawned` stores `_players`.

## 12. Battle lifecycle and puppet-mode switches (client)

- `main.gd :: _ready` → `RunData.on_wave_start`, `_wave_timer.start()`, `_wave_manager.init`,
  `_entity_spawner.init`. End: `_on_WaveTimer_timeout` → `clean_up_room()` → `_on_EndWaveTimer_timeout`
  → upgrades UI → shop scene. Death: `_on_player_died`.
- No run seed; ~65 files use global `randf()`/`randi()` → lockstep is not viable; host-authoritative is.
- Client simulation switches: `WaveManager.set_physics_process(false)`; `EntitySpawner._cleaning_up = true` +
  stop `_structure_timer`; pause `_wave_timer` / `HalfWaveTimer` / `EndWaveTimer` and drive them from host;
  per unit `set_physics_process(false)` + mode static, positions from snapshots; `Hurtbox.disable()`;
  `Utils.disable_node(weapons_container)`; `Player.disable_gold_pickup()`.

## 13. Client battle mirror (as implemented)

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

## 14. Menus (as implemented)

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
