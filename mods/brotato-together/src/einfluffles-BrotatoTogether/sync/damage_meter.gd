extends Node
# Damage meter: what every player's weapons and items dealt in the current wave (in the shop:
# in the wave before it). Shown by ui/damage_views.gd in the wave's HUD and in the shop.
#
# The numbers are the game's own counters: WeaponData.dmg_dealt_last_wave (reset when a wave
# starts, counted up by Weapon as it hits) and RunData.tracked_item_effects of the items whose
# tracking text is a damage text (counted for the whole run: the wave's part is the difference
# to the values at the wave's start). Two more numbers per player: the biggest single hit (the
# took_damage signal of every enemy and tree the battle's EntitySpawner spawns: the number the
# floating damage text shows, with the source that dealt it) and the seconds the wave timer ran,
# which make the damage per second.
#
# The machine that runs the wave measures (the host; any machine outside a session). A client's
# counters stand still during a puppet battle, so the host's board travels: section DAMAGE of
# sync/state_stream.gd, {wave, players: [[total, [[my_id, count, damage], ...]], ...], time:
# seconds, hits: [[damage, my_id or ""], ...] per player}, checked every UPDATE_SEC, sent when it
# changed. time and hits came later: a board without them is still one (0 and none). During
# the wave it carries live_sources() sources per player (what the HUD shows, picked by
# strongest()); the measurement when the battle scene leaves
# carries MAX_SOURCES, and that board stands through the shop until the next wave starts.
#
# Cost: a measurement reads the weapons and only the counters that are damage (their keys are
# looked up once per wave), a few dozen values per player however many items the run has.
#
# shown: this machine's switch (Options > Gameplay, extensions/ui/menu_options.gd), kept in the
# Mod Loader's config (session/settings.gd). Off: nothing is shown here; the host still measures
# while it has peers, who decide for themselves.
#
# After the Damage Meter mod by Oudstand (the idea, the counters it reads, the bonk dog's two
# damage values), written anew for a board that every machine shows the same.

signal changed

const StateStream := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd")
const Settings := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/settings.gd")
const BATTLE_SCENE := "res://main.tscn"
const DAMAGE_TEXTS := ["DAMAGE_DEALT", "EXPLOSION_DAMAGE_DEALT"]
const SUMMED := ["item_bonk_dog"]  # tracked as [explosions, hits]: both are damage
const UPDATE_SEC := 0.5
const MAX_SOURCES := 10
# During the wave: what the HUD shows, one line each. Fewer with 3 or 4 players: then two of
# them share each side of the screen.
const LIVE_SOURCES := 4
const LIVE_SOURCES_CROWDED := 3
const CROWDED_FROM := 3  # players
const OTHER_KIND_SHARE := 0.05  # of the player's total, see strongest()
const SETTING := "damage_meter"
const MAX_PLAYERS := 4
const MAX_ID_LENGTH := 96

var session: Node = null
var state_stream: Node = null  # sync/state_stream.gd (set by mod_main.gd)
var board := {}  # see above; {} before the first wave
var shown := true  # this machine shows the meter

var _baseline := []  # per player: RunData.tracked_item_effects when the wave started
var _scene_id := 0  # the battle scene being measured
var _since := 0.0
var _revision := 0
var _data := {}  # my_id -> item / weapon / character data
var _damage_ids := {}  # my_id -> whether its counter counts damage
var _keys := []  # per player: [[counter key, my_id], ...] of the damage counters
var _key_counts := []  # per player: how many counters there were when _keys was read
var _wave_time := 0.0  # seconds the wave timer ran in the battle being measured
var _hits := []  # per player: [damage, my_id] of the wave's biggest hit


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.transport.connect("lobby_left", self, "_on_lobby_left")
	state_stream.register_provider(StateStream.DAMAGE, self, UPDATE_SEC)
	state_stream.register_handler(StateStream.DAMAGE, self)


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	shown = bool(Settings.read(SETTING, true))


func set_shown(on: bool) -> void:
	if on == shown:
		return
	shown = on
	Settings.write(SETTING, on)
	emit_signal("changed")


func _process(delta: float) -> void:
	if session != null and session.is_client():
		return  # the host's board
	var scene := get_tree().current_scene
	if scene == null or scene.filename != BATTLE_SCENE:
		return
	if scene.get_instance_id() != _scene_id:
		_scene_id = scene.get_instance_id()
		_baseline = RunData.tracked_item_effects.duplicate(true)
		_keys = []
		_key_counts = []
		_since = UPDATE_SEC
		_wave_time = 0.0
		_hits = []
		_watch_hits(scene)
		# The wave's last word, with every source the shop's board lists.
		scene.connect("tree_exiting", self, "measure", [true], CONNECT_ONESHOT)
	# The wave's time: while its timer runs. The timer stands with the paused tree and stops when
	# the wave is over, so the collecting at the end does not count.
	var timer = scene.get_node_or_null("WaveTimer")
	if timer is Timer and not timer.is_stopped() and not get_tree().paused:
		_wave_time += delta
	_since += delta
	if _since >= UPDATE_SEC:
		_since = 0.0
		if shown or (session != null and session.is_host() and not session.peers.empty()):
			measure()


# --- measuring ---


# final: with all MAX_SOURCES sources per player (the shop's board), else the HUD's few.
func measure(final := false) -> void:
	var limit := MAX_SOURCES if final else live_sources(RunData.get_player_count())
	var players := []
	for p in RunData.get_player_count():
		var baseline: Dictionary = _baseline[p] if p < _baseline.size() else {}
		players.append(measure_player(p, baseline, limit, not final))
	var hits := []
	for p in players.size():
		hits.append(_hits[p].duplicate() if p < _hits.size() else [0, ""])
	var time := stepify(_wave_time, 0.1)
	_set_board({"wave": RunData.current_wave, "players": players, "time": time, "hits": hits})


# --- the biggest hit ---


func _watch_hits(main: Node) -> void:
	var spawner = main.get_node_or_null("EntitySpawner")
	if spawner == null:
		return
	for spawned in ["enemy_spawned", "neutral_spawned"]:
		if spawner.has_signal(spawned) and not spawner.is_connected(spawned, self, "_watch_unit"):
			spawner.connect(spawned, self, "_watch_unit")


# Spawned units are used again (the spawner's pools): one connection each.
func _watch_unit(unit: Node) -> void:
	if unit.has_signal("took_damage") and not unit.is_connected("took_damage", self, "on_hit"):
		unit.connect("took_damage", self, "on_hit")


# Unit.took_damage: unit, value (what the floating text shows), knockback, crit, dodge,
# protected, armor, args (TakeDamageArgs), hit type, one shot.
func on_hit(_unit, value: int, _kb, _crit, _dodge, _protected, _armor, args, _type, _one) -> void:
	if args == null or value <= 0:
		return
	var p: int = args.from_player_index
	if p < 0 or p >= MAX_PLAYERS:
		return
	while _hits.size() <= p:
		_hits.append([0, ""])
	if value > _hits[p][0]:
		_hits[p] = [value, source_of(args, p)]


# The weapon or item a hit came from, as my_id, or "" when it does not say. From the hitbox
# only: a burn tick reuses the unit's TakeDamageArgs with its hitbox cleared but `from` left as
# whatever hit that unit last, maybe another player's weapon (Unit._on_BurningTimer_timeout).
static func source_of(args, p: int) -> String:
	var hitbox = args.hitbox if is_instance_valid(args.hitbox) else null
	var from = hitbox.from if hitbox != null and is_instance_valid(hitbox.from) else null
	var key: int = Keys.empty_hash
	if from != null and "damage_tracking_key_hash" in from:
		key = from.damage_tracking_key_hash
	if key == Keys.empty_hash and from != null and "weapon_pos" in from:
		var weapons: Array = RunData.get_player_weapons(p)
		if from.weapon_pos >= 0 and from.weapon_pos < weapons.size():
			return weapons[from.weapon_pos].my_id
	if key == Keys.empty_hash and hitbox != null:
		key = hitbox.damage_tracking_key_hash
	return Keys.hash_to_string.get(key, "") if key != Keys.empty_hash else ""


# [total, [[my_id, count, damage], ...]]: the player's sources that dealt damage, strongest
# first, at most `limit` (mixed: see strongest()); the total counts all of them. Equal weapons
# and items are one source with their number (0: nothing of it in the inventory, e.g. a turret
# a weapon built).
func measure_player(p: int, baseline: Dictionary, limit := MAX_SOURCES, mixed := false) -> Array:
	var groups := {}  # my_id -> [count, damage]
	var weapons := {}  # my_id -> true for the weapons among them
	for weapon in RunData.get_player_weapons(p):
		var group = groups.get(weapon.my_id)
		if group == null:
			group = [0, 0]
			groups[weapon.my_id] = group
			weapons[weapon.my_id] = true
		group[0] += 1
		group[1] += int(weapon.dmg_dealt_last_wave)
	var tracked: Dictionary = RunData.tracked_item_effects[p]
	for pair in _damage_keys(p, tracked):
		var id: String = pair[1]
		var gained := _damage(tracked[pair[0]], id) - _damage(baseline.get(pair[0]), id)
		if gained > 0 and not groups.has(id):
			var count: int = RunData.get_nb_item(pair[0], p) if pair[0] is int else 0
			groups[id] = [count, gained]
	var total := 0
	var sources := []
	for id in groups:
		total += groups[id][1]
		if groups[id][1] > 0:
			sources.append([id, groups[id][0], groups[id][1]])
	sources.sort_custom(DamageOrder, "strongest_first")
	var least := int(ceil(total * OTHER_KIND_SHARE)) if mixed else -1
	return [total, strongest(sources, weapons, limit, least)]


# The sources the HUD shows in a wave with this many players.
static func live_sources(player_count: int) -> int:
	return LIVE_SOURCES_CROWDED if player_count >= CROWDED_FROM else LIVE_SOURCES


# The first `limit` of the sources (strongest first). When those are all weapons, or all of the
# rest (structures, pets, items, the character), and the strongest of the other kind dealt at
# least `least` (-1: never), the last of them gives way to it: the HUD shows a weapon build's
# turrets or burning, and a turret build's weapons, once they count (OTHER_KIND_SHARE).
static func strongest(sources: Array, weapons: Dictionary, limit: int, least := -1) -> Array:
	var kept := sources.slice(0, limit - 1) if limit > 0 and not sources.empty() else []
	if least < 0 or kept.size() < 2 or sources.size() <= kept.size():
		return kept
	var kind: bool = weapons.has(kept[0][0])
	for source in kept:
		if weapons.has(source[0]) != kind:
			return kept
	for k in range(kept.size(), sources.size()):
		if weapons.has(sources[k][0]) != kind:
			if sources[k][2] >= least:
				kept[kept.size() - 1] = sources[k]
			break
	return kept


# The player's counters that count damage, as [key, my_id]. Which ones they are only changes
# when a counter is added, so the list is read again when there are more (and with every wave).
func _damage_keys(p: int, tracked: Dictionary) -> Array:
	while _keys.size() <= p:
		_keys.append([])
		_key_counts.append(-1)
	if _key_counts[p] != tracked.size():
		_key_counts[p] = tracked.size()
		var pairs := []
		for key in tracked:
			var id: String = Keys.hash_to_string.get(key, "") if key is int else str(key)
			if _is_damage_item(id):
				pairs.append([key, id])
		_keys[p] = pairs
	return _keys[p]


# A tracked value: a number, or a list whose first entry is the damage.
static func _damage(value, id: String) -> int:
	if typeof(value) != TYPE_ARRAY:
		return int(value) if typeof(value) in [TYPE_INT, TYPE_REAL] else 0
	var damage := 0
	for i in value.size():
		if i == 0 or id in SUMMED:
			damage += int(value[i])
	return damage


func _is_damage_item(id: String) -> bool:
	if _damage_ids.empty():
		for list in [ItemService.items, ItemService.characters]:
			for data in list:
				_damage_ids[data.my_id] = data.tracking_text in DAMAGE_TEXTS
	return _damage_ids.get(id, false)


func _set_board(next: Dictionary) -> void:
	# Arrays compare by value, dictionaries by reference.
	var same := true
	for key in ["wave", "players", "time", "hits"]:
		same = same and next.get(key) == board.get(key)
	if same:
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
	var time = body.get("time", 0.0)
	if not typeof(time) in [TYPE_INT, TYPE_REAL] or time < 0:
		return {}
	var sent_hits = body.get("hits", [])
	if typeof(sent_hits) != TYPE_ARRAY or sent_hits.size() > MAX_PLAYERS:
		return {}
	var hits := []
	for hit in sent_hits:
		if typeof(hit) != TYPE_ARRAY or hit.size() != 2 or typeof(hit[0]) != TYPE_INT:
			return {}
		if hit[0] < 0 or typeof(hit[1]) != TYPE_STRING or hit[1].length() > MAX_ID_LENGTH:
			return {}
		hits.append([hit[0], hit[1]])
	return {"wave": body.wave, "players": players, "time": float(time), "hits": hits}


class DamageOrder:
	static func strongest_first(a: Array, b: Array) -> bool:
		return a[2] > b[2] if a[2] != b[2] else a[0] < b[0]
