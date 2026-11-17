extends Node
# The end-of-wave level-up / crate panels (main.tscn's coop UpgradesUI).
#
# Host: owns every decision. While the panels are visible it provides the state stream's
#   UPGRADES section (sync/state_stream.gd; see body() for the fields): run state + per player
#   what its panel shows, a panel revision, the carousel page and the meca upgrade rolls. The
#   run state is serialized only when it can have changed (run_cache, sync/run_cache.gd, as in
#   the shop): a page, a revision, a meca roll or a resend reuses the last one. It travels in
#   parts, per peer only those it lacks (sync/run_parts.gd: a level-up choice is one part).
# Client: shows those options in its own copy of the panels; nothing is rolled locally.
#   Its OWN panel runs here: its buttons drive its slot's FocusEmulator locally
#   (InputSync.set_local_device), so cursor, pages (upgrades / gear / stats), popups and the
#   description scroll cost no round trip. The panel's decision signals are rewired from the
#   game's handlers to UPGRADE_INTENT messages. The host checks an intent against the sender's
#   current panel (revision + option id) and runs the panel's own handler, so the rules stay
#   in the game's code and nothing is decided on a client.
#   The same goes for the crate weapon popup (characters whose crates give weapons): combine,
#   recycle and meca upgrade leave as intents that name the weapon by slot and id. The meca
#   upgrade's two options are rolled on the host on request and shown from the state (mecas);
#   the pick is an option index (sync/meca_choice.gd).
#   Its cursor and page also travel as UPGRADE_FOCUS: what the host and the others see.
#   Keyboard and mouse on the own panel, and the mouse kept off the others: sync/local_panel.gd.
# The other players' panels stay mirrored: cursors by FocusSync, pages from the state.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const LocalPanel := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/local_panel.gd")
const MecaChoice := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/meca_choice.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const RunCache := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_cache.gd")
const RunParts := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_parts.gd")
const UpgradesGear := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/upgrades_gear.gd"
)
const CHECK_INTERVAL := 0.1
# A state can wait for the puppet battle scene to load (on a rejoin the stream's resync comes
# right after BATTLE_START, which starts the load); it used to wait for battle_entered without
# a limit.
const PENDING_TIMEOUT_SEC := 30.0
const ITEM_KINDS := ["take", "discard", "ban"]
# UpgradesUI._ready: container signal -> UpgradesUI handler (bound to the player index).
const DECISION_HANDLERS := {
	"choose_button_pressed": "_on_choose_button_pressed",
	"item_take_button_pressed": "_on_take_button_pressed",
	"item_discard_button_pressed": "_on_discard_button_pressed",
	"item_ban_button_pressed": "_on_ban_button_pressed",
}
# UpgradesUI._setup_weapons_inventory (crates that give weapons): popup signal -> UpgradesUI
# handler. These change RunData directly, so no client keeps them; the own popup's presses
# leave as WEAPON_KINDS intents instead.
const WEAPON_POPUP_HANDLERS := {
	"item_combine_button_pressed": "_on_weapon_combine_button_pressed",
	"item_discard_button_pressed": "_on_weapon_discard_button_pressed",
	"item_meca_upgrade_selected": "_on_weapon_meca_upgrade_selected",
}
# weapon_meca_roll: the host rolls (or finds) the two meca options; weapon_meca: picks one.
const WEAPON_KINDS := ["weapon_combine", "weapon_discard", "weapon_meca_roll", "weapon_meca"]
const MAX_HELD := 8  # intents held while the host is paused (a few presses per player)
const LOG_NAME := "einfluffles-BrotatoTogether:UpgradesSync"
const DEVICE_OWNER := "upgrades"  # InputSync.set_local_device

var session: Node = null
var state_stream: Node = null  # sync/state_stream.gd (set by mod_main.gd)
var battle_host: Node = null
var battle_client: Node = null
var focus_sync: Node = null
var input_sync: Node = null
var last_intent := {}  # client: the last decision sent (also read by the tests)
var run_cache = RunCache.new("upgrades")  # host: the run state, serialized on change
var run_sender = null  # host: RunParts.Sender, shared with ShopSync (set by mod_main.gd)
var run_store = null  # client: RunParts.Store, shared with ShopSync (set by mod_main.gd)

# host
var _seq_ui_id := 0  # instance id of the UpgradesUI the revisions belong to
var _seqs := []  # per player: bumped whenever the panel shows something new
var _seq_keys := []
# Intents that came while the host was paused: [UpgradesUI instance id, player, msg], applied in
# order once it resumes (see host_apply_intent).
var _held := []
var _view_bytes := 0  # the last body without its run (RunParts.Sender's counters)

# client
var _guarded_ui: Node = null  # the puppet UpgradesUI whose decision signals are rewired
var _applied := {}  # player index -> key of the entry last applied
var _run_key := {}  # the run part ids RunData has
var _own: Node = null  # this client's own container
var _own_seq := -1
var _own_item_id := ""
var _local_active := false
var _sent_focus := ""
var _meca = MecaChoice.new()  # the own popup's meca upgrade
var _local_panel: Node = null  # in the guarded UI: device type and mouse for the own panel


func setup(netplay_session: Node, host_battle: Node, client_battle: Node) -> void:
	session = netplay_session
	battle_host = host_battle
	battle_client = client_battle
	session.connect("message", self, "_on_message")
	session.connect("peer_ready", self, "_on_peer_ready")
	session.transport.connect("lobby_left", self, "_on_lobby_left")
	state_stream.register_provider(StateStream.UPGRADES, self, CHECK_INTERVAL, true)
	state_stream.register_handler(StateStream.UPGRADES, self, PENDING_TIMEOUT_SEC)
	_meca.connect("roll_requested", self, "_on_own_meca_roll")
	_meca.connect("picked", self, "_on_own_meca_picked")
	battle_client.connect("battle_entered", self, "_on_battle_entered")
	battle_client.connect("battle_left", self, "_on_battle_left")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func _process(_delta: float) -> void:
	if is_instance_valid(_local_panel):
		_local_panel.blocked = input_sync != null and input_sync.local_input_blocked
	if _local_active:
		_report_own_focus()
	var ui = _showing_ui()
	if ui == null:
		# Panels closed or battle over (also without peers, when the stream asks nothing): the
		# run's text does not outlive the wave.
		run_sender.close(run_cache)
	_apply_held(ui)
	# The pause menu is the host's: a remote player who paused navigates it with its buttons.
	var showing: bool = session.is_host() and ui != null
	_block_remote_buttons(showing and not get_tree().paused)


func _on_message(steam_id: int, msg_type: int, msg) -> void:
	match msg_type:
		Protocol.Msg.UPGRADE_INTENT:
			var ui = _host_ui(msg)
			if ui != null and host_apply_intent(ui, battle_host._player_index_of(steam_id), msg):
				state_stream.flush(StateStream.UPGRADES)  # the answer goes out next frame
		Protocol.Msg.UPGRADE_FOCUS:
			var ui = _host_ui(msg)
			if ui != null:
				host_apply_focus(
					ui, battle_host._player_index_of(steam_id), msg.get("page"), msg.get("target")
				)


# --- host ---


# The host's UpgradesUI while its battle shows the panels, else null. No host check: the stream
# only asks its provider while host, and the tests ask it on a battle without a session.
func _showing_ui():
	if not battle_host.is_in_battle():
		return null
	var ui = battle_host._main.get("_coop_upgrades_ui")
	return ui if ui != null and ui.visible else null


# StateStream provider: "" (inactive: the clients get null once) unless the panels show. Called
# every CHECK_INTERVAL and on peer_ready, so it is the text of the panels and the run state's
# revision (run_cache: serialized only when it can have changed), never the run. Also where the
# revisions follow the panels between intents (_update_seqs, as the old poll did).
func state_key(_section: int) -> String:
	var ui = _showing_ui()
	if ui == null:
		run_sender.close(run_cache)
		return ""
	var players := capture(ui)
	_update_seqs(ui, players)
	run_cache.title = "Level-up panels, battle %d" % battle_host._battle_id
	run_cache.refresh(ui, [], _options(ui))
	var golds := []
	for p in RunData.get_player_count():
		golds.append(RunData.get_player_gold(p))
	var pages := _pages(ui, players.size())
	var rest := [battle_host._battle_id, players, _seqs, pages, golds, _mecas(ui)]
	return str(run_cache.rev) + var2str(rest)


# Built only when the stream sends.
func state_body(_section: int):
	var ui = _showing_ui()
	return body(capture(ui)) if ui != null else null


# battle_id, run (sync/run_parts.gd: every part here, state_patch narrows it to what the peer
# lacks), and per player:
#   players: ["none"] | ["done"] | ["upgrades", [upgrade ids], level, reroll_price]
#     | ["item", json, id]
#   seqs: the panel revision (bumped when it shows something new; an intent names it)
#   pages: the carousel page
#   mecas: the meca upgrade rolls its crate weapon popup remembers ([[weapon slot, weapon my_id,
#     stat key hash, value, stat key hash, value]], MecaChoice.entries, as in the shop state)
# The run is run_cache's, compressed once per change. Its refresh here is free right after
# state_key (same check: nothing new); called alone (tests, StateStream.message_for) it still
# sees a change of the fingerprint, so no body carries a run older than its own check.
func body(players: Array) -> Dictionary:
	var ui = battle_host._main.get("_coop_upgrades_ui")
	_update_seqs(ui, players)
	run_cache.refresh(ui, [], _options(ui))
	run_sender.offer(run_cache)
	var body := {
		"battle_id": battle_host._battle_id,
		"players": players,
		"seqs": _seqs.duplicate(),
		"pages": _pages(ui, players.size()),
		"mecas": _mecas(ui),
	}
	_view_bytes = var2bytes(body).size()
	body["run"] = run_cache.all()
	return body


# The run parts the peer lacks (state_sent records them as sent).
func state_patch(_section: int, steam_id: int) -> Dictionary:
	return {"run": run_sender.run_for(steam_id)}


func state_sent(_section: int, steam_id: int) -> void:
	run_sender.commit(steam_id, _view_bytes)


static func _pages(ui: Node, count: int) -> Array:
	var pages := []
	for p in count:
		pages.append(ui._get_player_container(p).carousel.index)
	return pages


# Per player, the meca upgrade rolls its crate weapon popup remembers ([] without that popup).
static func _mecas(ui: Node) -> Array:
	var mecas := []
	for p in RunData.get_player_count():
		var popup = ui._get_player_container(p).item_popup
		mecas.append(MecaChoice.entries(popup, p) if ui._weapons_inventory_enabled[p] else [])
	return mecas


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


# The panels' part of run_cache's fingerprint (the shared part, RunData and every player, is
# RunCache.fingerprint's), per player: the option its panel processes, the crate item it shows,
# its rerolls and whether it is done. Every decision moves it (an absent player's and the host's
# own presses too, which no intent forces), also one whose effect on the run the shared part
# might not see (a crate item recycled for 0 gold). What the decisions write to the run:
# - choose (main.on_upgrade_selected -> RunData.add_upgrade): upgrades_taken, stats
# - reroll (UpgradesUIPlayerContainer._on_RerollButton_pressed): gold, spyglass tracking
# - take (main.on_item_box_take_button_pressed): items (try_mutate_item_on_equip), or weapons
#   (_take_item_box_weapon: add_weapon, combine_weapon without a free slot)
# - discard (on_item_box_discard_button_pressed): gold, recycling tracking, meca parts refund
# - ban (on_item_box_ban_button_pressed): banned_items, remaining_ban_token, gold
# - extra crate items (UpgradesUI._get_extra_crate_item): treasure map tracking, with the above
# - crate weapon popup (UpgradesUI._on_weapon_combine / discard / meca_upgrade): weapons, gold,
#   meca parts, all in the shared part
# Pages, cursors, meca rolls and panel revisions are not run state: the key has them.
static func _options(ui: Node) -> Array:
	var values := []
	for p in RunData.get_player_count():
		var container = ui._get_player_container(p)
		var option = ui._showing_option[p]
		var item = container._item_data
		values.append(option.get_instance_id() if option != null else 0)
		values.append(item.get_instance_id() if item != null else 0)
		values.append(container._reroll_count)
		values.append(container._checkmark_group.visible)
	return values


# A player's decision, sent from its own panel. Only applied to what that panel shows right
# now: the revision catches a press that was made on options the host has since replaced, the
# id a mismatch in content. Returns whether a handler ran.
# While the host is paused nothing runs: the intent is held and applied once it resumes. The
# panels run on in a pause (pause_mode process), so the last decision would end them there and
# main.gd would load the shop with the tree still paused: a shop nobody can use, whose pause
# state turned every client's own panel off until the host paused and resumed again.
func host_apply_intent(ui: Node, p: int, msg: Dictionary) -> bool:
	if p < 0 or p >= RunData.get_player_count() or p >= _seqs.size():
		return false
	if get_tree().paused:
		if _held.size() < MAX_HELD:
			_held.append([ui.get_instance_id(), p, msg])
			ModLoaderLog.info(
				"Level-up intent of player %d held: the host is paused (%s)" % [p, msg.get("kind")],
				LOG_NAME
			)
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
	elif not (kind in WEAPON_KINDS) or not _host_apply_weapon(ui, p, kind, msg):
		return false
	if kind == "weapon_meca_roll":
		return true  # the panel shows nothing new; the roll goes out with the next state
	# The handlers show the next options right away: a second press on the old ones is stale.
	_update_seqs(ui, capture(ui))
	# The next check (the flush) serializes the run whatever the fingerprint says. The game's
	# handlers here change the run before they return; only a held ban
	# (_on_BanButton_pressed with ProgressData.settings.holding_button) ends later, in its own
	# coroutine, and is found by the fingerprint (banned items, ban tokens, gold).
	run_cache.force()
	return true


# The crate weapon popup of a player whose crates give weapons: combine, recycle or meca
# upgrade one of its weapons, named by its slot in the player's weapons and its id. The game's
# handlers decide (locked weapons, no partner, too few meca parts). Returns whether the
# weapons changed (a meca roll: whether the player's popup now remembers one for the weapon).
func _host_apply_weapon(ui: Node, p: int, kind: String, msg: Dictionary) -> bool:
	if not ui._weapons_inventory_enabled[p]:
		return false
	var weapons: Array = RunData.get_player_weapons(p)
	var slot = msg.get("weapon")
	if typeof(slot) != TYPE_INT or slot < 0 or slot >= weapons.size():
		return false
	var weapon = weapons[slot]
	if weapon.my_id != msg.id:
		return false
	var popup = ui._get_player_container(p).item_popup
	if kind == "weapon_meca_roll":
		# Kept in the host's copy of the player's popup, where the game keeps its own roll.
		return MecaChoice.roll(popup, weapon, p) != null
	var before := _weapons_key(p)
	match kind:
		"weapon_combine":
			ui._on_weapon_combine_button_pressed(weapon, p)
		"weapon_discard":
			ui._on_weapon_discard_button_pressed(weapon, p)
		"weapon_meca":
			# Only one of the two options rolled and sent for this weapon (meca: the index).
			var upgraded = MecaChoice.take(popup, weapon, p, msg.get("meca"))
			if upgraded == null:
				return false
			ui._on_weapon_meca_upgrade_selected(weapon, upgraded, p)
	return _weapons_key(p) != before


static func _weapons_key(p: int) -> Array:
	var key := []
	for weapon in RunData.get_player_weapons(p):
		key.append(weapon.get_instance_id())
	return key


# A remote player's own cursor and page, for the host's screen and (through FocusSync and the
# state) the other clients'. Cosmetic: decisions never depend on it.
# target: a ui/focus_targets.gd target naming one of p's own panel parts.
func host_apply_focus(ui: Node, p: int, page, target) -> void:
	if p < 0 or p >= RunData.get_player_count():
		return
	var container = ui._get_player_container(p)
	var emulator = container.focus_emulator
	if emulator == null or emulator.player_index != p:
		return  # finished: the game parks the emulator (player_index -1)
	var carousel = container.carousel
	if typeof(page) == TYPE_INT and page >= 0 and page != carousel.index:
		carousel.index = page  # the setter clamps and shows that page
	var control = FocusTargets.resolve(target, ui, p)
	if control is Control and control.is_visible_in_tree() and emulator.focused_control != control:
		emulator.focused_control = control


func _host_ui(msg):
	if not session.is_host() or not battle_host.is_in_battle():
		return null
	if typeof(msg) != TYPE_DICTIONARY or msg.get("battle_id") != battle_host._battle_id:
		return null
	return _showing_ui()


# A peer that (re)joins must get the true run state, every part of it: the stream's resync for
# it (its next step, after every peer_ready handler) is a check that serializes it; a
# difference found goes to everyone. (Harmless on a client: only the host's state_key refreshes.)
func _on_peer_ready(steam_id: int) -> void:
	run_cache.force()
	run_sender.forget(steam_id)


func _on_lobby_left() -> void:
	run_cache.clear()
	_held = []


# The revision changes with what the panel shows, even when two options in a row look the same
# (the same crate item twice): the option being processed and the reroll count are part of it.
# So are the player's weapons: the crate weapon popup changes them under the same crate item.
func _update_seqs(ui: Node, players: Array) -> void:
	if ui.get_instance_id() != _seq_ui_id:
		_seq_ui_id = ui.get_instance_id()
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
				_weapons_key(p),
			]
		)
		if key != _seq_keys[p]:
			_seq_keys[p] = key
			_seqs[p] += 1


# Every frame: the intents held during a pause, once the host resumed, in the order they came,
# on the panels they were sent for (gone panels drop them). The revision check still applies.
func _apply_held(ui) -> void:
	if _held.empty() or get_tree().paused:
		return
	var held := _held
	_held = []
	for entry in held:
		var applied := false
		if ui != null and ui.get_instance_id() == entry[0]:
			applied = host_apply_intent(ui, entry[1], entry[2])
		var outcome: String = "applied" if applied else "dropped"
		ModLoaderLog.info(
			"Held level-up intent of player %d %s after the pause" % [entry[1], outcome], LOG_NAME
		)
		if applied:
			state_stream.flush(StateStream.UPGRADES)


func _block_remote_buttons(block: bool) -> void:
	if input_sync == null:
		return
	var all: int = (1 << VirtualDevices.BUTTON_ACTIONS.size()) - 1
	input_sync.blocked_buttons = all & ~(1 << VirtualDevices.PAUSE_INDEX) if block else 0


# --- client ---


# A state that came before the puppet scene was ready is applied now, not a frame later.
func _on_battle_entered() -> void:
	state_stream.retry()


# StateStream: every body as it arrives, also one a newer body replaces before it is applied:
# its run parts are stored now (a missing one asks the host for a full resync).
func accept_state(_section: int, state, _revision: int) -> void:
	if typeof(state) == TYPE_DICTIONARY:
		run_store.take(state.get("run"), "level-up")


# StateStream handler. false keeps the state pending in the stream: its battle has not started
# here yet (not expected: a rejoin's resync follows its BATTLE_START) or its puppet scene is
# still loading. Applied again on a resync: apply() only rebuilds what changed.
func apply_state(_section: int, state, _revision: int) -> bool:
	if typeof(state) != TYPE_DICTIONARY or typeof(state.get("battle_id")) != TYPE_INT:
		return true  # malformed: dropped
	if state.battle_id != battle_client._battle_id or not battle_client.is_in_battle():
		return false
	var main: Node = battle_client._main
	if main.get("_coop_upgrades_ui") == null:
		return false
	apply(main, state)
	return true


# The host's panels are gone (everyone done, or its battle is over). The puppet's panels stay
# as they are until its scene goes (_on_battle_left), as before; the own panel stops taking
# input (its intents would name a revision the host no longer has), and a later state
# rebuilds every panel.
func clear_state(_section: int) -> void:
	stop_local("host's panels closed")
	_applied = {}
	_own_seq = -1
	_own_item_id = ""


func apply(main: Node, msg: Dictionary) -> void:
	if typeof(msg.get("players")) != TYPE_ARRAY:
		return
	var ui = main.get("_coop_upgrades_ui")
	if ui == null:
		return
	var you: int = battle_client._you
	_guard(ui, you)
	var changed = _apply_run(msg.get("run"))
	if changed == null:
		return  # a run part is missing: nothing applied, the host resyncs this client
	ui.show()
	var seqs = msg.get("seqs")
	var pages = msg.get("pages")
	for p in min(msg.players.size(), RunData.get_player_count()):
		var entry = msg.players[p]
		if typeof(entry) != TYPE_ARRAY or entry.empty() or typeof(entry[0]) != TYPE_STRING:
			continue
		var container = ui._get_player_container(p)
		var slot := UpgradesGear.weapon_slot(ui, container, p)  # before anything is rebuilt
		var in_popup: bool = ui._popup_manager._elements_pressed[p] != null
		# Only what the run change touched: a changed player's stats, gold and crate weapons (new
		# weapon objects), its gear (about 250 elements late in a run) only when its gear changed.
		var player_changed: bool = changed.has(p)
		var gear_changed: bool = changed.get(p, false)
		var gear_cursor := []
		if gear_changed:
			gear_cursor = UpgradesGear.rebuild_gear(ui, container, p)
		if player_changed:
			container.update_stats()
			container._update_gold_label()
		var seq: int = _int_at(seqs, p)
		var key := var2str([seq, entry])
		# Only a panel that shows something new is rebuilt: the others keep their state (a
		# rebuild of this client's own panel would fight its local cursor).
		var rebuilt: bool = seq < 0 or _applied.get(p) != key
		if rebuilt:
			_applied[p] = key
			_show_entry(container, p, entry)
		var on_weapon := false
		if rebuilt or player_changed:
			on_weapon = UpgradesGear.refresh_weapons(ui, container, p, slot, p == you)
		# After the crate list's refresh, which closes a popup opened from the gear.
		var on_gear: bool = not on_weapon and UpgradesGear.put_gear_cursor(container, gear_cursor)
		if rebuilt and p == you:
			_own_seq = seq
			_own_item_id = entry[2] if entry[0] == "item" and entry.size() == 3 else ""
			_on_own_panel_changed(ui, container, entry[0], on_weapon or on_gear)
		elif (
			player_changed
			and p == you
			and _local_active
			and not on_weapon
			and not on_gear
			and (UpgradesGear.popup_refreshed(ui, p, in_popup, gear_changed) or not gear_cursor.empty())
		):
			# The refresh closed the popup the cursor was in (opened from the gear page), or
			# the gear it was in has no element left at its place.
			container.call_deferred("focus")
		if p == you:
			# The host's meca rolls for this player: the one the own popup asked for is shown.
			_meca.set_rolls(_list_at(msg.get("mecas"), p))
		var page: int = _int_at(pages, p)
		if p != you and page >= 0 and container.carousel.index != page:
			container.carousel.index = page


# The puppet scene goes with its wave: keep nothing of it (a freed node's address is reused).
func _on_battle_left() -> void:
	stop_local("battle left")
	_guarded_ui = null
	_own = null
	_local_panel = null  # a child of the scene's UpgradesUI
	_meca.detach()
	_applied = {}
	_run_key = {}


# The own panel stops taking local input. Gives up only this screen's device and cursor: a stop
# that comes late (the shop already took over) leaves the shop's alone.
func stop_local(reason := "stopped") -> void:
	if not _local_active:
		return
	ModLoaderLog.info("Own level-up panel stops (%s)" % reason, LOG_NAME)
	_local_active = false
	_sent_focus = ""
	if input_sync != null:
		input_sync.set_local_device(DEVICE_OWNER, -1, reason)
	if focus_sync != null:
		focus_sync.set_local_emulator(DEVICE_OWNER, null)
	if is_instance_valid(_local_panel):
		_local_panel.set_own(null, null, -1)


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


# The run state is only re-applied when its part ids changed. Returns player -> whether its
# gear changed, for each player the change touched ({} when the ids did not change; every
# player, gear too, on the first state of these panels: UpgradesGear.changed_players), null when
# a part is missing (or the run malformed).
func _apply_run(run):
	var ids = run_store.ids_for(run)
	if RunParts.same_ids(ids, _run_key):
		return {}
	var state: Dictionary = run_store.state_for(ids)
	if state.empty():
		return null
	RunStateCodec.apply(state)
	var changed := UpgradesGear.changed_players(run_store, _run_key, ids)
	_run_key = ids
	return changed


# Once per puppet scene. On a client no panel may decide anything: the containers' decision
# signals lose the game's handlers (which change RunData and roll options), and this client's
# own container gets ours instead. A new button the game adds stays unconnected here, so it
# does nothing rather than change the local copy of the run.
func _guard(ui: Node, you: int) -> void:
	if ui == _guarded_ui:
		return
	_guarded_ui = ui
	_applied = {}
	_run_key = {}
	_own = null
	_own_seq = -1
	_own_item_id = ""
	_meca.detach()
	stop_local("new panels")
	var containers := []
	for p in RunData.get_player_count():
		var container = ui._get_player_container(p)
		containers.append(container)
		for signal_name in DECISION_HANDLERS:
			_disconnect(container, signal_name, ui, DECISION_HANDLERS[signal_name])
		_disconnect(container._reroll_button, "pressed", container, "_on_RerollButton_pressed")
		for signal_name in WEAPON_POPUP_HANDLERS:
			_disconnect(container.item_popup, signal_name, ui, WEAPON_POPUP_HANDLERS[signal_name])
		MecaChoice.cut(container.item_popup)  # the popup would roll its own meca options
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
		var popup = container.item_popup
		popup.connect("item_combine_button_pressed", self, "_on_own_weapon", ["weapon_combine"])
		popup.connect("item_discard_button_pressed", self, "_on_own_weapon", ["weapon_discard"])
		_meca.attach(popup, p)
	if is_instance_valid(_local_panel):
		_local_panel.free()
	_local_panel = LocalPanel.new()
	_local_panel.panels = containers
	_local_panel.connect("player_type_changed", self, "_on_own_type_changed")
	ui.add_child(_local_panel)  # after the FocusEmulators, so it gets every event before them


static func _disconnect(source: Object, signal_name: String, target: Object, method: String):
	if source != null and source.is_connected(signal_name, target, method):
		source.disconnect(signal_name, target, method)


# This client's panel shows new options: it takes local control (or gives it up when done).
# on_weapon: the cursor kept its place in the crate weapons list (see UpgradesGear.refresh_weapons).
func _on_own_panel_changed(ui: Node, container: Node, kind: String, on_weapon := false) -> void:
	if kind != "upgrades" and kind != "item":
		stop_local("own panel shows %s" % kind)
		return
	if not _local_active:
		_local_active = true
		ModLoaderLog.info(
			"Own level-up panel runs here (player %d, %s)" % [container.player_index, kind], LOG_NAME
		)
		# main._on_EndWaveTimer_timeout does this on the host; it never runs on a puppet.
		Utils.set_process_input_where_defined(ui, true)
		if input_sync != null:
			input_sync.set_local_device(
				DEVICE_OWNER,
				CoopService.get_remapped_player_device(container.player_index),
				"own panel shows %s" % kind
			)
		if focus_sync != null:
			focus_sync.set_local_emulator(DEVICE_OWNER, container.focus_emulator)
		if is_instance_valid(_local_panel):
			_local_panel.set_own(container, container.focus_emulator, container.player_index)
	if not on_weapon:
		container.call_deferred("focus")  # the game's own starting cursor for the current page


# The own slot is typed as another device now (keyboard <-> pad): LocalPanel has switched the
# carousel and the glyphs; the way to the page arrows is the container's own.
func _on_own_type_changed(_player_type: int, cursor_lost: bool) -> void:
	if not is_instance_valid(_own):
		return
	_own._set_focus_neighbours()
	if cursor_lost:
		_own.focus()  # the cursor sat on an arrow that is a trigger glyph now


func _report_own_focus() -> void:
	if not battle_client.is_in_battle() or not is_instance_valid(_own):
		stop_local("battle over or own panel gone")
		return
	var control = _own.focus_emulator.focused_control
	var target := []
	if control != null and is_instance_valid(control) and is_instance_valid(_guarded_ui):
		# [] outside the own panel
		target = FocusTargets.describe(control, _guarded_ui, _own.player_index)
	var message := {
		"battle_id": battle_client._battle_id, "page": _own.carousel.index, "target": target
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


# The crate weapon popup's combine / recycle / meca pick. The weapon goes out as its slot in
# the own weapons plus its id, never as an object.
func _on_own_weapon(weapon, kind: String, meca := -1) -> void:
	var slot: int = RunData.get_player_weapons(_own.player_index).find(weapon)
	if slot >= 0:
		_send_intent(kind, weapon.my_id, meca, {"weapon": slot})
	# The game's handlers close the popup once they changed the weapons. Here they change
	# when the host answers, if it does: until then the cursor is back on the weapon.
	_guarded_ui._on_weapon_cancel_button_pressed(weapon, _own.player_index)


# The popup's upgrade button: the host rolls the two options (the popup stays as it is, so
# Cancel still closes it); they arrive with the next state (MecaChoice.set_rolls).
func _on_own_meca_roll(weapon) -> void:
	var slot: int = RunData.get_player_weapons(_own.player_index).find(weapon)
	if slot >= 0:
		_send_intent("weapon_meca_roll", weapon.my_id, -1, {"weapon": slot})


# One of the host's two options, by index.
func _on_own_meca_picked(weapon, index: int) -> void:
	_on_own_weapon(weapon, "weapon_meca", index)


func _send_intent(kind: String, id: String, meca := -1, weapon := {}) -> void:
	last_intent = {
		"battle_id": battle_client._battle_id,
		"seq": _own_seq,
		"kind": kind,
		"id": id,
		"meca": meca,
	}
	for field in weapon:
		last_intent[field] = weapon[field]
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


# values[index] when it is a list, else [] (network data: mecas may be missing).
static func _list_at(values, index: int) -> Array:
	if typeof(values) != TYPE_ARRAY or index < 0 or index >= values.size():
		return []
	return values[index] if typeof(values[index]) == TYPE_ARRAY else []


# values[index] when it is an int, else -1 (network data: seqs / pages may be missing).
static func _int_at(values, index: int) -> int:
	if typeof(values) != TYPE_ARRAY or index >= values.size():
		return -1
	return values[index] if typeof(values[index]) == TYPE_INT else -1
