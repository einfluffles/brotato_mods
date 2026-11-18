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
const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const FocusSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/focus_sync.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const CursorTargetTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/cursor_target_tests.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const ShopIntents := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/shop_intents.gd"
)
const BIT_ACCEPT := 1
const BIT_INFO := 1 << 3
const REMOTE := 1  # the remote player's slot on the host
const ShopMecaTests := preload("res://mods-unpacked/einfluffles-TogetherTests/shop_meca_tests.gd")
const ShopStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_stream_tests.gd"
)
const ShopLockTests := preload("res://mods-unpacked/einfluffles-TogetherTests/shop_lock_tests.gd")
const ShopTextTests := preload("res://mods-unpacked/einfluffles-TogetherTests/shop_text_tests.gd")
const ShopModIntentTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_mod_intent_tests.gd"
)
const ShopGearTests := preload("res://mods-unpacked/einfluffles-TogetherTests/shop_gear_tests.gd")
const PISTOL := "weapon_pistol_1"
const ShopPopupMouseTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_popup_mouse_tests.gd"
)
const WheelScrollTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/wheel_scroll_tests.gd"
)

var _t: Node = null
var _sync: Node = null
var _input: Node = null
var _shop: Node = null
var _states := {}  # name -> RUN_SHOP body as a client receives it
var _meca = ShopMecaTests.new()  # kept alive across its yields
var _locks = ShopLockTests.new()
var _texts = ShopTextTests.new()
var _wheel = null  # WheelScrollTests, kept alive across its yields
var _mods = ShopModIntentTests.new()
var _gear = ShopGearTests.new()  # kept alive across its yields
var _popups = ShopPopupMouseTests.new()  # kept alive across its yields


func run(t: Node, together: Node):
	_t = t
	_sync = together.shop_sync
	_input = together.input_sync
	_wheel = WheelScrollTests.new(t)
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
	_sync._host_shop = null  # set by hand in _host_part: the host shop is gone
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
	ShopGearTests.host_anvil(self)
	_capture("start")
	var start: Dictionary = _states.start
	_t._check(_sync._player_index_of(_t.FAKE_PEER) == REMOTE, "host knows the peer's player")
	_t._check(
		start.seqs.size() == 2 and start.seqs[REMOTE] > 0 and start.pages == [0, 0],
		"shop state carries a revision and page per player (%s, %s)" % [start.seqs, start.pages]
	)
	yield(_host_blocked_buttons(together), "completed")
	_host_focus()
	var players := WheelScrollTests.as_keyboard_player(0)
	var panels := [_shop._get_coop_player_container(0), _shop._get_coop_player_container(REMOTE)]
	yield(_wheel.check_wheel("shop, host", panels[0], panels[1]), "completed")
	var scroller: Node = together.scroll_sync
	yield(
		_wheel.check_sync("shop, host", scroller, _shop, panels[0], panels[1], [0, REMOTE]),
		"completed"
	)
	CoopService.connected_players = players
	_host_rejections()
	yield(_host_slot_intents(), "completed")
	yield(_host_weapon_intents(), "completed")
	_host_ready_intents()
	_mods.host(self)
	yield(_gear.host(self), "completed")
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
	# Described on the sender, a Damage-Meter-like button next to reroll on the host only.
	var target := FocusTargets.describe(node._button, _shop, REMOTE)
	var reroll: Node = _shop._get_reroll_button(REMOTE)
	var extra := Button.new()
	reroll.get_parent().add_child(extra)
	reroll.get_parent().move_child(extra, reroll.get_index())
	ShopIntents.apply_focus(_shop, REMOTE, 0, target)
	_t._check(emulator.focused_control == node._button, "host shows a remote shop cursor")
	_t._check(_shop._focused_shop_item[REMOTE] == node, "and the game follows it (focused item)")
	ShopIntents.apply_focus(_shop, REMOTE, 0, FocusTargets.describe(reroll, _shop, REMOTE))
	_t._check(emulator.focused_control == reroll, "remote cursor on reroll, next to another mod's")
	extra.get_parent().remove_child(extra)
	extra.free()
	var own_target := FocusTargets.describe(_shop._get_reroll_button(0), _shop)
	ShopIntents.apply_focus(_shop, REMOTE, 0, own_target)
	_t._check(emulator.focused_control == reroll, "a target in another player's panel ignored")
	_t._check(
		FocusTargets.describe(_shop._get_reroll_button(0), _shop, REMOTE).empty(),
		"a client reports nothing outside its own panel"
	)
	ShopIntents.apply_focus(_shop, REMOTE, 0, target)
	ShopIntents.apply_focus(_shop, REMOTE, 1, [])
	_t._check(panel.carousel.index == 1, "host shows a remote player's shop page")
	ShopIntents.apply_focus(_shop, REMOTE, 0, ["junk"])
	_t._check(panel.carousel.index == 0, "page back, junk target ignored")
	_shop_targets()


# Every kind of shop cursor target, by meaning, with extra nodes on one side only.
func _shop_targets() -> void:
	var panel = _shop._get_coop_player_container(REMOTE)
	var reroll: Node = _shop._get_reroll_button(REMOTE)
	var gear = _shop._get_gear_container(REMOTE)
	var popup = _shop._get_item_popup(REMOTE)
	var weapon_element = gear.weapons_container.get_element(1)  # the second of three pistols
	_t._check(weapon_element != null, "remote player's gear shows its second weapon")
	var controls := [
		reroll,
		_shop._get_go_button(REMOTE),
		_node(REMOTE, 2)._button,
		popup._combine_button,
		panel.carousel.arrow_right,
		panel.get("_endless_button"),
	]
	if weapon_element != null:
		controls.append(weapon_element)
	CursorTargetTests.check_robust(_t, "shop (own panel)", _shop, controls, REMOTE, reroll)
	var pause_button = CursorTargetTests.first_button(_shop._pause_menu)
	if pause_button != null:
		controls.append(pause_button)  # outside the panels: the generic path from the scene
	CursorTargetTests.check_robust(_t, "shop (FocusSync)", _shop, controls, -1, reroll)
	var element: Array = FocusTargets.describe(weapon_element, _shop)
	_t._check(
		element.size() == 4 and element[0] == "shop_gear" and element[1] == REMOTE,
		"a gear element is named from the player's gear container (%s)" % [element]
	)
	CursorTargetTests.check_junk(_t, _shop)


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
	_t._check(_apply("lock", slot, id, 1, -1), "lock applied by intent, whatever the revision")
	_t._check(
		node.locked and RunData.get_player_locked_shop_items(REMOTE).size() == 1,
		"host locked the item"
	)
	_t._check(
		_locks.sent(self)[slot] and _locks.sent(self).count(true) == 1,
		"the state names the locked slot"
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
	_locks.host_after_buy(self, slot)

	# Reroll, with bone dice: the stat it gives is shown over the reroll button, so it is sent.
	seq = _seq()
	gold = RunData.get_player_gold(REMOTE)
	var dice: Array = _texts.host_before()
	var reroll := _intent("reroll")
	_t._check(_sync.host_apply_intent(_shop, REMOTE, reroll), "reroll applied by intent")
	yield(_frames(1), "completed")
	_texts.host_after(self, dice)
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
	yield(_meca.host(self), "completed")


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
	_receive(_states.start)
	yield(_sync, "shop_entered")
	yield(_frames(2), "completed")
	var shop: Node = _sync._client_shop
	_shop = shop
	var emulator = Utils.get_focus_emulator(0, shop)
	_t._check(local.active and local.you == 0, "own shop panel runs locally")
	ShopGearTests.client_anvil(self, [PISTOL, PISTOL])
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
	yield(_locks.client_own(self, shop, node, before), "completed")
	shop._item_steals[0] = 1  # the same shortcut steals when the player has a steal
	yield(_tap("ui_select"), "completed")
	_t._check(local.last_intent.get("kind") == "steal", "steal shortcut sends an intent")
	shop._item_steals[0] = 0
	_t._check(
		node.active and not node.locked and _run_view(shop) == before,
		"nothing stolen locally, and the stealing press locks nothing"
	)

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
	yield(_meca.client(self, shop, emulator, before), "completed")
	_client_other_panel(shop, before)
	yield(_client_view(together, emulator, node), "completed")
	_locks.client_other(self)
	yield(_client_states(emulator, node), "completed")
	_gear.client(self, shop)
	_texts.client(self, shop)
	var panels := [shop._get_coop_player_container(0), shop._get_coop_player_container(REMOTE)]
	yield(_wheel.check_wheel("shop, client", panels[0], panels[1]), "completed")
	var scroller: Node = together.scroll_sync
	yield(
		_wheel.check_sync("shop, client", scroller, shop, panels[0], panels[1], [0, REMOTE]),
		"completed"
	)
	_mods.client(self, shop)
	yield(_client_keyboard_mouse(emulator), "completed")

	# The host pauses: nothing runs here meanwhile. Leaving the shop ends local control.
	var local_panel: Node = local.local_panel
	local.set_paused(true)
	_t._check(_input._local_buttons == null, "local buttons off while the host is paused")
	_t._check(not local_panel.has_own(), "and the mouse drives no shop panel")
	local.set_paused(false)
	_t._check(_input._local_buttons != null, "and back on afterwards")
	_t._check(local_panel.has_own(), "the mouse too")
	local.take_over(REMOTE)
	_t._check(
		local_panel._own == shop._get_coop_player_container(REMOTE) and local_panel.has_own(),
		"another slot: LocalPanel follows to its panel"
	)
	local.take_over(0)
	local.leave(shop)
	_t._check(
		not local.active and _input._local_buttons == null and focus_sync.local_emulators.empty(),
		"local control ends with the shop"
	)
	_t._check(not local_panel.has_own(), "and LocalPanel lets go of the own panel")


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
	_t._check(local.last_intent.empty(), "a meca selection without an effect pressed sends nothing")
	var own_button = popup._upgrade_button
	var other_popup = shop._get_item_popup(REMOTE)
	var other_button = other_popup._upgrade_button
	_t._check(
		(
			own_button != null
			and other_button != null
			and not own_button.is_connected("pressed", popup, "_on_UpgradeButton_pressed")
			and own_button.is_connected("pressed", local.meca, "_on_upgrade_pressed")
			and not other_button.is_connected("pressed", other_popup, "_on_UpgradeButton_pressed")
			and not other_button.is_connected("pressed", local.meca, "_on_upgrade_pressed")
		),
		"the own popup's meca upgrade asks the host, another player's is dead"
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
	var target := FocusTargets.describe(emulator.focused_control, shop, 0)
	_t._check(
		not target.empty() and var2str(target) in local._sent_focus,
		"own shop cursor reported to the host (%s)" % [target]
	)
	_t._check(
		FocusTargets.resolve(target, shop, 0) == emulator.focused_control,
		"and the report names that control"
	)
	var focus_sync: Node = together.focus_sync
	var own_cursor = emulator.focused_control
	var cursor := FocusSync.cursor_of(emulator, shop._get_go_button(0), shop)
	_t._check(
		cursor.size() == 3 and FocusSync.find_emulator(shop, cursor[0], cursor[1]) == emulator,
		"host cursor names the own emulator by player (%s)" % [cursor]
	)
	var body := {"scene": shop.filename, "cursors": [cursor]}
	var done: bool = focus_sync.apply_state(StateStream.CURSORS, body, 0)
	_t._check(
		done and emulator.focused_control == own_cursor,
		"host cursor never moves the own shop cursor (handler done with it: %s)" % done
	)


# Only what changed is rebuilt; Go is the host's flag, kept while the cursor rests on it.
func _client_states(emulator: Node, node: Node):
	var local = _sync.local
	var shop: Node = _shop
	var gear = shop._get_gear_container(0)
	var weapons: Node = gear.weapons_container._elements
	var element = weapons.get_child(0)
	var own_data = RunData.players_data[0]
	node.effect_choice_selected = 1  # marker: set_shop_item resets it
	_receive(_states.remote_changed)
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
	_receive(_states.own_gear_changed)
	var cursor = emulator.focused_control
	_t._check(
		weapons.get_child_count() == 3 and is_instance_valid(cursor) and cursor.get_parent() == weapons,
		"own gear rebuilt, the cursor stays on a weapon"
	)
	yield(_frames(2), "completed")

	var ready: Dictionary = _states.own_gear_changed.duplicate()
	ready.go = [true, false]
	local.last_intent = {}
	_receive(ready)
	local.process()
	_t._check(
		local.last_intent.get("kind") == "go" and local.last_intent.get("arg") == 0,
		"ready with the cursor elsewhere is taken back (%s)" % [local.last_intent]
	)
	emulator.focused_control = shop._get_go_button(0)
	local.last_intent = {}
	_receive(ready)
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


# The own panel's device and mouse (sync/local_panel.gd, added by ShopLocal.guard). A pad
# button types the own slot as a pad (trigger glyphs), a key as the keyboard (page arrows that
# take focus, by the panel's own focus neighbours); the mouse moves and presses the own cursor
# only, stays inside an open popup, and leaves a cursor on Go while ready is on its way.
func _client_keyboard_mouse(emulator: Node):
	var local = _sync.local
	var shop: Node = _shop
	var own = shop._get_coop_player_container(0)
	var other = shop._get_coop_player_container(REMOTE)
	var local_panel: Node = local.local_panel
	var carousel = own.carousel
	var arrows := [carousel.arrow_left, carousel.arrow_right]
	var go: Control = shop._get_go_button(0)
	var keyboard: int = CoopService.PlayerType.KEYBOARD_AND_MOUSE
	var pad: int = CoopService.PlayerType.GAMEPAD_XBOX
	var glyph: Texture = CoopService.gamepad_rtrigger_icon
	var was_using_gamepad: bool = InputService.using_gamepad
	_t._check(
		(
			is_instance_valid(local_panel)
			and local_panel.get_parent() == shop
			and local_panel.get_index() > shop.get_node("FocusEmulator4").get_index()
		),
		"LocalPanel sits in the puppet shop after its emulators"
	)
	_t._check(
		local_panel.panels == [own, other] and local_panel.has_own() and local_panel._own == own,
		"every shop panel is LocalPanel's, the own one local"
	)
	_t._check(
		CoopService.get_player_input_type(0) == VirtualDevices.local_player_type(),
		"own shop slot typed as the device in use when the shop starts"
	)
	_input.local_input_blocked = true
	local.process()
	var blocked: bool = local_panel.blocked
	_input.local_input_blocked = false
	local.process()
	_t._check(
		blocked and not local_panel.blocked, "LocalPanel stands back while the lobby popup is open"
	)

	# Pad on the stats page: trigger glyphs, Go leads down to the first stat.
	yield(_pad_button(), "completed")
	_t._check(
		(
			CoopService.get_player_input_type(0) == pad
			and carousel.are_trigger_buttons_active()
			and arrows[1].disabled
			and arrows[1].texture_hover == glyph
		),
		"a pad button types the own shop slot as a pad (trigger glyphs)"
	)
	carousel._on_ArrowRight_pressed()  # what the right trigger calls
	yield(_frames(2), "completed")
	_t._check(carousel.index == 1, "pad: own shop panel on the stats page")

	# Keyboard: arrows, and the panel's focus neighbours lead to them.
	yield(_t._tap_key(KEY_SHIFT), "completed")
	_t._check(
		CoopService.get_player_input_type(0) == keyboard and not InputService.using_gamepad,
		"a key types the own shop slot as keyboard"
	)
	_t._check(
		CoopService.get_player_input_type(REMOTE) == pad and other.carousel.are_trigger_buttons_active(),
		"another player's shop panel keeps its triggers"
	)
	_t._check(
		(
			not carousel.are_trigger_buttons_active()
			and not arrows[0].disabled
			and arrows[0].focus_mode == Control.FOCUS_ALL
			and arrows[1].texture_hover != null
			and arrows[1].texture_hover != glyph
		),
		"keyboard: the shop's page arrows are arrows again and take focus"
	)
	emulator.focused_control = go
	yield(_tap("ui_down"), "completed")
	_t._check(
		emulator.focused_control == arrows[0],
		"keyboard: down from Go reaches the page arrow (neighbours redone)"
	)
	yield(_tap("ui_accept"), "completed")
	_t._check(carousel.index == 0, "keyboard: accept on the arrow pages the shop panel")
	yield(_frames(2), "completed")

	# Mouse: hover and click on the own panel; another player's panel never reacts.
	var hovered: Control = null
	var hovered_slot := -1
	for i in 4:
		var candidate = _node(0, i)
		if candidate.active and candidate._button != emulator.focused_control:
			hovered = candidate._button
			hovered_slot = i
			break
	yield(_mouse(hovered, "move"), "completed")
	_t._check(emulator.focused_control == hovered, "mouse hover moves the own shop cursor")
	yield(_popups.cover(self, emulator, own, hovered), "completed")
	var other_emulator = Utils.get_focus_emulator(REMOTE, shop)
	var other_cursor = other_emulator.focused_control
	var other_button: Control = _node(REMOTE, _pick(REMOTE))._button
	local.last_intent = {}
	yield(_mouse(other_button, "move"), "completed")
	yield(_click(other_button), "completed")
	_t._check(
		(
			emulator.focused_control == hovered
			and other_emulator.focused_control == other_cursor
			and local.last_intent.empty()
		),
		"the mouse does nothing on another player's shop panel"
	)
	yield(_click(hovered), "completed")
	var sent: Dictionary = local.last_intent
	_t._check(
		sent.get("kind") == "buy" and sent.get("slot") == hovered_slot,
		"a click on an own shop item sends its buy (%s)" % [sent]
	)

	# Ready only lasts while the cursor rests on Go: a drifting mouse leaves it there.
	yield(_click(go), "completed")
	sent = local.last_intent
	_t._check(
		sent.get("kind") == "go" and sent.get("arg") == 1 and emulator.focused_control == go,
		"a click on Go sends ready (%s)" % [sent]
	)
	local.process()
	yield(_mouse(hovered, "move"), "completed")
	_t._check(emulator.focused_control == go, "hover leaves the cursor on Go while ready is sent")
	yield(_click(hovered), "completed")
	local.process()
	_t._check(
		emulator.focused_control == hovered and not local_panel.hold_cursor,
		"a click still moves it, and hover is free again"
	)

	yield(_popups.inventory(self, emulator), "completed")

	# A cursor on a page arrow when the arrows become trigger glyphs again.
	yield(_click(arrows[1]), "completed")
	_t._check(
		carousel.index == 1 and emulator.focused_control == arrows[1],
		"a click on the own page arrow pages the shop panel"
	)
	yield(_pad_button(), "completed")
	var first_stat: Control = own.primary_stats_container.first_primary_stat
	_t._check(
		CoopService.get_player_input_type(0) == pad and arrows[1].disabled,
		"pad again: trigger glyphs"
	)
	_t._check(emulator.focused_control == go, "pad: a cursor on a page arrow goes to Go")
	_t._check(
		go.focus_neighbour_bottom == go.get_path_to(first_stat),
		"pad: the shop panel's focus neighbours are redone"
	)
	carousel._on_ArrowLeft_pressed()
	yield(_frames(2), "completed")
	InputService.using_gamepad = was_using_gamepad


# --- helpers ---


func _capture(name: String) -> void:
	var body: Dictionary = _sync.state_body(ShopStreamTests.StateStream.RUN_SHOP)
	body["you"] = 0
	_states[name] = body


# Through the client's stream, like a state from the host.
func _receive(body: Dictionary) -> void:
	ShopStreamTests.deliver(_sync.state_stream, ShopStreamTests.StateStream.RUN_SHOP, body)


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


# A button of a real pad: the local player picked the pad up.
func _pad_button():
	for pressed in [true, false]:
		var button := InputEventJoypadButton.new()
		button.button_index = JOY_L3
		button.pressed = pressed
		Input.parse_input_event(button)
		yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")


func _click(control: Control):
	yield(_mouse(control, "down"), "completed")
	yield(_mouse(control, "up"), "completed")


# A mouse event at the middle of a control, in window coordinates like a real one.
func _mouse(control: Control, kind: String):
	var canvas_pos: Vector2 = control.get_global_transform_with_canvas().xform(
		control.rect_size / 2.0
	)
	yield(_mouse_at(canvas_pos, kind), "completed")


func _mouse_at(canvas_pos: Vector2, kind: String):
	var pos: Vector2 = _t.get_viewport().get_final_transform().xform(canvas_pos)
	var event = null  # InputEventMouseMotion or InputEventMouseButton
	if kind == "move":
		event = InputEventMouseMotion.new()
	else:
		event = InputEventMouseButton.new()
		event.button_index = BUTTON_LEFT
		event.pressed = kind == "down"
	event.position = pos
	event.global_position = pos
	Input.parse_input_event(event)
	for _i in 3:  # flushed by the test mod, then resolved by LocalPanel in its _process
		yield(_t.get_tree(), "idle_frame")
