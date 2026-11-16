extends Node
# Damage meter: what every player's weapons and items dealt in the current wave (in the shop:
# in the wave before it). Shown by ui/damage_views.gd in the wave's HUD and in the shop.
#
# The numbers are the game's own counters: WeaponData.dmg_dealt_last_wave (reset when a wave
# starts, counted up by Weapon as it hits) and RunData.tracked_item_effects of the items whose
# tracking text is a damage text (counted for the whole run: the wave's part is the difference
# to the values at the wave's start). No hook into the fight.
#
# The machine that runs the wave measures (the host; any machine outside a session). A client's
# counters stand still during a puppet battle, so the host's board travels: section DAMAGE of
# sync/state_stream.gd, {wave, players: [[total, [[my_id, count, damage], ...]], ...]}, checked
# every UPDATE_SEC, sent when it changed. It stays as it is through the shop until the next
# wave starts.
#
# After the Damage Meter mod by Oudstand (the idea, the counters it reads, the bonk dog's two
# damage values), written anew for a board that every machine shows the same.

signal changed

const StateStream := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd")
const BATTLE_SCENE := "res://main.tscn"
const DAMAGE_TEXTS := ["DAMAGE_DEALT", "EXPLOSION_DAMAGE_DEALT"]
const SUMMED := ["item_bonk_dog"]  # tracked as [explosions, hits]: both are damage
const UPDATE_SEC := 0.5
const MAX_SOURCES := 10
const MAX_PLAYERS := 4
const MAX_ID_LENGTH := 96

var session: Node = null
var state_stream: Node = null  # sync/state_stream.gd (set by mod_main.gd)
var board := {}  # see above; {} before the first wave

var _baseline := []  # per player: RunData.tracked_item_effects when the wave started
var _scene_id := 0  # the battle scene being measured
var _since := 0.0
var _revision := 0
var _data := {}  # my_id -> item / weapon / character data


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.transport.connect("lobby_left", self, "_on_lobby_left")
	state_stream.register_provider(StateStream.DAMAGE, self, UPDATE_SEC)
	state_stream.register_handler(StateStream.DAMAGE, self)


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func _process(delta: float) -> void:
	if session != null and session.is_client():
		return  # the host's board
	var scene := get_tree().current_scene
	if scene == null or scene.filename != BATTLE_SCENE:
		return
	if scene.get_instance_id() != _scene_id:
		_scene_id = scene.get_instance_id()
		_baseline = RunData.tracked_item_effects.duplicate(true)
		_since = UPDATE_SEC
		scene.connect("tree_exiting", self, "measure", [], CONNECT_ONESHOT)  # the final numbers
	_since += delta
	if _since >= UPDATE_SEC:
		_since = 0.0
		measure()


# --- measuring ---


func measure() -> void:
	var players := []
	for p in RunData.get_player_count():
		players.append(measure_player(p, _baseline[p] if p < _baseline.size() else {}))
	_set_board({"wave": RunData.current_wave, "players": players})


# [total, [[my_id, count, damage], ...]]: the player's sources that dealt damage, strongest
# first, at most MAX_SOURCES; the total counts all of them. Equal weapons and items are one
# source with their number (0: nothing of it in the inventory, e.g. a turret a weapon built).
static func measure_player(p: int, baseline: Dictionary) -> Array:
	var groups := {}  # my_id -> [count, damage]
	for weapon in RunData.get_player_weapons(p):
		var group = groups.get(weapon.my_id)
		if group == null:
			group = [0, 0]
			groups[weapon.my_id] = group
		group[0] += 1
		group[1] += int(weapon.dmg_dealt_last_wave)
	var counts := {}
	for item in RunData.get_player_items(p):
		counts[item.my_id] = counts.get(item.my_id, 0) + 1
	var tracked: Dictionary = RunData.tracked_item_effects[p]
	for key in tracked:
		var id: String = Keys.hash_to_string.get(key, "") if key is int else str(key)
		var gained := _damage(tracked[key], id) - _damage(baseline.get(key), id)
		if gained > 0 and not groups.has(id) and _is_damage_item(id):
			groups[id] = [counts.get(id, 0), gained]
	var total := 0
	var sources := []
	for id in groups:
		total += groups[id][1]
		if groups[id][1] > 0:
			sources.append([id, groups[id][0], groups[id][1]])
	sources.sort_custom(DamageOrder, "strongest_first")
	return [total, sources.slice(0, MAX_SOURCES - 1)]


# A tracked value: a number, or a list whose first entry is the damage.
static func _damage(value, id: String) -> int:
	if typeof(value) != TYPE_ARRAY:
		return int(value) if typeof(value) in [TYPE_INT, TYPE_REAL] else 0
	var damage := 0
	for i in value.size():
		if i == 0 or id in SUMMED:
			damage += int(value[i])
	return damage


static func _is_damage_item(id: String) -> bool:
	for list in [ItemService.items, ItemService.characters]:
		for data in list:
			if data.my_id == id:
				return data.tracking_text in DAMAGE_TEXTS
	return false


func _set_board(next: Dictionary) -> void:
	if var2str(next) == var2str(board):
		return
	board = next
	_revision += 1
	emit_signal("changed")


# The item, weapon or character a source names (icon, name, tier), or null.
func data_of(id: String):
	if _data.empty():
		for list in [ItemService.items, ItemService.weapons, ItemService.characters]:
			for data in list:
				_data[data.my_id] = data
	return _data.get(id)


# --- state stream ---


func state_key(_section: int) -> String:
	return "" if board.empty() else str(_revision)


func state_body(_section: int) -> Dictionary:
	return board


func apply_state(_section: int, body, _revision_sent: int) -> bool:
	var next := clean(body)
	if not next.empty():
		_set_board(next)
	return true


func clear_state(_section: int) -> void:
	_set_board({})


func _on_lobby_left() -> void:
	_scene_id = 0
	_set_board({})


# A board from the network, or {} when it is not one.
static func clean(body) -> Dictionary:
	if typeof(body) != TYPE_DICTIONARY or typeof(body.get("wave")) != TYPE_INT:
		return {}
	var sent = body.get("players")
	if typeof(sent) != TYPE_ARRAY or sent.size() > MAX_PLAYERS:
		return {}
	var players := []
	for entry in sent:
		if typeof(entry) != TYPE_ARRAY or entry.size() != 2:
			return {}
		if typeof(entry[0]) != TYPE_INT or typeof(entry[1]) != TYPE_ARRAY:
			return {}
		if entry[0] < 0 or entry[1].size() > MAX_SOURCES:
			return {}
		var sources := []
		for source in entry[1]:
			if typeof(source) != TYPE_ARRAY or source.size() != 3:
				return {}
			if typeof(source[0]) != TYPE_STRING or source[0].length() > MAX_ID_LENGTH:
				return {}
			if typeof(source[1]) != TYPE_INT or typeof(source[2]) != TYPE_INT:
				return {}
			if source[1] < 0 or source[2] < 0:
				return {}
			sources.append([source[0], source[1], source[2]])
		players.append([entry[0], sources])
	return {"wave": body.wave, "players": players}


class DamageOrder:
	static func strongest_first(a: Array, b: Array) -> bool:
		return a[2] > b[2] if a[2] != b[2] else a[0] < b[0]
