extends Node
# Damage meter: what every player's weapons and items dealt in the current wave (in the shop: in
# the wave before it), and at the end of a wave the run so far (sync/damage_ledger.gd).
#
# The total is the health the player's hits took, from every unit's took_damage: a hit takes its
# value, a killing hit at most the health the unit had. The biggest hit is the biggest number the
# player's hits showed above a unit, a killing hit's whole value. The sources are the game's own
# counters: WeaponData.dmg_dealt_last_wave (per wave) and RunData.tracked_item_effects (per run:
# the wave's part is the difference to the values at the wave's start). Some counters count damage
# that a weapon's counter holds too (OVERLAPS: a bonus inside the weapon's hit or burn); the views
# show those as included and leave them out of the shares, and what no shown source holds is
# "other".
#
# The host's board is section DAMAGE of the state stream:
#   {wave, players: [[total, [[my_id, count, damage], ...]], ...], time: seconds,
#    hits: [[damage, my_id or ""], ...] per player, run (only once the wave is over):
#    {waves, time, players: [[total, sources, [damage, my_id], kills, damage taken], ...]}}
#
# After the Damage Meter mod by Oudstand (the idea, the counters it reads, the bonk dog's two
# damage values), written anew for a board that every machine shows the same.

signal changed

const StateStream := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd")
const Settings := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/settings.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const DamageLedger := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/damage_ledger.gd"
)
const BATTLE_SCENE := "res://main.tscn"
# Between and after the waves; any other scene is outside a run and clears the board.
const RUN_SCENES := [
	"res://ui/menus/shop/shop.tscn",
	"res://ui/menus/shop/coop_shop.tscn",
	"res://ui/menus/run/end_run.tscn",
	"res://ui/menus/run/coop_end_run.tscn",
]
const LOG_NAME := "einfluffles-BrotatoTogether:DamageMeter"
const DAMAGE_TEXTS := ["DAMAGE_DEALT", "EXPLOSION_DAMAGE_DEALT"]
# Damage counters whose item text does not say so: the chef's consumable explosions and burns,
# the builder's turret (one key per level).
const EXTRA_IDS := [
	"character_chef",
	"item_builder_turret_0",
	"item_builder_turret_1",
	"item_builder_turret_2",
	"item_builder_turret_3",
]
const BUILDER := "item_builder_turret"  # its levels are one source
const BUILDER_LEVELS := 4
# Counters of damage another counter holds as well: Giant Belt's crit bonus is part of the
# weapon's hit, Greek Fire's bonus part of the burn tick that a weapon is credited with, Scared
# Sausage counts its bonus in the weapons' burns (and its own burns, which no weapon holds).
const OVERLAPS := ["item_giant_belt", "item_greek_fire", "item_scared_sausage"]
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
const MAX_WAVES := 10000

var session: Node = null
var state_stream: Node = null
var board := {}  # see above; {} before the first wave
var shown := true  # this machine's switch; the host measures for its peers either way
var ledger: Reference = DamageLedger.new()

var _baseline := []  # per player: RunData.tracked_item_effects when the wave started
var _scene_id := 0  # the battle scene being measured
var _seen_id := 0  # the current scene when _process last looked
var _since := 0.0
var _revision := 0
var _data := {}  # my_id -> item / weapon / character data
var _damage_ids := {}  # my_id -> whether its counter counts damage
var _keys := []  # per player: [[counter key, my_id], ...] of the damage counters
var _key_counts := []  # per player: how many counters there were when _keys was read
var _wave_time := 0.0  # seconds the wave timer ran in the battle being measured
var _frozen := false  # the wave's last measurement is taken
var _hits := []  # per player: [value, my_id] of the wave's biggest number above a unit
var _dealt := []  # per player: the health the wave's hits took
var _kills := []  # per player: enemies killed this wave
var _taken := []  # per player: damage the player took this wave
var _health := {}  # unit instance id -> its health after its last hit
var _gone := {}  # unit instance id -> the health it had left at its death, less what hits took
# For the wave's log line, whoever hit: the health the shown hits took, of it what no player's hits
# took and what hits on units after their death took, what the hidden hits took, the enemies
# killed.
var _lost := 0
var _unowned := 0
var _after_death := 0
var _hidden := 0
var _all_kills := 0
var _builder_keys := []  # the builder turret levels' counter keys


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


# The switch is this machine's: the panel of a player on another machine shows what that player
# sees, so it never loses the damage page here (nor passes a clamped page on).
func shown_for(player_index: int) -> bool:
	return shown or not _plays_here(player_index)


func _plays_here(player_index: int) -> bool:
	if session != null and session.is_client():
		return player_index == CoopService.bt_own_slot
	var players: Array = CoopService.connected_players
	if player_index < 0 or player_index >= players.size():
		return true
	return not VirtualDevices.is_virtual(players[player_index][0])


func _process(delta: float) -> void:
	if session != null and session.is_client():
		return  # the host's board
	var scene := get_tree().current_scene
	if scene != null and scene.get_instance_id() != _seen_id:
		_seen_id = scene.get_instance_id()
		_on_scene(scene)
	if scene == null or scene.filename != BATTLE_SCENE:
		return
	if scene.get_instance_id() != _scene_id:
		_start_battle(scene)
	if _frozen:
		return
	if scene.get("_end_wave_timer_timedout") == true:
		freeze()  # the timer's own call came first (see _watch_hits)
		return
	# The wave's time: while its timer runs. The timer stands with the paused tree and stops when
	# the wave is over, so the collecting at the end does not count.
	var timer = scene.get_node_or_null("WaveTimer")
	if timer is Timer and not timer.is_stopped() and not get_tree().paused:
		_wave_time += delta
	_check_resets()
	_since += delta
	if _since >= UPDATE_SEC:
		_since = 0.0
		if shown or (session != null and session.is_host() and not session.peers.empty()):
			measure()


func _on_scene(scene: Node) -> void:
	if scene.filename in RUN_SCENES:
		ledger.commit()  # the run went on, or ended, with the frozen wave
	elif scene.filename != BATTLE_SCENE:
		ledger.reset()  # outside a run: a run resumed later starts with an empty board
		_set_board({})


func _start_battle(scene: Node) -> void:
	_scene_id = scene.get_instance_id()
	_baseline = RunData.tracked_item_effects.duplicate(true)
	_keys = []
	_key_counts = []
	_since = UPDATE_SEC
	_wave_time = 0.0
	_frozen = false
	_hits = []
	_dealt = []
	_kills = []
	_taken = []
	_health = {}
	_gone = {}
	_lost = 0
	_unowned = 0
	_after_death = 0
	_hidden = 0
	_all_kills = 0
	ledger.start_wave(RunData.current_wave)
	_watch_hits(scene)
	# Left without the end of the wave (the pause menu's end run, restart or quit).
	scene.connect("tree_exiting", self, "freeze", [], CONNECT_ONESHOT)


# The wave's last word, with every source the shop's board lists and the run so far, taken when
# the wave is over and before the crate and level-up panels (combining or recycling a weapon
# there takes its counter along) and the retry prompt (which restores the run state).
func freeze() -> void:
	if _frozen:
		return
	_frozen = true
	measure(true)
	ModLoaderLog.info(wave_line(), LOG_NAME)


func measure(final := false) -> void:
	var limit := MAX_SOURCES if final else live_sources(RunData.get_player_count())
	var players := []
	var wave_players := []
	for p in RunData.get_player_count():
		var baseline: Dictionary = _baseline[p] if p < _baseline.size() else {}
		var dealt: int = _dealt[p] if p < _dealt.size() else 0
		players.append(measure_player(p, baseline, limit, not final, dealt))
		if final:
			wave_players.append(_wave_record(p, baseline, players[p][0]))
	var hits := []
	for p in players.size():
		hits.append(_hits[p].duplicate() if p < _hits.size() else [0, ""])
	var time := stepify(_wave_time, 0.1)
	var next := {"wave": RunData.current_wave, "players": players, "time": time, "hits": hits}
	if final:
		ledger.hold(RunData.current_wave, _wave_time, wave_players)
		next["run"] = ledger.wire(MAX_SOURCES)
	_set_board(next)


# The wave for the ledger: every source, a weapon's tiers and the builder's turrets as one.
func _wave_record(p: int, baseline: Dictionary, total: int) -> Dictionary:
	var sources := {}
	for source in wave_sources(p, baseline)[0]:
		var key := _ledger_key(source[0])
		var into = sources.get(key)
		if into == null:
			sources[key] = source.duplicate()
		else:
			into[1] += source[1]
			into[2] += source[2]
	return {
		"sources": sources,
		"total": total,
		"hit": _hits[p].duplicate() if p < _hits.size() else [0, ""],
		"kills": _kills[p] if p < _kills.size() else 0,
		"taken": _taken[p] if p < _taken.size() else 0,
	}


func _ledger_key(id: String) -> String:
	var data = data_of(id)
	if data != null and data.get("weapon_id") is String and data.weapon_id != "":
		return data.weapon_id
	return BUILDER if id.begins_with(BUILDER) else id


func _watch_hits(main: Node) -> void:
	var spawner = main.get_node_or_null("EntitySpawner")
	if spawner != null:
		for spawned in ["enemy_spawned", "neutral_spawned"]:
			if spawner.has_signal(spawned) and not spawner.is_connected(spawned, self, "_watch_unit"):
				spawner.connect(spawned, self, "_watch_unit")
		for list in ["enemies", "bosses", "neutrals"]:  # spawned before this frame
			var units = spawner.get(list)
			for unit in units if units is Array else []:
				if is_instance_valid(unit):
					_watch_unit(unit)
	# Godot 3 calls a signal's targets in order of object id: this node, older than any battle
	# scene, freezes before main's own handler ends the wave.
	var timer = main.get_node_or_null("EndWaveTimer")
	if timer is Timer and not timer.is_connected("timeout", self, "freeze"):
		timer.connect("timeout", self, "freeze")
	var players = main.get("_players")
	if players is Array:
		for player in players:
			if is_instance_valid(player) and not player.is_connected("took_damage", self, "_on_hurt"):
				player.connect("took_damage", self, "_on_hurt")


# Spawned units are used again (the spawner's pools): one connection each.
func _watch_unit(unit: Node) -> void:
	if unit.has_signal("took_damage") and not unit.is_connected("took_damage", self, "on_hit"):
		unit.connect("took_damage", self, "on_hit")
		unit.connect("died", self, "_on_unit_gone")
		# The health a unit gains without a hit: a healer's heal, a buffer's boost.
		for signal_name in ["healed", "stats_boosted"]:
			if unit.has_signal(signal_name):
				unit.connect(signal_name, self, "_on_health_set")


# Unit.took_damage: unit, value (what the floating text shows), knockback, crit, dodge,
# protected, armor, args (TakeDamageArgs), hit type, one shot. value is the hit's full damage,
# above the health that was left on a killing hit.
func on_hit(unit, value: int, _kb, crit, _dodge, _protected, _armor, args, _type, one) -> void:
	if args == null or value <= 0 or _frozen:
		return
	var dealt := value
	var killed := false
	var after_death := false
	if unit != null and is_instance_valid(unit) and unit.get("current_stats") != null:
		var id: int = unit.get_instance_id()
		if unit.get("dead") == true:
			# A unit that died without a killing hit (the game's cap on enemies, a tree's last
			# hit) can still be hit: a bullet that entered it in the physics step the game
			# removed it in (Unit.hurt_area_entered_deferred checks _pending_die, not dead), a
			# burn. The hit takes what it had left, as the weapon's counter counts it.
			var left: int = _gone.get(id, 0)
			dealt = int(clamp(left - unit.current_stats.health, 0, value))
			_gone[id] = left - dealt
			after_death = true
		elif unit.current_stats.health <= 0:
			# Not seen hit since it (re)spawned: it had all its health.
			dealt = int(min(value, _health.get(id, unit.max_stats.health)))
			killed = true
			_health.erase(id)
		else:
			_health[id] = int(unit.current_stats.health)
	var p: int = args.from_player_index
	var owned := p >= 0 and p < MAX_PLAYERS
	var enemy_killed: bool = killed and unit.get("enemy_id") != null
	if enemy_killed:
		_all_kills += 1
	# The brachiosaurus' foot hands its hits on to the boss, hidden: the weapon counts the foot's.
	if args.hide_feedback:
		_hidden += dealt
	else:
		_lost += dealt
		if not owned:
			_unowned += dealt
		if after_death:
			_after_death += dealt
	if not owned:
		return
	_grow(p)
	if enemy_killed:
		_kills[p] += 1
	if args.hide_feedback:
		return
	_dealt[p] += dealt
	# The number above the unit (FloatingTextManager._on_unit_took_damage): the whole value, but a
	# one-shot that is no crit shows "ONE_SHOT" in its place.
	if value > _hits[p][0] and (crit or not one):
		_hits[p] = [value, source_of(args, p)]


# A player's took_damage, same arguments.
func _on_hurt(unit, value: int, _kb, _crit, dodge, protected, _armor, _args, _type, _one) -> void:
	if value <= 0 or dodge or protected or _frozen or unit.get("player_index") == null:
		return
	var p: int = unit.player_index
	if p >= 0 and p < MAX_PLAYERS:
		_grow(p)
		_taken[p] += value


func _on_unit_gone(unit, _args) -> void:
	_health.erase(unit.get_instance_id())
	_gone[unit.get_instance_id()] = int(max(0, unit.current_stats.health))


func _on_health_set(unit) -> void:
	if is_instance_valid(unit) and _health.has(unit.get_instance_id()):
		_health[unit.get_instance_id()] = int(unit.current_stats.health)


func _grow(p: int) -> void:
	while _hits.size() <= p:
		_hits.append([0, ""])
		_dealt.append(0)
		_kills.append(0)
		_taken.append(0)


# From the hitbox only: a burn tick (Unit._on_BurningTimer_timeout) reuses the unit's
# TakeDamageArgs with its hitbox cleared but `from` left as whatever hit that unit last.
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


# The host's check of the meter, logged when the wave is over: the totals on the board against
# the health the shown hits took whoever dealt them (of it what no player's hits took and what
# hits on units after their death took; the hidden hits apart, which no total holds), per player
# the plain rows and what the overlapping ones hold besides, the biggest hit with its source and
# the kills, and the enemies killed.
#   Wave 12 damage: total 15,234, health lost 15,234 (by no player 0, after death 2, hidden 0);
#   p0 9,100 (rows 8,900 + 1,200 included, biggest hit 1,204 weapon_smg_3, 50 kills), p1 ...;
#   87 kills
func wave_line() -> String:
	var players: Array = board.get("players", [])
	var hits: Array = board.get("hits", [])
	var team := 0
	var parts := []
	for p in players.size():
		team += players[p][0]
		var rows := [0, 0]  # plain, overlapping
		var baseline: Dictionary = _baseline[p] if p < _baseline.size() else {}
		for source in wave_sources(p, baseline)[0]:
			rows[1 if overlaps(source[0]) else 0] += source[2]
		var hit: Array = hits[p] if p < hits.size() else [0, ""]
		var part := "p%d %s (rows %s" % [p, _number(players[p][0]), _number(rows[0])]
		if rows[1] > 0:
			part += " + %s included" % _number(rows[1])
		if hit[0] > 0:
			var source: String = hit[1] if hit[1] != "" else "unknown"
			part += ", biggest hit %s %s" % [_number(hit[0]), source]
		else:
			part += ", no hit"
		parts.append(part + ", %d kills)" % (_kills[p] if p < _kills.size() else 0))
	return (
		(
			"Wave %d damage: total %s, health lost %s (by no player %s, after death %s, hidden %s);"
			+ " %s; %d kills"
		)
		% [
			board.get("wave", RunData.current_wave),
			_number(team),
			_number(_lost),
			_number(_unowned),
			_number(_after_death),
			_number(_hidden),
			PoolStringArray(parts).join(", "),
			_all_kills,
		]
	)


static func _number(value: int) -> String:
	return Text.get_formatted_number(value)


# [total, [[my_id, count, damage], ...]], strongest first. Equal weapons and items are one source
# with their number (0: nothing of it in the inventory, e.g. a turret a weapon built). The total
# is `dealt`, the health the hits took, but never below what the sources that hold no other's
# damage sum to (a hit on a unit the meter did not see).
func measure_player(
	p: int, baseline: Dictionary, limit := MAX_SOURCES, mixed := false, dealt := 0
) -> Array:
	var found := wave_sources(p, baseline)
	var total := dealt
	var own := 0
	for source in found[0]:
		if not overlaps(source[0]):
			own += source[2]
	total = int(max(total, own))
	var least := int(ceil(total * OTHER_KIND_SHARE)) if mixed else -1
	return [total, strongest(found[0], found[1], limit, least)]


# [every source that dealt something this wave as [my_id, count, damage] strongest first,
# {my_id: true} of the weapons among them].
func wave_sources(p: int, baseline: Dictionary) -> Array:
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
	var builder := ""  # the id the builder's turret levels count under
	for pair in _damage_keys(p, tracked):
		var id: String = pair[1]
		var now := _damage(tracked[pair[0]], id)
		var before := _damage(baseline.get(pair[0]), id)
		if now < before and typeof(baseline.get(pair[0])) == TYPE_INT:
			before = 0  # set back during the wave, see _check_resets
			baseline[pair[0]] = 0
		var gained := now - before
		if gained <= 0:
			continue
		if id.begins_with(BUILDER):
			if builder == "":
				builder = _builder_id(p, id)
			id = builder
		if weapons.has(id):
			continue  # a weapon that counts under its own id: its counter has it
		if groups.has(id):
			groups[id][1] += gained
		else:
			var count: int = RunData.get_nb_item(pair[0], p) if pair[0] is int else 0
			if id != pair[1]:
				count = RunData.get_nb_item(Keys.generate_hash(id), p)
			groups[id] = [count, gained]
	var sources := []
	for id in groups:
		if groups[id][1] > 0:
			sources.append([id, groups[id][0], groups[id][1]])
	sources.sort_custom(DamageOrder, "strongest_first")
	return [sources, weapons]


# The builder's turret has a counter per level: the one the player holds names them all (else
# the first that counted).
static func _builder_id(p: int, id: String) -> String:
	for level in BUILDER_LEVELS:
		var level_id := "%s_%d" % [BUILDER, level]
		if RunData.get_nb_item(Keys.generate_hash(level_id), p) > 0:
			return level_id
	return id


static func overlaps(id: String) -> bool:
	return id in OVERLAPS


# A counter the game sets back during the wave counts from 0 from there on: each builder turret's
# set_data zeroes the turret's counters, maybe after the wave's start values were read. Checked
# every frame, before the counter can climb past its start value again.
func _check_resets() -> void:
	if _builder_keys.empty():
		for level in BUILDER_LEVELS:
			_builder_keys.append(Keys.generate_hash("%s_%d" % [BUILDER, level]))
	for p in _baseline.size():
		var tracked: Dictionary = RunData.tracked_item_effects[p]
		var baseline: Dictionary = _baseline[p]
		for key in _builder_keys:
			var start = baseline.get(key)
			var value = tracked.get(key)
			if typeof(start) == TYPE_INT and typeof(value) == TYPE_INT and value < start:
				baseline[key] = 0


static func live_sources(player_count: int) -> int:
	return LIVE_SOURCES_CROWDED if player_count >= CROWDED_FROM else LIVE_SOURCES


# The first `limit` sources. When those are all weapons or all not weapons and the strongest of
# the other kind dealt at least `least` (-1: never), the last of them gives way to it.
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


# Which counters count damage only changes when a counter is added, so the list is read again
# when there are more (and with every wave).
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
		for extra in EXTRA_IDS:
			_damage_ids[extra] = true
	return _damage_ids.get(id, false)


func _set_board(next: Dictionary) -> void:
	var same := true
	for key in ["wave", "players", "time", "hits"]:
		same = same and next.get(key) == board.get(key)
	# Dictionaries compare by identity.
	same = same and var2str(next.get("run")) == var2str(board.get("run"))
	if same:
		return
	board = next
	_revision += 1
	emit_signal("changed")


func data_of(id: String):
	if _data.empty():
		for list in [ItemService.items, ItemService.weapons, ItemService.characters]:
			for data in list:
				_data[data.my_id] = data
	return _data.get(id)


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
	ledger.reset()
	_set_board({})


static func clean(body) -> Dictionary:
	if typeof(body) != TYPE_DICTIONARY or typeof(body.get("wave")) != TYPE_INT:
		return {}
	var players = _clean_players(body.get("players"), 2)
	if players == null:
		return {}
	var time = body.get("time", 0.0)
	if not _is_amount(time):
		return {}
	var sent_hits = body.get("hits", [])
	if typeof(sent_hits) != TYPE_ARRAY or sent_hits.size() > MAX_PLAYERS:
		return {}
	var hits := []
	for hit in sent_hits:
		if not _is_hit(hit):
			return {}
		hits.append([hit[0], hit[1]])
	var next := {"wave": body.wave, "players": players, "time": float(time), "hits": hits}
	if body.has("run"):
		var run := _clean_run(body.run)
		if run.empty():
			return {}
		next["run"] = run
	return next


# {waves, time, players: [[total, sources, hit, kills, taken], ...]}; {} when malformed.
static func _clean_run(run) -> Dictionary:
	if typeof(run) != TYPE_DICTIONARY or typeof(run.get("waves")) != TYPE_INT:
		return {}
	if run.waves < 0 or run.waves > MAX_WAVES or not _is_amount(run.get("time")):
		return {}
	var players = _clean_players(run.get("players"), 5)
	if players == null:
		return {}
	return {"waves": run.waves, "time": float(run.time), "players": players}


# Board players: `size` entries each, [total, sources] or [total, sources, hit, kills, taken];
# null when malformed.
static func _clean_players(sent, size: int):
	if typeof(sent) != TYPE_ARRAY or sent.size() > MAX_PLAYERS:
		return null
	var players := []
	for entry in sent:
		if typeof(entry) != TYPE_ARRAY or entry.size() != size:
			return null
		if typeof(entry[0]) != TYPE_INT or typeof(entry[1]) != TYPE_ARRAY:
			return null
		if entry[0] < 0 or entry[1].size() > MAX_SOURCES:
			return null
		var sources := []
		for source in entry[1]:
			if typeof(source) != TYPE_ARRAY or source.size() != 3:
				return null
			if typeof(source[0]) != TYPE_STRING or source[0].length() > MAX_ID_LENGTH:
				return null
			if typeof(source[1]) != TYPE_INT or typeof(source[2]) != TYPE_INT:
				return null
			if source[1] < 0 or source[2] < 0:
				return null
			sources.append([source[0], source[1], source[2]])
		var cleaned := [entry[0], sources]
		if size > 2:
			if not _is_hit(entry[2]) or not _is_count(entry[3]) or not _is_count(entry[4]):
				return null
			cleaned += [[entry[2][0], entry[2][1]], entry[3], entry[4]]
		players.append(cleaned)
	return players


static func _is_amount(value) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_REAL] and value >= 0


static func _is_count(value) -> bool:
	return typeof(value) == TYPE_INT and value >= 0


static func _is_hit(hit) -> bool:
	if typeof(hit) != TYPE_ARRAY or hit.size() != 2 or not _is_count(hit[0]):
		return false
	return typeof(hit[1]) == TYPE_STRING and hit[1].length() <= MAX_ID_LENGTH


class DamageOrder:
	static func strongest_first(a: Array, b: Array) -> bool:
		return a[2] > b[2] if a[2] != b[2] else a[0] < b[0]
