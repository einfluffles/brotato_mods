# Brotato hook map (Godot 3.7, Mod Loader 6.3.0)

Shared knowledge for all mods in this repo: where the base game does what, and how a mod can
hook it. The statements describe the game. Where a line says what a mod of this repo does, it
starts with the mod's name and names the file.

## Reading this map

- Paths are `res://` paths into the decompiled game (`reference/`, which is not in the
  repository; see [Game code](game-code.md)). Search by function name, because
  the sources shift between game versions.
- `file.gd :: function` is a function in that file. `Class.member` is a member of a class or
  autoload.
- `a` -> `b` means that `a` calls `b` or leads to it.
- `<dev>` is a remapped device id (section 1). `<vdev>` is the id of a virtual device, one that
  stands for a remote player.
- `rjoy` is the right stick. `gpe` is the game's prefix for objects placed on the map, such as
  holes (`global/gpe_spawner.gd`).
- **Hook** marks a way for a mod to intercept the game at that point.
- **brotato:together** marks what that mod does there. Paths after it are relative to
  `mods/brotato-together/src/einfluffles-BrotatoTogether/`. Its design is described in
  [its implementation notes](../mods/brotato-together/docs/implementation.md).

## 1. Co-op slots and devices (`singletons/coop_service.gd`)

- `connected_players: Array` holds one entry `[remapped_device, PlayerType]` per player. The slot
  index is the position in the array.
- Remapped device ids are `0..7` (`REMAP_END = 8`). `6` is joypad 0 and `7` is keyboard and
  mouse. `8..11` are reserved for the game's own debug devices (`FIRST_DEBUG_DEVICE_ID`,
  `DEBUG_DEVICE_COUNT`).
- `_add_player(device, player_type)` and `_remove_player(device)` are called directly by the game
  itself (Switch, Streamplay, `coop_resume.gd`), so a mod that calls them follows the game's
  pattern.
- `get_max_players()` returns 4. Related: `RunData.is_coop_run`, `RunData.set_coop_run()`,
  `RunData.get_player_count()`.
- Join screen: `ui/menus/run/character_selection.gd` (`_play_mode_init`,
  `_on_connected_players_updated`).
- Gameplay binding: `global/entity_spawner.gd` sets
  `player._movement_behavior.device = CoopService.connected_players[player_index][0]`.
- **brotato:together:** virtual devices use ids `12..15`, outside every range above
  (`sync/virtual_devices.gd`). Remote players join through the game's hold-to-join, and an
  extension of `_add_player` types them as `PlayerType.GAMEPAD_XBOX`
  (`extensions/singletons/coop_service.gd`).

## 2. Gameplay input

- **Movement:** `entities/units/movement_behaviors/player_movement_behavior.gd :: get_movement()`.
  There is one such node per player, with a `device` field. In co-op it reads
  `Input.get_vector("<analog_|button_>move_*_<device>")`.
- **Aim:** `singletons/utils.gd :: get_player_rjoy_vector(player_index)` returns zero unless the
  player is of a gamepad type. `main.gd :: _physics_process` copies it into
  `player.gamepad_attack_vector` when it is not zero, and `weapons/weapon.gd` uses that for
  gamepad players. The function is also used for UI scrolling.
- **Manual aim:** `Utils.is_manual_aim(i)` depends on the settings and on gamepad use. In co-op,
  aim is manual only for gamepad players (with `settings.manual_aim`) or while the right stick is
  pushed (`manual_aim_on_mouse_press`). Solo keyboard players aim at the mouse
  (`weapon.gd :: _physics_process`, `get_global_mouse_position()`). The result is cached per
  frame (`_manual_aim_cache`).
- Mouse aim and movement are effectively off in co-op: `InputService` hides the mouse when the
  player count is above 1.
- `InputService` and `Utils` are autoloads that come after `ModLoader`, so script extensions
  apply to them. Godot 3 calls `_input` and `_process` of every script level (multilevel calls):
  an extension can add to them, not replace them.
- **brotato:together:** no extension of the movement behaviour or of `get_player_rjoy_vector`.
  The host presses the actions `analog_move_*_<vdev>` and `rjoy_*_<vdev>` with the remote
  player's values (`sync/virtual_devices.gd`), and the game's own functions read them. The
  gamepad type from section 1 makes right-stick aim apply. An extension of `Utils.is_manual_aim`
  lets each client's own setting count (`extensions/singletons/utils.gd`).

## 3. UI input per player

- Every co-op screen has `FocusEmulator1..4` nodes (`Utils.get_focus_emulator(i)`, script
  `ui/menus/global/focus_emulator.gd`). Each takes its `_device` from `connected_players`. It
  reacts to the suffixed actions `ui_accept_<dev>`, `ui_left_<dev>` and so on, and also checks
  `Input.is_action_pressed("ui_left_<dev>")` for navigation.
- Screen-level actions (`ui_select`, `ui_ban`, `ui_cancel`, `ltrigger`, `rtrigger`, `ui_pause`) go
  through `Utils.is_player_action_pressed/released(event, i, action)`, which checks
  `"%s_%s" % [action, device]`. Users: `base_shop.gd`, `base_selection.gd`,
  `weapon_selection.gd`, `upgrades_ui_player_container.gd`, `item_popup.gd`,
  `coop_item_popup.gd`, `carousel.gd`.
- **Carousel pages** (`ui/menus/global/carousel.gd`, one per player panel in the co-op shop, on
  the level-up screen and at the end of a run):
  - There is one page per child of `%Headings`, shown with the `%Content` child of the same
    index.
  - LB / RB (`ltrigger` / `rtrigger`, which also cover LT / RT) and the arrows step through the
    pages.
  - A page added by code (a heading plus a content child) is reached like the game's own.
  - `max_index >= 0` caps the pages without removing any, and the `index` setter clamps.
  - The solo screens have no carousel. Their `StatsContainer` toggles Primary / Secondary on the
    same triggers.
- **Hook, injecting input:**
  `Input.parse_input_event(InputEventAction{action="ui_accept_<vdev>", pressed=..., device=<vdev>})`.
  The game does the same in `InputService._emulate_action`.
  - `device` must be set, because `CoopService._input` treats device 0 as the keyboard.
  - Parsed events are buffered and flushed by the platform once per frame, so
    `Input.is_action_pressed` updates on the next frame. The headless platform never flushes;
    tests call `Input.flush_buffered_events()`.
  - Do **not** synthesize raw joypad events. The base actions have joypad events with device
    `-1`, so a fake joypad event would also fire the global `ui_cancel` and its like.
  - **brotato:together:** a remote player's buttons are injected this way
    (`sync/virtual_devices.gd`).

## 4. InputMap actions for virtual devices

- `InputService._copy_device_actions()` builds `<action>_<0..7>`.
- `enable_gamepad_movement` and `disable_gamepad_movement` call `InputMap.load_from_globals()`,
  which **wipes custom actions**.
- **Hook:** an extension of `singletons/input_service.gd` can add its actions again after every
  `_copy_device_actions()`.
- **brotato:together:** that extension (`extensions/singletons/input_service.gd`) registers
  `<base>_<vdev>` for the bases `ui_accept/select/cancel/info/pause/ban/left/right/up/down`,
  `ltrigger/rtrigger`, `analog_move_*`, `rjoy_*` and `button_move_*` (the last are never
  pressed; they exist so that the game's lookups find them). The actions have no events. They
  are driven by `Input.action_press` / `action_release` and by `InputEventAction`.

## 5. Pause

- **In a wave:** `main.gd :: _check_for_pause`. The release of any player's `ui_pause_<dev>`
  pauses (`PauseMenu.pause(i)`).
- **In the shop:** `base_shop.gd :: _is_pause_requested`.
- **Pause menu:** `ui/menus/ingame/pause_menu.gd`.
  - A pause triggers on the **release** of `ui_pause`. `main` polls `is_action_just_released`;
    the shop uses the press and release events.
  - `PauseMenu.pause(i)` emits `paused` *before* `_main_menu.init(i)`.
  - The menu is operated by player `i` only (`_player_index` and that player's `FocusEmulator`).
  - To hand the menu to another player, do what `PauseMenu.on_game_lost_focus` does: set
    `_player_index` and `_focus_emulator.player_index`, then call `_menus.reset()` and
    `_main_menu.init(i)`.
  - `PauseMenu.enabled = false` makes `pause()` do nothing.
- **Other pause triggers:** `InputService.game_lost_focus` (the window loses focus, a pad
  disconnects) reaches `main.gd :: _on_game_lost_focus` (connected in `_ready`) and
  `coop_shop.gd` (only while paused, to hand the menu to player 0). The default is
  `settings.pause_on_focus_lost = true`.
- The pause menu's `FocusEmulator` marks every event that is not its owner's UI action as
  handled, as on any co-op screen. Code that polls `Input` (movement, `main._check_for_pause`)
  is not affected by that.
- The confirm pages (`MenuRestart`, `MenuEndRun`, `MenuConfirm`) and the codex go back on the
  plain `ui_cancel`, and Esc is `ui_pause` and `ui_cancel` at once. Without the tree paused, the
  same key press reaches a page, the pause menu and `main`'s polling.
- **brotato:together:** a wave of an online session never pauses. A script extension of
  `PauseMenu` (`extensions/ui/pause_menu.gd`) adds a live mode that opens and closes the menu
  without touching `get_tree().paused`, and allows one step back per 200 ms because of the
  double meaning of Esc. `sync/pause_control.gd` decides when the live mode is on and who may
  pause in the shop and on the level-up panels.

### Menu pages

- `ui/menus/menus.gd` (`Menus`) is a `Control` whose children are full-screen pages, one of
  them visible.
  - `switch(from, to)` runs `to.show(); to.init(); from.hide()`, sets `_current_page` and emits
    `menu_page_switched`.
  - `back()` and `reset()` return to `_main_menu`.
  - The main page emits one signal per button, and `Menus` connects each to a `switch`.
  - Title screen: `TitleScreenMenus` (`TitleScreen._menus`). Its main page is
    `ui/menus/pages/main_menu.gd`, which resets `%ErrorLabel` and grabs the focus in `init()`,
    that is on every return.
  - Pause menu: `IngameMenus` (`PauseMenu._menus`), with the main page `IngameMainMenu`.
- A page has `init()`, a `back_button_pressed` or `cancel_button_pressed` signal, and an `_input`
  that goes back on the release of the plain `ui_cancel`.
  - It keeps `focus_before_created = get_focus_owner()` to give the focus back. With a
    `FocusEmulator` there is no Godot focus owner, so that value is null in co-op
    (`null.grab_focus()` is only ignored in release builds).
  - Buttons are plain `Button`s with `ui/menus/global/my_menu_button.gd` (sounds, focus on
    hover, `disabled` for 0.05 s after a press; `disable()` / `activate()`).
- The pause menu's `FocusEmulator` has `Menus` as a focus base, so the pausing player reaches
  any focusable control of any page under it.
- In character selection, `FocusEmulator1` has the grid, the run options box and Back as bases.
  The other emulators have only the grid.

### Menu echo

- `InputService._process` repeats held d-pad and left-stick directions as pressed
  `ui_*_<dev>` `InputEventAction`s (delay 0.3 s, interval 0.09 s), for the real pads `0..7`
  only. `set_gamepad_echo_processing` switches it; it is off during waves.
- Emulated actions are never released, so the base `ui_left` and its like can stay "pressed" in
  `Input` after stick navigation.

## 6. Mod loading (Steam build)

- Mod Loader 6.3.0 runs with the options profile `steam`: `enable_mods = true`,
  `steam_workshop_enabled = true`.
- `addons/mod_loader/mod_loader.gd :: _load_mod_zips()` loads **only subscribed Workshop items**
  when the workshop is enabled (`internal/third_party/steam.gd :: load_steam_workshop_zips`,
  filtered by `Platform.get_subscribed_mods()`). `<game>/mods` and `--mods-path` are ignored on
  Steam. [Releasing](releasing.md#trying-a-build-in-the-game) describes the development loop that
  follows from this.
- `mod_main.gd` is instantiated without `_init` arguments and added as a child of the
  `ModLoader` autoload, so it survives scene changes. Script extensions are applied after the
  `_init` of all mods.
- Before the first extension of a game script, the loader stores a backup of it with
  `script.duplicate()` in `ModLoaderStore.saved_scripts[path][0]`
  (`internal/script_extension.gd :: apply_extension`), unless `path` already has an entry. On a
  script whose class defines its own `duplicate()` (`Effect`, `ItemParentData`, `EnemyData` and other resources)
  Godot runs that method on the script instead: the boot log shows `ERROR: Can't call non-static
  function 'duplicate' in script.` and the backup is null. It is only read when a mod is disabled
  while the game runs. During the mods' `_init` the autoloads are not in the tree yet, but their
  names resolve. **brotato:together** stores the backup itself before installing such an extension
  (`extensions/script_backup.gd`).
- The log is `user://logs/modloader.log`.
- The built-in mods menu (`ui/menus/pages/mods/menu_mods.gd`) is read-only.

## 7. Steam and GodotSteam (`singletons/platforms/steam.gd`)

- The `Platform` autoload is a `SteamPlatform` when `OS.has_feature("steam")`. The game fetches
  the singleton with `Engine.get_singleton("Steam")`, never through the bare `Steam` identifier.
  The object is at `Platform._platform_impl.steam`.
- The game calls `steamInitEx(1942280, true)`. The second argument is GodotSteam's
  `embed_callbacks`. **brotato:together** never calls `run_callbacks()`, and its Steam signals
  fire (`net/steam_transport.gd`).
- The local Steam id is `Platform._platform_impl.steam_id` (int).
- The game uses no lobby, networking, rich presence or persona APIs.

## 8. Scene flow (co-op run)

1. `ui/menus/pages/main_menu.gd :: _on_StartButton_pressed` loads
   `ui/menus/run/character_selection.tscn`.
2. Character selection: `_on_selections_completed` -> `RunData.add_character`, then
   `ui/menus/run/weapon_selection.tscn`.
3. Weapon selection, then `ui/menus/run/difficulty_selection/difficulty_selection.tscn`.
4. Difficulty selection: `_on_element_pressed` loads `main.tscn` (the wave).
5. `main.gd :: _on_EndWaveTimer_timeout` shows `ui/menus/ingame/coop_upgrades_ui.tscn`
   (level-ups and crates).
6. `RunData.get_shop_scene_path()` gives `coop_shop.tscn`.
7. `base_shop.gd :: _on_GoButton_pressed`, once all players pressed Go, loads `main.tscn` again.
8. Steps 5 to 7 repeat until `coop_end_run.tscn`.

The scene paths are in `singletons/menu_data.gd`.

## 9. Where player state changes are applied

| Action | Applied in |
|---|---|
| Buy / steal | `base_shop.gd :: on_shop_item_bought` -> `RunData.remove_currency` + `buy_item` (`RunData.add_item_triggering_stat_gain_effects`) / `buy_weapon` (`RunData.add_weapon`) |
| Lock | `shop_item.gd :: change_lock_status` -> `RunData.lock_player_shop_item` / `unlock_player_shop_item` |
| Reroll | `base_shop.gd :: _on_RerollButton_pressed` -> `fill_shop_items` -> `ItemService.get_player_shop_items` |
| Combine / recycle | `RunData.combine_weapon` / `RunData.recycle_weapon` |
| Level-up pick | `main.gd :: on_upgrade_selected` -> `RunData.add_upgrade` |
| Crate | `main.gd :: on_item_box_take_button_pressed` / `_discard_` / `_ban_` |
| Go | `base_shop.gd :: _on_GoButton_pressed` (waits for all players) |

The random numbers are unseeded (`Utils._rng.randomize()`), so two machines cannot roll the
same shop or the same upgrades. **brotato:together** applies all of these on the host only.

## 10. Per-player run state

- `RunData.players_data[i]` is a `PlayerRunData` (`singletons/player_run_data.gd`,
  `extends Reference`). Its fields include `current_character`, `current_health`,
  `current_level`, `current_xp`, `gold` (the materials), `weapons`, `items`, `effects` (all
  stats, with **int-hash keys** `Keys.*_hash`), sets, upgrades and bans.
- **Save path, one player:** `PlayerRunData.serialize() -> Dictionary` and
  `PlayerRunData.new().deserialize(d)`. After replacing `players_data[i]`, the caches need
  `LinkedStats.reset_player(i)`, `Utils.reset_stat_cache(i)` and `RunData.reset_run_caches()`.
- **Save path, whole run:** `RunData.get_state()` and `RunData.resume_from_state(state)` (wave,
  zone, difficulty and so on).
- **There is no single "state changed" signal.** `add_item`, `remove_item`, `add_weapon`,
  `remove_weapon` and `apply_item_effects` emit nothing.
- **Stats:** `Utils.get_stat(hash, i)` is `RunData.get_stat` plus `TempStats` plus
  `LinkedStats`, cached per player. `RunData.stats_updated(i)` fires only for changes through
  `add_stat` / `remove_stat` and for temporary and linked stats.
- **Weapon slots** are `effects[Keys.weapon_slot_hash]` (default 6).
- **Item objects are shared.** Shop pools hand out `ItemService`'s own `ItemData` objects
  (`get_pool` copies the list, not the items), so one object can be in a player's `items`
  several times and in several players' lists. A resumed run has a copy per entry.
  `RunData.add_weapon` always copies. `RunData.remove_item` erases the item's appearances even
  when another copy stays.
- **brotato:together:** the host sends the run as the game's save code serializes it
  (`ProgressData.get_run_state`), split into parts, and a client applies it with
  `RunData.resume_from_state` (`sync/run_state_codec.gd`, `sync/run_parts.gd`). The host finds
  changes with a cheap fingerprint and serializes only when that moved, with a check once a
  second for what the fingerprint cannot see (`sync/run_cache.gd`).

## 11. Player nodes in a wave

- **Weapon nodes** are created once per wave in `Player.apply_items_effects()`
  (`entities/units/player/player.gd`), so a weapon added to the run in the middle of a wave has
  no node until the next wave.
- The only change of the weapon nodes in the middle of a wave is a removal:
  `Player.on_weapon_wanted_to_break` (signal `Weapon.wanted_to_break`, the `break_on_hit`
  effect, the brick of `abyssal_terrors`) erases the node from `current_weapons` and calls
  `RunData.remove_weapon_by_index`. Crates add to `RunData` after the wave.
- **Cursed weapons:** `Weapon._ready` frees every child of `Sprite/Muzzle` when `is_cursed` and puts
  the curse particles there. Molotov lists `Sprite/Muzzle/BurningParticles` in
  `throwned_projectile_hide`, which `RangedWeapon.on_projectile_shot` hides and shows by path on
  every throw: a cursed Molotov logs two `get_node` errors per throw, in solo too.
  **brotato:together** drops such paths after `_ready` (`extensions/weapons/fireball.gd`).
- **Move speed:** `Player.get_move_speed()` is (`current_stats.speed` + `bonus_speed` +
  `decaying_bonus_speed`) / (1 + `petrol_malus`). Petrol is set per physics frame
  (`update_petrol_effect`), and the slow decays in `Unit._physics_process`.
- **Movement:** a player is a `RigidBody2D` in `MODE_KINEMATIC` (layer 2, mask 130: players and
  layer 8 "obstacles", which are holes, `TileMap` and `TileMapLimits`).
  `Unit._physics_process` moves it with `test_motion(velocity * delta, true, 0.08)` and, when
  that hits, once more with the velocity slid along the normal. There is no `move_and_slide`
  anywhere. A tick along the edge of a hole can therefore move up to two steps.

## 12. Shop inventory and item popups

- `ui/menus/global/popup_manager.gd` (`BaseShop._popup_manager`) shows a player's `ItemPopup`
  for the focused gear element. On accept it focuses the popup (`_elements_pressed[p]`,
  `ItemPopup.focus()`, cursor on Cancel) when `ItemPopup.will_show_buttons_when_focused(item)`.
  - The game says yes only for weapons (`should_show_buttons`). `_update_button_visibilities`
    then asks `RunData.can_combine`, whose parameter is typed `WeaponData`, so buttons for an
    item need a branch of their own.
  - In co-op the popup is a `CoopItemPopup` (`coop_item_popup.tscn`, also one per player on the
    level-up screen). Its buttons are in `ItemPanelUI/MarginContainer/VBoxContainer` (Combine,
    Recycle, Cancel, Upgrade), and `_update_button_focus_neighbours` rebuilds their up and down
    neighbours. With two players, `_ready` replaces the popup's outer box.
- **Placement:** `BasePopup._process` calls `_reposition` every frame, which takes
  `_get_new_position(_attachment, _anchor_panel)`: below the item (above it from the parent
  rect's lower half) with `DIST` (10 px) between them, clamped to the parent rect, then shifted
  sideways by the item's width plus `DIST` (100 px for a `ButtonWithIcon`) if it still covers
  the item. An override of
  `_get_new_position` therefore holds every frame. **brotato:together** drops the vertical gap
  (`extensions/ui/coop_item_popup.gd`).
- **Closing:** the popup's `item_cancel_button_pressed` reaches
  `BaseShop._on_item_cancel_button_pressed` (`_popup_manager.reset_focus(p)`, cursor back on the
  element; `CoopShop` hides the dim screen). `ItemPopup._input` emits the signal on the player's
  `ui_cancel` while `_focused`.
- **Hook:** `_input` runs on every script level, the extension's first. A script extension that
  clears `_focused` there keeps the base from closing the popup on that press.
- `grab_focus()` on a control inside a player's panel moves that player's `FocusEmulator` (each
  has its own `CoopShopPlayerContainer` as focus base, through `gui_focus_changed`).
  `Inventory.remove_element` ends in one, so removing another player's element moves that
  player's cursor into its gear.
- **Gear rows:** `PlayerGearContainer.set_weapons_data` and `set_items_data` free every element
  and build new ones (`Inventory.clear_elements` removes them from the tree at once). Take a
  `FocusEmulator` off an element first. Plain items stack in one element (`current_number`).

## 13. Battlefield entities

- There are no gameplay groups and **no stable entity ids**. Everything is pooled
  (`main.gd :: get_node_from_pool` / `add_node_to_pool`, `Entity.free_entity()`).
- `global/entity_spawner.gd` has the lists `enemies`, `bosses`, `neutrals`, `structures` and
  `pets`, and `get_all_enemies()`. The spawn flow is `on_group_spawn_timing_reached` -> births
  -> `spawn_entity`. Its signals are `enemy_spawned` and `*_respawned`.
- The containers in `main.gd` are `%Entities` (YSort), `%PlayerProjectiles`,
  `%EnemyProjectiles`, `%Materials` (`_active_golds`, `spawn_gold`, `on_gold_picked_up`),
  `%Consumables` (`_consumables`) and `%Births`.
- Players are spawned in `EntitySpawner.init()`. `main.gd :: _on_EntitySpawner_players_spawned`
  stores them in `_players`.
- **Holes** (`global/gpe_spawner.gd`, children of `main._gpe_container`): `main._ready` calls
  `spawn_holes_full_scene()` when the wave data's `spawn_holes` is set. That loads a random
  layout scene from `holes_scene` / `holes_old_scene` / `holes_explorer_scene`, by map size.
  `Hole._ready` adds a forbidden circle to `ZoneService`. In the middle of a wave,
  `BrachiosaurusFoot._stomp` calls `spawn_single_hole_at_position`.
- **Hook:** `EntitySpawner.spawn_entity` covers both the first spawn and the respawn from the
  pool. An enemy's kind is its scene's `filename` plus its `enemy_id`.
- **brotato:together:** the host gives every node a net id of its own on each spawn and respawn
  from the pool, and at the latest when the node first enters a snapshot
  (`BattleHost._assign_net_id`, `sync/battle_host.gd`). The type sent with it is the scene's
  `filename`, with a tag where one scene stands for several things.

## 14. Battle lifecycle

- **Start:** `main.gd :: _ready` -> `RunData.on_wave_start`, `_wave_timer.start()`,
  `_wave_manager.init`, `_entity_spawner.init`.
- **End:** `_on_WaveTimer_timeout` -> `clean_up_room()` -> `_on_EndWaveTimer_timeout` -> the
  upgrades UI -> the shop scene. `main._end_wave_timer_timedout` is set while the level-up
  panels run.
- **Death:** `_on_player_died`.
- There is no run seed, and about 65 files use the global `randf()` / `randi()`. Lockstep
  simulation is therefore not viable; a host-authoritative design is.
- **Hook, switches that stop parts of the simulation:**
  - `WaveManager.set_physics_process(false)`.
  - `EntitySpawner._cleaning_up = true`, and stopping its `_structure_timer`.
  - Pausing `_wave_timer`, `HalfWaveTimer` and `EndWaveTimer`.
  - Per unit: `set_physics_process(false)` and the static body mode, `Hurtbox.disable()`,
    `Utils.disable_node(weapons_container)` and `Player.disable_gold_pickup()`.
- **brotato:together:** a client loads `main.tscn` and switches its simulation off. It stops the
  processing and the timers of `_wave_manager`, `_entity_spawner`, `_effect_behaviors` and
  `_stats_manager` (`BattleClient._freeze`, `sync/battle_client.gd`). Each unit becomes a puppet
  without physics, collisions or hit areas, placed from the host's snapshots
  (`PuppetEntity.puppetize`, `sync/puppet_entity.gd`).

## 15. DLC ownership and content

- All DLC content ships in the base `Brotato.pck`: `dlcs/dlc_1` is `abyssal_terrors`,
  `dlcs/dlc_2` is `primal_dread`, and the DLC items, characters, weapons and enemies are under
  `items/`, `entities/` and `zones/`.
- Ownership only gates **registration**. `ProgressData.check_for_available_dlcs()` fills
  `available_dlc_ids` from `Platform.is_dlc_owned()` (headless or without Steam: none). Then
  `ItemService.init_dlc_content()` runs `update.dlc_data.add_resources()` (backgrounds, title
  screen backgrounds, `entities` for the codex's enemy data, `effects` for the effect scripts).
  `DLCData.remove_resources()` undoes it.
- `ItemService.items`, `characters` and `weapons` are setget caches rebuilt from
  `update_data_list`, filtered by `available_dlc_ids` (`invalidate_*_cache()`).
  `_item_id_lookup`, `_weapon_id_lookup` and `_base_weapon_lookup` are lazy and never cleared by
  the game.
- `ItemService.init_unlocked_pool()` builds `_tiers_data` from
  `ProgressData.active_update_data`. That is the result of `refresh_active_update_data()`: the
  available DLCs minus `deactivated_update_data`. A resumed run applies its own
  `active_update_data_ids`.
- **Not gated:** `ZoneService.zones` (every zone; `zone.dlc_id` is checked by the zone selection
  UI), `ItemService.get_dlc_data_by_id()`, and scenes loaded by path.
- `ChallengeService.load_update_challenges()` skips the challenges of unowned DLCs once at
  startup.
- The DLC's drop consumables (poisoned, meca, mutant and mutation fruit, meca parts) are
  `DLCData` properties, not entries of `ItemService.consumables`.
- `available_dlc_ids` and `active_update_data` are not saved. `save()` writes the unlock lists,
  `difficulties_unlocked`, the stats, the run and `deactivated_update_data`
  (`ProgressData._set_loader_properties`).
