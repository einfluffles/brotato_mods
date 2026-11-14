extends Reference
# The shop that runs on the clients themselves (sync/shop_sync.gd, shop_intents.gd,
# shop_local.gd). Host: a remote player's intent is only applied to what its panel offers right
# now (revision + identity), by the game's own code, and its raw buttons stay off the host's
# copy. Client: the own panel takes local input and sends intents without changing anything
# here (gold, items, locks, slots, Go), the other panels are dead, and a panel is only rebuilt
# when its part of the state changed.
# Called from mod_main.gd after the shop loopback (needs its two-player run); checks go
# through its _check.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const ShopIntents := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/shop_intents.gd"
)
const BIT_ACCEPT := 1
const BIT_INFO := 1 << 3
const REMOTE := 1  # the remote player's slot on the host
const PISTOL := "weapon_pistol_1"

var _t: Node = null
var _sync: Node = null
var _input: Node = null
var _shop: Node = null
var _states := {}  # name -> SHOP_STATE body as a client receives it


func run(t: Node, together: Node):
	_t = t
	_sync = together.shop_sync
	_input = together.input_sync
	_sync.set_process(false)  # driven by hand (no Steam session)
	var saved_players: Array = CoopService.connected_players.duplicate(true)
	var saved_devices: Dictionary = _input.devices.duplicate()
	var saved_hold: bool = ProgressData.settings.holding_button
	yield(_host_part(together), "completed")
	yield(_client_part(together), "completed")
	ProgressData.settings.holding_button = saved_hold
	_input.devices = saved_devices
	CoopService.connected_players = saved_players
	Puppet.set_active(false)
	_sync.set_process(true)


# --- host: player 1 is remote (virtual device), player 0 local ---


func _host_part(together: Node):
	CoopService.connected_players.clear()
	CoopService.connected_players.push_back([0, CoopService.PlayerType.GAMEPAD_XBOX])
	CoopService.connected_players.push_back([_t.DEVICE, CoopService.PlayerType.GAMEPAD_XBOX])
	_input.devices[_t.FAKE_PEER] = _t.DEVICE
	var pistol = _t._find_by_id(ItemService.weapons, PISTOL)
	for p in 2:
		RunData.players_data[p].weapons.clear()
		var count := 3 if p == REMOTE else 2
		for _i in count:
			RunData.add_weapon(pistol, p)
		RunData.add_gold(3000, p)
	_t.get_tree().change_scene(RunData.get_shop_scene_path())
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	_shop = _t.get_tree().current_scene
	_sync._host_shop = _shop
	_sync._shop_id = 11
	_capture("start")
	var start: Dictionary = _states.start
	_t._check(_sync._player_index_of(_t.FAKE_PEER) == REMOTE, "host knows the peer's player")
	_t._check(
		start.seqs.size() == 2 and start.seqs[REMOTE] > 0 and start.pages == [0, 0],
		"shop state carries a revision and page per player (%s, %s)" % [start.seqs, start.pages]
	)
	yield(_host_blocked_buttons(together), "completed")
	_host_focus()
	_host_rejections()
	yield(_host_slot_intents(), "completed")
	yield(_host_weapon_intents(), "completed")
	_host_ready_intents()
	_capture("remote_changed")  # only the remote player's part differs from "start"
	RunData.add_weapon(pistol, 0)
	_capture("own_gear_changed")
	_input.devices.erase(_t.FAKE_PEER)


func _host_blocked_buttons(together: Node):
	_input._remote.erase(_t.FAKE_PEER)
	_t._send(_input, Vector2.ZERO, Vector2.ZERO, 0)  # first packet: nothing held
	_sync._block_remote_buttons(true)
	var pause_bit: int = 1 << VirtualDevices.PAUSE_INDEX
	_t._check(
		_input.blocked_mask() & BIT_ACCEPT != 0 and _input.blocked_mask() & pause_bit == 0,
		"shop blocks remote buttons on the host, except pause"
	)
	together.upgrades_sync._block_remote_buttons(false)  # what it does every frame in a shop
	_t._check(_input.blocked_mask() & BIT_ACCEPT != 0, "the level-up panels don't lift the block")
	var gold: int = RunData.get_player_gold(REMOTE)
	_t._send(_input, Vector2.ZERO, Vector2.ZERO, 0)
	_t._send(_input, Vector2.ZERO, Vector2.ZERO, BIT_ACCEPT)
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	_t._check(
		not Input.is_action_pressed("ui_accept_%s" % _t.DEVICE),
		"remote accept never reaches the host's shop"
	)
	_t._check(RunData.get_player_gold(REMOTE) == gold, "and buys nothing there")
	_t._send(_input, Vector2.ZERO, Vector2.ZERO, 0)
	_sync._block_remote_buttons(false)
	_t._check(_input.blocked_mask() == 0, "block lifted")
	_t._send(_input, Vector2.ZERO, Vector2.ZERO, BIT_INFO)
	yield(_t.get_tree(), "idle_frame")
	_t._check(Input.is_action_pressed("ui_info_%s" % _t.DEVICE), "remote buttons back afterwards")
	_t._send(_input, Vector2.ZERO, Vector2.ZERO, 0)
	yield(_t.get_tree(), "idle_frame")
	_input._remote.erase(_t.FAKE_PEER)


# A remote player's own cursor and page, shown on the host.
func _host_focus() -> void:
	var panel = _shop._get_coop_player_container(REMOTE)
	var emulator = Utils.get_focus_emulator(REMOTE, _shop)
	var node = _node(REMOTE, 2)
	ShopIntents.apply_focus(_shop, REMOTE, 0, ScenePaths.path_of(node._button, panel))
	_t._check(emulator.focused_control == node._button, "host shows a remote shop cursor")
	_t._check(_shop._focused_shop_item[REMOTE] == node, "and the game follows it (focused item)")
	ShopIntents.apply_focus(_shop, REMOTE, 1, PoolIntArray())
	_t._check(panel.carousel.index == 1, "host shows a remote player's shop page")
	ShopIntents.apply_focus(_shop, REMOTE, 0, ["junk"])
	_t._check(panel.carousel.index == 0, "page back, junk path ignored")


func _host_rejections() -> void:
	var slot := _pick(REMOTE)
	var id: String = _node(REMOTE, slot).item_data.my_id
	var before := _run_view(_shop)
	_t._check(not _apply("buy", slot, id, -1, -1), "stale shop revision dropped")
	_t._check(not _apply("buy", slot, "item_does_not_exist"), "item the panel doesn't offer dropped")
	_t._check(not _apply("fly", slot, id), "unknown kind dropped")
	_t._check(not _sync.host_apply_intent(_shop, REMOTE, {"kind": "buy", "slot": "1"}), "junk dropped")
	_t._check(not _sync.host_apply_intent(_shop, 5, _intent("buy", slot, id)), "unknown player")
	_t.get_tree().paused = true
	_t._check(not _apply("buy", slot, id), "nothing is applied while the host is paused")
	_t.get_tree().paused = false
	_t._check(_run_view(_shop) == before, "rejected shop intents changed nothing")


func _host_slot_intents():
	# Lock / unlock: wanted states, applied once, no new revision.
	var slot := _pick(REMOTE)
	var node = _node(REMOTE, slot)
	var id: String = node.item_data.my_id
	var seq: int = _seq()
	_t._check(_apply("lock", slot, id, 1), "lock applied by intent")
	_t._check(
		node.locked and RunData.get_player_locked_shop_items(REMOTE).size() == 1,
		"host locked the item"
	)
	_t._check(not _apply("lock", slot, id, 1), "locking a locked item does nothing")
	_t._check(_apply("lock", slot, id, 0), "unlock applied by intent")
	_t._check(RunData.get_player_locked_shop_items(REMOTE).empty(), "host unlocked the item")
	_t._check(_seq() == seq, "locks leave the revision alone")

	# Buy: identity wins over a wrong index; the same press twice applies once.
	var other_slot := (slot + 1) % 4
	var others := _slots(0)
	var gold: int = RunData.get_player_gold(REMOTE)
	var press := _intent("buy", other_slot if _node(REMOTE, other_slot).active else -1, id)
	_t._check(_sync.host_apply_intent(_shop, REMOTE, press), "buy applied (found by identity)")
	_t._check(_seq() > seq, "an applied press makes the revision stale at once")
	yield(_frames(2), "completed")
	_t._check(
		not node.active and RunData.get_player_gold(REMOTE) < gold, "host bought the named item"
	)
	_t._check(_slots(0) == others, "the other player's panel untouched")
	_t._check(not _sync.host_apply_intent(_shop, REMOTE, press), "the same buy twice applies once")
	yield(_buy_delay(), "completed")

	# Reroll.
	seq = _seq()
	gold = RunData.get_player_gold(REMOTE)
	var reroll := _intent("reroll")
	_t._check(_sync.host_apply_intent(_shop, REMOTE, reroll), "reroll applied by intent")
	_t._check(
		_shop._reroll_count[REMOTE] == 1 and RunData.get_player_gold(REMOTE) <= gold,
		"host rerolled once"
	)
	_t._check(not _sync.host_apply_intent(_shop, REMOTE, reroll), "a second reroll needs a new press")
	_t._check(_shop._reroll_count[REMOTE] == 1 and _seq() > seq, "rerolled panel has a new revision")

	# Steal: only with a steal left; costs nothing.
	slot = _pick(REMOTE)
	node = _node(REMOTE, slot)
	id = node.item_data.my_id
	_t._check(not _apply("steal", slot, id), "no steal without the effect")
	_shop._item_steals[REMOTE] = 1
	_shop._get_shop_items_container(REMOTE).item_steals = 1
	gold = RunData.get_player_gold(REMOTE)
	_t._check(_apply("steal", slot, id), "steal applied by intent")
	yield(_frames(2), "completed")
	_t._check(
		(
			not node.active
			and _shop._item_steals[REMOTE] == 0
			and RunData.get_player_gold(REMOTE) >= gold
		),
		"host stole the item for free"
	)
	yield(_buy_delay(), "completed")

	# Ban: dead while the game doesn't offer it; the container checks the token.
	slot = _pick(REMOTE)
	node = _node(REMOTE, slot)
	id = node.item_data.my_id
	var data = RunData.players_data[REMOTE]
	if node._ban_button.disabled:
		_t._check(not _apply("ban", slot, id), "no ban while the game doesn't offer it")
	data.remaining_ban_token = 1
	node._ban_button.activate()
	_t._check(_apply("ban", slot, id), "ban applied by intent")
	_t._check(
		(
			not node.active
			and data.remaining_ban_token == 0
			and data.banned_items.has(node.item_data.my_id_hash)
		),
		"host banned the item and spent the token"
	)
	yield(_host_dismantle(), "completed")


# Meca weapons only exist with the DLC: a pistol marked as one stands in for the checks.
func _host_dismantle():
	var slot := _pick(REMOTE)
	var node = _node(REMOTE, slot)
	var weapon = _t._find_by_id(ItemService.weapons, PISTOL).duplicate()
	weapon.is_meca = true
	weapon.meca_power = 1
	var offered: Array = _shop._shop_items[REMOTE]
	for entry in offered:
		if entry[0] == node.item_data:
			entry[0] = weapon
	node.set_shop_item(weapon, node.wave_value)
	var effects: Dictionary = RunData.get_player_effects(REMOTE)
	var evolution = effects.get(Keys.stat_evolution_hash, 0)
	effects[Keys.stat_evolution_hash] = 0
	_t._check(not _apply("dismantle", slot, weapon.my_id), "no dismantle without the effect")
	effects[Keys.stat_evolution_hash] = 1
	var gold: int = RunData.get_player_gold(REMOTE)
	_t._check(_apply("dismantle", slot, weapon.my_id), "dismantle applied by intent")
	yield(_frames(1), "completed")
	_t._check(
		not node.active and RunData.get_player_gold(REMOTE) < gold, "host dismantled the weapon"
	)
	effects[Keys.stat_evolution_hash] = evolution


func _host_weapon_intents():
	var count: int = RunData.get_player_weapons(REMOTE).size()
	_t._check(not _apply("combine", 0, "weapon_does_not_exist"), "weapon the player lacks dropped")
	_t._check(not _apply("combine", 0, PISTOL, -1, -1), "stale weapon intent dropped")
	_t._check(_apply("combine", 0, PISTOL), "combine applied by intent")
	yield(_frames(1), "completed")
	var ids := _weapon_ids(REMOTE)
	_t._check(
		ids.size() == count - 1 and "weapon_pistol_2" in ids, "host combined two pistols %s" % [ids]
	)
	var gold: int = RunData.get_player_gold(REMOTE)
	_t._check(_apply("discard", 7, PISTOL), "recycle applied (found by identity)")
	yield(_frames(1), "completed")
	_t._check(
		not (PISTOL in _weapon_ids(REMOTE)) and RunData.get_player_gold(REMOTE) > gold,
		"host recycled the weapon"
	)


func _host_ready_intents() -> void:
	var pressed: Array = _shop._player_pressed_go_button
	_t._check(_apply("go", -1, "", 1, -9), "Go applied, whatever the revision")
	_t._check(pressed[REMOTE] and not pressed[0], "host marked the remote player ready")
	_t._check(not _apply("go", -1, "", 1), "ready twice changes nothing")
	_t._check(_shop == _t.get_tree().current_scene, "the shop waits for the other player")
	_t._check(_apply("go", -1, "", 0) and not pressed[REMOTE], "not ready again by intent")
	var endless = _shop._get_coop_player_container(REMOTE)._endless_button
	_t._check(not _apply("endless", -1, "", 1), "no endless toggle while the game hides it")
	endless.visible = true
	_t._check(_apply("endless", -1, "", 1) and RunData.is_endless_run, "endless on by intent")
	_t._check(_apply("endless", -1, "", 0) and not RunData.is_endless_run, "endless off by intent")
	endless.visible = false


# --- client: becomes player 0 of the host's shop ---


func _client_part(together: Node):
	var local = _sync.local
	var focus_sync: Node = together.focus_sync
	_sync._client_shop_id = 0
	_sync._on_state(_states.start)
	yield(_sync, "shop_entered")
	yield(_frames(2), "completed")
	var shop: Node = _sync._client_shop
	_shop = shop
	var emulator = Utils.get_focus_emulator(0, shop)
	_t._check(local.active and local.you == 0, "own shop panel runs locally")
	_t._check(
		_input._local_buttons != null and _input._local_buttons.device == _t.DEVICE,
		"local buttons drive the own slot's device in the shop"
	)
	_t._check(focus_sync.local_emulators == [emulator], "own shop cursor is not the host's")
	var before := _run_view(shop)

	# Buy with the own device's accept: an intent, and nothing bought here.
	var slot := _pick(0)
	var node = _node(0, slot)
	emulator.focused_control = node._button
	yield(_tap("ui_accept"), "completed")
	var sent: Dictionary = local.last_intent
	_t._check(
		sent.get("kind") == "buy" and sent.get("slot") == slot and sent.get("id") == node.item_data.my_id,
		"buying sends an intent (%s)" % [sent]
	)
	_t._check(sent.get("seq") == _states.start.seqs[0], "intent names the shop panel's revision")
	_t._check(_run_view(shop) == before, "nothing bought locally")

	# The lock shortcut ends in ShopItem.change_lock_status, with no signal in between.
	yield(_tap("ui_select"), "completed")
	sent = local.last_intent
	_t._check(sent.get("kind") == "lock" and sent.get("arg") == 1, "lock shortcut sends an intent")
	_t._check(not node.locked and _run_view(shop) == before, "nothing locked locally")
	shop._item_steals[0] = 1  # the same shortcut steals when the player has a steal
	yield(_tap("ui_select"), "completed")
	_t._check(local.last_intent.get("kind") == "steal", "steal shortcut sends an intent")
	shop._item_steals[0] = 0
	_t._check(node.active and _run_view(shop) == before, "nothing stolen locally")

	shop._get_reroll_button(0).emit_signal("pressed")
	_t._check(local.last_intent.get("kind") == "reroll", "reroll sends a shop intent")
	shop._get_go_button(0).emit_signal("pressed")
	sent = local.last_intent
	_t._check(sent.get("kind") == "go" and sent.get("arg") == 1, "Go sends an intent")
	_t._check(_run_view(shop) == before, "no local reroll, no local Go")
	_t._check(_t.get_tree().current_scene == shop, "the client never leaves the shop on its own")
	node._dismantle_button.activate()
	node._on_DismantleButton_pressed()
	_t._check(local.last_intent.get("kind") == "dismantle", "dismantle sends an intent")
	yield(_client_ban(node, before), "completed")
	_client_popup(shop, before)
	_client_other_panel(shop, before)
	yield(_client_view(together, emulator, node), "completed")
	yield(_client_states(emulator, node), "completed")

	# The host pauses: nothing runs here meanwhile. Leaving the shop ends local control.
	local.set_paused(true)
	_t._check(_input._local_buttons == null, "local buttons off while the host is paused")
	local.set_paused(false)
	_t._check(_input._local_buttons != null, "and back on afterwards")
	local.leave(shop)
	_t._check(
		not local.active and _input._local_buttons == null and focus_sync.local_emulators.empty(),
		"local control ends with the shop"
	)


# Hold-to-ban keeps its local bar and sends the intent when the hold completes.
func _client_ban(node: Node, before: String):
	var local = _sync.local
	node._ban_button.activate()
	ProgressData.settings.holding_button = false
	local.last_intent = {}
	node._release_BanButton()
	_t._check(local.last_intent.get("kind") == "ban", "ban sends an intent")
	ProgressData.settings.holding_button = true
	local.last_intent = {}
	node._on_BanButton_button_down()
	for _i in 5:
		yield(_t.get_tree(), "physics_frame")
	_t._check(
		node._progress_ban.value > 0.0 and local.last_intent.empty(),
		"the hold fills its bar locally, no intent yet"
	)
	var deadline := OS.get_ticks_msec() + 4000
	while local.last_intent.empty() and OS.get_ticks_msec() < deadline:
		yield(_t.get_tree(), "idle_frame")
	_t._check(local.last_intent.get("kind") == "ban", "the completed hold sends the ban")
	yield(_frames(2), "completed")  # the ban animation puts the panel back
	_t._check(node.active and _run_view(_shop) == before, "nothing banned locally")


func _client_popup(shop: Node, before: String) -> void:
	var local = _sync.local
	var popup = shop._get_item_popup(0)
	var weapon = RunData.get_player_weapons(0)[1]
	popup.emit_signal("item_combine_button_pressed", weapon)
	var sent: Dictionary = local.last_intent
	_t._check(
		sent.get("kind") == "combine" and sent.get("slot") == 1 and sent.get("id") == PISTOL,
		"combining sends an intent (%s)" % [sent]
	)
	popup.emit_signal("item_discard_button_pressed", weapon)
	_t._check(local.last_intent.get("kind") == "discard", "recycling sends an intent")
	local.last_intent = {}
	popup.emit_signal("item_meca_upgrade_selected", weapon, weapon)
	_t._check(
		local.last_intent.empty() and popup._upgrade_button == null,
		"the popup's meca upgrade fails closed"
	)
	_t._check(_run_view(shop) == before, "no weapon changed locally")


func _client_other_panel(shop: Node, before: String) -> void:
	var local = _sync.local
	var other = _node(REMOTE, _pick(REMOTE))
	local.last_intent = {}
	other.emit_signal("buy_button_pressed", other)
	other.emit_signal("steal_button_pressed", other)
	other.emit_signal("ban_item_pressed", other)
	other.change_lock_status(true)
	shop._get_reroll_button(REMOTE).emit_signal("pressed")
	shop._get_go_button(REMOTE).emit_signal("pressed")
	shop._get_item_popup(REMOTE).emit_signal(
		"item_discard_button_pressed", RunData.get_player_weapons(REMOTE)[0]
	)
	_t._check(
		local.last_intent.empty() and _run_view(shop) == before,
		"another player's shop panel decides nothing here"
	)


# The own cursor moves here and is reported; the host's cursor for it is never applied.
func _client_view(together: Node, emulator: Node, node: Node):
	var local = _sync.local
	var shop: Node = _shop
	emulator.focused_control = node._button
	for action in ["ui_right", "ui_left", "ui_down"]:
		if emulator.focused_control == node._button:
			yield(_tap(action), "completed")
	_t._check(emulator.focused_control != node._button, "own shop cursor moves locally")
	local._sent_focus = ""
	local.process()
	var path := ScenePaths.path_of(emulator.focused_control, shop._get_coop_player_container(0))
	_t._check(
		not path.empty() and var2str(path) in local._sent_focus, "own shop cursor reported to the host"
	)
	var focus_sync: Node = together.focus_sync
	var own_cursor = emulator.focused_control
	focus_sync._scene = shop
	var go_path := ScenePaths.path_of(shop._get_go_button(0), shop)
	focus_sync._apply(
		{"scene": shop.filename, "cursors": [[ScenePaths.path_of(emulator, shop), 0, go_path]]}
	)
	_t._check(emulator.focused_control == own_cursor, "host cursor never moves the own shop cursor")


# Only what changed is rebuilt; Go is the host's flag, kept while the cursor rests on it.
func _client_states(emulator: Node, node: Node):
	var local = _sync.local
	var shop: Node = _shop
	var gear = shop._get_gear_container(0)
	var weapons: Node = gear.weapons_container._elements
	var element = weapons.get_child(0)
	var own_data = RunData.players_data[0]
	node.effect_choice_selected = 1  # marker: set_shop_item resets it
	_sync._on_state(_states.remote_changed)
	_t._check(
		node.effect_choice_selected == 1 and weapons.get_child(0) == element,
		"own panel not rebuilt when only another player's part changed"
	)
	_t._check(RunData.players_data[0] == own_data, "and its run objects stay the same")
	_t._check(
		not (PISTOL in _weapon_ids(REMOTE)) and "weapon_pistol_2" in _weapon_ids(REMOTE),
		"the other player's panel shows the host's state %s" % [_weapon_ids(REMOTE)]
	)
	_t._check(local.seq == _states.remote_changed.seqs[0], "own revision follows the host")

	emulator.focused_control = element
	_sync._on_state(_states.own_gear_changed)
	var cursor = emulator.focused_control
	_t._check(
		weapons.get_child_count() == 3 and is_instance_valid(cursor) and cursor.get_parent() == weapons,
		"own gear rebuilt, the cursor stays on a weapon"
	)
	yield(_frames(2), "completed")

	var ready: Dictionary = _states.own_gear_changed.duplicate()
	ready.go = [true, false]
	local.last_intent = {}
	_sync._on_state(ready)
	local.process()
	_t._check(
		local.last_intent.get("kind") == "go" and local.last_intent.get("arg") == 0,
		"ready with the cursor elsewhere is taken back (%s)" % [local.last_intent]
	)
	emulator.focused_control = shop._get_go_button(0)
	local.last_intent = {}
	_sync._on_state(ready)
	local.process()
	_t._check(
		shop._player_pressed_go_button[0] and local.last_intent.empty(),
		"ready stays while the cursor rests on Go"
	)
	emulator.focused_control = node._button
	local.process()
	_t._check(
		not shop._player_pressed_go_button[0] and local.last_intent.get("arg") == 0,
		"leaving Go tells the host"
	)


# --- helpers ---


func _capture(name: String) -> void:
	var body: Dictionary = bytes2var(var2bytes(_sync._shop_body()), false)
	body["you"] = 0
	_states[name] = body


func _intent(kind: String, slot := -1, id := "", arg := -1, seq_offset := 0) -> Dictionary:
	var intent := {
		"shop_id": _sync._shop_id,
		"seq": _seq() + seq_offset,
		"kind": kind,
		"slot": slot,
		"id": id,
		"arg": arg,
	}
	return bytes2var(var2bytes(intent), false)


func _apply(kind: String, slot := -1, id := "", arg := -1, seq_offset := 0) -> bool:
	return _sync.host_apply_intent(_shop, REMOTE, _intent(kind, slot, id, arg, seq_offset))


func _seq() -> int:
	_sync._update_seqs(_shop)
	return _sync._seqs[REMOTE]


func _node(p: int, slot: int) -> Node:
	return _shop._get_shop_items_container(p).get_shop_item_node(slot)


func _slots(p: int) -> Array:
	return _t._shop_slots(_shop, p)


# An offered slot of player p, an item rather than a weapon when there is one (no weapon
# slot rules), whose id no other slot of that player repeats.
func _pick(p: int) -> int:
	var ids := _slots(p)
	var fallback := -1
	for slot in ids.size():
		if ids[slot] == "-" or ids.count(ids[slot]) > 1:
			continue
		if _node(p, slot).item_data.get_category() == Category.ITEM:
			return slot
		fallback = slot
	return fallback


func _weapon_ids(p: int) -> Array:
	var ids := []
	for weapon in RunData.get_player_weapons(p):
		ids.append(weapon.my_id)
	return ids


# Everything a decision could change, as the scene and RunData have it.
func _run_view(shop: Node) -> String:
	var view := []
	for p in RunData.get_player_count():
		var data = RunData.players_data[p]
		var locked := []
		for entry in RunData.get_player_locked_shop_items(p):
			locked.append(entry[0].my_id)
		view.append(
			[
				RunData.get_player_gold(p),
				_weapon_ids(p),
				RunData.get_player_items(p).size(),
				locked,
				_t._shop_slots(shop, p),
				shop._player_pressed_go_button[p],
				shop._reroll_count[p],
				data.remaining_ban_token,
				data.banned_items.size(),
			]
		)
	return var2str(view)


# ShopItemsContainer ignores presses for 0.05 s after a buy, steal or dismantle (headless frames
# are uncapped, so frames don't wait that long).
func _buy_delay():
	yield(_t.get_tree().create_timer(0.1), "timeout")


func _frames(count: int):
	for _i in count:
		yield(_t.get_tree(), "idle_frame")


func _tap(action: String):
	for pressed in [true, false]:
		VirtualDevices.press_button("%s_%s" % [action, _t.DEVICE], _t.DEVICE, pressed)
		yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
