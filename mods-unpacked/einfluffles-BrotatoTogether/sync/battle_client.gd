extends Node
# Client: mirror the host's battle.
# BATTLE_START -> apply run state, load main.tscn in puppet mode (simulation frozen right after
# main._ready, before its first physics frame). SNAPSHOTs are buffered and rendered
# INTERP_DELAY_MSEC in the past, interpolating between the two snapshots around render time:
# smooth motion at any fps, independent of the 30 Hz network rate.

signal battle_entered
signal battle_left

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const PuppetEntity := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/puppet_entity.gd"
)
const LOG_NAME := "einfluffles-BrotatoTogether:BattleClient"
const BATTLE_SCENE := "res://main.tscn"
const INTERP_DELAY_MSEC := 100
const MAX_BUFFERED := 32
const CLOCK_CREEP_MSEC := 0.5  # per snapshot: lets the offset follow rising latency / drift
const WAVE_TIMER_TOLERANCE := 0.3

var session: Node = null
var interp_lag_msec := 0  # render time vs newest snapshot, for the debug overlay

var _battle_id := 0
var _types := {}  # idx -> PackedScene (null if rejected)
var _buffer := []  # parsed snapshots, ascending t
var _clock_offset := 0.0  # local_msec - host_msec (min-filtered)
var _has_clock := false
var _main: Node = null
var _entities := {}  # net id -> node
var _last_positions := {}  # net id / "p<i>" -> Vector2


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.connect("message", self, "_on_message")
	session.transport.connect("lobby_left", self, "_on_lobby_left")
	get_tree().connect("node_added", self, "_on_node_added")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func is_in_battle() -> bool:
	return _main != null and is_instance_valid(_main)


func _on_message(steam_id: int, msg_type: int, body) -> void:
	if not session.is_client() or steam_id != session.transport.host_id:
		return
	match msg_type:
		Protocol.Msg.BATTLE_START:
			_on_battle_start(body)
		Protocol.Msg.BATTLE_END:
			if typeof(body) == TYPE_DICTIONARY and body.get("battle_id") == _battle_id:
				_leave_battle()
		Protocol.Msg.TYPE_DEF:
			if typeof(body) == TYPE_DICTIONARY and body.get("battle_id") == _battle_id:
				_define_type(body.get("idx"), body.get("path"))
		Protocol.Msg.SNAPSHOT:
			_on_snapshot(Snapshot.parse(body))


# --- battle lifecycle ---


func _on_battle_start(body) -> void:
	if typeof(body) != TYPE_DICTIONARY or typeof(body.get("battle_id")) != TYPE_INT:
		return
	var state := RunStateCodec.decode(body.get("run"))
	if state.empty():
		ModLoaderLog.error("Invalid run state in BATTLE_START", LOG_NAME)
		return
	_reset_battle_state()
	_battle_id = body.battle_id
	var types = body.get("types")
	if typeof(types) == TYPE_DICTIONARY:
		for idx in types:
			_define_type(idx, types[idx])

	Puppet.set_active(true)
	RunStateCodec.apply(state)
	_fill_coop_slots(RunData.get_player_count())
	get_tree().paused = false
	if get_tree().change_scene(BATTLE_SCENE) != OK:
		ModLoaderLog.error("Could not load the battle scene", LOG_NAME)
	ModLoaderLog.info("Entering battle %s (wave %s)" % [_battle_id, RunData.current_wave], LOG_NAME)


func _leave_battle() -> void:
	_reset_battle_state()
	emit_signal("battle_left")


func _on_lobby_left() -> void:
	_reset_battle_state()
	Puppet.set_active(false)
	CoopService.clear_coop_players()


func _reset_battle_state() -> void:
	_main = null
	_battle_id = 0
	_types.clear()
	_buffer.clear()
	_entities.clear()
	_last_positions.clear()
	_has_clock = false


# main.tscn spawns players from CoopService.connected_players; give it one slot per host player.
func _fill_coop_slots(count: int) -> void:
	CoopService.connected_players.clear()
	for i in count:
		CoopService.connected_players.push_back(
			[VirtualDevices.FIRST + i, CoopService.PlayerType.GAMEPAD_XBOX]
		)


func _on_node_added(node: Node) -> void:
	if Puppet.is_active() and _battle_id != 0 and node.filename == BATTLE_SCENE:
		node.connect("ready", self, "_on_battle_scene_ready", [node], CONNECT_ONESHOT)


# Runs right after main._ready(), before the first physics frame.
func _on_battle_scene_ready(main: Node) -> void:
	_main = main
	# Local pause/aim handling off; pause goes to the host via input. main._physics_process stays
	# on: it only recolors life bars.
	main.set_process(false)
	for node_name in ["_wave_manager", "_entity_spawner", "_effect_behaviors", "_stats_manager"]:
		var node = main.get(node_name)
		if node != null:
			node.propagate_call("set_physics_process", [false])
			node.propagate_call("set_process", [false])
			for child in node.get_children():
				if child is Timer:
					child.stop()
	_disconnect_timer_callbacks(main)
	var half_second_timers = main.get("_half_second_timers")
	if half_second_timers != null:
		for timer in half_second_timers.get_children():
			if timer is Timer:
				timer.stop()
	for player in main.get("_players"):
		PuppetEntity.puppetize(player)
	emit_signal("battle_entered")


# Wave end, half-wave events, harvesting, ... are host decisions. Timers keep counting (the wave
# timer drives the HUD label) but no longer call into main.
func _disconnect_timer_callbacks(main: Node) -> void:
	for connection in main.get_incoming_connections():
		if connection.source is Timer and connection.signal_name == "timeout":
			connection.source.disconnect("timeout", main, connection.method_name)


# --- snapshots ---


func _define_type(idx, path) -> void:
	if typeof(idx) != TYPE_INT or typeof(path) != TYPE_STRING:
		return
	# Only game/mod scenes; the host is trusted but paths still come from the network.
	if not path.begins_with("res://") or not path.ends_with(".tscn") or ".." in path:
		_types[idx] = null
		return
	_types[idx] = load(path)


func _on_snapshot(snapshot: Dictionary) -> void:
	if snapshot.empty() or snapshot.battle_id != _battle_id:
		return
	var sample := float(OS.get_ticks_msec() - snapshot.t)
	if not _has_clock or sample < _clock_offset:
		_clock_offset = sample
		_has_clock = true
	else:
		_clock_offset += CLOCK_CREEP_MSEC
	# Insert sorted by host time; drop duplicates and stale ones.
	var i := _buffer.size()
	while i > 0 and _buffer[i - 1].t > snapshot.t:
		i -= 1
	if i > 0 and _buffer[i - 1].t == snapshot.t:
		return
	_buffer.insert(i, snapshot)
	while _buffer.size() > MAX_BUFFERED:
		_buffer.pop_front()


func _process(_delta: float) -> void:
	if not is_in_battle() or _buffer.empty():
		return
	var render_t := OS.get_ticks_msec() - _clock_offset - INTERP_DELAY_MSEC
	# Drop snapshots that are fully in the past (keep one before render_t).
	while _buffer.size() > 2 and _buffer[1].t <= render_t:
		_buffer.pop_front()
	var from: Dictionary = _buffer[0]
	var to: Dictionary = _buffer[1] if _buffer.size() > 1 else from
	var alpha := 1.0
	if to.t > from.t:
		alpha = clamp((render_t - from.t) / float(to.t - from.t), 0.0, 1.0)
	interp_lag_msec = int(_buffer[-1].t - render_t)
	_apply_players(from, to, alpha)
	_apply_entities(from, to, alpha)
	_apply_wave_timer(to.wave_time_left)


func _apply_players(from: Dictionary, to: Dictionary, alpha: float) -> void:
	var players: Array = _main.get("_players")
	for i in min(players.size(), to.players.size()):
		var target: Array = to.players[i]
		var position: Vector2 = target[0]
		if i < from.players.size():
			position = from.players[i][0].linear_interpolate(target[0], alpha)
		_move(players[i], "p%s" % i, position)
		var player = players[i]
		if player.current_stats.health != target[1] or player.max_stats.health != target[2]:
			player.current_stats.health = target[1]
			player.max_stats.health = target[2]
			player.emit_signal("health_updated", player, target[1], target[2])


func _apply_entities(from: Dictionary, to: Dictionary, alpha: float) -> void:
	var alive := {}
	var ids: PoolIntArray = to.ids
	for i in ids.size():
		var id := ids[i]
		var node = _entities.get(id)
		if node == null or not is_instance_valid(node):
			node = _spawn(to.types[i])
			if node == null:
				continue
			_entities[id] = node
		alive[id] = true
		var position: Vector2 = to.positions[i]
		var j := Snapshot.index_of(from, id)
		if j >= 0:
			position = from.positions[j].linear_interpolate(position, alpha)
		_move(node, id, position)
	for id in _entities.keys():
		if not alive.has(id):
			_despawn(_entities[id])
			_entities.erase(id)
			_last_positions.erase(id)


func _move(node: Node, key, position: Vector2) -> void:
	var last: Vector2 = _last_positions.get(key, position)
	node.global_position = position
	_last_positions[key] = position
	PuppetEntity.animate(node, position - last)


func _spawn(type_idx: int) -> Node:
	var scene = _types.get(type_idx)
	if scene == null:
		return null
	var node: Node = scene.instance()
	var container = _container_for(node)
	if container == null:
		node.free()
		return null
	container.add_child(node)
	PuppetEntity.puppetize(node)
	return node


func _container_for(node: Node) -> Node:
	if node.get_script() != null and node.get_script().resource_path.begins_with("res://items/"):
		return _main.get("_materials_container")
	return _main.get("_entities_container")


func _despawn(node) -> void:
	if is_instance_valid(node):
		node.queue_free()


func _apply_wave_timer(host_time_left: float) -> void:
	var timer = _main.get("_wave_timer")
	if timer == null or host_time_left <= 0.0:
		return
	if abs(timer.time_left - host_time_left) > WAVE_TIMER_TOLERANCE:
		timer.start(host_time_left)
