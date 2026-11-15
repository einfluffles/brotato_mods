extends Node
# Co-op shop.
# Host: owns every decision and the RNG. While coop_shop.tscn runs it provides section RUN_SHOP of
#   the state stream (sync/state_stream.gd), sent whenever the shop or run state changes (the
#   run state is serialized only when it can have changed: sync/shop_run_cache.gd). Body:
#   shop_id, run (RunStateCodec: the full run state incl. the shop's own save data: offered items,
#   rerolls, steals), per player slots (the slot layout), go (the Go flag), seqs (a panel
#   revision), pages (the carousel page) and mecas (the meca upgrade rolls its item popup
#   remembers: [[weapon slot, weapon my_id, stat key hash, value, stat key hash, value]],
#   sync/meca_choice.gd), colors (palette index per slot), and per peer you (which player it is,
#   -1: none). Remote players' decisions arrive as SHOP_INTENT and are applied by the
#   game's own code when they still match the sender's panel (sync/shop_intents.gd); their raw
#   buttons, except pause, are kept off the virtual devices meanwhile.
# Client: loads the real shop through the game's resume path (RunData.resumed_from_state_in_shop),
#   so it shows exactly the host's items without rolling; later states are applied in place, and
#   only for the players whose part changed. Its own panel runs locally and sends intents
#   (sync/shop_local.gd); the other panels stay mirrored (cursors by FocusSync). Also handles
#   section PAUSE_SHOP (provided by sync/pause_control.gd): the host's pause turns the own panel
#   off and shows who paused.

signal shop_entered

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const PauseControl := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/pause_control.gd"
)
const ShopIntents := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/shop_intents.gd"
)
const ShopLocal := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/shop_local.gd")
const MecaChoice := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/meca_choice.gd")
const ShopRunCache := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/shop_run_cache.gd"
)
const LOG_NAME := "einfluffles-BrotatoTogether:ShopSync"
const SHOP_SCENE := "res://ui/menus/shop/coop_shop.tscn"
const CHECK_INTERVAL := 0.1
# A shop that never got ready must not block the next (also how long a state waits for it).
const LOADING_TIMEOUT_MSEC := 10000
const BLOCK_KEY := "shop"  # InputSync.blocked_by

var session: Node = null
var state_stream: Node = null  # sync/state_stream.gd (set by mod_main.gd)
var input_sync: Node = null setget set_input_sync
var focus_sync: Node = null setget set_focus_sync
var local = ShopLocal.new()  # client: this client's own panel
var run_cache = ShopRunCache.new()  # host: the shop's run state, serialized on change

# host
var _host_shop: Node = null
var _shop_id := 0
var _seq_shop_id := 0  # instance id of the shop the revisions belong to
var _seqs := []  # per player: bumped whenever the panel offers something new
var _seq_keys := []

# client
var _client_shop: Node = null
var _loading_msec := -LOADING_TIMEOUT_MSEC  # when the puppet shop began to load (far back: not)
var _client_shop_id := 0
var _state := {}  # the run state RunData has, with the bytes it came from
var _run_bytes := PoolByteArray()
var _state_keys := []
var _applied := {}  # player index -> what its panel shows (player_keys entry + "slots")


func setup(netplay_session: Node) -> void:
	session = netplay_session
	local.session = session
	session.connect("message", self, "_on_message")
	session.connect("peer_ready", self, "_on_peer_ready")
	session.transport.connect("lobby_left", self, "_on_lobby_left")
	var timeout_sec := LOADING_TIMEOUT_MSEC / 1000.0
	state_stream.register_provider(StateStream.RUN_SHOP, self, CHECK_INTERVAL)
	state_stream.register_handler(StateStream.RUN_SHOP, self, timeout_sec)
	state_stream.register_handler(StateStream.PAUSE_SHOP, self, timeout_sec)


func set_input_sync(node: Node) -> void:
	input_sync = node
	local.input_sync = node


func set_focus_sync(node: Node) -> void:
	focus_sync = node
	local.focus_sync = node


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func is_in_shop() -> bool:
	return _client_shop != null and is_instance_valid(_client_shop)


func _process(_delta: float) -> void:
	local.process()
	var scene := get_tree().current_scene
	if not session.is_host() or scene == null or scene.filename != SHOP_SCENE:
		_host_shop = null
		_block_remote_buttons(false)
		return
	if scene != _host_shop:
		_host_shop = scene
		_shop_id += 1  # part of the state key: the new shop goes out at the next check
	# The pause menu is the host's: a remote player who paused navigates it with its buttons.
	_block_remote_buttons(not get_tree().paused)


func _on_message(steam_id: int, msg_type: int, body) -> void:
	match msg_type:
		Protocol.Msg.SHOP_INTENT:
			var shop = _host_shop_for(body)
			if shop != null:
				host_apply_intent(shop, _player_index_of(steam_id), body)
		Protocol.Msg.SHOP_FOCUS:
			var shop = _host_shop_for(body)
			var p := _player_index_of(steam_id)
			if shop != null and p >= 0 and p < RunData.get_player_count():
				ShopIntents.apply_focus(shop, p, body.get("page"), body.get("target"))


# --- host ---


# State stream provider, section RUN_SHOP: inactive ("") unless the host is in the shop. The key
# is the run state's revision (run_cache: serialized only when it can have changed, compressed
# once per change) + everything else the body and the per-peer part are built from.
func state_key(_section: int) -> String:
	if _host_shop == null or not is_instance_valid(_host_shop):
		run_cache.clear()
		return ""
	if _host_shop != get_tree().current_scene:
		run_cache.clear()
		return ""
	run_cache.refresh(_host_shop)
	var parts := _shop_parts()
	var rest := [
		_shop_id, parts.slots, parts.go, parts.seqs, parts.pages, parts.mecas, _yous(),
		CoopService.bt_slot_colors,
	]
	return str(run_cache.rev) + var2str(rest)


# Right after state_key in the same check, so refresh finds nothing new and the run is not
# serialized again; called alone (tests), it still sees a change of the fingerprint.
func state_body(_section: int) -> Dictionary:
	run_cache.refresh(_host_shop)
	var parts := _shop_parts()
	return {
		"shop_id": _shop_id,
		"run": run_cache.pack(),
		"slots": parts.slots,
		"go": parts.go,
		"seqs": parts.seqs,
		"pages": parts.pages,
		"mecas": parts.mecas,
		"colors": CoopService.bt_slot_colors.duplicate(),
	}


# Each client also learns which player's panel is its own (-1: none).
func state_patch(_section: int, steam_id: int) -> Dictionary:
	return {"you": _player_index_of(steam_id)}


func _yous() -> Array:
	var yous := []
	for steam_id in session.peers:
		yous.append([steam_id, _player_index_of(steam_id)])
	return yous


# The view parts of the state (the run state is run_cache's).
func _shop_parts() -> Dictionary:
	var shop := _host_shop
	_update_seqs(shop)
	var slots := []
	var pages := []
	var mecas := []
	for p in RunData.get_player_count():
		mecas.append(MecaChoice.entries(shop._get_item_popup(p), p))
		var active := []
		var container = shop._get_shop_items_container(p)
		for i in container._shop_items.size():
			active.append(container.get_shop_item_node(i).active)
		slots.append(active)
		pages.append(shop._get_coop_player_container(p).carousel.index)
	return {
		"slots": slots,
		"go": shop._player_pressed_go_button.duplicate(),
		"seqs": _seqs.duplicate(),
		"pages": pages,
		"mecas": mecas,
	}


# A peer that (re)joins must get the true run state: the next check serializes it. That check is
# the stream's resync for the peer, which runs in its next step, after every peer_ready handler;
# a difference it finds goes to everyone. (Harmless on a client: only the host's state_key
# refreshes.)
func _on_peer_ready(_steam_id: int) -> void:
	run_cache.force()


# A remote player's decision, sent from its own panel (see sync/shop_intents.gd). Only applied
# to what that panel offers right now. Returns whether the game's code ran for it.
func host_apply_intent(shop: Node, p: int, msg: Dictionary) -> bool:
	# Paused: the game ignores the shop's buttons too (the pause menu covers them).
	if p < 0 or p >= RunData.get_player_count() or get_tree().paused:
		return false
	_update_seqs(shop)
	var result: int = ShopIntents.apply(shop, p, msg, _seqs[p])
	if result == ShopIntents.DROPPED:
		return false
	if result == ShopIntents.CHANGED:
		# A second press made on the same panel is stale, whatever this one turns out to do.
		_seqs[p] += 1
	# The game connects Buy and Steal deferred: they run at the end of this frame, so the state
	# goes out in the next one (the stream holds its check until then) instead of once before
	# and once after. That check serializes the run whatever the fingerprint says.
	run_cache.force(1)
	state_stream.flush(StateStream.RUN_SHOP, true)
	call_deferred("_settle_host_cursor", shop, p)
	return true


# The game's handlers move the player's cursor with deferred grab_focus calls, some of them
# onto an inventory element that the same handler already queued for deletion (it relies on a
# later one, which a visible mouse skips). Runs after those calls and before the deletion: a
# FocusEmulator must never keep a freed control.
func _settle_host_cursor(shop: Node, p: int) -> void:
	if not is_instance_valid(shop) or not shop.is_inside_tree():
		return
	var emulator = Utils.get_focus_emulator(p, shop)
	var control = emulator.focused_control if emulator != null else null
	if control != null and is_instance_valid(control) and control.is_queued_for_deletion():
		emulator.focused_control = shop._get_default_focus_control(p)


func _host_shop_for(msg):
	if not session.is_host() or typeof(msg) != TYPE_DICTIONARY:
		return null
	if _host_shop == null or not is_instance_valid(_host_shop):
		return null
	return _host_shop if msg.get("shop_id") == _shop_id else null


func _update_seqs(shop: Node) -> void:
	if shop.get_instance_id() != _seq_shop_id:
		_seq_shop_id = shop.get_instance_id()
		_seqs = []
		_seq_keys = []
	for p in RunData.get_player_count():
		if p >= _seqs.size():
			_seqs.append(0)
			_seq_keys.append("")
		var key: String = ShopIntents.revision_key(shop, p)
		if key != _seq_keys[p]:
			_seq_keys[p] = key
			_seqs[p] += 1


# While the shop runs on the clients themselves, a remote button (except pause) must not also
# press the host's copy of that player's panel.
func _block_remote_buttons(block: bool) -> void:
	if input_sync == null:
		return
	if block:
		var all: int = (1 << VirtualDevices.BUTTON_ACTIONS.size()) - 1
		input_sync.blocked_by[BLOCK_KEY] = all & ~(1 << VirtualDevices.PAUSE_INDEX)
	else:
		input_sync.blocked_by.erase(BLOCK_KEY)


func _player_index_of(steam_id: int) -> int:
	var device = input_sync.devices.get(steam_id) if input_sync != null else null
	if device == null:
		return -1
	for i in CoopService.connected_players.size():
		if CoopService.connected_players[i][0] == device:
			return i
	return -1


# --- client ---


# State stream handler: RUN_SHOP (the shop) and PAUSE_SHOP (the host's pause). False: the shop
# is still loading, the stream keeps the latest body and _on_shop_ready retries it.
func apply_state(section: int, body, _revision: int) -> bool:
	if section == StateStream.PAUSE_SHOP:
		return _apply_pause(body)
	if typeof(body) != TYPE_DICTIONARY:
		return true
	if typeof(body.get("shop_id")) != TYPE_INT or typeof(body.get("slots")) != TYPE_ARRAY:
		return true
	if typeof(body.get("go")) != TYPE_ARRAY:
		return true
	# A second state for the shop that is still loading (both arrived in one frame after a
	# hitch) must not enter it again: the second scene would have no hook and roll its own items.
	if body.shop_id == _client_shop_id and _is_loading():
		return false
	var entering: bool = body.shop_id != _client_shop_id or not is_in_shop()
	var run = body.get("run")
	var bytes := PoolByteArray()
	if typeof(run) == TYPE_DICTIONARY and typeof(run.get("data")) == TYPE_RAW_ARRAY:
		bytes = run.data
	# The bytes RunData already has (only a Go flag, a page or a revision changed, or a resync):
	# nothing to rebuild.
	var run_changed: bool = entering or _state.empty() or bytes.empty() or bytes != _run_bytes
	if run_changed:
		var raw := RunStateCodec.parse(run)
		var keys := player_keys(raw)  # before the game's deserializer touches it
		var state := RunStateCodec.deserialize(raw)
		if state.empty() or not state.get("has_run_state", false):
			ModLoaderLog.error("Invalid shop state", LOG_NAME)
			return true
		_state = state
		_run_bytes = bytes
		_state_keys = keys
	if entering:
		_client_shop_id = body.shop_id
		_enter_shop(_state)
		return false  # the whole body once the shop is ready
	_apply_body(_client_shop, body, run_changed)
	return true


func _is_loading() -> bool:
	return OS.get_ticks_msec() - _loading_msec < LOADING_TIMEOUT_MSEC


# [paused, by (name), by_id (steam id, 0: the host)]. While the host is paused its pause menu
# is in charge: the own panel is off. The banner waits for the shop that is loading.
func _apply_pause(body) -> bool:
	if typeof(body) != TYPE_ARRAY or body.size() != 3:
		return true
	if typeof(body[1]) != TYPE_STRING or typeof(body[2]) != TYPE_INT:
		return true
	if _is_loading():
		return false
	var paused := bool(body[0])
	local.set_paused(paused)
	if is_in_shop():
		var text := PauseControl.banner_text(body[1], body[2], session.transport.local_id)
		PauseControl.show_banner(_client_shop, paused, text)
	return true


# Per player, the parts of the sent run state that its panel is built from, as text: a panel
# is only rebuilt when its part differs from what it shows.
static func player_keys(raw: Dictionary) -> Array:
	var keys := []
	var players = raw.get("players_data")
	if typeof(players) != TYPE_ARRAY:
		return keys
	for p in players.size():
		var data = players[p]
		var gear := []
		if typeof(data) == TYPE_DICTIONARY:
			gear = [data.get("weapons"), data.get("items")]
		var offered := [_at(raw.get("shop_items"), p), _at(raw.get("item_steals"), p)]
		keys.append({"data": to_json(data), "gear": to_json(gear), "items": to_json(offered)})
	return keys


func _enter_shop(state: Dictionary) -> void:
	Puppet.set_active(true)
	_client_shop = null
	_applied = {}
	RunStateCodec.apply(state)
	# The game's "continue run in shop" path: BaseShop._ready takes items/rerolls from here.
	ProgressData.saved_run_state = state
	RunData.resumed_from_state_in_shop = true
	RunData.shop_effects_checked = true  # anvil/destroy effects already ran on the host
	VirtualDevices.fill_puppet_slots(RunData.get_player_count())
	get_tree().paused = false
	# Only while the puppet shop loads: no node_added handler for every node otherwise.
	if not get_tree().is_connected("node_added", self, "_on_node_added"):
		get_tree().connect("node_added", self, "_on_node_added")
	_loading_msec = OS.get_ticks_msec()
	if get_tree().change_scene(SHOP_SCENE) != OK:
		_loading_msec = -LOADING_TIMEOUT_MSEC
		ModLoaderLog.error("Could not load the shop scene", LOG_NAME)


# The puppet shop reacts to mirrored state/cursors with its own sounds; the host's replace them.
# Muted from node_added (not ready) so sounds from the shop's own _ready are covered too.
func _on_node_added(node: Node) -> void:
	if Puppet.is_active() and node.filename == SHOP_SCENE:
		node.connect("ready", self, "_on_shop_ready", [node], CONNECT_ONESHOT)
		SoundRelay.set_muted(true)
		node.connect("tree_exited", self, "_on_puppet_shop_exited", [node], CONNECT_ONESHOT)


# The old scene leaves the tree before the next one is added, so this never undoes the battle's
# mute (BattleClient mutes when main.tscn is ready).
func _on_puppet_shop_exited(shop: Node) -> void:
	SoundRelay.set_muted(false)
	local.leave(shop)
	if shop == _client_shop:
		_client_shop = null


func _stop_watching_scenes() -> void:
	if get_tree().is_connected("node_added", self, "_on_node_added"):
		get_tree().disconnect("node_added", self, "_on_node_added")


func _on_shop_ready(shop: Node) -> void:
	_stop_watching_scenes()
	_loading_msec = -LOADING_TIMEOUT_MSEC
	_client_shop = shop
	_applied = {}
	# Leaving the shop would roll curses on locked items locally; the host decides those.
	if shop.is_connected("tree_exited", shop, "_on_tree_exited"):
		shop.disconnect("tree_exited", shop, "_on_tree_exited")
	PauseControl.disable_local_pause(shop)
	state_stream.retry()  # the state that entered it, or a newer one that came meanwhile
	emit_signal("shop_entered")


# body: a validated RUN_SHOP body for this shop, whose run state is _state. run_changed: RunData
# does not have it yet.
func _apply_body(shop: Node, body: Dictionary, run_changed: bool) -> void:
	var state: Dictionary = _state
	var keys: Array = _state_keys
	var shown: Array = RunData.players_data
	# A shop that shows nothing yet (just ready) gets the whole run again: its _ready ran on it.
	run_changed = run_changed or _applied.empty()
	if run_changed:
		RunStateCodec.apply(state)
	local.guard(shop, _client_shop_id)
	for p in RunData.get_player_count():
		# No keys for this player (not in the sent run state): everything counts as new.
		var keyed: bool = p < keys.size()
		var fresh: Dictionary = keys[p].duplicate() if keyed else {}
		var old: Dictionary = _applied.get(p, {})
		fresh["slots"] = var2str(_list_at(body.slots, p))
		var data_changed: bool = not keyed or fresh.data != old.get("data")
		var items_changed: bool = data_changed or fresh.items != old.get("items")
		var changed := {
			"data": data_changed,
			"gear": data_changed and (not keyed or fresh.gear != old.get("gear")),
			"items": items_changed or fresh.slots != old.get("slots"),
		}
		if run_changed and not data_changed and p < shown.size():
			# Same content: the objects this panel already shows stay (gear, popup, cursor).
			RunData.players_data[p] = shown[p]
		_refresh_player(shop, state, p, changed, body)
		_applied[p] = fresh if keyed else {}
	shop._update_visual_locks()
	shop.update_go_next_button_text()
	var you: int = body.you if typeof(body.get("you")) == TYPE_INT else -1
	_mirror_view(shop, you, body.get("pages"))
	if you >= 0 and you < RunData.get_player_count():
		local.take_over(you)
		local.on_state(_int_at(body.get("seqs"), you), shop._player_pressed_go_button[you])
		local.on_mecas(_list_at(body.get("mecas"), you))
	else:
		local.stop()


# The per-player part of BaseShop._ready, re-run with the host's values (no RNG anywhere).
# changed: which parts of this player's panel differ from what it shows ("data": anything of
# the player's run, "gear": weapons / items, "items": the offered items). The rest is left
# alone: a rebuild of this client's own panel would fight its local cursor and popups.
func _refresh_player(
	shop: Node, state: Dictionary, p: int, changed: Dictionary, body: Dictionary
) -> void:
	if changed.gear:
		_refresh_gear(shop, p)
	if changed.data:
		shop._update_stats(p)
		shop._get_gold_label(p).update_value(RunData.get_player_gold(p))
		shop._refresh_meca_parts_ui(RunData.get_player_meca_parts(p), p)

	for key in ["reroll_count", "paid_reroll_count", "initial_free_rerolls", "free_rerolls"]:
		if state.get(key) is Array and p < state[key].size():
			shop.get("_" + key)[p] = int(state[key][p])
	shop._item_steals[p] = int(state.item_steals[p]) if p < state.item_steals.size() else 0
	var price: Array = ItemService.get_reroll_price(
		RunData.current_wave, shop._paid_reroll_count[p], p
	)
	shop._reroll_price[p] = price[0]
	shop._reroll_discount[p] = price[1]

	var items: Array = state.shop_items[p] if p < state.shop_items.size() else []
	shop._shop_items[p] = items
	var container = shop._get_shop_items_container(p)
	container.item_steals = shop._item_steals[p]
	shop._get_item_popup(p).item_steals = shop._item_steals[p]
	if changed.items:
		container.unlock_all_shop_items_visually()
		var active: Array = _list_at(body.slots, p)
		var next := 0
		for i in container._shop_items.size():
			var node = container.get_shop_item_node(i)
			var is_active: bool = active[i] if i < active.size() else next < items.size()
			if is_active and next < items.size():
				node.item_steals = shop._item_steals[p]
				node.set_shop_item(items[next][0], items[next][1])
				if not node.active:
					node.activate()
				next += 1
			elif node.active:
				node.deactivate()
	shop._refresh_currency_dependent_buttons(p)
	shop._refresh_bonus_free_reroll(p)

	var go: bool = body.go[p] if p < body.go.size() else false
	shop._player_pressed_go_button[p] = go
	shop._get_checkmark(p).visible = go


# set_weapons_data / set_items_data replace every inventory element. A cursor resting on one
# (or inside the popup opened from one) is taken off first and put back on the element at the
# same place: the emulator must never keep a control that is about to be freed.
func _refresh_gear(shop: Node, p: int) -> void:
	var gear = shop._get_gear_container(p)
	var inventories := [gear.weapons_container._elements, gear.items_container._elements]
	var emulator = Utils.get_focus_emulator(p, shop)
	var cursor := _take_gear_cursor(shop, p, emulator, inventories)
	gear.set_weapons_data(RunData.get_player_weapons(p))
	gear.set_items_data(RunData.get_player_items(p))
	if cursor.empty():
		return
	var inventory: Node = inventories[cursor[0]]
	var target: Control = null
	if inventory.get_child_count() > 0:
		target = inventory.get_child(int(min(cursor[1], inventory.get_child_count() - 1)))
	elif local.active and p == local.you:
		target = shop._get_default_focus_control(p)
	if target != null and target.is_visible_in_tree():
		emulator.focused_control = target


# [inventory, element index] when player p's cursor is in the gear, else [].
func _take_gear_cursor(shop: Node, p: int, emulator: Node, inventories: Array) -> Array:
	if emulator == null:
		return []
	var element = emulator.focused_control
	var popup = shop._get_item_popup(p)
	var in_popup: bool = popup._focused
	if in_popup:
		# The view half of the game's "close the popup" handler; its weapon may be gone.
		element = shop._popup_manager._elements_pressed[p]
		shop._popup_manager.reset_focus(p)
		shop._get_coop_player_container(p).on_hide_focused_inventory_popup()
	if element == null or not is_instance_valid(element):
		return []
	for i in inventories.size():
		if element.get_parent() == inventories[i]:
			emulator.focused_control = null
			return [i, element.get_index()]
	return []


# View state that is not this client's own: the other players' pages, and the "endless" toggle.
func _mirror_view(shop: Node, you: int, pages) -> void:
	for p in RunData.get_player_count():
		var panel = shop._get_coop_player_container(p)
		var page := _int_at(pages, p)
		if p != you and page >= 0 and panel.carousel.index != page:
			panel.carousel.index = page
		var endless = panel.get("_endless_button")
		if endless != null and endless.visible and endless.pressed != RunData.is_endless_run:
			endless.set_pressed_no_signal(RunData.is_endless_run)


func _on_lobby_left() -> void:
	_stop_watching_scenes()
	_loading_msec = -LOADING_TIMEOUT_MSEC
	_block_remote_buttons(false)
	run_cache.clear()
	local.stop()
	local.set_paused(false)
	_client_shop = null
	_client_shop_id = 0
	_state = {}
	_run_bytes = PoolByteArray()
	_state_keys = []
	_applied = {}


# values[index] when values is a list that long, else null (network data).
static func _at(values, index: int):
	if typeof(values) != TYPE_ARRAY or index < 0 or index >= values.size():
		return null
	return values[index]


static func _list_at(values, index: int) -> Array:
	var value = _at(values, index)
	return value if typeof(value) == TYPE_ARRAY else []


# values[index] when it is an int, else -1 (network data: seqs / pages may be missing).
static func _int_at(values, index: int) -> int:
	if typeof(values) != TYPE_ARRAY or index >= values.size():
		return -1
	return values[index] if typeof(values[index]) == TYPE_INT else -1
