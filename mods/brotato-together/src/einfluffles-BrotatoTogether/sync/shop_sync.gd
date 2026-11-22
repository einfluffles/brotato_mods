extends Node
# Co-op shop. Host: owns every decision and the RNG, and provides section RUN_SHOP while
# coop_shop.tscn runs. Client: loads the real shop through the game's resume path, so it shows the
# host's items without rolling; its own panel runs locally and sends intents (sync/shop_local.gd).

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
const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const MecaChoice := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/meca_choice.gd")
const UpgradesGear := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/upgrades_gear.gd"
)
const ClientReport := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/client_report.gd"
)
const PopupView := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/popup_view.gd")
const RunCache := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_cache.gd")
const RunParts := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_parts.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:ShopSync"
const SHOP_SCENE := "res://ui/menus/shop/coop_shop.tscn"
const CHECK_INTERVAL := 0.1
# A shop that never got ready must not block the next (also how long a state waits for it).
const LOADING_TIMEOUT_MSEC := 10000
const BLOCK_KEY := "shop"  # InputSync.blocked_by

var session: Node = null
var state_stream: Node = null
var input_sync: Node = null setget set_input_sync
var focus_sync: Node = null setget set_focus_sync
var local = ShopLocal.new()  # client: this client's own panel
var run_cache = RunCache.new("shop")  # host: the shop's run state, serialized on change
var run_sender = null  # host: RunParts.Sender, shared with UpgradesSync
var run_store = null  # client: RunParts.Store, shared with UpgradesSync
var last_text := {}  # host: the last SHOP_TEXT sent

var _host_shop: Node = null
var _shop_id := 0
var _seq_shop_id := 0  # instance id of the shop the revisions belong to
var _seqs := []  # per player: bumped whenever the panel offers something new
var _seq_keys := []
var _mod_kinds := {}  # other mods' intent kinds: kind -> [target, method, revision]
var _view_bytes := 0  # the last body without its run (RunParts.Sender's counters)
var _reported := {}  # player -> [shop instance id, the last SHOP_FOCUS target of its client]
# player -> [shop instance id, its client's open menu (PopupView), its client's steam id], kept
# on the host's copy until an intent of that player changes the panel or the client leaves
var _reported_popups := {}
var _popup_memo := {}  # PopupView.apply's, for the copy of each player's panel here

var _client_shop: Node = null
# When the puppet shop began to load. It starts far enough back to count as not loading.
var _loading_msec := -LOADING_TIMEOUT_MSEC
var _client_shop_id := 0
var _state := {}  # the run state RunData has, with the part ids it came from
var _run_ids := {}
var _state_keys := []
var _applied := {}  # player index -> what its panel shows (player_keys entry + "slots")
var _host_kinds := []  # other mods' intent kinds the host handles (its last state)


func setup(netplay_session: Node) -> void:
	session = netplay_session
	local.session = session
	session.connect("message", self, "_on_message")
	session.connect("peer_ready", self, "_on_peer_ready")
	session.connect("peer_removed", self, "_on_peer_removed")
	session.transport.connect("lobby_left", self, "_on_lobby_left")
	RunData.connect("stat_added", self, "_on_stat_added")
	var timeout_sec := LOADING_TIMEOUT_MSEC / 1000.0
	state_stream.register_provider(StateStream.RUN_SHOP, self, CHECK_INTERVAL, true)
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
		_reported_popups = {}
		_popup_memo = {}
	# The pause menu is the host's: a remote player who paused navigates it with its buttons.
	_block_remote_buttons(not get_tree().paused)
	_keep_reported_popups()


# For other mods: a decision of their own on a player's shop panel (a button they add).
# Host: register_intent(kind, target, method). method(shop, player, slot, id, arg) -> bool runs
#   for a remote player's press with the checks every intent gets (the sender's own player, its
#   panel's revision, not paused) and returns whether it changed the run; the state then goes
#   out like after the game's own decisions. Local players' presses never come here.
# Client: the run is the host's, so the mod changes nothing in a puppet shop (is_puppet_shop).
#   It sends the press of this client's own player (send_intent) when the host has the kind
#   (host_handles), and the result arrives with the host's next state.


# kind: namespaced by the mod ("trade.item"); slot, id and arg are the mod's to define.
# revision false: the press skips the panel revision (its slot and id name its target and its
# handler checks everything again), so a second press sent before the host's answer counts too.
func register_intent(kind: String, target: Object, method: String, revision := true) -> bool:
	if kind == "" or kind in ShopIntents.OWN_KINDS or target == null:
		return false
	_mod_kinds[kind] = [target, method, revision]
	return true


func is_puppet_shop(shop: Node) -> bool:
	return Puppet.is_active() and is_instance_valid(shop) and shop.filename == SHOP_SCENE


func host_handles(kind: String) -> bool:
	return kind in _host_kinds


func own_player() -> int:
	return local.you if local.active else -1


# False: not sent (not this client's own panel, or the host does not know the kind).
func send_intent(shop: Node, player: int, kind: String, slot: int, id: String, arg: int) -> bool:
	if shop != _client_shop or player != own_player() or not host_handles(kind):
		return false
	return local.send_mod_intent(kind, slot, id, arg)


func _on_message(steam_id: int, msg_type: int, body) -> void:
	match msg_type:
		Protocol.Msg.SHOP_INTENT:
			var shop = _host_shop_for(body)
			if shop != null:
				host_apply_intent(shop, _player_index_of(steam_id), body)
		Protocol.Msg.SHOP_TEXT:
			if session.is_client() and steam_id == session.transport.host_id:
				client_show_text(body)
		Protocol.Msg.SHOP_FOCUS:
			var shop = _host_shop_for(body)
			var p := _player_index_of(steam_id)
			if shop != null and p >= 0 and p < RunData.get_player_count():
				var popup = body.get("popup")
				host_apply_focus(shop, p, body.get("page"), body.get("target"), popup, steam_id)


# popup: the client's open menu (PopupView), shown on the host's copy before the cursor goes
# into it. The page first, as on the level-up panels: the popup's element shows only on it.
func host_apply_focus(shop: Node, p: int, page, target, popup = [], steam_id := 0) -> void:
	_reported[p] = [shop.get_instance_id(), target]
	_reported_popups[p] = [shop.get_instance_id(), popup, steam_id]
	ShopIntents.apply_page(shop, p, page)
	_apply_popup(shop, p, popup, null)
	ShopIntents.apply_focus(shop, p, page, target)


# The host's copy closes a remote player's popup on its own (a gear rebuild): open again what
# that player's client still has open.
func _keep_reported_popups() -> void:
	for p in _reported_popups:
		var reported: Array = _reported_popups[p]
		if reported[0] != _host_shop.get_instance_id():
			continue
		if p < RunData.get_player_count() and _apply_popup(_host_shop, p, reported[1], null):
			var control := _reported_control(_host_shop, p)
			var emulator = Utils.get_focus_emulator(p, _host_shop)
			if control != null and emulator != null and emulator.focused_control != control:
				emulator.focused_control = control


# A client that left keeps no popup open on the host's copy.
func _on_peer_removed(steam_id: int) -> void:
	for p in _reported_popups.keys():
		var reported: Array = _reported_popups[p]
		if reported[2] != steam_id:
			continue
		_reported_popups.erase(p)
		var shop := _host_shop
		if is_instance_valid(shop) and shop.get_instance_id() == reported[0]:
			if p < RunData.get_player_count():
				_apply_popup(shop, p, [], null)


func _apply_popup(shop: Node, p: int, view, rolls) -> bool:
	var manager: Node = shop._popup_manager
	var popup: Node = shop._get_item_popup(p)
	var panel: Node = shop._get_coop_player_container(p)
	return PopupView.apply(shop, manager, popup, panel, p, view, rolls, _popup_memo)


# A reroll that gives a stat (bone dice) floats its icon and number over the player's reroll
# button, on the host only. BaseShop._on_RerollButton_pressed calls RunData.add_stat before it
# counts the reroll, so the gain is sent when that player's reroll count rose within the frame.
func _on_stat_added(stat, value, _db_mod, p) -> void:
	if _host_shop == null or not is_instance_valid(_host_shop):
		return
	if typeof(stat) != TYPE_INT or typeof(p) != TYPE_INT:
		return
	var rerolls: Array = _host_shop._reroll_count
	if p >= 0 and p < rerolls.size():
		var shop_id := _host_shop.get_instance_id()
		call_deferred("_send_reroll_text", shop_id, p, stat, int(value), rerolls[p])


func _send_reroll_text(shop_id: int, p: int, stat: int, value: int, rerolls_before: int) -> void:
	if not is_instance_valid(_host_shop) or _host_shop.get_instance_id() != shop_id:
		return
	if _host_shop._reroll_count[p] <= rerolls_before:
		return
	last_text = {"shop_id": _shop_id, "player": p, "stat": stat, "value": value}
	if session.is_host():
		session.broadcast_reliable(Protocol.Msg.SHOP_TEXT, last_text)


# Section RUN_SHOP. The key is the run state's revision plus everything else the body and the
# per-peer part are built from.
func state_key(_section: int) -> String:
	if _host_shop == null or not is_instance_valid(_host_shop):
		run_sender.close(run_cache)
		return ""
	if _host_shop != get_tree().current_scene:
		run_sender.close(run_cache)
		return ""
	run_cache.title = "Shop %d" % RunData.current_wave
	run_cache.refresh(_host_shop, shop_args(_host_shop))
	var parts := _shop_parts()
	var rest := [
		_shop_id, parts.slots, parts.locks, parts.go, parts.seqs, parts.pages, parts.mecas,
		parts.popups, _yous(), CoopService.bt_slot_colors, _kinds(),
	]
	return str(run_cache.rev) + var2str(rest)


# Body: shop_id, run (the run state incl. the shop's own save data, in parts: sync/run_parts.gd;
# every part here, state_patch narrows it to what the peer lacks) and per player:
#   slots: which slot nodes are active; locks: the lock per slot; go: the Go flag
#   seqs: the panel revision; pages: the carousel page
#   mecas: the meca upgrade rolls its item popup remembers (MecaChoice.entries)
#   popups: its open menu (PopupView)
# plus colors (palette index per slot), kinds (other mods' intent kinds the host handles) and,
# per peer, you (which player it is, -1: none).
func state_body(_section: int) -> Dictionary:
	run_cache.refresh(_host_shop, shop_args(_host_shop))
	run_sender.offer(run_cache)
	var parts := _shop_parts()
	var body := {
		"shop_id": _shop_id,
		"slots": parts.slots,
		"locks": parts.locks,
		"go": parts.go,
		"seqs": parts.seqs,
		"pages": parts.pages,
		"mecas": parts.mecas,
		"popups": parts.popups,
		"colors": CoopService.bt_slot_colors.duplicate(),
		"kinds": _kinds(),
	}
	_view_bytes = var2bytes(body).size()
	body["run"] = run_cache.all()
	return body


func _kinds() -> Array:
	var kinds := _mod_kinds.keys()
	kinds.sort()
	return kinds


func state_patch(_section: int, steam_id: int) -> Dictionary:
	return {"you": _player_index_of(steam_id), "run": run_sender.run_for(steam_id)}


func state_sent(_section: int, steam_id: int) -> void:
	run_sender.commit(steam_id, _view_bytes)


func _yous() -> Array:
	var yous := []
	for steam_id in session.peers:
		yous.append([steam_id, _player_index_of(steam_id)])
	return yous


# BaseShop.save_run_state's arguments: the shop's own part of the run state and of run_cache's
# fingerprint (RunCache.fingerprint has the shared part and what moves it).
static func shop_args(shop: Node) -> Array:
	return [
		shop._shop_items,
		shop._reroll_count,
		shop._paid_reroll_count,
		shop._initial_free_rerolls,
		shop._free_rerolls,
		shop._item_steals,
	]


func _shop_parts() -> Dictionary:
	var shop := _host_shop
	_update_seqs(shop)
	var slots := []
	var locks := []
	var pages := []
	var mecas := []
	var popups := []
	for p in RunData.get_player_count():
		var popup = shop._get_item_popup(p)
		mecas.append(MecaChoice.entries(popup, p))
		var panel = shop._get_coop_player_container(p)
		popups.append(PopupView.describe(shop, shop._popup_manager, popup, panel, p))
		var active := []
		var locked := []
		for node in shop._get_shop_items_container(p)._shop_items:
			active.append(node.active)
			locked.append(node.active and node.locked)
		slots.append(active)
		locks.append(locked)
		pages.append(shop._get_coop_player_container(p).carousel.index)
	return {
		"slots": slots,
		"locks": locks,
		"go": shop._player_pressed_go_button.duplicate(),
		"seqs": _seqs.duplicate(),
		"pages": pages,
		"mecas": mecas,
		"popups": popups,
	}


# A (re)joining peer gets every part of the true run state (see UpgradesSync._on_peer_ready).
func _on_peer_ready(steam_id: int) -> void:
	run_cache.force()
	run_sender.forget(steam_id)


# Returns whether the game's code ran for the intent.
func host_apply_intent(shop: Node, p: int, msg: Dictionary) -> bool:
	# Paused: the game ignores the shop's buttons too (the pause menu covers them).
	if p < 0 or p >= RunData.get_player_count() or get_tree().paused:
		return false
	_update_seqs(shop)
	var result: int = ShopIntents.apply(shop, p, msg, _seqs[p], _mod_kinds)
	if result == ShopIntents.DROPPED:
		return false
	if result == ShopIntents.CHANGED:
		# A second press made on the same panel is stale, whatever this one turns out to do.
		_seqs[p] += 1
	# The game's handler closes the popup itself; the client's next report says what is open.
	_reported_popups.erase(p)
	# The game connects Buy and Steal deferred: they run at the end of this frame, so the stream
	# holds its check until the next one, which serializes the run whatever the fingerprint says.
	run_cache.force(1)
	state_stream.flush(StateStream.RUN_SHOP, true)
	call_deferred("_settle_host_cursor", shop, p)
	return true


# After the game's deferred grab_focus calls and before the deletion they target: a
# FocusEmulator must never keep a freed control. The cursor goes back where the client last
# reported it (the client reports it only when it moves).
func _settle_host_cursor(shop: Node, p: int) -> void:
	if not is_instance_valid(shop) or not shop.is_inside_tree():
		return
	var emulator = Utils.get_focus_emulator(p, shop)
	if emulator == null:
		return
	var reported := _reported_control(shop, p)
	if reported != null:
		if emulator.focused_control != reported:
			emulator.focused_control = reported
		return
	var control = emulator.focused_control
	if control != null and is_instance_valid(control) and control.is_queued_for_deletion():
		emulator.focused_control = shop._get_default_focus_control(p)


# What player p's client last reported its cursor on, if a cursor can rest there now (not a
# slot just bought, not a weapon just recycled).
func _reported_control(shop: Node, p: int) -> Control:
	var reported = _reported.get(p)
	if reported == null or reported[0] != shop.get_instance_id():
		return null
	var control = FocusTargets.resolve(reported[1], shop, p)
	if not (control is Control) or not control.is_visible_in_tree():
		return null
	if control.focus_mode != Control.FOCUS_ALL or (control is BaseButton and control.disabled):
		return null
	return control


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


# SHOP_TEXT: the game's own floating text where BaseShop puts it (the co-op place: the right end
# of the player's reroll button). Its sound is the host's (UI_SOUNDS).
func client_show_text(body) -> bool:
	if typeof(body) != TYPE_DICTIONARY or not is_in_shop():
		return false
	var p = body.get("player")
	var stat = body.get("stat")
	var value = body.get("value")
	if body.get("shop_id") != _client_shop_id or typeof(p) != TYPE_INT:
		return false
	if typeof(stat) != TYPE_INT or typeof(value) != TYPE_INT or value == 0:
		return false
	if p < 0 or p >= RunData.get_player_count() or not Utils.is_stat_key(stat):
		return false
	var button: Control = _client_shop._get_reroll_button(p)
	var position: Vector2 = button.rect_global_position + Vector2(button.rect_size.x - 80, 0)
	_client_shop._floating_text_manager.stat_added(stat, value, 0, position, [], [])
	return true


func accept_state(section: int, body, _revision: int) -> void:
	if section == StateStream.RUN_SHOP and typeof(body) == TYPE_DICTIONARY:
		run_store.take(body.get("run"), "shop")


# RUN_SHOP (the shop) and PAUSE_SHOP (the host's pause). False: the shop is still loading, and
# _on_shop_ready retries the pending body.
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
	var ids = run_store.ids_for(body.get("run"))
	# The parts RunData already has (only a Go flag, a page or a revision changed, or a resync):
	# nothing to rebuild.
	var run_changed: bool = entering or _state.empty() or not RunParts.same_ids(ids, _run_ids)
	if run_changed:
		var state: Dictionary = run_store.timed_state(ids)
		if state.empty() or not state.get("has_run_state", false):
			ModLoaderLog.warning("Shop state without a complete run state; dropped", LOG_NAME)
			return true
		_state = state
		_run_ids = ids
		_state_keys = player_keys(ids, run_store.raws({"c": ids.get("c")}).c)
	if entering:
		_client_shop_id = body.shop_id
		_enter_shop(_state)
		return false  # the whole body once the shop is ready
	_apply_body(_client_shop, body, run_changed)
	return true


func _is_loading() -> bool:
	return OS.get_ticks_msec() - _loading_msec < LOADING_TIMEOUT_MSEC


# While the host is paused its pause menu is in charge: the own panel is off. That holds from
# the moment the body arrives, also while a shop loads: only the banner waits for that shop.
func _apply_pause(body) -> bool:
	if typeof(body) != TYPE_ARRAY or body.size() != 3:
		return true
	if typeof(body[1]) != TYPE_STRING or typeof(body[2]) != TYPE_INT:
		return true
	var paused := bool(body[0])
	local.set_paused(paused)
	if _is_loading():
		return false
	if is_in_shop():
		var text := PauseControl.banner_text(body[1], body[2], session.transport.local_id)
		PauseControl.show_banner(_client_shop, paused, text)
	return true


# The host left the shop (also from its pause menu): no pause of that shop may carry over to
# the next one.
func clear_state(section: int) -> void:
	if section == StateStream.PAUSE_SHOP:
		local.set_paused(false)
		if is_in_shop():
			PauseControl.show_banner(_client_shop, false, "")


# Per player, what of the sent run state its panel is built from: its run parts' ids (data: the
# "p" and "g" parts, gear: "g") and a hash of its offered items (in the common part as parsed).
# A panel is only rebuilt when its part differs from what it shows.
static func player_keys(ids: Dictionary, common) -> Array:
	var keys := []
	var raw: Dictionary = common if typeof(common) == TYPE_DICTIONARY else {}
	var count = raw.get("players_data")
	if typeof(count) != TYPE_INT and typeof(count) != TYPE_REAL:
		return keys
	for p in int(count):
		var gear = ids.get("g%d" % p)
		var offered := [_at(raw.get("shop_items"), p), _at(raw.get("item_steals"), p)]
		keys.append({"data": [ids.get("p%d" % p), gear], "gear": gear, "items": hash(offered)})
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
	if not get_tree().is_connected("node_added", self, "_on_node_added"):
		get_tree().connect("node_added", self, "_on_node_added")
	_loading_msec = OS.get_ticks_msec()
	if get_tree().change_scene(SHOP_SCENE) != OK:
		_loading_msec = -LOADING_TIMEOUT_MSEC
		ModLoaderLog.error("Could not load the shop scene", LOG_NAME)


# Muted from node_added (not ready), so sounds from the shop's own _ready are covered too.
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
	_popup_memo = {}
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
	var started := OS.get_ticks_usec()  # "shop panels" (apply has its own mark)
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
	_apply_locks(shop, body.get("locks"))
	_host_kinds = []
	var kinds = body.get("kinds")
	for kind in kinds if typeof(kinds) == TYPE_ARRAY else []:
		if typeof(kind) == TYPE_STRING:
			_host_kinds.append(kind)
	shop.update_go_next_button_text()
	var you: int = body.you if typeof(body.get("you")) == TYPE_INT else -1
	_mirror_view(shop, you, body.get("pages"))
	_mirror_popups(shop, you, body)
	if you >= 0 and you < RunData.get_player_count():
		local.take_over(you)
		local.on_state(_int_at(body.get("seqs"), you), shop._player_pressed_go_button[you])
		local.on_mecas(_list_at(body.get("mecas"), you))
	else:
		local.stop("no own panel in the host's state")
	ClientReport.mark(ClientReport.Mark.SHOP_PANELS, OS.get_ticks_usec() - started)


# The per-player part of BaseShop._ready, re-run with the host's values (no RNG anywhere).
# changed: which parts of this player's panel differ from what it shows ("data", "gear",
# "items"). The rest is left alone: a rebuild of the own panel would fight its local cursor.
func _refresh_player(
	shop: Node, state: Dictionary, p: int, changed: Dictionary, body: Dictionary
) -> void:
	if changed.gear:
		_refresh_gear(shop, p)
	elif changed.data:
		_refresh_gear(shop, p, false)
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
				_deactivate(shop, p, node)
	shop._refresh_currency_dependent_buttons(p)
	shop._refresh_bonus_free_reroll(p)

	var go: bool = body.go[p] if p < body.go.size() else false
	shop._player_pressed_go_button[p] = go
	shop._get_checkmark(p).visible = go


# BaseShop.on_shop_item_deactivated sends a cursor that rests on no shop item to the default
# control. From the host's state (a buy that arrives late) that would pull it out of an open popup:
# only a cursor on that item, or on nothing, moves.
static func _deactivate(shop: Node, p: int, node: Node) -> void:
	var emulator = Utils.get_focus_emulator(p, shop)
	var control = emulator.focused_control if emulator != null else null
	var moves: bool = not is_instance_valid(control) or node.is_a_parent_of(control)
	node.deactivate()
	if moves:
		shop.on_shop_item_deactivated(node, p)


# By slot: BaseShop._update_visual_locks matches by index in the offered list, which is wrong
# once an item is bought. The own panel shows a press the host has not answered yet.
func _apply_locks(shop: Node, locks) -> void:
	for p in RunData.get_player_count():
		var flags := _list_at(locks, p)
		var nodes: Array = shop._get_shop_items_container(p)._shop_items
		var popup = shop._get_item_popup(p)
		for i in nodes.size():
			var node = nodes[i]
			if not node.active or node.item_data == null:
				continue
			var host_locked: bool = i < flags.size() and typeof(flags[i]) == TYPE_BOOL and flags[i]
			var locked: bool = local.lock_shown(node, host_locked)
			if locked == node.locked:
				continue
			ShopLocal.show_lock(node, locked)
			if popup.shop_item == node:
				popup.show_shop_hints(node)  # "lock" <-> "unlock"


# The rows keep every element that shows the same (UpgradesGear.sync_inventory), so a cursor on
# one stays, and so does the popup opened from one (its buttons, another mod's menu in it). Only
# when that element is gone does the popup close; the cursor then goes to the element at its place.
# items false: only p's other parts changed, its weapons are new objects of the same weapons (the
# elements and an open popup are pointed at them, as a shop intent names them).
func _refresh_gear(shop: Node, p: int, items := true) -> void:
	var gear = shop._get_gear_container(p)
	var inventories := [gear.weapons_container._elements, gear.items_container._elements]
	var emulator = Utils.get_focus_emulator(p, shop)
	var popup = shop._get_item_popup(p)
	var manager = shop._popup_manager
	var pressed = manager._elements_pressed[p]
	var in_popup: bool = popup._focused and not _gear_place(pressed, inventories).empty()
	var element = pressed if in_popup else (emulator.focused_control if emulator != null else null)
	var place := _gear_place(element, inventories)
	var old_item = element.item if not place.empty() else null
	var panel = shop._get_coop_player_container(p)
	var resume := _gear_place(panel._resume_shop_control_focus, inventories)
	var weapons: Array = RunData.get_player_weapons(p)
	UpgradesGear.sync_gear(gear, emulator, weapons, RunData.get_player_items(p), items)
	if not resume.empty() and _gear_place(panel._resume_shop_control_focus, inventories).empty():
		# The game's way back from the stats page names no freed element.
		panel._resume_shop_control_focus = _live_at(inventories[resume[0]], resume[1])
	if place.empty():
		return
	var now := _gear_place(element, inventories)
	if not now.empty() and now[0] == place[0] and now[2] == place[2]:
		if in_popup:
			# Cancel puts the cursor back on the element holding this object.
			popup._item_data = element.item
			local.meca.retarget(old_item, element.item)
			_refresh_popup_buttons(popup, emulator)
		elif manager._elements_focused[p] == element:
			popup.display_element(element)  # what focusing it shows
		return
	if in_popup:
		# The view half of the game's "close the popup" handler: its item is gone.
		manager.reset_focus(p)
		shop._get_coop_player_container(p).on_hide_focused_inventory_popup()
	var target: Control = _live_at(inventories[place[0]], place[1])
	if target == null and local.active and p == local.you:
		target = shop._get_default_focus_control(p)
	if emulator != null and target != null and target.is_visible_in_tree():
		if emulator.focused_control == target:
			# The same node shows another item now: its focus shows that item's details.
			emulator.focused_control = null
		emulator.focused_control = target
	elif emulator != null and (in_popup or emulator.focused_control == element):
		emulator.focused_control = null  # never left on a freed element or a hidden popup


# [inventory, element index, what it shows] of a gear element, else [].
static func _gear_place(control, inventories: Array) -> Array:
	if not is_instance_valid(control) or control.is_queued_for_deletion():
		return []
	for i in inventories.size():
		if control.get_parent() == inventories[i] and control.item != null:
			return [i, control.get_index(), UpgradesGear.shows(control.item)]
	return []


# A popup kept open on its weapon shows the buttons for the run now (Combine once a second copy
# came, the recycle value). Not while it lists meca effects or another mod's menu (brotato:trade's
# player list, PopupView's together_menu): the game's refresh would close those. A cursor on a
# button that is hidden now goes to Cancel.
static func _refresh_popup_buttons(popup: Node, emulator) -> void:
	if popup.is_choosing_meca_upgrade():
		return
	if popup.has_method("together_menu") and popup.together_menu() != null:
		return
	popup._update_button_visibilities()
	var control = emulator.focused_control if emulator != null else null
	if is_instance_valid(control) and popup.is_a_parent_of(control) and not control.visible:
		emulator.focused_control = popup._cancel_button


# The live element at index in inventory (the last one if there are fewer), null when it has none.
static func _live_at(inventory: Node, index: int):
	var live := []
	for child in inventory.get_children():
		if not child.is_queued_for_deletion():
			live.append(child)
	return live[int(min(index, live.size() - 1))] if not live.empty() else null


# View state that is not this client's own: the other players' pages, and the "endless" toggle.
func _mirror_view(shop: Node, you: int, pages) -> void:
	for p in RunData.get_player_count():
		var panel = shop._get_coop_player_container(p)
		var page := _int_at(pages, p)
		# Clamped: the damage page may be off here (ui/damage_views.gd).
		var shown := int(min(page, panel.carousel._get_max_index()))
		if p != you and page >= 0 and panel.carousel.index != shown:
			panel.carousel.index = page
		var endless = panel.get("_endless_button")
		if endless != null and endless.visible and endless.pressed != RunData.is_endless_run:
			endless.set_pressed_no_signal(RunData.is_endless_run)


# The other players' open menus. Their cursors go back where the host has them: opening a popup
# moves the game's cursor to Cancel.
func _mirror_popups(shop: Node, you: int, body: Dictionary) -> void:
	var changed := false
	for p in RunData.get_player_count():
		if p != you:
			var view = _at(body.get("popups"), p)
			changed = _apply_popup(shop, p, view, _list_at(body.get("mecas"), p)) or changed
	if changed and focus_sync != null:
		focus_sync.reapply()


func _on_lobby_left() -> void:
	_stop_watching_scenes()
	_loading_msec = -LOADING_TIMEOUT_MSEC
	_block_remote_buttons(false)
	run_cache.clear()
	local.stop("lobby left")
	local.set_paused(false)
	_client_shop = null
	_client_shop_id = 0
	_state = {}
	_run_ids = {}
	_state_keys = []
	_applied = {}
	_host_kinds = []
	_reported_popups = {}
	_popup_memo = {}


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
