extends Reference
# Battle state that changes the scene itself rather than moving something in it (protocol 13):
# - the jungle waves' hole layout, picked at random by every machine's main._ready
#   (GPESpawner.spawn_holes_full_scene): BATTLE_START carries the host's, the client swaps its own;
# - weapons that leave a player during a wave (Player.on_weapon_wanted_to_break, the only path in
#   the game: the brick's break_on_hit): the snapshot's per-weapon data is matched by index, so
#   the client must drop the same weapon from its puppet;
# - each player's current move speed (petrol puddles, slows, temporary speed stats), which the
#   client's own-player prediction and the walk animation use.
# One instance per battle on each side (BattleHost / BattleClient replace it with the battle).

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const PF := Snapshot.PlayerField
# GPESpawner's exported layout lists; which one the game picks depends on the map size effect.
const HOLE_LAYOUT_LISTS := ["holes_scene", "holes_old_scene", "holes_explorer_scene"]
const HOLE_LAYOUT_POSITION := Vector2.ONE  # where spawn_holes_full_scene puts it
const SPEED_REPEAT := 4  # snapshots: a speed is sent this long after it changes
const SPEED_REFRESH := 10  # ... and every this many snapshots (staggered against the stats)

# Host
var _wave_weapons := {}  # player index -> instance ids of its weapons at wave start
var _speeds := {}  # player index -> [speed (px/s, integer), snapshot count of the last change]
# Client
var _start_slots := []  # BATTLE_START's weapon_slots, validated; [] when absent
var _start_holes := ""  # BATTLE_START's hole layout scene ("" none)
var _weapon_slots := {}  # player index -> host wave-start slot of each puppet weapon, in order


# --- host ---


# Weapons are told apart by instance id: a broken weapon is freed, and no reference to a freed
# object may stay in a script variable.
func host_start(main: Node) -> void:
	var players: Array = main.get("_players")
	for i in players.size():
		var ids := []
		for weapon in players[i].current_weapons:
			ids.append(weapon.get_instance_id())
		_wave_weapons[i] = ids


# The wave-start slots of the player's weapons, ascending; null while it has all of them (the
# game adds no weapon during a wave: crates and the shop come after it).
func weapon_slots(i: int, player: Node):
	var wave: Array = _wave_weapons.get(i, [])
	var weapons: Array = player.current_weapons
	if weapons.size() == wave.size():
		return null
	var slots := PoolIntArray()
	for weapon in weapons:
		var slot := wave.find(weapon.get_instance_id())
		if slot < 0 or slot >= Snapshot.MAX_WEAPONS:
			return null  # not a weapon the client has: nothing it could map
		slots.append(slot)
	return slots


# For BATTLE_START: a client that joins mid-wave builds its puppet from the run state as it is
# now, so it must know which wave-start slots those weapons are.
func start_slots(main) -> Array:
	var all := []
	if not is_instance_valid(main):
		return all
	var players: Array = main.get("_players")
	for i in players.size():
		var slots = weapon_slots(i, players[i])
		all.append(Array(slots) if slots != null else range(players[i].current_weapons.size()))
	return all


# The move speed the host's physics uses for this player (Player.get_move_speed: stats, slows,
# petrol), in whole px/s; null in the snapshots that leave it out: it is sent for a few
# snapshots after a change and every SPEED_REFRESH, like the HUD stats.
func speed(i: int, player, snapshot_count: int):  # player: anything with get_move_speed()
	var value := int(round(player.get_move_speed()))
	var last = _speeds.get(i)
	if last == null or last[0] != value:
		last = [value, snapshot_count]
		_speeds[i] = last
	if snapshot_count - last[1] < SPEED_REPEAT or (snapshot_count + i + 5) % SPEED_REFRESH == 0:
		return value
	return null


# The scene of the hole layout this battle shows, "" when it has none.
static func hole_layout(main) -> String:
	if not is_instance_valid(main):
		return ""
	var layout = _find_layout(main, _layout_scenes(main))
	return layout.filename if layout != null else ""


# --- client ---


func client_start(body: Dictionary) -> void:
	var holes = body.get("holes")
	_start_holes = holes if typeof(holes) == TYPE_STRING else ""
	_start_slots = []
	var slots = body.get("weapon_slots")
	if typeof(slots) != TYPE_ARRAY or slots.size() > Snapshot.MAX_PLAYERS:
		return
	for entry in slots:
		if not _valid_slots(entry):
			_start_slots = []
			return
		_start_slots.append(Array(entry))


static func _valid_slots(slots) -> bool:
	if typeof(slots) != TYPE_ARRAY and typeof(slots) != TYPE_INT_ARRAY:
		return false
	var last := -1
	for slot in slots:
		if typeof(slot) != TYPE_INT or slot <= last or slot >= Snapshot.MAX_WEAPONS:
			return false
		last = slot
	return true


# Right after main._ready (BattleClient._freeze): the host's hole layout, and which wave-start
# weapon each puppet weapon is.
func client_scene_ready(main: Node) -> void:
	apply_hole_layout(main, _start_holes)
	var players: Array = main.get("_players")
	for i in players.size():
		var count: int = players[i].current_weapons.size()
		var slots: Array = _start_slots[i] if i < _start_slots.size() else []
		_weapon_slots[i] = slots if slots.size() == count else range(count)


# Replaces the layout main._ready picked here with the host's. Only scenes of the spawner's own
# lists are taken (the path comes from the network). Returns whether the scene changed.
static func apply_hole_layout(main: Node, path: String) -> bool:
	var scenes := _layout_scenes(main)
	var container = main.get("_gpe_container")
	var current = _find_layout(main, scenes)
	var current_path: String = current.filename if current != null else ""
	if container == null or current_path == path or (path != "" and not scenes.has(path)):
		return false
	if current != null:
		container.remove_child(current)
		current.free()
	# Holes are the only thing that registers forbidden circles (Hole._ready), and at this point
	# only the layout's holes exist: the new layout's holes register theirs as they enter.
	ZoneService.forbidden_circles.clear()
	ZoneService._valid_cells_dirty = true
	if path != "":
		var layout: Node2D = scenes[path].instance()
		layout.global_position = HOLE_LAYOUT_POSITION
		container.add_child(layout)
	return true


# path -> PackedScene of every layout the game can pick.
static func _layout_scenes(main: Node) -> Dictionary:
	var scenes := {}
	var spawner = main.get("_gpe_spawner")
	if spawner == null:
		return scenes
	for list_name in HOLE_LAYOUT_LISTS:
		var list = spawner.get(list_name)
		if list is Array:
			for scene in list:
				if scene is PackedScene:
					scenes[scene.resource_path] = scene
	return scenes


static func _find_layout(main: Node, scenes: Dictionary):
	var container = main.get("_gpe_container")
	if container == null:
		return null
	for child in container.get_children():
		if scenes.has(child.filename) and not child.is_queued_for_deletion():
			return child
	return null


# At render time, before the snapshot's weapon data is applied by index: the puppet drops the
# weapons the host no longer has, as Player.on_weapon_wanted_to_break does.
func follow_weapons(player: Node, i: int, entry: Array) -> void:
	var slots = entry[PF.WEAPON_SLOTS] if entry.size() > PF.WEAPON_SLOTS else null
	var own = _weapon_slots.get(i)
	if slots == null or own == null or own.size() == slots.size():
		return
	var keep := {}
	for slot in slots:
		keep[slot] = true
	for k in range(own.size() - 1, -1, -1):
		if not keep.has(own[k]) and k < player.current_weapons.size():
			own.remove(k)
			_remove_weapon(player, i, k)


static func _remove_weapon(player: Node, i: int, k: int) -> void:
	var weapon = player.current_weapons[k]
	player.current_weapons.remove(k)
	for other in player.current_weapons:
		if other.weapon_pos > weapon.weapon_pos:
			other.weapon_pos -= 1
	weapon.queue_free()
	# Only the list (the live menu shows it): stats and effects are the host's, and the next run
	# state (shop) brings the rest.
	var weapons: Array = RunData.players_data[i].weapons if i < RunData.players_data.size() else []
	if k < weapons.size():
		weapons.remove(k)


# The host's speed replaces whatever made up the puppet's (its stats are frozen at wave start;
# petrol and slows are host physics): own-player prediction and the walk animation read it
# through Player.get_move_speed.
static func apply_speed(player: Node, entry: Array) -> void:
	var value = entry[PF.SPEED] if entry.size() > PF.SPEED else null
	if value == null or player.get_move_speed() == float(value):
		return
	player.current_stats.speed = value
	player.bonus_speed = 0
	player.decaying_bonus_speed = 0.0
	player.petrol_malus = 0.0
