extends Node
# The end-of-wave level-up / crate panels (main.tscn's coop UpgradesUI).
#
# Host: owns every decision. While the panels are visible it sends UPGRADES_STATE on change:
#   run state + per player
#   ["none"] | ["done"] | ["upgrades", [upgrade ids], level, reroll_price] | ["item", json, id]
#   plus, per player, a panel revision (seqs) and the carousel page (pages).
# Client: shows those options in its own copy of the panels; nothing is rolled locally.
#   Its OWN panel runs here: its buttons drive its slot's FocusEmulator locally
#   (InputSync.set_local_device), so cursor, pages (upgrades / gear / stats), popups and the
#   description scroll cost no round trip. The panel's decision signals are rewired from the
#   game's handlers to UPGRADE_INTENT messages. The host checks an intent against the sender's
#   current panel (revision + option id) and runs the panel's own handler, so the rules stay
#   in the game's code and nothing is decided on a client.
#   Its cursor and page also travel as UPGRADE_FOCUS: what the host and the others see.
# The other players' panels stay mirrored: cursors by FocusSync, pages from UPGRADES_STATE.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const CHECK_INTERVAL := 0.1
const PATH_TYPES := [TYPE_INT_ARRAY, TYPE_ARRAY]
const ITEM_KINDS := ["take", "discard", "ban"]
# UpgradesUI._ready: container signal -> UpgradesUI handler (bound to the player index).
const DECISION_HANDLERS := {
	"choose_button_pressed": "_on_choose_button_pressed",
	"item_take_button_pressed": "_on_take_button_pressed",
	"item_discard_button_pressed": "_on_discard_button_pressed",
	"item_ban_button_pressed": "_on_ban_button_pressed",
}
# UpgradesUI._setup_weapons_inventory (crates that give weapons): these change RunData
# directly. Not sent as intents yet, so they do nothing on a client.
const WEAPON_POPUP_HANDLERS := {
	"item_combine_button_pressed": "_on_weapon_combine_button_pressed",
	"item_discard_button_pressed": "_on_weapon_discard_button_pressed",
	"item_meca_upgrade_selected": "_on_weapon_meca_upgrade_selected",
}

var session: Node = null
var battle_host: Node = null
var battle_client: Node = null
var focus_sync: Node = null
var input_sync: Node = null
var last_intent := {}  # client: the last decision sent (also read by the tests)

# host
var _last_sent_key := ""
var _check_left := 0.0
var _seq_ui: Node = null
var _seqs := []  # per player: bumped whenever the panel shows something new
var _seq_keys := []

# client
var _pending := {}  # state that arrived while the battle scene was still loading
var _guarded_ui: Node = null  # the puppet UpgradesUI whose decision signals are rewired
var _applied := {}  # player index -> key of the entry last applied
var _run_key := []
var _own: Node = null  # this client's own container
var _own_seq := -1
var _own_item_id := ""
var _local_active := false
var _sent_focus := ""


func setup(netplay_session: Node, host_battle: Node, client_battle: Node) -> void:
	session = netplay_session
	battle_host = host_battle
	battle_client = client_battle
	session.connect("message", self, "_on_message")
	session.connect("peer_ready", self, "_on_peer_ready")
	battle_client.connect("battle_entered", self, "_on_battle_entered")
	battle_client.connect("battle_left", self, "stop_local")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func _process(delta: float) -> void:
	if _local_active:
		_report_own_focus()
	if not session.is_host() or not battle_host.is_in_battle():
		_last_sent_key = ""
		_block_remote_buttons(false)
		return
	var ui = battle_host._main.get("_coop_upgrades_ui")
	var showing: bool = ui != null and ui.visible
	# The pause menu is the host's: a remote player who paused navigates it with its buttons.
	_block_remote_buttons(showing and not get_tree().paused)
	if not showing:
		return
	_check_left -= delta
	if _check_left > 0.0:
		return
	_check_left = CHECK_INTERVAL
	var players := capture(ui)
	_update_seqs(ui, players)
	var golds := []
	for p in RunData.get_player_count():
		golds.append(RunData.get_player_gold(p))
	var key := var2str([players, _seqs, _pages(ui, players.size()), golds])
	if key == _last_sent_key:
		return
	_last_sent_key = key
	session.broadcast_reliable(Protocol.Msg.UPGRADES_STATE, body(players))  # encodes the run


func _on_message(steam_id: int, msg_type: int, msg) -> void:
	match msg_type:
		Protocol.Msg.UPGRADES_STATE:
			if session.is_client() and steam_id == session.transport.host_id:
				_on_state(msg)
		Protocol.Msg.UPGRADE_INTENT:
			var ui = _host_ui(msg)
			if ui != null and host_apply_intent(ui, battle_host._player_index_of(steam_id), msg):
				_check_left = 0.0
		Protocol.Msg.UPGRADE_FOCUS:
			var ui = _host_ui(msg)
			if ui != null:
				host_apply_focus(
					ui, battle_host._player_index_of(steam_id), msg.get("page"), msg.get("path")
				)


# --- host ---


func body(players: Array) -> Dictionary:
	var ui = battle_host._main.get("_coop_upgrades_ui")
	_update_seqs(ui, players)
	return {
		"battle_id": battle_host._battle_id,
		"visible": true,
		"run": RunStateCodec.encode(),
		"players": players,
		"seqs": _seqs.duplicate(),
		"pages": _pages(ui, players.size()),
	}


static func _pages(ui: Node, count: int) -> Array:
	var pages := []
	for p in count:
		pages.append(ui._get_player_container(p).carousel.index)
	return pages


static func capture(ui: Node) -> Array:
	var players := []
	for p in RunData.get_player_count():
		var container = ui._get_player_container(p)
		if container._checkmark_group.visible:
			players.append(["done"])
		elif container._upgrades_container.visible:
			var ids := []
			for upgrade in container._old_upgrades:
				ids.append(upgrade.my_id)
			players.append(["upgrades", ids, container._level, container._reroll_price])
		elif container._items_container.visible and container._item_data != null:
			var item = container._item_data
			players.append(["item", JSON.print(item.serialize()), item.my_id])
		else:
			players.append(["none"])
	return players


# A player's decision, sent from its own panel. Only applied to what that panel shows right
# now: the revision catches a press that was made on options the host has since replaced, the
# id a mismatch in content. Returns whether a handler ran.
func host_apply_intent(ui: Node, p: int, msg: Dictionary) -> bool:
	if p < 0 or p >= RunData.get_player_count() or p >= _seqs.size():
		return false
	var kind = msg.get("kind")
	var id = msg.get("id")
	if typeof(kind) != TYPE_STRING or typeof(id) != TYPE_STRING:
		return false
	if typeof(msg.get("seq")) != TYPE_INT or msg.seq != _seqs[p]:
		return false
	var container = ui._get_player_container(p)
	if container._checkmark_group.visible:
		return false
	if kind == "choose" or kind == "reroll":
		if not container._upgrades_container.visible:
			return false
		if kind == "reroll":
			if not container._reroll_button.visible:
				return false
			container._on_RerollButton_pressed()
		else:
			var upgrade = _find(container._old_upgrades, id)
			if upgrade == null:
				return false
			container._on_choose_button_pressed(upgrade)
	elif kind in ITEM_KINDS:
		var item = container._item_data
		if not container._items_container.visible or item == null or item.my_id != id:
			return false
		if kind == "take":
			var meca = msg.get("meca")
			if item.is_meca and typeof(meca) == TYPE_INT and (meca == 0 or meca == 1):
				container._meca_effect_choice_selected = meca
				container.update_effect_choice_buttons_visuals()
			container._on_TakeButton_pressed()
		elif kind == "discard":
			container._on_DiscardButton_pressed()
		elif container._ban_button.visible:
			container._on_BanButton_pressed()
		else:
			return false
	else:
		return false
	# The handlers show the next options right away: a second press on the old ones is stale.
	_update_seqs(ui, capture(ui))
	return true


# A remote player's own cursor and page, for the host's screen and (through FocusSync and
# UPGRADES_STATE) the other clients'. Cosmetic: decisions never depend on it.
func host_apply_focus(ui: Node, p: int, page, path) -> void:
	if p < 0 or p >= RunData.get_player_count():
		return
	var container = ui._get_player_container(p)
	var emulator = container.focus_emulator
	if emulator == null or emulator.player_index != p:
		return  # finished: the game parks the emulator (player_index -1)
	var carousel = container.carousel
	if typeof(page) == TYPE_INT and page >= 0 and page != carousel.index:
		carousel.index = page  # the setter clamps and shows that page
	var indices := _int_path(path)
	if indices.empty():
		return
	var control = ScenePaths.resolve(container, indices)
	if control is Control and control.is_visible_in_tree() and emulator.focused_control != control:
		emulator.focused_control = control


func _host_ui(msg):
	if not session.is_host() or not battle_host.is_in_battle():
		return null
	if typeof(msg) != TYPE_DICTIONARY or msg.get("battle_id") != battle_host._battle_id:
		return null
	var ui = battle_host._main.get("_coop_upgrades_ui")
	return ui if ui != null and ui.visible else null


# The revision changes with what the panel shows, even when two options in a row look the same
# (the same crate item twice): the option being processed and the reroll count are part of it.
func _update_seqs(ui: Node, players: Array) -> void:
	if ui != _seq_ui:
		_seq_ui = ui
		_seqs = []
		_seq_keys = []
	while _seqs.size() < players.size():
		_seqs.append(0)
		_seq_keys.append("")
	for p in players.size():
		var container = ui._get_player_container(p)
		var option = ui._showing_option[p]
		var item = container._item_data
		var key := var2str(
			[
				players[p],
				option.get_instance_id() if option != null else 0,
				item.get_instance_id() if item != null else 0,
				container._reroll_count,
			]
		)
		if key != _seq_keys[p]:
			_seq_keys[p] = key
			_seqs[p] += 1


func _block_remote_buttons(block: bool) -> void:
	if input_sync == null:
		return
	var all: int = (1 << VirtualDevices.BUTTON_ACTIONS.size()) - 1
	input_sync.blocked_buttons = all & ~(1 << VirtualDevices.PAUSE_INDEX) if block else 0


# A (re)joining client needs the current panels too: force a resend.
func _on_peer_ready(_steam_id: int) -> void:
	_last_sent_key = ""


# --- client ---


func _on_battle_entered() -> void:
	if not _pending.empty() and _pending.get("battle_id") == battle_client._battle_id:
		apply(battle_client._main, _pending)
	_pending = {}


func _on_state(msg) -> void:
	if typeof(msg) != TYPE_DICTIONARY or msg.get("battle_id") != battle_client._battle_id:
		return
	if not battle_client.is_in_battle():
		_pending = msg  # BATTLE_START just arrived; the scene is still loading
		return
	apply(battle_client._main, msg)


func apply(main: Node, msg: Dictionary) -> void:
	if typeof(msg.get("players")) != TYPE_ARRAY:
		return
	var ui = main.get("_coop_upgrades_ui")
	if ui == null:
		return
	var you: int = battle_client._you
	_guard(ui, you)
	var run_changed := _apply_run(msg.get("run"))
	ui.show()
	var seqs = msg.get("seqs")
	var pages = msg.get("pages")
	for p in min(msg.players.size(), RunData.get_player_count()):
		var entry = msg.players[p]
		if typeof(entry) != TYPE_ARRAY or entry.empty() or typeof(entry[0]) != TYPE_STRING:
			continue
		var container = ui._get_player_container(p)
		if run_changed:
			container.update_inventory()
			container.update_stats()
			container._update_gold_label()
		var seq: int = _int_at(seqs, p)
		var key := var2str([seq, entry])
		# Only a panel that shows something new is rebuilt: the others keep their state (a
		# rebuild of this client's own panel would fight its local cursor).
		if seq < 0 or _applied.get(p) != key:
			_applied[p] = key
			_show_entry(container, p, entry)
			if p == you:
				_own_seq = seq
				_own_item_id = entry[2] if entry[0] == "item" and entry.size() == 3 else ""
				_on_own_panel_changed(ui, container, entry[0])
		var page: int = _int_at(pages, p)
		if p != you and page >= 0 and container.carousel.index != page:
			container.carousel.index = page


func stop_local() -> void:
	if not _local_active:
		return
	_local_active = false
	_sent_focus = ""
	if input_sync != null:
		input_sync.set_local_device(-1)
	if focus_sync != null:
		focus_sync.local_emulators = []


func _show_entry(container, p: int, entry: Array) -> void:
	match entry[0]:
		"done":
			container.finish()
		"upgrades":
			if entry.size() == 4:
				_show_upgrades(container, p, entry[1], int(entry[2]), int(entry[3]))
		"item":
			if entry.size() == 3:
				_show_item(container, entry[1], entry[2])


# The run state is only re-applied (and the inventories and stats rebuilt) when it changed.
func _apply_run(payload) -> bool:
	var key := []
	if typeof(payload) == TYPE_DICTIONARY and typeof(payload.get("data")) == TYPE_RAW_ARRAY:
		key = [payload.get("size"), hash(payload.data)]
	if not key.empty() and key == _run_key:
		return false
	var state := RunStateCodec.decode(payload)
	if state.empty():
		return false
	RunStateCodec.apply(state)
	_run_key = key
	return true


# Once per puppet scene. On a client no panel may decide anything: the containers' decision
# signals lose the game's handlers (which change RunData and roll options), and this client's
# own container gets ours instead. A new button the game adds stays unconnected here, so it
# does nothing rather than change the local copy of the run.
func _guard(ui: Node, you: int) -> void:
	if ui == _guarded_ui:
		return
	_guarded_ui = ui
	_applied = {}
	_run_key = []
	_own = null
	_own_seq = -1
	_own_item_id = ""
	stop_local()
	for p in RunData.get_player_count():
		var container = ui._get_player_container(p)
		for signal_name in DECISION_HANDLERS:
			_disconnect(container, signal_name, ui, DECISION_HANDLERS[signal_name])
		_disconnect(container._reroll_button, "pressed", container, "_on_RerollButton_pressed")
		for signal_name in WEAPON_POPUP_HANDLERS:
			_disconnect(container.item_popup, signal_name, ui, WEAPON_POPUP_HANDLERS[signal_name])
		# The "still to process" icons are never filled on a puppet, and the container's press
		# handlers would look up the option there (a crate's ConsumableData, unknown here).
		container._things_to_process_container = null
		if p != you:
			continue
		_own = container
		container.connect("choose_button_pressed", self, "_on_own_choose")
		for kind in ITEM_KINDS:
			container.connect("item_%s_button_pressed" % kind, self, "_on_own_item", [kind])
		container._reroll_button.connect("pressed", self, "_on_own_reroll")


static func _disconnect(source: Object, signal_name: String, target: Object, method: String):
	if source != null and source.is_connected(signal_name, target, method):
		source.disconnect(signal_name, target, method)


# This client's panel shows new options: it takes local control (or gives it up when done).
func _on_own_panel_changed(ui: Node, container: Node, kind: String) -> void:
	if kind != "upgrades" and kind != "item":
		stop_local()
		return
	if not _local_active:
		_local_active = true
		# main._on_EndWaveTimer_timeout does this on the host; it never runs on a puppet.
		Utils.set_process_input_where_defined(ui, true)
		if input_sync != null:
			input_sync.set_local_device(
				CoopService.get_remapped_player_device(container.player_index)
			)
		if focus_sync != null:
			focus_sync.local_emulators = [container.focus_emulator]
	container.call_deferred("focus")  # the game's own starting cursor for the current page


func _report_own_focus() -> void:
	if not battle_client.is_in_battle() or not is_instance_valid(_own):
		stop_local()
		return
	var control = _own.focus_emulator.focused_control
	var path := PoolIntArray()
	if control != null and is_instance_valid(control):
		path = ScenePaths.path_of(control, _own)
	var message := {
		"battle_id": battle_client._battle_id, "page": _own.carousel.index, "path": path
	}
	var key := var2str(message)
	if key != _sent_focus:
		_sent_focus = key
		_send(Protocol.Msg.UPGRADE_FOCUS, message)


func _on_own_choose(upgrade) -> void:
	_send_intent("choose", upgrade.my_id)


func _on_own_item(_item_data, kind: String) -> void:
	# The id the host sent, not the local object's: taking a meca item replaces it locally.
	_send_intent(kind, _own_item_id, _own._meca_effect_choice_selected)


func _on_own_reroll() -> void:
	_send_intent("reroll", "")


func _send_intent(kind: String, id: String, meca := -1) -> void:
	last_intent = {
		"battle_id": battle_client._battle_id,
		"seq": _own_seq,
		"kind": kind,
		"id": id,
		"meca": meca,
	}
	_send(Protocol.Msg.UPGRADE_INTENT, last_intent)


func _send(msg_type: int, message: Dictionary) -> void:
	if session.is_client():
		session.send_reliable(session.transport.host_id, msg_type, message)


# show_upgrades_for_level() without ItemService.get_upgrades (RNG): the host's options instead.
static func _show_upgrades(container, p: int, ids: Array, level: int, price: int) -> void:
	var upgrades := []
	for id in ids:
		var upgrade = _find(ItemService.upgrades, id)
		if upgrade != null:
			upgrades.append(upgrade)
	container._level = level
	container._old_upgrades = upgrades
	container._reroll_price = price
	container._reroll_button.init(price, p)
	var upgrade_uis: Array = container._get_upgrade_uis()
	for i in upgrade_uis.size():
		upgrade_uis[i].visible = i < upgrades.size()
		if upgrade_uis[i].visible:
			upgrade_uis[i].set_upgrade(upgrades[i], p)
	container._reroll_button.visible = upgrades.size() > 1
	container._update_gold_label()
	container._checkmark_group.hide()
	container._items_container.hide()
	container._upgrades_container.show()


# Crate items can be cursed/modified copies: rebuild from the base element + serialized changes.
static func _show_item(container, json: String, id: String) -> void:
	var parsed := JSON.parse(json)
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return
	var base = _find(ItemService.items, id)
	if base == null:
		base = _find(ItemService.weapons, id)
	if base == null:
		return
	var item = base.duplicate()
	item.deserialize_and_merge(parsed.result)
	container._checkmark_group.hide()
	container.show_item(item)


static func _find(elements: Array, my_id: String):
	for element in elements:
		if element.my_id == my_id:
			return element
	return null


# values[index] when it is an int, else -1 (network data: seqs / pages may be missing).
static func _int_at(values, index: int) -> int:
	if typeof(values) != TYPE_ARRAY or index >= values.size():
		return -1
	return values[index] if typeof(values[index]) == TYPE_INT else -1


# A child-index path from the network: empty unless it is a list of ints.
static func _int_path(value) -> PoolIntArray:
	var path := PoolIntArray()
	if not (typeof(value) in PATH_TYPES):
		return path
	for index in value:
		if typeof(index) != TYPE_INT:
			return PoolIntArray()
		path.append(index)
	return path
