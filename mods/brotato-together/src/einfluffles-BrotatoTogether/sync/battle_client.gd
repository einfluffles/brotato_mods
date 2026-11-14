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
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const PuppetEntity := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/puppet_entity.gd"
)
const Pose := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/pose.gd")
const AnimMirror := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/anim_mirror.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:BattleClient"
const BATTLE_SCENE := "res://main.tscn"
const PF := Snapshot.PlayerField
const INTERP_DELAY_MSEC := 100
const PREDICTION_ERROR_DECAY := 12.0  # 1/s: how fast prediction corrections are smoothed out
const MAX_BUFFERED := 32
const MAX_QUEUED_EVENTS := 512
const CURSED_TAG := "cursed"  # see BattleHost._type_key
const SOUND_EXTENSIONS := ["wav", "ogg", "mp3"]
const CLOCK_CREEP_MSEC := 0.5  # per snapshot: lets the offset follow rising latency / drift
const WAVE_TIMER_TOLERANCE := 0.3
# A killing blow's damage event arrives with the snapshot that drops the enemy, which the client
# despawns a frame or two before replaying the event: keep the target findable for a moment.
const DESPAWN_GRACE_MSEC := 1000

var session: Node = null
var input_sync: Node = null
var interp_lag_msec := 0  # render time vs newest snapshot, for the F9 menu

var _battle_id := 0
var _types := {}  # idx -> PackedScene (null if rejected)
var _type_data := {}  # idx -> spawn-time data (ConsumableData) or null
var _buffer := []  # parsed snapshots, ascending t
var _clock_offset := 0.0  # local_msec - host_msec (min-filtered)
var _has_clock := false
var _main: Node = null
var _entities := {}  # net id -> node
var _last_positions := {}  # net id / "p<i>" -> Vector2
var _despawned := {}  # net id -> [node, expires msec], for late damage events
var _you := -1  # player slot this client controls (-1: spectator)
var _own_base_t := -1
var _own_error := Vector2.ZERO
var _own_display := Vector2.ZERO
var _paused := false
var _banner: CanvasLayer = null
var _events := []  # [host t, event] waiting for render time
var _pose = Pose.new()
var _anim_mirror = AnimMirror.new()


func setup(netplay_session: Node, local_input: Node) -> void:
	session = netplay_session
	input_sync = local_input
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
		Protocol.Msg.BATTLE_PAUSE:
			if typeof(body) == TYPE_DICTIONARY and body.get("battle_id") == _battle_id:
				_set_paused(bool(body.get("paused", false)))


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
	_you = int(body.get("you", -1)) if typeof(body.get("you")) == TYPE_INT else -1
	_paused = bool(body.get("paused", false))
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
	_type_data.clear()
	_buffer.clear()
	_entities.clear()
	_last_positions.clear()
	_despawned.clear()
	_has_clock = false
	_you = -1
	_paused = false
	_banner = null
	_events.clear()
	SoundRelay.set_muted(false)
	_own_base_t = -1
	_own_error = Vector2.ZERO


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
	_set_paused(_paused)
	SoundRelay.set_muted(true)  # only the host's sounds from now on
	emit_signal("battle_entered")


# Host paused: snapshots stop, so say why the world froze.
func _set_paused(paused: bool) -> void:
	_paused = paused
	if not is_in_battle():
		return
	if _banner == null or not is_instance_valid(_banner):
		_banner = CanvasLayer.new()
		_banner.layer = 100
		var label := Label.new()
		label.text = "Paused by the host"
		label.align = Label.ALIGN_CENTER
		label.valign = Label.VALIGN_CENTER
		label.anchor_right = 1.0
		label.anchor_bottom = 1.0
		_banner.add_child(label)
		_main.add_child(_banner)
	_banner.visible = paused


# Wave end, half-wave events, harvesting, ... are host decisions. Timers keep counting (the wave
# timer drives the HUD label) but no longer call into main.
func _disconnect_timer_callbacks(main: Node) -> void:
	for connection in main.get_incoming_connections():
		if connection.source is Timer and connection.signal_name == "timeout":
			connection.source.disconnect("timeout", main, connection.method_name)


# --- snapshots ---


# Type key: "<scene path>[#<data id>]" (see BattleHost._type_key).
func _define_type(idx, key) -> void:
	if typeof(idx) != TYPE_INT or typeof(key) != TYPE_STRING:
		return
	var parts: PoolStringArray = key.split("#", false, 1)
	var path: String = parts[0] if parts.size() > 0 else ""
	# Only game/mod scenes and sounds; the host is trusted but paths come from the network.
	var allowed: bool = path.ends_with(".tscn") or path.get_extension() in SOUND_EXTENSIONS
	if not path.begins_with("res://") or not allowed or ".." in path:
		_types[idx] = null
		return
	_types[idx] = load(path)
	_type_data[idx] = null
	if parts.size() > 1:
		_type_data[idx] = parts[1] if parts[1] == CURSED_TAG else _find_consumable(parts[1])


func _find_consumable(my_id: String):
	for data in ItemService.consumables:
		if data.my_id == my_id:
			return data
	return null


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
	for event in snapshot.events:
		if _events.size() < MAX_QUEUED_EVENTS:
			_events.append([snapshot.t, event])
	while _buffer.size() > MAX_BUFFERED:
		_buffer.pop_front()


func _process(delta: float) -> void:
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
	_apply_players(from, to, alpha, _buffer[-1], delta)
	_apply_entities(from, to, alpha)
	_apply_wave_timer(to.wave_time_left)
	_fire_events(render_t)


func _apply_players(
	from: Dictionary, to: Dictionary, alpha: float, newest: Dictionary, delta: float
) -> void:
	var players: Array = _main.get("_players")
	for i in min(players.size(), to.players.size()):
		var player = players[i]
		if player.dead:
			_move(player, "p%s" % i, to.players[i][PF.POSITION])
		elif i == _you and i < newest.players.size():
			_predict_own(player, i, newest, delta)
		else:
			var position: Vector2 = to.players[i][PF.POSITION]
			if i < from.players.size():
				position = from.players[i][PF.POSITION].linear_interpolate(position, alpha)
			_move(player, "p%s" % i, position)
		_apply_player_stats(player, i, newest.players[i])
		var from_weapons: PoolRealArray = (
			from.players[i][PF.WEAPONS]
			if i < from.players.size()
			else PoolRealArray()
		)
		Snapshot.apply_weapons(
			player.current_weapons, from_weapons, to.players[i][PF.WEAPONS], alpha
		)


# Own player: newest host position + replay of inputs the host hasn't applied yet, so movement
# responds immediately. Corrections (host disagrees) are blended out instead of snapping.
func _predict_own(player: Node2D, i: int, newest: Dictionary, delta: float) -> void:
	var entry: Array = newest.players[i]
	var predicted: Vector2 = entry[PF.POSITION]
	var step: float = player.get_move_speed() / float(Engine.iterations_per_second)
	for input in input_sync.history:
		if input[0] > entry[PF.INPUT_ACK]:
			predicted += input[1].normalized() * step
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	predicted.x = clamp(predicted.x, zone.position.x, zone.end.x)
	predicted.y = clamp(predicted.y, zone.position.y, zone.end.y)
	if _own_base_t < 0:
		_own_display = predicted
	elif newest.t != _own_base_t:
		_own_error = _own_display - predicted
	_own_base_t = newest.t
	_own_error *= exp(-delta * PREDICTION_ERROR_DECAY)
	_own_display = predicted + _own_error
	_move(player, "p%s" % i, _own_display)


# HUD values (the HUD listens to these signals). Level-ups only update visuals here: the game's
# own levelled_up handler would also change stats, which is the host's job.
func _apply_player_stats(player: Node, i: int, entry: Array) -> void:
	if entry[PF.HEALTH] <= 0 and not player.dead:
		PuppetEntity.player_died(player)
	if (
		player.current_stats.health != entry[PF.HEALTH]
		or player.max_stats.health != entry[PF.MAX_HEALTH]
	):
		player.current_stats.health = entry[PF.HEALTH]
		player.max_stats.health = entry[PF.MAX_HEALTH]
		player.emit_signal("health_updated", player, entry[PF.HEALTH], entry[PF.MAX_HEALTH])
	var data = RunData.players_data[i]
	if data.gold != entry[PF.GOLD]:
		data.gold = entry[PF.GOLD]
		RunData.emit_signal("gold_changed", data.gold, i)
	var levelled_up: bool = entry[PF.LEVEL] > data.current_level
	if data.current_xp != entry[PF.XP] or levelled_up:
		data.current_level = entry[PF.LEVEL]
		data.current_xp = entry[PF.XP]
		RunData.emit_signal("xp_added", data.current_xp, RunData.get_next_level_xp_needed(i), i)
	if levelled_up:
		_show_level_up(i)


func _show_level_up(i: int) -> void:
	var players_ui = _main.get("_players_ui")
	if players_ui != null and i < players_ui.size():
		players_ui[i].update_level_label()
	var containers = _main.get("_things_to_process_player_containers")
	if containers != null and i < containers.size():
		containers[i].upgrades.add_element(
			ItemService.get_icon(Keys.icon_upgrade_to_process_hash), RunData.get_player_level(i)
		)


func _apply_entities(from: Dictionary, to: Dictionary, alpha: float) -> void:
	var alive := {}
	var ids: PoolIntArray = to.ids
	for i in ids.size():
		var id := ids[i]
		var node = _entities.get(id)
		var fresh := false
		if node == null or not is_instance_valid(node):
			node = _spawn(to.types[i])
			if node == null:
				continue
			_entities[id] = node
			_forget_despawned(node)  # reused from the pool: no longer the old id's target
			fresh = true
		alive[id] = true
		var position: Vector2 = to.positions[i]
		var j := Snapshot.index_of(from, id)
		if j >= 0:
			position = from.positions[j].linear_interpolate(position, alpha)
		_move(node, id, position)
		if fresh:
			_pose.spawned(node, _main)
		_apply_flags(node, Snapshot.get_flags(to.flags, i))
		var from_pose: PoolRealArray = from.poses.get(j, PoolRealArray())
		_pose.apply(node, from_pose, to.poses.get(i, PoolRealArray()), alpha)  # also without a pose
	var now := OS.get_ticks_msec()
	for id in _entities.keys():
		if not alive.has(id):
			_despawn(_entities[id])
			_despawned[id] = [_entities[id], now + DESPAWN_GRACE_MSEC]
			_entities.erase(id)
			_last_positions.erase(id)
	for id in _despawned.keys():
		if now > _despawned[id][1]:
			_despawned.erase(id)


func _forget_despawned(node: Node) -> void:
	for id in _despawned.keys():
		if _despawned[id][0] == node:
			_despawned.erase(id)


# After _move: the host's facing wins over the one derived from interpolated motion.
func _apply_flags(node: Node, flags: int) -> void:
	if node is Unit and node.sprite != null:
		var x: float = abs(node.sprite.scale.x)
		node.sprite.scale.x = -x if flags & Snapshot.FLAG_FACING_LEFT else x
		node.sprite.flip_h = bool(flags & Snapshot.FLAG_FLIP_H)
	var hidden := bool(flags & Snapshot.FLAG_HIDDEN)
	if node.visible == hidden:
		node.visible = not hidden


func _move(node: Node, key, position: Vector2) -> void:
	var last: Vector2 = _last_positions.get(key, position)
	node.global_position = position
	_last_positions[key] = position
	if not node.get("dead"):
		PuppetEntity.animate(node, position - last)


func _spawn(type_idx: int) -> Node:
	var scene = _types.get(type_idx)
	if scene == null:
		return null
	# Units go through main's pool like in the game: they return themselves to it when their
	# death animation ends (Entity.free_entity), and are reused from it here.
	var pool_id: int = scene.get_instance_id()
	if not _main._pool.has(pool_id):
		_main._pool[pool_id] = []
	var pool: Array = _main._pool[pool_id]
	var pooled = null
	while pooled == null and not pool.empty():
		var candidate = pool.pop_back()
		if is_instance_valid(candidate):
			pooled = candidate
	var node: Node = pooled if pooled != null else scene.instance()
	var container = _container_for(node)
	if container == null:
		if node != pooled:
			node.free()
		return null
	container.add_child(node)
	if node is Entity:
		node.pool_id = pool_id
		if node == pooled:
			PuppetEntity.revive(node)
	if node is Projectile:
		PuppetEntity.start_projectile_animation(node)
	var data = _type_data.get(type_idx)
	if data != null and node is Consumable:
		node.consumable_data = data
		node.set_texture(data.icon)
	if node is Structure:
		# Pooled puppets are shared between cursed and normal variants of a scene.
		var cursed: bool = data is String and data == CURSED_TAG
		var particles = node.curse_particle_instance
		if cursed and not is_instance_valid(particles):
			node.add_curse_particles()
		elif not cursed and is_instance_valid(particles):
			particles.queue_free()
			node.curse_particle_instance = null
	PuppetEntity.puppetize(node)
	AnimMirror.detach_game_handlers(node)
	return node


func _container_for(node: Node) -> Node:
	if node is PlayerProjectile:
		return _main.get("_player_projectiles")
	if node is Projectile:
		return _main.get("_enemy_projectiles")
	if node.get_script() != null and node.get_script().resource_path.begins_with("res://items/"):
		return _main.get("_materials_container")
	return _main.get("_entities_container")


# Units play their real death animation (cleaning_up: no loot, stats or challenge side effects)
# and pool themselves afterwards; everything else just goes away.
func _despawn(node) -> void:
	if not is_instance_valid(node):
		return
	if node is Entity:
		if not node.dead:
			var args := Entity.DieArgs.new()
			args.cleaning_up = true
			args.enemy_killed_by_player = false
			node.die(args)
	else:
		node.queue_free()


# One-shot feedback fires when its snapshot's time is rendered, so a damage number appears
# together with the hit it belongs to.
func _fire_events(render_t: float) -> void:
	while not _events.empty() and _events[0][0] <= render_t:
		var event = _events.pop_front()[1]
		if typeof(event) != TYPE_ARRAY or event.empty() or typeof(event[0]) != TYPE_INT:
			continue
		if event[0] == Snapshot.EVENT_DAMAGE and event.size() == 6:
			_show_damage(event)
		elif event[0] == Snapshot.EVENT_SOUND and event.size() == 5:
			var sound = _types.get(event[1])
			if sound is AudioStream and (event[2] == null or typeof(event[2]) == TYPE_VECTOR2):
				SoundRelay.replay(sound, event[2], float(event[3]), float(event[4]))
		elif event[0] == Snapshot.EVENT_ANIM:
			_anim_mirror.replay(_entities, event)


# Same handlers main.gd connects to Unit.took_damage (numbers, particles) + the hit flash.
func _show_damage(event: Array) -> void:
	var target = _damage_target(event[1])
	if target == null or typeof(event[3]) != TYPE_VECTOR2:
		return
	var flags := int(event[4])
	var args := [
		target,
		int(event[2]),
		event[3],
		bool(flags & Snapshot.DAMAGE_CRIT),
		bool(flags & Snapshot.DAMAGE_DODGE),
		bool(flags & Snapshot.DAMAGE_PROTECTED),
		bool(flags & Snapshot.DAMAGE_ARMOR),
		TakeDamageArgs.new(RunData.DUMMY_PLAYER_INDEX),  # no hitbox: feedback at the unit
		int(event[5]),
		bool(flags & Snapshot.DAMAGE_ONE_SHOT),
	]
	for manager_name in ["_floating_text_manager", "_effects_manager"]:
		var manager = _main.get(manager_name)
		if manager != null:
			manager.callv("_on_unit_took_damage", args)
	if int(event[2]) > 0 and target.has_method("flash") and not target.dead:
		target.flash()


func _damage_target(id):
	if typeof(id) != TYPE_INT:
		return null
	if id < 0:
		var players: Array = _main.get("_players")
		var index: int = -id - 1
		return players[index] if index < players.size() else null
	var node = _entities.get(id)
	if node == null and _despawned.has(id):
		node = _despawned[id][0]
	return node if node != null and is_instance_valid(node) else null


func _apply_wave_timer(host_time_left: float) -> void:
	var timer = _main.get("_wave_timer")
	if timer == null or host_time_left <= 0.0:
		return
	if abs(timer.time_left - host_time_left) > WAVE_TIMER_TOLERANCE:
		timer.start(host_time_left)
