extends Reference
# Battle state that changes the scene itself rather than moving something in it: the hole layout,
# dig sites, weapons that break during a wave, each player's move speed, and the obstacles that
# stop the own-player prediction. One instance per battle on each side.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const PF := Snapshot.PlayerField
# GPESpawner's exported layout lists; which one the game picks depends on the map size effect.
const HOLE_LAYOUT_LISTS := ["holes_scene", "holes_old_scene", "holes_explorer_scene"]
const HOLE_LAYOUT_POSITION := Vector2.ONE  # where spawn_holes_full_scene puts it
const SPEED_REPEAT := 4  # snapshots a speed is sent for after it changes
const SPEED_REFRESH := 10  # snapshots between resends (staggered against the stats)
# Physics layer "obstacles" (holes, the map's limits): all a player's body runs into besides the
# other players.
const OBSTACLES := 128
const MOTION_MARGIN := 0.08  # Unit._physics_process's test_motion margin

var _wave_weapons := {}  # player index -> instance ids of its weapons at wave start
var _speeds := {}  # player index -> [speed (px/s, integer), snapshot count of the last change]
var _start_slots := []  # BATTLE_START's weapon_slots, validated; [] when absent
var _start_holes := ""  # BATTLE_START's hole layout scene ("" none)
var _weapon_slots := {}  # player index -> host wave-start slot of each puppet weapon, in order


# Weapons are told apart by instance id: a broken weapon is freed, and no reference to a freed
# object may stay in a script variable.
func host_start(main: Node) -> void:
	var players: Array = main.get("_players")
	for i in players.size():
		var ids := []
		for weapon in players[i].current_weapons:
			ids.append(weapon.get_instance_id())
		_wave_weapons[i] = ids


# null while the player has all its wave-start weapons (the game adds none during a wave).
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


# A client that joins mid-wave builds its puppet from the run state as it is now, so it must
# know which wave-start slots those weapons are.
func start_slots(main) -> Array:
	var all := []
	if not is_instance_valid(main):
		return all
	var players: Array = main.get("_players")
	for i in players.size():
		var slots = weapon_slots(i, players[i])
		all.append(Array(slots) if slots != null else range(players[i].current_weapons.size()))
	return all


# Player.get_move_speed in whole px/s; null in the snapshots that leave it out.
func speed(i: int, player, snapshot_count: int):  # player: anything with get_move_speed()
	var value := int(round(player.get_move_speed()))
	var last = _speeds.get(i)
	if last == null or last[0] != value:
		last = [value, snapshot_count]
		_speeds[i] = last
	if snapshot_count - last[1] < SPEED_REPEAT or (snapshot_count + i + 5) % SPEED_REFRESH == 0:
		return value
	return null


static func hole_layout(main) -> String:
	if not is_instance_valid(main):
		return ""
	var layout = _find_layout(main, _layout_scenes(main))
	return layout.filename if layout != null else ""


# Single holes (spawn_single_hole_at_position) are children of the container itself; the
# layout's holes are children of its scene.
static func spawned_holes(main) -> Array:
	var holes := []
	var container = main.get("_gpe_container")
	if not is_instance_valid(container):
		return holes
	for child in container.get_children():
		if child is Hole and not child.is_queued_for_deletion():
			holes.append(child)
	return holes


# DigSiteSceneEffectBehavior places them at random on every machine: the host's are mirrored as
# static snapshot entities, their progress as pose values (sync/pose.gd).
static func dig_sites(main) -> Array:
	var sites := []
	var container = main.get("_gpe_container")
	if not is_instance_valid(container):
		return sites
	for child in container.get_children():
		if child is DigSite and not child.is_queued_for_deletion():
			sites.append(child)
	return sites


static func free_own_dig_sites(main: Node) -> void:
	for site in dig_sites(main):
		site.get_parent().remove_child(site)
		site.free()


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


func client_scene_ready(main: Node) -> void:
	apply_hole_layout(main, _start_holes)
	free_own_dig_sites(main)  # before any puppet of the host's
	var players: Array = main.get("_players")
	for i in players.size():
		var count: int = players[i].current_weapons.size()
		var slots: Array = _start_slots[i] if i < _start_slots.size() else []
		_weapon_slots[i] = slots if slots.size() == count else range(count)


# main._ready picks a hole layout at random on every machine (GPESpawner.spawn_holes_full_scene).
# Only scenes of the spawner's own lists are taken: the path comes from the network.
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


# The snapshot's per-weapon data is matched by index, so the puppet drops the weapons the host
# no longer has, as Player.on_weapon_wanted_to_break does.
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


# The puppet's stats are frozen at wave start, and petrol and slows are host physics: the host's
# speed replaces them all. Prediction and the walk animation read it via Player.get_move_speed.
static func apply_speed(player: Node, entry: Array) -> void:
	var value = entry[PF.SPEED] if entry.size() > PF.SPEED else null
	if value == null or player.get_move_speed() == float(value):
		return
	player.current_stats.speed = value
	player.bonus_speed = 0
	player.decaying_bonus_speed = 0.0
	player.petrol_malus = 0.0


# Tardigrade charges, used up by the host's blocked hits: the HUD counter, and the life bars'
# tint, which main._physics_process reads from _hit_protection every frame.
static func apply_hit_protection(main: Node, i: int, player: Node, entry: Array) -> void:
	if player._hit_protection == entry[PF.HIT_PROTECTION]:
		return
	player._hit_protection = entry[PF.HIT_PROTECTION]
	var players_ui = main.get("_players_ui")
	if players_ui != null and i < players_ui.size():
		players_ui[i].update_hit_protection_count(player, player._hit_protection)


# One physics tick of a player as Unit._physics_process moves it on the host: test_motion against
# its collision mask, then once more along what it hit. The body itself stays where it is.
# result: a Physics2DTestMotionResult to reuse.
static func step(player: Node2D, from: Vector2, motion: Vector2, result) -> Vector2:
	if not player is PhysicsBody2D:
		return from + motion
	var xform: Transform2D = player.global_transform
	xform.origin = from
	var body: RID = player.get_rid()
	var hit := Physics2DServer.body_test_motion(body, xform, motion, true, MOTION_MARGIN, result)
	# RigidBody2D.test_motion reports no hit for a body that only touches something and gets its
	# whole way: the server does, and a second slide along a wall doubled the step.
	hit = hit and result.collision_safe_fraction < 1.0
	from += result.motion
	if hit:
		xform.origin = from
		var slide := motion.slide(result.collision_normal)
		Physics2DServer.body_test_motion(body, xform, slide, true, MOTION_MARGIN, result)
		from += result.motion
	return from
