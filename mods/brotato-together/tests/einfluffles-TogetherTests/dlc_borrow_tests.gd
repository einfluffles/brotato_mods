extends Reference
# A client without one of the host's DLCs borrows it for the session (session/dlc_borrow.gd).
# Host and client share one process, so both sides are simulated: primal_dread is registered
# (as ItemService.init_dlc_content does for owners) while the host's run state is encoded, then
# unregistered the way ProgressData / ItemService look on a machine without it. Headless, Steam is
# missing, so the game owns no DLC; the harness's real state is put back at the end.
# Synchronous (no frame passes while the fake lobby is up), like session_lifecycle_tests.gd.
#  - without borrowing, the host's DLC character / items / weapons / effects / background are lost
#  - WELCOME's DLC list -> borrowed (validated), F9 note, run state round-trips, client lookups,
#    DLC consumable / enemy types render, enemy pillar puppets
#  - leaving / hosting / leaving client mode by any path: everything is exactly as before, and
#    nothing save() writes changed

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Compat := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/compat.gd")
const DlcBorrow := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/dlc_borrow.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const PuppetEntity := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/puppet_entity.gd"
)
const AnimMirror := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/anim_mirror.gd")
const MenuPuppet := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/menu_puppet.gd"
)
const SessionLifecycleTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/session_lifecycle_tests.gd"
)
const DLC := "primal_dread"  # last in ItemService.update_data_list: re-registers in place
const OTHER_DLC := "abyssal_terrors"
const DLC_ZONE := 2  # zone_3_jungle (dlc_id primal_dread)
const CONSUMABLE_SCENE := "res://items/consumables/consumable.tscn"
const DLC_ENEMY_SCENE := (
	"res://entities/units/enemies/jungle/basic/dilophosaurus/dilophosaurus.tscn"
)
# Enemy pillar (abyss enemies, colossus): its autoplay animation calls stop() from a method track.
const PILLAR_SCENE := "res://projectiles/pillar_enemy/pillar_projectile.tscn"
const LOCAL := 1
const HOST := 2
const LOBBY := 98

var _t: Node = null  # test runner: _check()
var _together: Node = null
var _steam = null  # SessionLifecycleTests.FakeSteam
var _update = null  # UpdateData of DLC


func run(t: Node, together: Node) -> void:
	_t = t
	_together = together
	var transport: Node = together.transport
	var saved := {
		"steam": transport.steam,
		"local_id": transport.local_id,
		"client_active": together._client_active,
		"zone": RunData.current_zone,
		"run_state": ProgressData.saved_run_state,
		"last_run_state": ProgressData.last_saved_run_state,
	}
	for update in ItemService.update_data_list:
		if update != null and update.id == DLC:
			_update = update
	if _update == null:
		_t._check(false, "%s update data found" % DLC)
		return
	_steam = SessionLifecycleTests.FakeSteam.new()
	transport.steam = _steam
	transport.local_id = LOCAL

	var harness_state := _stash_state()
	var harness_print := fingerprint()
	var was_owned: bool = DLC in ProgressData.available_dlc_ids
	if not was_owned:
		_own()
	var host_run := _host_run()
	_unown()
	_t._check(not fingerprint().dlc_char_known, "simulated client lacks %s" % DLC)
	_test_without_borrow(host_run)
	_test_validation()

	var before := fingerprint()  # the client's own state right before it joins
	var save_before := save_fingerprint()
	_test_borrowed_session(transport, host_run, before, save_before)
	_test_host_while_borrowed(transport, before)
	_test_safety_net(before)

	_restore_state(harness_state, was_owned)
	_t._check(fingerprint().hash() == harness_print.hash(), "DLC ownership simulation undone")
	transport.leave_lobby()
	transport.steam = saved.steam
	transport.local_id = saved.local_id
	transport.pending_join_id = 0
	together.session.peers.clear()
	together._client_active = saved.client_active
	ProgressData.saved_run_state = saved.run_state
	ProgressData.last_saved_run_state = saved.last_run_state
	together.get_node("TogetherMenu").close()
	RunData.reset()
	RunData.current_zone = saved.zone  # reset() keeps the zone; later battle tests use it


# Host: a 2-player run with the DLC's characters, weapon, items, zone and background.
func _host_run() -> Dictionary:
	var item_set = _update.item_set
	RunData.reset()
	RunData.set_coop_run(true)
	RunData.set_player_count(2)
	RunData.add_character(item_set.characters[0], 0)
	RunData.add_character(item_set.characters[1], 1)
	RunData.add_weapon(item_set.weapons[0], 0)
	RunData.add_item(item_set.items[0], 1)
	var effect_item = _item_with_dlc_effect()
	if effect_item is WeaponData:
		RunData.add_weapon(effect_item, 1)
	elif effect_item != null:
		RunData.add_item(effect_item, 0)
	RunData.current_zone = DLC_ZONE
	RunData.current_background = _update.dlc_data.backgrounds[0]
	return {
		"payload": bytes2var(var2bytes(RunStateCodec.encode()), false),
		"expected": _run_summary(),
		"effect_item": effect_item.my_id if effect_item != null else "",
	}


# An item whose effect script only the DLC registers (dropped by deserialization without it).
func _item_with_dlc_effect():
	for item in ItemService.items + ItemService.weapons:
		for effect in item.effects:
			if effect.get_script() in _update.dlc_data.effect_scripts:
				return item
	return null


func _run_summary() -> Dictionary:
	var players := []
	for i in RunData.get_player_count():
		var items := []
		var effect_count := 0
		for item in RunData.get_player_items(i):
			items.append(item.my_id)
			effect_count += item.effects.size()
		var weapons := []
		for weapon in RunData.get_player_weapons(i):
			weapons.append(weapon.my_id)
			effect_count += weapon.effects.size()
		players.append([RunData.get_player_character(i).my_id, items, effect_count, weapons])
	var background = RunData.current_background
	return {
		"players": players,
		"zone": RunData.current_zone,
		"background": background.name if background != null else "",
	}


func _test_without_borrow(host_run: Dictionary) -> void:
	var state := RunStateCodec.decode(host_run.payload)
	var first = state.players_data[0] if not state.empty() else null
	_t._check(
		first != null and first.current_character == null,
		"finding: without the DLC the host's DLC character is lost on the client"
	)
	var background = state.get("current_background")
	_t._check(
		background != null and background.name != host_run.expected.background,
		"finding: without the DLC the host's DLC background falls back"
	)


func _test_validation() -> void:
	var host_list := [DLC, DLC, OTHER_DLC, "bogus_dlc", "", 7, null]
	var expected := [DLC]
	if not ProgressData.is_dlc_available(OTHER_DLC):
		expected.append(OTHER_DLC)
	_t._check(DlcBorrow.missing(host_list) == expected, "only known DLC ids the client lacks")
	_t._check(DlcBorrow.missing("primal_dread").empty(), "malformed DLC list borrows nothing")
	_t._check(DlcBorrow.borrow(DlcBorrow.owned_ids()).empty(), "nothing to borrow when owned")
	_t._check(not DlcBorrow.is_active(), "owned DLC: no borrow state")
	_t._check(
		Puppet.DLC_BORROW_META_KEY == DlcBorrow.META_KEY, "save guard watches the borrow flag"
	)


func _test_borrowed_session(
	transport: Node, host_run: Dictionary, before: Dictionary, save_before: String
) -> void:
	var session: Node = _together.session
	var menu: Node = _together.get_node("TogetherMenu")
	var lent := DlcBorrow.missing([OTHER_DLC, DLC])  # in update_data_list order
	_join(transport, [DLC, OTHER_DLC, "bogus_dlc"])
	_t._check(
		DlcBorrow.borrowed_ids() == lent and DLC in lent,
		"WELCOME lends the host's missing DLC (%s)" % [DlcBorrow.borrowed_ids()]
	)
	_t._check(session.peers[HOST].ready, "client ready with the borrowed DLC")
	_t._check(ProgressData.is_dlc_available(DLC), "borrowed DLC registered")
	_t._check(not DLC in Compat.local_info("x").dlcs, "borrowed DLC never reported as owned")
	menu.open()
	_t._check(
		"Using the host's DLC for this session: " in menu.details_text()
		and "Primal Dread" in menu.details_text(),
		"F9 details note the borrowed DLC"
	)
	menu._refresh()
	_t._check(menu._host_button.disabled, "Host lobby disabled while a client")
	menu.close()
	_t._check(Puppet.blocks_progress(), "saves / challenges blocked while borrowed")
	_t._check(save_fingerprint() == save_before, "borrowing changes nothing save() writes")

	# Run state round trip + puppet run on the client.
	var state := RunStateCodec.decode(host_run.payload)
	_t._check(not state.empty(), "host run decodes while borrowed")
	if not state.empty():
		Puppet.set_active(true)
		RunStateCodec.apply(state)
		var actual := _run_summary()
		_t._check(
			str(actual) == str(host_run.expected),
			"DLC characters / items / weapons / zone / background round-trip: %s" % [actual]
		)
		_t._check(
			ZoneService.get_zone_data(RunData.current_zone).dlc_id == DLC, "host's DLC zone"
		)
		if host_run.effect_item == "":
			print("  info: no item or weapon with a DLC-only effect script found")
		else:
			print("  info: DLC-only effect script on %s" % host_run.effect_item)
	var menus = MenuPuppet.new()
	var char_id: String = _update.item_set.characters[0].my_id
	_t._check(menus._find_item(char_id) != null, "the selection screens know the DLC character")
	menus.free()
	_test_dlc_types()
	MusicManager.shuffled_tracks.append(_update.dlc_data.music_tracks[0])  # queue refilled

	transport.leave_lobby()
	_t._check(not DlcBorrow.is_active() and not Puppet.blocks_progress(), "leaving ends borrow")
	_expect_reverted(before, "after leaving")
	_t._check(save_fingerprint() == save_before, "nothing DLC-related saved after leaving")


# Enemy / consumable types the host announces: DLC scenes and drop data resolve on the client.
func _test_dlc_types() -> void:
	var client: Node = _together.battle_client
	var other_data = ItemService.get_dlc_data_by_id(OTHER_DLC)
	var fruits := [_update.dlc_data.meca_fruit, _update.dlc_data.mutation_fruit]
	fruits.append(other_data.poisoned_fruit)
	for i in fruits.size():
		var idx: int = 9000 + i
		client._define_type(idx, "%s#%s" % [CONSUMABLE_SCENE, fruits[i].my_id])
		var data = client._type_data.get(idx)
		_t._check(
			client._types.get(idx) is PackedScene and data != null and data.icon == fruits[i].icon,
			"DLC consumable %s renders with its own icon" % fruits[i].my_id
		)
	client._define_type(9100, DLC_ENEMY_SCENE)
	var enemy = client._types.get(9100).instance() if client._types.get(9100) != null else null
	_t._check(enemy is Entity, "DLC enemy scene loads by path")
	if enemy != null:
		enemy.free()
	for idx in [9000, 9001, 9002, 9100]:
		client._types.erase(idx)
		client._type_data.erase(idx)

	# Finding (DLC zones, not ownership): a puppet enemy pillar's autoplay "shoot" ends in stop(),
	# which returned it to the game's pool by a pool id clients don't have (script errors).
	var pillar: Node = load(PILLAR_SCENE).instance()
	_t.add_child(pillar)
	PuppetEntity.puppetize(pillar)
	var stripped: Animation = client._anim_mirror.strip_projectile(pillar)
	PuppetEntity.start_projectile_animation(pillar)
	var player: AnimationPlayer = pillar._animation_player
	var animation: Animation = player.get_animation(player.assigned_animation)
	_t._check(
		player.is_playing()
		and animation == stripped
		and not AnimMirror._has_method_tracks(animation),
		"puppet pillar plays its animation without method tracks"
	)
	player.advance(animation.length + 0.1)  # a stop() call would error (deferred: next frame)
	pillar.queue_free()


# F9 "Host lobby" while still a client (its button is disabled, but if it got pressed): leaves
# first, so the borrowed DLC is gone before the lobby exists.
func _test_host_while_borrowed(transport: Node, before: Dictionary) -> void:
	_join(transport, [DLC])
	_t._check(DlcBorrow.is_active(), "borrowed again on the next join")
	_steam.created = 0
	_together.get_node("TogetherMenu")._on_host_pressed()  # as if clicked anyway
	_t._check(_steam.created == 1 and not DlcBorrow.is_active(), "hosting reverts the borrow first")
	_expect_reverted(before, "before hosting")
	transport._on_lobby_created(1, LOBBY)
	_t._check(transport.is_host() and not DlcBorrow.is_active(), "host has no borrowed DLC")
	_t._check(not DLC in Compat.local_info("x").dlcs, "host reports only owned DLC")
	transport.leave_lobby()


# Any way out of client mode that skipped lobby_left: Session reverts on its next frame.
func _test_safety_net(before: Dictionary) -> void:
	DlcBorrow.borrow([DLC])
	_t._check(DlcBorrow.is_active(), "borrow state set outside a lobby")
	_together.session._process(0.0)
	_t._check(not DlcBorrow.is_active(), "not a client any more -> reverted")
	_expect_reverted(before, "by the safety net")


func _join(transport: Node, host_dlcs: Array) -> void:
	var session: Node = _together.session
	transport.lobby_id = LOBBY
	transport.host_id = HOST
	transport.members = [HOST]
	_steam.lobby_members = [LOCAL, HOST]
	session._on_lobby_ready(LOBBY, false)
	session._on_peer_joined(HOST)
	var welcome := {"version": Protocol.VERSION, "accepted": true, "reason": "", "dlcs": host_dlcs}
	var data := Protocol.encode(Protocol.Msg.WELCOME, bytes2var(var2bytes(welcome), false))
	_together._client_active = true  # peer_ready: no client view scene switch
	session._on_message_received(HOST, 0, data)
	_together._client_active = false  # leaving: no title screen scene switch


func _expect_reverted(before: Dictionary, when: String) -> void:
	var after := fingerprint()
	var changed := []
	for key in before:
		if str(after[key]) != str(before[key]):
			changed.append(key)
	_t._check(
		changed.empty(),
		"%s: DLC ids, registrations, item lists, pools, lookups, unlocks, music as before %s"
		% [when, changed]
	)


# --- client simulation ---


# What the game reads to decide what's registered and what save() writes from it.
func fingerprint() -> Dictionary:
	var char_id: String = _update.item_set.characters[0].my_id
	var result := {
		"dlc_char_known": ItemService.get_element_safe(ItemService.characters, char_id) != null,
		"music": str(MusicManager.shuffled_tracks).hash(),
		"items": str(ItemService.items).hash(),
		"characters": str(ItemService.characters).hash(),
		"weapons": str(ItemService.weapons).hash(),
	}
	for field in DlcBorrow.PROGRESS_FIELDS:
		result[field] = str(ProgressData.get(field)).hash()
	var lists := ["backgrounds", "title_screen_backgrounds", "entities", "effects"]
	for field in lists + DlcBorrow.ITEM_SERVICE_FIELDS:
		result[field] = str(ItemService.get(field)).hash()
	return result


# The save object without the run (that one is Puppet's: session/puppet.gd).
func save_fingerprint() -> String:
	var save: Dictionary = ProgressData.get_current_save_object()
	save.erase("current_run_state")
	return JSON.print(save)


func _stash_state() -> Dictionary:
	var stash := {"progress": {}, "items": {}}
	for field in DlcBorrow.PROGRESS_FIELDS:
		stash.progress[field] = ProgressData.get(field).duplicate()
	for field in DlcBorrow.ITEM_SERVICE_FIELDS:
		stash.items[field] = ItemService.get(field).duplicate(true)
	return stash


# This machine without DLC: unregistered like ItemService.init_dlc_content never ran for it.
func _own() -> void:
	ProgressData.available_dlc_ids.append(DLC)
	_update.dlc_data.add_resources()
	DlcBorrow._invalidate_item_lists()


func _unown() -> void:
	ProgressData.available_dlc_ids.erase(DLC)
	_update.dlc_data.remove_resources()
	for field in ["_item_id_lookup", "_weapon_id_lookup", "_base_weapon_lookup"]:
		ItemService.set(field, {})
	DlcBorrow._invalidate_item_lists()
	ProgressData.refresh_active_update_data()
	ItemService.init_unlocked_pool()


func _restore_state(stash: Dictionary, was_owned: bool) -> void:
	if was_owned:
		_update.dlc_data.add_resources()
	for field in stash.progress:
		DlcBorrow._assign(ProgressData, field, stash.progress[field])
	for field in stash.items:
		ItemService.set(field, stash.items[field])
	DlcBorrow._invalidate_item_lists()
