extends Node
# Host: while the battle scene (main.tscn) runs, mirror it to clients.
# - BATTLE_START (reliable) with the full run state + entity type table, also for late joiners
# - SNAPSHOT (unreliable) at SNAPSHOT_HZ with players, entities and wave time
# - BATTLE_END (reliable) when the battle scene goes away

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Pose := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/pose.gd")
const AnimMirror := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/anim_mirror.gd")
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const LOG_NAME := "einfluffles-BrotatoTogether:BattleHost"
const BATTLE_SCENE := "res://main.tscn"
const SNAPSHOT_HZ := 30
const NET_ID_META := "brotato_together_net_id"
const CURSED_TAG := "cursed"
const SPAWNER_RESPAWN_SIGNALS := [
	"enemy_respawned", "neutral_respawned", "structure_respawned", "pet_respawned"
]
# Bosses first: clients spawn in snapshot order, and boss parts look up their boss in _ready
# (BrachiosaurusFoot finds "Brachiosaurus").
const SPAWNER_LISTS := ["bosses", "enemies", "neutrals", "structures", "pets"]
const REST_AFTER := 4  # snapshots without movement before an entity's position is left out
const REST_REFRESH := 15  # ... but it is still sent every this many snapshots (staggered by id)
const STATS_REPEAT := 4  # snapshots: player stats are sent this long after they change
const STATS_REFRESH := 10  # ... and every this many snapshots
const MAX_EVENTS := 48  # per snapshot; Snapshot.select_events drops the least valuable

var session: Node = null
var input_sync: Node = null
var snapshot_bytes := 0  # size of the last snapshot, for the F9 menu

var _main: Node = null
var _battle_id := 0
var _next_net_id := 1
var _types := {}  # scene path -> type idx
var _seen_last_snapshot := {}  # instance id -> true
var _live_ids := {}  # net ids in the last snapshot (not reused while alive)
var _rest := {}  # instance id -> [net id, quantized position, unchanged snapshots]
var _stats := {}  # player index -> [stats Array, snapshot count of the last change]
var _snapshot_count := 0
var _accumulator := 0.0
var _paused := false
var _events := []  # one-shot feedback since the last snapshot
var _pose = Pose.new()
var _anim_mirror = AnimMirror.new()


func setup(netplay_session: Node, remote_input: Node) -> void:
	session = netplay_session
	input_sync = remote_input
	session.connect("peer_ready", self, "_on_peer_ready")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func is_in_battle() -> bool:
	return _main != null and is_instance_valid(_main)


func _process(_delta: float) -> void:
	if not session.is_host():
		if is_in_battle():
			_end_battle()
		return
	var scene := get_tree().current_scene
	var in_battle_scene := scene != null and scene.filename == BATTLE_SCENE
	if is_in_battle() and scene != _main:
		_end_battle()
	if in_battle_scene and not is_in_battle():
		_start_battle(scene)


func _physics_process(delta: float) -> void:
	if not is_in_battle() or not session.is_host():
		return
	if get_tree().paused != _paused:
		_paused = get_tree().paused
		session.broadcast_reliable(
			Protocol.Msg.BATTLE_PAUSE, {"battle_id": _battle_id, "paused": _paused}
		)
	if _paused:
		return
	_accumulator += delta
	if _accumulator < 1.0 / SNAPSHOT_HZ:
		return
	_accumulator = fmod(_accumulator, 1.0 / SNAPSHOT_HZ)
	var bytes := var2bytes(_build_snapshot())
	snapshot_bytes = bytes.size()
	for steam_id in session.peers:
		if session.peers[steam_id].ready:
			session.transport.send(steam_id, session.transport.CHANNEL_UNRELIABLE, bytes)


# --- battle lifecycle ---


func _start_battle(main: Node) -> void:
	_main = main
	_battle_id += 1
	_paused = false
	_events.clear()
	_anim_mirror = AnimMirror.new()
	SoundRelay.set_sink(self)
	var main_players: Array = main.get("_players")
	for i in main_players.size():
		main_players[i].connect("took_damage", self, "_on_took_damage", [-(i + 1)])
	_types.clear()
	_seen_last_snapshot.clear()
	_rest.clear()
	_stats.clear()
	_preregister_types(main)
	var spawner = main.get("_entity_spawner")
	for signal_name in SPAWNER_RESPAWN_SIGNALS:
		if spawner != null and spawner.has_signal(signal_name):
			spawner.connect(signal_name, self, "_on_entity_respawned")
	ModLoaderLog.info("Battle %s started (wave %s)" % [_battle_id, RunData.current_wave], LOG_NAME)
	var start := _battle_start_body()
	for steam_id in session.peers:
		if session.peers[steam_id].ready:
			_send_battle_start(steam_id, start)


func _end_battle() -> void:
	ModLoaderLog.info("Battle %s ended" % _battle_id, LOG_NAME)
	_main = null
	SoundRelay.set_sink(null)
	if session.is_host():
		session.broadcast_reliable(Protocol.Msg.BATTLE_END, {"battle_id": _battle_id})


func _battle_start_body() -> Dictionary:
	var types_by_idx := {}
	for path in _types:
		types_by_idx[_types[path]] = path
	return {
		"battle_id": _battle_id,
		"run": RunStateCodec.encode(),
		"types": types_by_idx,
		"paused": _paused,
	}


func _on_peer_ready(steam_id: int) -> void:
	if session.is_host() and is_in_battle():
		_send_battle_start(steam_id, _battle_start_body())


# Each client also learns which player slot it controls (-1: spectator).
func _send_battle_start(steam_id: int, start: Dictionary) -> void:
	var body := start.duplicate()
	body["you"] = _player_index_of(steam_id)
	session.send_reliable(steam_id, Protocol.Msg.BATTLE_START, body)


func _player_index_of(steam_id: int) -> int:
	var device = input_sync.devices.get(steam_id)
	if device == null:
		return -1
	for i in CoopService.connected_players.size():
		if CoopService.connected_players[i][0] == device:
			return i
	return -1


# Last INPUT seq applied for the peer controlling player i (0 for local players).
func _input_ack_of(player_index: int) -> int:
	if player_index >= CoopService.connected_players.size():
		return 0
	var device: int = CoopService.connected_players[player_index][0]
	for steam_id in input_sync.devices:
		if input_sync.devices[steam_id] == device:
			return input_sync.last_applied_seq(steam_id)
	return 0


# Pooled nodes are reused for new entities; every (re)spawn gets a fresh net id.
func _on_entity_respawned(entity: Node) -> void:
	_assign_net_id(entity)


func _assign_net_id(node: Node) -> void:
	node.set_meta(NET_ID_META, _new_net_id())
	if not node.is_connected("tree_exiting", self, "_on_tracked_exiting"):
		node.connect("tree_exiting", self, "_on_tracked_exiting", [node])


# Pools take nodes out of the tree: whatever comes back is a new entity, even when it is reused
# before the next snapshot (the game's pools are LIFO).
func _on_tracked_exiting(node: Node) -> void:
	if node.has_meta(NET_ID_META):
		node.remove_meta(NET_ID_META)


# Scenes the battle will need, so clients load them with BATTLE_START instead of mid-wave: the
# wave's units, the players' projectiles, gold.
func _preregister_types(main: Node) -> void:
	var paths := []
	var wave_manager = main.get("_wave_manager")
	var wave_data = wave_manager.get("current_wave_data") if wave_manager != null else null
	if wave_data != null:
		for group in wave_data.groups_data:
			for unit in group.wave_units_data:
				if unit.unit_scene != null:
					paths.append(unit.unit_scene.resource_path)
	for player in main.get("_players"):
		for weapon in player.current_weapons:
			var stats = weapon.get("current_stats")
			var scene = stats.get("projectile_scene") if stats != null else null
			if scene is PackedScene:
				paths.append(scene.resource_path)
	var gold_scene = main.get("gold_scene")
	if gold_scene is PackedScene:
		paths.append(gold_scene.resource_path)
	for path in paths:
		if path != "" and not _types.has(path):
			_types[path] = _types.size()


# --- snapshot ---


func _build_snapshot() -> Array:
	var view := {
		"battle_id": _battle_id,
		"t": OS.get_ticks_msec(),
		"wave_time_left": 0.0,
		"players": _capture_players(),
		"ids": PoolIntArray(),
		"types": PoolIntArray(),
		"positions": PoolVector2Array(),
		"poses": {},
	}
	var wave_timer = _main.get("_wave_timer")
	view.wave_time_left = wave_timer.time_left if wave_timer != null else 0.0
	var flags := []
	var ids := PoolIntArray()  # pool arrays are values: filled locally, stored at the end
	var types := PoolIntArray()
	var positions := PoolVector2Array()
	var seen := {}
	var rest := {}
	for node in _grouped_by_type(_tracked_nodes(), seen):
		if node is Unit and not node.is_connected("took_damage", self, "_on_took_damage"):
			node.connect("took_damage", self, "_on_took_damage", [0])
		var net_id: int = node.get_meta(NET_ID_META)
		ids.append(net_id)
		types.append(_type_idx(_type_key(node)))
		positions.append(node.global_position)
		_anim_mirror.capture(node, net_id, _events)
		var pose: PoolRealArray = _pose.capture(node)
		if not pose.empty():
			view.poses[ids.size() - 1] = pose
		var node_flags := _flags_of(node)
		if pose.empty() and _is_resting(node, net_id, rest):
			node_flags |= Snapshot.FLAG_REST
		flags.append(node_flags)
	_seen_last_snapshot = seen
	_rest = rest
	_live_ids = {}
	for net_id in ids:
		_live_ids[net_id] = true
	_anim_mirror.end_snapshot()
	view.ids = ids
	view.types = types
	view.positions = positions
	view.flags = Snapshot.pack_flags(flags)
	view["events"] = Snapshot.select_events(_events, MAX_EVENTS)
	_events = []
	_snapshot_count += 1
	return [Protocol.Msg.SNAPSHOT, Snapshot.encode(view)]


func _capture_players() -> Array:
	var players := []
	var main_players: Array = _main.get("_players")
	for i in main_players.size():
		var player = main_players[i]
		var stats := [
			int(player.current_stats.health),
			int(player.max_stats.health),
			RunData.get_player_gold(i),
			RunData.get_player_level(i),
			float(RunData.get_player_xp(i)),
		]
		var entry := [player.global_position, null, null, _input_ack_of(i), null, null, null]
		entry.append(Snapshot.pack_weapons(player.current_weapons))
		var last = _stats.get(i)
		if last == null or last[0] != stats:
			last = [stats, _snapshot_count]
			_stats[i] = last
		if (
			_snapshot_count - last[1] < STATS_REPEAT
			or (_snapshot_count + i) % STATS_REFRESH == 0
		):
			for k in stats.size():
				entry[Snapshot.STAT_FIELDS[k]] = stats[k]
		players.append(entry)
	return players


# Live nodes with their net ids, grouped by type (types travel as runs) and sorted by id inside a
# group (ids travel as deltas); groups keep the order in which their first entity appears, so
# bosses stay first.
func _grouped_by_type(nodes: Array, seen: Dictionary) -> Array:
	var groups := {}
	var order := []
	for node in nodes:
		if not is_instance_valid(node) or not node.is_inside_tree() or node.get("dead"):
			continue
		var instance_id: int = node.get_instance_id()
		# Not present last snapshot -> new logical entity (covers pool reuse without a signal).
		if not node.has_meta(NET_ID_META) or not _seen_last_snapshot.has(instance_id):
			_assign_net_id(node)
		seen[instance_id] = true
		var key := _type_key(node)
		if not groups.has(key):
			groups[key] = []
			order.append(key)
		groups[key].append(node)
	var grouped := []
	for key in order:
		var group: Array = groups[key]
		group.sort_custom(self, "_net_id_less")
		grouped += group
	return grouped


func _net_id_less(a: Node, b: Node) -> bool:
	return a.get_meta(NET_ID_META) < b.get_meta(NET_ID_META)


# Unmoved for REST_AFTER snapshots: the position is left out (clients keep the last one), except
# in a refresh every REST_REFRESH snapshots for clients that missed it.
func _is_resting(node: Node, net_id: int, rest: Dictionary) -> bool:
	var position := Snapshot.quantize_position(node.global_position)
	var last = _rest.get(node.get_instance_id())
	var unchanged := 0
	if last != null and last[0] == net_id and last[1] == position:
		unchanged = last[2] + 1
	rest[node.get_instance_id()] = [net_id, position, unchanged]
	return unchanged >= REST_AFTER and (_snapshot_count + net_id) % REST_REFRESH != 0


# Facing is host state: behaviors turn units toward their target, and knockback would flip a
# puppet that faced its interpolated motion. Hidden: e.g. stampede dinos before their charge.
# flip_h: JumpAttackBehavior turns the sprite toward its landing spot (and leaves it so).
func _flags_of(node: Node) -> int:
	var flags := 0
	if node is Unit and node.sprite != null:
		flags |= Snapshot.FLAG_FACING_LEFT if node.sprite.scale.x < 0 else 0
		flags |= Snapshot.FLAG_FLIP_H if node.sprite.flip_h else 0
	if not node.visible:
		flags |= Snapshot.FLAG_HIDDEN
	return flags


# --- one-shot feedback (damage numbers, hit flashes/particles, sounds) ---


# player_target: -(player_index + 1) for players, 0 for entities (looked up by net id).
func _on_took_damage(
	unit: Node,
	value: int,
	knockback: Vector2,
	is_crit: bool,
	is_dodge: bool,
	is_protected: bool,
	armor_did_something: bool,
	args,
	hit_type: int,
	is_one_shot: bool,
	player_target: int
) -> void:
	if not is_in_battle() or (args != null and args.hide_feedback):
		return
	var target := player_target
	if target == 0:
		if not unit.has_meta(NET_ID_META):
			return
		target = unit.get_meta(NET_ID_META)
	var flags := 0
	flags |= Snapshot.DAMAGE_CRIT if is_crit else 0
	flags |= Snapshot.DAMAGE_DODGE if is_dodge else 0
	flags |= Snapshot.DAMAGE_PROTECTED if is_protected else 0
	flags |= Snapshot.DAMAGE_ARMOR if armor_did_something else 0
	flags |= Snapshot.DAMAGE_ONE_SHOT if is_one_shot else 0
	_events.append([Snapshot.EVENT_DAMAGE, target, value, knockback, flags, hit_type])


# Called by SoundRelay for every sound the host's sound managers accept during the battle
# (cooldown: playSingle's duplicate_cooldown, 0 for play()).
# Not while paused: the pause menu isn't shown on clients, and its sounds would arrive as a
# burst with the first snapshot after unpausing.
func record_sound(
	sound: Resource, position, volume_mod: float, pitch_rand: float, always := false, cooldown := 0.0
) -> void:
	if not is_in_battle() or get_tree().paused or sound == null or sound.resource_path == "":
		return
	var idx := _type_idx(sound.resource_path)
	_events.append([Snapshot.EVENT_SOUND, idx, position, volume_mod, pitch_rand, always, cooldown])


func _tracked_nodes() -> Array:
	var nodes := []
	var spawner = _main.get("_entity_spawner")
	if spawner != null:
		for list_name in SPAWNER_LISTS:
			var list = spawner.get(list_name)
			if list is Array:
				nodes += list
	for list_name in ["_active_golds", "_consumables"]:
		var list = _main.get(list_name)
		if list is Array:
			nodes += list
	# Pooled projectiles are removed from the tree, so container children are the live ones.
	for container_name in ["_player_projectiles", "_enemy_projectiles"]:
		var container = _main.get(container_name)
		if container != null:
			for child in container.get_children():
				if child is Projectile:
					nodes.append(child)
	return nodes


# Scene path, plus "#<tag>" where the look comes from data assigned at spawn: consumables (fruit
# vs. crate vs. legendary crate share one scene) and cursed structures (curse particles).
func _type_key(node: Node) -> String:
	if node is Consumable and node.consumable_data != null:
		return "%s#%s" % [node.filename, node.consumable_data.my_id]
	if node is Structure and node.is_cursed:
		return "%s#%s" % [node.filename, CURSED_TAG]
	return node.filename


func _type_idx(path: String) -> int:
	if not _types.has(path):
		var idx := _types.size()
		_types[path] = idx
		session.broadcast_reliable(
			Protocol.Msg.TYPE_DEF, {"battle_id": _battle_id, "idx": idx, "path": path}
		)
	return _types[path]


# u16 on the wire: wraps around, skipping ids that are still alive.
func _new_net_id() -> int:
	for _i in Snapshot.MAX_NET_ID:
		_next_net_id = _next_net_id % Snapshot.MAX_NET_ID + 1
		if not _live_ids.has(_next_net_id):
			break
	return _next_net_id
