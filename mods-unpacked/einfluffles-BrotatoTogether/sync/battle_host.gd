extends Node
# Host: while the battle scene (main.tscn) runs, mirror it to clients.
# - BATTLE_START (reliable) with the full run state + entity type table, also for late joiners
# - SNAPSHOT (unreliable) at SNAPSHOT_HZ with players, entities and wave time
# - BATTLE_END (reliable) when the battle scene goes away

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const LOG_NAME := "einfluffles-BrotatoTogether:BattleHost"
const BATTLE_SCENE := "res://main.tscn"
const SNAPSHOT_HZ := 30
const NET_ID_META := "brotato_together_net_id"
const SPAWNER_RESPAWN_SIGNALS := [
	"enemy_respawned", "neutral_respawned", "structure_respawned", "pet_respawned"
]

var session: Node = null
var snapshot_bytes := 0  # size of the last snapshot, for the debug overlay

var _main: Node = null
var _battle_id := 0
var _next_net_id := 1
var _types := {}  # scene path -> type idx
var _seen_last_snapshot := {}  # instance id -> true
var _accumulator := 0.0


func setup(netplay_session: Node) -> void:
	session = netplay_session
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
	if not is_in_battle() or not session.is_host() or get_tree().paused:
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
	_types.clear()
	_seen_last_snapshot.clear()
	var spawner = main.get("_entity_spawner")
	for signal_name in SPAWNER_RESPAWN_SIGNALS:
		if spawner != null and spawner.has_signal(signal_name):
			spawner.connect(signal_name, self, "_on_entity_respawned")
	ModLoaderLog.info("Battle %s started (wave %s)" % [_battle_id, RunData.current_wave], LOG_NAME)
	var start := _battle_start_body()
	session.broadcast_reliable(Protocol.Msg.BATTLE_START, start)


func _end_battle() -> void:
	ModLoaderLog.info("Battle %s ended" % _battle_id, LOG_NAME)
	_main = null
	if session.is_host():
		session.broadcast_reliable(Protocol.Msg.BATTLE_END, {"battle_id": _battle_id})


func _battle_start_body() -> Dictionary:
	var types_by_idx := {}
	for path in _types:
		types_by_idx[_types[path]] = path
	return {"battle_id": _battle_id, "run": RunStateCodec.encode(), "types": types_by_idx}


func _on_peer_ready(steam_id: int) -> void:
	if session.is_host() and is_in_battle():
		session.send_reliable(steam_id, Protocol.Msg.BATTLE_START, _battle_start_body())


# Pooled nodes are reused for new entities; every (re)spawn gets a fresh net id.
func _on_entity_respawned(entity: Node) -> void:
	entity.set_meta(NET_ID_META, _new_net_id())


# --- snapshot ---


func _build_snapshot() -> Array:
	var players := []
	for player in _main.get("_players"):
		players.append(
			[
				player.global_position,
				int(player.current_stats.health),
				int(player.max_stats.health),
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
		ids.append(node.get_meta(NET_ID_META))
		types.append(_type_idx(node.filename))
		positions.append(node.global_position)
	_seen_last_snapshot = seen
	var wave_timer = _main.get("_wave_timer")
	var time_left: float = wave_timer.time_left if wave_timer != null else 0.0
	return [
		Protocol.Msg.SNAPSHOT,
		Snapshot.build(_battle_id, OS.get_ticks_msec(), time_left, players, ids, types, positions)
	]


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
	return nodes


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
