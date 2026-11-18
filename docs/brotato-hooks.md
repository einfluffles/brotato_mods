# Brotato hook map (Godot 3.7, Mod Loader 6.3.0)

Shared knowledge for all mods in this repo: where the game does what, and how to hook it.

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
  `Utils.is_manual_aim` in co-op: manual only for gamepad players (with `settings.manual_aim`), or while the
  right stick is pushed (`manual_aim_on_mouse_press`); solo keyboard players aim at the mouse
  (`weapon.gd :: _physics_process`, `get_global_mouse_position()`). Cached per frame (`_manual_aim_cache`).
- `InputService` and `Utils` are autoloads after `ModLoader`, so script extensions apply. Godot 3 calls
  `_input`/`_process` of every script level (multilevel): an extension can add to them, not replace them.

## 3. UI input per player

- Every co-op screen has `FocusEmulator1..4` nodes (`Utils.get_focus_emulator(i)`), script
  `ui/menus/global/focus_emulator.gd`; each takes its `_device` from `connected_players`.
  It reacts to suffixed actions `ui_accept_<dev>`, `ui_left_<dev>` … and additionally checks
  `Input.is_action_pressed("ui_left_<dev>")` for navigation.
- Screen-level actions (`ui_select`, `ui_ban`, `ui_cancel`, `ltrigger`, `rtrigger`, `ui_pause`) go through
  `Utils.is_player_action_pressed/released(event, i, action)` → checks `"%s_%s" % [action, device]`.
  Users: `base_shop.gd`, `base_selection.gd`, `weapon_selection.gd`, `upgrades_ui_player_container.gd`,
  `item_popup.gd`, `coop_item_popup.gd`, `carousel.gd`.
- **Carousel pages** (`ui/menus/global/carousel.gd`, per player panel in the co-op shop, level-up and end
  of run): one page per child of `%Headings`, shown with the `%Content` child of the same index; LB / RB
  (`ltrigger` / `rtrigger`, which also cover LT / RT) and the arrows step through them. A page added by
  code (a heading plus a content child) is reached like the game's own; `max_index >= 0` caps the pages
  without removing any, and the `index` setter clamps. The solo screens have no carousel: their
  `StatsContainer` toggles Primary / Secondary on the same triggers.
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
- Pause triggers on the **release** of `ui_pause` (polled `is_action_just_released` in main, press+release
  events in the shop). `PauseMenu.pause(i)` emits `paused` *before* `_main_menu.init(i)`; the menu is operated
  by player `i` only (`_player_index`, its `FocusEmulator`). Ownership change = the steps in
  `PauseMenu.on_game_lost_focus`: `_player_index`, `_focus_emulator.player_index`, `_menus.reset()`,
  `_main_menu.init(i)`. `PauseMenu.enabled = false` makes `pause()` a no-op.
- Local pause triggers: `ui_pause_<dev>` (above), `InputService.game_lost_focus` (window focus out, pad
  disconnect) → `main.gd :: _on_game_lost_focus` (connected in `_ready`) and `coop_shop.gd` (only while paused,
  to hand the menu to player 0). Default `settings.pause_on_focus_lost = true`.
- Policy (brotato:together): a wave of an online session never pauses. `PauseMenu` gets a script
  extension with a live mode (opens / closes without touching `get_tree().paused`); the game's own
  callers (`main._check_for_pause`, the base `_input`, which Godot 3 runs next to the extension's) end
  in `pause()`, which toggles the live menu. A real pause is left for the shop (remote players can
  pause; the menu goes to the host's first local player, no blind quit/restart; the remote player who
  paused resumes with pause), the level-up panels (host's local players) and a host without peers.
  Clients never pause locally.
- A live menu's `FocusEmulator` marks every event that is not its owner's UI action as handled, like on
  any co-op screen: fine during a wave (movement and `main._check_for_pause` poll `Input`), not while
  the level-up panels run, so the live menu closes when `main._end_wave_timer_timedout` is set.
- The confirm pages (`MenuRestart`, `MenuEndRun`, `MenuConfirm`) and the codex go back on the plain
  `ui_cancel`, and Esc is `ui_pause` and `ui_cancel` at once: without the tree paused the same key press
  reaches a page, the pause menu and main's polling. The extension allows one step back per 200 ms.

### Menu pages

- `ui/menus/menus.gd` (`Menus`): a `Control` whose children are full-screen pages, one visible.
  `switch(from, to)` = `to.show(); to.init(); from.hide()`, sets `_current_page`, emits
  `menu_page_switched`; `back()` / `reset()` return to `_main_menu`. The main page emits a signal per
  button, `Menus` connects it to a `switch`. Title screen: `TitleScreenMenus` (`TitleScreen._menus`,
  main page `ui/menus/pages/main_menu.gd`, which resets `%ErrorLabel` and grabs the focus in `init()`,
  i.e. on every return); pause menu: `IngameMenus` (`PauseMenu._menus`, main page `IngameMainMenu`).
- A page: `init()`, a `back_button_pressed` / `cancel_button_pressed` signal, `_input` going back on the
  plain `ui_cancel` release, and `focus_before_created = get_focus_owner()` to give the focus back. With a
  `FocusEmulator` there is no Godot focus owner, so that is null in co-op (`null.grab_focus()` is only
  ignored in release builds). Buttons are plain `Button`s with `ui/menus/global/my_menu_button.gd`
  (sounds, focus on hover, `disabled` for 0.05 s after a press; `disable()` / `activate()`).
- The pause menu's `FocusEmulator` has `Menus` as a focus base: any focusable control of any page under
  it is reachable by the pausing player. Character selection: `FocusEmulator1` has the grid, the run
  options box and Back as bases, the other emulators only the grid.

### Menu echo

- `InputService._process` repeats held d-pad / left-stick directions as `ui_*_<dev>` pressed
  `InputEventAction`s (delay 0.3 s, interval 0.09 s) for real pads `0..7` only; switched by
  `set_gamepad_echo_processing` (off during waves). Emulated actions are never released, so the base
  `ui_left` etc. can stay "pressed" in `Input` after stick navigation.

## 6. Mod loading (Steam build)

- Mod Loader 6.3.0, options profile `steam` → `enable_mods = true`, `steam_workshop_enabled = true`.
- `addons/mod_loader/mod_loader.gd :: _load_mod_zips()` — with workshop enabled, **only subscribed Workshop
  items** are loaded (`internal/third_party/steam.gd :: load_steam_workshop_zips`, filtered by
  `Platform.get_subscribed_mods()`). `<game>/mods` and `--mods-path` are ignored on Steam.
  → Dev loop: private Workshop item + overwrite its local zip (`tools/deploy.sh <name> <item_id>`).
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
  The only mid-wave change of the weapon nodes is a removal: `Player.on_weapon_wanted_to_break` (signal
  `Weapon.wanted_to_break`, `break_on_hit` effect, abyssal_terrors' brick) erases the node from
  `current_weapons` and calls `RunData.remove_weapon_by_index`. Crates add to `RunData` after the wave.
- Move speed: `Player.get_move_speed()` = (`current_stats.speed` + `bonus_speed` + `decaying_bonus_speed`)
  / (1 + `petrol_malus`); petrol is set per physics frame (`update_petrol_effect`), the slow decays in
  `Unit._physics_process`.
- Player movement: a `RigidBody2D` in `MODE_KINEMATIC` (layer 2, mask 130: players + layer 8
  "obstacles" = holes, `TileMap`, `TileMapLimits`). `Unit._physics_process` moves it with
  `test_motion(velocity * delta, true, 0.08)` and, when that hits, once more with the velocity slid
  along the normal; no `move_and_slide` anywhere. A tick along a hole's edge can so move up to two steps.

### Inventory popup (shop)

- `ui/menus/global/popup_manager.gd` (`BaseShop._popup_manager`) shows a player's `ItemPopup` for the
  focused gear element and, on accept, focuses it (`_elements_pressed[p]`, `ItemPopup.focus()`, cursor on
  Cancel) when `ItemPopup.will_show_buttons_when_focused(item)`. The game only says yes for weapons
  (`should_show_buttons`), and `_update_button_visibilities` then asks `RunData.can_combine`, whose
  parameter is typed `WeaponData`: buttons for an item need their own branch. Co-op: `CoopItemPopup`
  (`coop_item_popup.tscn`, also one per player on the level-up screen), buttons in
  `ItemPanelUI/MarginContainer/VBoxContainer` (Combine, Recycle, Cancel, Upgrade), up / down neighbours
  rebuilt by `_update_button_focus_neighbours`; with two players `_ready` replaces the popup's outer box.
- Closing: the popup's `item_cancel_button_pressed` -> `BaseShop._on_item_cancel_button_pressed`
  (`_popup_manager.reset_focus(p)`, cursor back on the element; `CoopShop` hides the dim screen).
  `ItemPopup._input` emits it on the player's `ui_cancel` while `_focused`. `_input` runs on every
  script level, the extension's first: a script extension that clears `_focused` there keeps the base
  from closing the popup on that press.
- `grab_focus()` on a control inside a player's panel moves that player's `FocusEmulator` (each has its
  own `CoopShopPlayerContainer` as focus base, `gui_focus_changed`); `Inventory.remove_element` ends in
  one, so removing another player's element moves that player's cursor into its gear.
- Gear rows: `PlayerGearContainer.set_weapons_data` / `set_items_data` free every element and build new
  ones (`Inventory.clear_elements` removes them from the tree at once). Take a `FocusEmulator` off an
  element first; plain items stack in one element (`current_number`).
- Item objects are shared: shop pools hand out `ItemService`'s own `ItemData` objects
  (`get_pool` copies the list, not the items), so one object can be in a player's `items` several
  times and in several players' lists; a resumed run has a copy per entry. `RunData.add_weapon`
  always copies. `RunData.remove_item` erases the item's appearances even when another copy stays.

## 11. Battlefield entities

- No gameplay groups and **no stable entity ids** — everything is pooled (`main.gd :: get_node_from_pool` /
  `add_node_to_pool`, `Entity.free_entity()`). → Assign our own net id in `EntitySpawner.spawn_entity`
  (covers first spawn and respawn from pool); type = scene `filename` + `enemy_id`.
- `global/entity_spawner.gd`: `enemies`, `bosses`, `neutrals`, `structures`, `pets`, `get_all_enemies()`;
  spawn flow `on_group_spawn_timing_reached` → births → `spawn_entity`; signals `enemy_spawned`, `*_respawned`.
- `main.gd` containers: `%Entities` (YSort), `%PlayerProjectiles`, `%EnemyProjectiles`, `%Materials`
  (`_active_golds`, `spawn_gold`, `on_gold_picked_up`), `%Consumables` (`_consumables`), `%Births`.
- Players spawned in `EntitySpawner.init()`; `main.gd :: _on_EntitySpawner_players_spawned` stores `_players`.
- Holes (`global/gpe_spawner.gd`, children of `main._gpe_container`): `main._ready` →
  `spawn_holes_full_scene()` when the wave data's `spawn_holes` is set (a random layout scene from
  `holes_scene` / `holes_old_scene` / `holes_explorer_scene`, by map size); `Hole._ready` adds a
  `ZoneService` forbidden circle. Mid-wave: `BrachiosaurusFoot._stomp` → `spawn_single_hole_at_position`.

## 12. Battle lifecycle and puppet-mode switches (client)

- `main.gd :: _ready` → `RunData.on_wave_start`, `_wave_timer.start()`, `_wave_manager.init`,
  `_entity_spawner.init`. End: `_on_WaveTimer_timeout` → `clean_up_room()` → `_on_EndWaveTimer_timeout`
  → upgrades UI → shop scene. Death: `_on_player_died`.
- No run seed; ~65 files use global `randf()`/`randi()` → lockstep is not viable; host-authoritative is.
- Client simulation switches: `WaveManager.set_physics_process(false)`; `EntitySpawner._cleaning_up = true` +
  stop `_structure_timer`; pause `_wave_timer` / `HalfWaveTimer` / `EndWaveTimer` and drive them from host;
  per unit `set_physics_process(false)` + mode static, positions from snapshots; `Hurtbox.disable()`;
  `Utils.disable_node(weapons_container)`; `Player.disable_gold_pickup()`.

## 13. DLC ownership vs. content

- All DLC content (`dlcs/dlc_1` = `abyssal_terrors`, `dlcs/dlc_2` = `primal_dread`, and the DLC items /
  characters / weapons / enemies under `items/`, `entities/`, `zones/`) ships in the base `Brotato.pck`.
  Ownership only gates **registration**: `ProgressData.check_for_available_dlcs()` fills
  `available_dlc_ids` from `Platform.is_dlc_owned()` (headless/no Steam: none), then
  `ItemService.init_dlc_content()` runs `update.dlc_data.add_resources()` (backgrounds, title screen
  backgrounds, `entities` (codex enemy data), `effects` (effect scripts)); `DLCData.remove_resources()`
  undoes it.
- `ItemService.items/characters/weapons` are setget caches rebuilt from `update_data_list` filtered by
  `available_dlc_ids` (`invalidate_*_cache()`); `_item_id_lookup` / `_weapon_id_lookup` /
  `_base_weapon_lookup` are lazy and never cleared by the game. `ItemService.init_unlocked_pool()` builds
  `_tiers_data` from `ProgressData.active_update_data` (= `refresh_active_update_data()`: available DLCs
  minus `deactivated_update_data`; a resumed run applies its own `active_update_data_ids`).
- Not gated: `ZoneService.zones` (every zone; `zone.dlc_id` is checked by the zone selection UI),
  `ItemService.get_dlc_data_by_id()`, scenes by path. `ChallengeService.load_update_challenges()` skips
  unowned DLC challenges once at startup. DLC drop consumables (poisoned / meca / mutant / mutation fruit,
  meca parts) are `DLCData` properties, not in `ItemService.consumables`.
- `available_dlc_ids` / `active_update_data` aren't saved; `save()` writes the unlock lists,
  `difficulties_unlocked`, stats, the run, `deactivated_update_data` (`ProgressData._set_loader_properties`).
