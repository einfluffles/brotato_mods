extends Node
# Host: while the battle scene (main.tscn) runs, mirror it to clients.
# - BATTLE_START (reliable) with the full run state + entity type table, also for late joiners
# - SNAPSHOT (unreliable) at SNAPSHOT_HZ with players, entities and wave time
# - BATTLE_END (reliable) when the battle scene goes away

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
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

var session: Node = null
var input_sync: Node = null
var snapshot_bytes := 0  # size of the last snapshot, for the debug overlay

var _main: Node = null
var _battle_id := 0
var _next_net_id := 1
var _types := {}  # scene path -> type idx
var _seen_last_snapshot := {}  # instance id -> true
var _accumulator := 0.0
var _paused := false
var _events := []  # one-shot feedback since the last snapshot


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
	SoundRelay.set_sink(self)
	var main_players: Array = main.get("_players")
	for i in main_players.size():
		main_players[i].connect("took_damage", self, "_on_took_damage", [-(i + 1)])
	_types.clear()
	_seen_last_snapshot.clear()
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
	entity.set_meta(NET_ID_META, _new_net_id())


# --- snapshot ---


func _build_snapshot() -> Array:
	var players := []
	var main_players: Array = _main.get("_players")
	for i in main_players.size():
		var player = main_players[i]
		players.append(
			[
				player.global_position,
				int(player.current_stats.health),
				int(player.max_stats.health),
				_input_ack_of(i),
				RunData.get_player_gold(i),
				RunData.get_player_level(i),
				float(RunData.get_player_xp(i)),
				Snapshot.pack_weapons(player.current_weapons),
			]
		)
	var ids := PoolIntArray()
	var types := PoolIntArray()
	var positions := PoolVector2Array()
	var seen := {}
	for node in _tracked_nodes():
		if not is_instance_valid(node) or not node.is_inside_tree() or node.get("dead"):
			continue
		var instance_id: int = node.get_instance_id()
		# Not present last snapshot -> new logical entity (covers pool reuse without a signal).
		if not node.has_meta(NET_ID_META) or not _seen_last_snapshot.has(instance_id):
			node.set_meta(NET_ID_META, _new_net_id())
		seen[instance_id] = true
		if node is Unit and not node.is_connected("took_damage", self, "_on_took_damage"):
			node.connect("took_damage", self, "_on_took_damage", [0])
		ids.append(node.get_meta(NET_ID_META))
		types.append(_type_idx(_type_key(node)))
		positions.append(node.global_position)
	_seen_last_snapshot = seen
	var wave_timer = _main.get("_wave_timer")
	var time_left: float = wave_timer.time_left if wave_timer != null else 0.0
	var events := _events
	_events = []
	var snapshot := Snapshot.build(
		_battle_id, OS.get_ticks_msec(), time_left, players, ids, types, positions, events
	)
	return [Protocol.Msg.SNAPSHOT, snapshot]


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


# Called by SoundRelay for every sound the host plays during the battle.
func record_sound(sound: Resource, position, volume_mod: float, pitch_rand: float) -> void:
	if not is_in_battle() or sound == null or sound.resource_path == "":
		return
	_events.append(
		[Snapshot.EVENT_SOUND, _type_idx(sound.resource_path), position, volume_mod, pitch_rand]
	)


func _tracked_nodes() -> Array:
	var nodes := []
	var spawner = _main.get("_entity_spawner")
	if spawner != null:
		for list_name in ["enemies", "bosses", "neutrals", "structures", "pets"]:
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


func _new_net_id() -> int:
	_next_net_id += 1
	return _next_net_id
