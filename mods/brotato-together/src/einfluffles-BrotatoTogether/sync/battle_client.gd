extends Node
# Client: mirror the host's battle.
# BATTLE_START -> apply its run state (in parts: sync/battle_run.gd), load main.tscn in puppet
# mode (simulation frozen right after main._ready, before its first physics frame). SNAPSHOTs
# are buffered and rendered INTERP_DELAY_MSEC in the past, interpolating between the two
# snapshots around render time: smooth motion at any fps, independent of the 30 Hz network rate.

signal battle_entered
signal battle_left

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const BattleRun := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/battle_run.gd")
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
const PauseControl := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/pause_control.gd"
)
const FeedbackMirror := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/feedback_mirror.gd"
)
const Looks := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/looks.gd")
const Facing := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/facing.gd")
const Puddles := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/puddles.gd")
const BattleScene := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/battle_scene.gd")
const StateStream := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd")
const RenderDelay := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/render_delay.gd")
const StreamGaps := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/stream_gaps.gd")
const ClientReport := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/client_report.gd"
)
const LOG_NAME := "einfluffles-BrotatoTogether:BattleClient"
const BATTLE_SCENE := "res://main.tscn"
const PF := Snapshot.PlayerField
const INTERP_DELAY_MSEC := 100  # longer through a stall: sync/render_delay.gd
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
# Own-player prediction only while the host's world moves: not while paused, not after the wave's
# end, not when the newest snapshot is older than this (stall), and never more than
# MAX_REPLAY_INPUTS (0.75 s) ahead.
# Network stalls of 300 to 500 ms (seen every 20 to 50 s on some connections) are ridden out: at
# 250 ms the player snapped back to the host's last position and jumped ahead again when the
# snapshots came. Inputs still reach the host during a stall of the snapshots alone, so the
# prediction is right; past 600 ms the connection is gone rather than late, and the player stays
# with the frozen world (the same limit as the host's INPUT timeout, Protocol.STALL_LIMIT_MSEC).
# The replay covers that stall plus the round trip (on a good connection the host acks within a
# few inputs, so the cap changes nothing there); it is above the host's catch-up backlog
# (InputSync.MAX_BACKLOG), so whatever the host still catches up on is in the replay.
const PREDICTION_STALE_MSEC := Protocol.STALL_LIMIT_MSEC
const MAX_REPLAY_INPUTS := 45
# Faster than anything moves: a pooled node reused for a new entity under an old id; snap.
const MAX_INTERP_SPEED := 6000.0  # px/s
const MAX_POOLED_PER_TYPE := 128  # non-Entity puppets (projectiles, gold, consumables)
const BRACHIOSAURUS_FOOT := (
	"res://entities/units/enemies/jungle/bosses/brachiosaurus/"
	+ "brachiosaurus_foot/brachiosaurus_foot.tscn"
)
const BOSS_PARTS := {BRACHIOSAURUS_FOOT: "Brachiosaurus"}  # scene -> boss node its _ready finds
const PUPPET_TYPE_META := "brotato_together_puppet_type"
# After a stall the queued sounds and damage numbers of that time would all fire in one frame.
const STALE_EVENT_MSEC := 250
const KIND_UNIT := 1  # its sprite's facing and flip_h come with the flags
const KIND_PROJECTILE := 2  # faces its motion
const KIND_BIRTH := 4  # a spawn marker: started when it appears
const KIND_ANIMATED := 8  # has an update_animation of its own (pets)
const KIND_POSE := 16  # its scene has parts sync/pose.gd moves
const LOADING_TIMEOUT_MSEC := 10000  # a scene that never got ready must not block the next

var session: Node = null
var state_stream: Node = null  # sync/state_stream.gd (set by mod_main.gd)
var input_sync: Node = null
var run_store = null  # RunParts.Store, shared with ShopSync and UpgradesSync (set by mod_main.gd)
var interp_lag_msec := 0  # render time vs newest snapshot, for the lobby page

var _battle_id := 0
var _types := {}  # idx -> PackedScene (null if rejected)
var _type_data := {}  # idx -> spawn-time data (ConsumableData) or null
var _buffer := []  # parsed snapshots, ascending t
var _clock_offset := 0.0  # local_msec - host_msec (min-filtered)
var _has_clock := false
var _main: Node = null
var _main_id := 0  # its instance id: tells this battle's scene from a later one when it exits
var _loading := false  # change_scene called, the scene not ready yet
var _loading_msec := 0
var _queued_start := {}  # BATTLE_START of another battle that arrived while loading
var _entities := {}  # net id -> node
var _entity_types := {}  # net id -> type idx of its node
var _entity_kinds := {}  # net id -> KIND_* bits of its node
var _applied_to := {}  # the snapshot _apply_entities ran for last
var _no_pose := PoolRealArray()
var _resolve_cache := {}  # see Snapshot.resolve
var _newest_rx_msec := 0  # local time the newest snapshot (by host time) arrived
var _puppet_pool := {}  # type idx -> pooled non-Entity puppets (out of the tree)
var _last_positions := {}  # net id / "p<i>" -> Vector2
var _despawned := {}  # net id -> [node, expires msec], for late damage events
var _you := -1  # player slot this client controls (-1: spectator)
var _own_base_t := -1
var _own_error := Vector2.ZERO
var _own_display := Vector2.ZERO
var _own_seq := 0  # newest own input the displayed position includes
var _motion_result := Physics2DTestMotionResult.new()  # reused by BattleScene.step
var _paused := false
var _wave_over := false  # the host's wave ended: its players stand (_note_wave_end)
var _pause_text := ""
var _events := []  # [host t, event] waiting for render time
var _pose = Pose.new()
var _anim_mirror = AnimMirror.new()
var _feedback = FeedbackMirror.new()  # explosions, texts, shake, wave end (protocol 11)
var _looks = Looks.new()
var _battle_scene = BattleScene.new()  # hole layout, weapon slots of the puppets
var _render_delay = RenderDelay.new(INTERP_DELAY_MSEC)
var _snapshot_gaps = StreamGaps.new("snapshot")  # stalls of the host's snapshots, for the log


func setup(netplay_session: Node, local_input: Node) -> void:
	session = netplay_session
	input_sync = local_input
	session.connect("message", self, "_on_message")
	session.transport.connect("lobby_left", self, "_on_lobby_left")
	# Pending up to 30 s: a (re)joining peer gets it right after its BATTLE_START, while the scene
	# loads (and copes with it arriving first all the same).
	state_stream.register_handler(StateStream.PAUSE_BATTLE, self, 30.0)
	# Sections waiting for the puppet battle (pause, retry prompt) apply the frame it is ready.
	if not is_connected("battle_entered", state_stream, "retry"):
		connect("battle_entered", state_stream, "retry")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func is_in_battle() -> bool:
	return _main != null and is_instance_valid(_main)


func _on_message(steam_id: int, msg_type: int, body) -> void:
	if not session.is_client() or steam_id != session.transport.host_id:
		return
	match msg_type:
		Protocol.Msg.BATTLE_START:
			if BattleRun.take(run_store, body):  # as it arrives, also when adopted or queued
				_on_battle_start(body)
		Protocol.Msg.BATTLE_END:
			if typeof(body) != TYPE_DICTIONARY:
				return
			if body.get("battle_id") == _battle_id:
				_leave_battle()
			elif body.get("battle_id") == _queued_start.get("battle_id"):
				_queued_start = {}  # over before its scene could load
		Protocol.Msg.TYPE_DEF:
			if typeof(body) == TYPE_DICTIONARY and body.get("battle_id") == _battle_id:
				_define_type(body.get("idx"), body.get("path"))
		Protocol.Msg.SNAPSHOT:
			_on_snapshot(Snapshot.parse(body))


# Section pause_battle (BattleHost.state_body): the host's battle is paused. Pending until the
# puppet battle of that battle_id is ready (a peer joining a paused battle gets it before its
# BATTLE_START); a pause of an earlier battle is dropped.
func apply_state(_section: int, body, _revision: int) -> bool:
	if typeof(body) != TYPE_DICTIONARY or typeof(body.get("battle_id")) != TYPE_INT:
		return true
	if body.battle_id < _battle_id:
		return true
	if body.battle_id != _battle_id or not is_in_battle():
		return false
	var by = body.get("by")
	var by_id = body.get("by_id")
	_pause_text = PauseControl.banner_text(
		by if typeof(by) == TYPE_STRING else "",
		by_id if typeof(by_id) == TYPE_INT else 0,
		session.transport.local_id
	)
	_set_paused(true)
	return true


# Resumed (or the battle is over: _leave_battle resets the pause anyway).
func clear_state(_section: int) -> void:
	_snapshot_gaps.reset()  # the pause was no stall
	_pause_text = ""
	_set_paused(false)


# --- battle lifecycle ---


func _on_battle_start(body) -> void:
	if typeof(body) != TYPE_DICTIONARY or typeof(body.get("battle_id")) != TYPE_INT:
		return
	# A resync of the battle this client is in or is loading: keep the scene.
	var loading := _loading and OS.get_ticks_msec() - _loading_msec < LOADING_TIMEOUT_MSEC
	if body.battle_id == _battle_id and (loading or is_in_battle()):
		_adopt_start(body)
		return
	# Two scene changes in one frame would leave the second one unhooked (a real local battle).
	if loading:
		_queued_start = body
		return
	var state := BattleRun.state(run_store, body)
	if state.empty():
		ModLoaderLog.error("Invalid run state in BATTLE_START", LOG_NAME)
		return
	if _main_id != 0:
		_leave_battle()  # replaced without a BATTLE_END: the others drop its scene's nodes too
	else:
		_reset_battle_state()
	_battle_id = body.battle_id
	_adopt_start(body)
	_battle_scene.client_start(body)  # for the scene this start loads, not for a resync

	CoopService.bt_apply_remote_colors(body.get("colors"))
	Puppet.set_active(true)
	BattleRun.apply(state)
	VirtualDevices.fill_puppet_slots(RunData.get_player_count())
	get_tree().paused = false
	# Only until the battle scene is ready: no node_added handler for every node otherwise.
	if not get_tree().is_connected("node_added", self, "_on_node_added"):
		get_tree().connect("node_added", self, "_on_node_added")
	_loading = true
	_loading_msec = OS.get_ticks_msec()
	if get_tree().change_scene(BATTLE_SCENE) != OK:
		_loading = false
		_stop_watching_scenes()
		ModLoaderLog.error("Could not load the battle scene", LOG_NAME)
	ModLoaderLog.info("Entering battle %s (wave %s)" % [_battle_id, RunData.current_wave], LOG_NAME)


# What a BATTLE_START says besides the run: this client's slot, the type table. The pause comes
# with section pause_battle (apply_state).
func _adopt_start(body: Dictionary) -> void:
	_you = int(body.get("you", -1)) if typeof(body.get("you")) == TYPE_INT else -1
	var types = body.get("types")
	if typeof(types) == TYPE_DICTIONARY:
		for idx in types:
			if not _types.has(idx):
				_define_type(idx, types[idx])


# The wave is over here too: its puppets, buffers and tables go, whatever screen comes next.
func _leave_battle() -> void:
	_reset_battle_state()
	# main.on_wave_start set these; only the host's flow would clear them (the shop's stats
	# read the flag, the timer is freed with the scene).
	RunData.wave_in_progress = false
	RunData.wave_timer = null
	emit_signal("battle_left")


func _on_lobby_left() -> void:
	_reset_battle_state()
	if session.transport.was_host:
		return  # the host's own run (and its co-op slots) goes on: see InputSync._on_lobby_left
	Puppet.set_active(false)  # restores the client's own saved run (session/puppet.gd)
	CoopService.clear_coop_players()  # the puppet slots


func _reset_battle_state() -> void:
	_main = null
	_main_id = 0
	_queued_start = {}
	_battle_id = 0
	_types.clear()
	_type_data.clear()
	_buffer.clear()
	_entities.clear()
	_entity_types.clear()
	_entity_kinds.clear()
	_applied_to = {}
	_resolve_cache = {}
	_looks = Looks.new()
	_newest_rx_msec = 0
	_free_puppet_pool()
	if not _loading:  # a scene still loading must be frozen when it is ready, battle or not
		_stop_watching_scenes()
	_last_positions.clear()
	_despawned.clear()
	_has_clock = false
	_you = -1
	_paused = false
	_wave_over = false
	_pause_text = ""
	if input_sync != null:
		input_sync.set_host_paused("battle", false)
	_events.clear()
	_feedback = FeedbackMirror.new()
	SoundRelay.set_muted(false)
	_own_base_t = -1
	_own_error = Vector2.ZERO
	_battle_scene = BattleScene.new()
	_render_delay = RenderDelay.new(INTERP_DELAY_MSEC)
	_snapshot_gaps.reset()


func _on_node_added(node: Node) -> void:
	if node.filename == BATTLE_SCENE:
		node.connect("ready", self, "_on_battle_scene_ready", [node], CONNECT_ONESHOT)


func _stop_watching_scenes() -> void:
	if get_tree().is_connected("node_added", self, "_on_node_added"):
		get_tree().disconnect("node_added", self, "_on_node_added")


# Runs right after main._ready(), before the first physics frame.
func _on_battle_scene_ready(main: Node) -> void:
	_stop_watching_scenes()
	_loading = false
	var started := OS.get_ticks_usec()
	_freeze(main)
	ClientReport.mark(ClientReport.Mark.PUPPET_SETUP, OS.get_ticks_usec() - started)
	# No battle: it ended while its scene loaded. Frozen until the next screen replaces it.
	if _battle_id != 0:
		_battle_scene.client_scene_ready(main)
		_main = main
		_main_id = main.get_instance_id()
		# The next screen can replace the scene without a BATTLE_END (the shop was faster).
		main.connect("tree_exited", self, "_on_battle_scene_exited", [_main_id], CONNECT_ONESHOT)
		_set_paused(_paused)
		SoundRelay.set_muted(true)  # only the host's sounds from now on
		emit_signal("battle_entered")
	if not _queued_start.empty():
		var next := _queued_start
		_queued_start = {}
		call_deferred("_on_battle_start", next)


func _on_battle_scene_exited(main_id: int) -> void:
	if main_id == _main_id:
		_leave_battle()


func _freeze(main: Node) -> void:
	# Local pause/aim handling off (PauseControl opens the menu for this client's own pause).
	# main._physics_process stays on: it only recolors life bars. Focus loss / pad disconnect
	# would open the local pause menu.
	main.set_process(false)
	PauseControl.disable_local_pause(main)
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
		player.collision_mask = BattleScene.OBSTACLES  # no layer: nothing runs into a puppet
	# On a bullet-hell wave main._ready adds its own generator (a random pattern); the host's
	# bullets arrive as puppets.
	var enemy_projectiles = main.get("_enemy_projectiles")
	if enemy_projectiles != null:
		for child in enemy_projectiles.get_children():
			if child is BulletHell:
				child.free()


# Host paused: snapshots stop, so say why the world froze.
func _set_paused(paused: bool) -> void:
	_paused = paused
	if input_sync != null:
		input_sync.set_host_paused("battle", paused and is_in_battle())
	if not is_in_battle():
		return
	var text := _pause_text if _pause_text != "" else "Paused by the host"
	PauseControl.show_banner(_main, paused, text)


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
	if parts.size() > 1 and Puddles.is_tag(parts[1]):
		_type_data[idx] = Puddles.parse_tag(parts[1])
	elif parts.size() > 1:
		var tag: String = parts[1]
		var plain: bool = tag == CURSED_TAG or PuppetEntity.BIRTH_TAGS.has(tag)
		_type_data[idx] = tag if plain else _find_consumable(tag)


func _find_consumable(my_id: String):
	for data in ItemService.consumables:
		if data.my_id == my_id:
			return data
	# DLC drops (poisoned / meca / mutant / mutation fruit, meca parts) aren't in that list (not
	# even for owners): they are DLCData properties, which every copy of the game has.
	for update in ItemService.update_data_list:
		var dlc_data = update.dlc_data if update != null else null
		if dlc_data == null:
			continue
		for property in dlc_data.get_property_list():
			if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				var value = dlc_data.get(property.name)
				if value is ConsumableData and value.my_id == my_id:
					return value
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
	if i == _buffer.size():
		_newest_rx_msec = OS.get_ticks_msec()
		var host_id: int = session.transport.host_id
		_snapshot_gaps.note(session, host_id, snapshot.t, LOG_NAME, _render_delay.text(), _paused)
	Looks.resolve(snapshot, _resolve_cache)  # first: it reads the entity indices as parsed
	Snapshot.resolve(snapshot, _resolve_cache)
	Facing.resolve(snapshot, _resolve_cache)
	_buffer.insert(i, snapshot)
	for event in snapshot.events:
		if _events.size() < MAX_QUEUED_EVENTS:
			_events.append([snapshot.t, event])
	_note_wave_end(snapshot.events)
	while _buffer.size() > MAX_BUFFERED:
		_buffer.pop_front()


func _process(delta: float) -> void:
	if not is_in_battle() or _buffer.empty():
		return
	var started := OS.get_ticks_usec()
	var render_t: float = _render_delay.render_time(
		OS.get_ticks_msec(), _clock_offset, _buffer[-1].t, delta
	)
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
	ClientReport.mirror_cost(OS.get_ticks_usec() - started, _entities.size())


func _apply_players(
	from: Dictionary, to: Dictionary, alpha: float, newest: Dictionary, delta: float
) -> void:
	var players: Array = _main.get("_players")
	for i in min(players.size(), to.players.size()):
		var player = players[i]
		BattleScene.apply_speed(player, newest.players[i])  # before the prediction reads it
		_battle_scene.follow_weapons(player, i, to.players[i])  # before weapons apply by index
		if Snapshot.is_dead(newest.players[i]) and not player.dead:
			PuppetEntity.player_died(player)
		if player.dead:
			_move(player, "p%s" % i, to.players[i][PF.POSITION])
		elif i == _you and i < newest.players.size():
			_predict_own(player, i, newest, delta)
		else:
			var position: Vector2 = to.players[i][PF.POSITION]
			if i < from.players.size():
				position = from.players[i][PF.POSITION].linear_interpolate(position, alpha)
			_move(player, "p%s" % i, position)
		if Snapshot.has_stats(newest.players[i]):  # unknown until the host's first stats arrive
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
# responds immediately. Corrections (host disagrees) are blended out instead of snapping. The steps
# of the inputs sent since the last frame are the player's own motion, not a correction: counted as
# one, they pulled the display back by the newest step on every snapshot (a lag of a few steps
# while running, and a glide after the stop).
func _predict_own(player: Node2D, i: int, newest: Dictionary, delta: float) -> void:
	var predicted := _own_target(player, newest.players[i])
	var history: Array = input_sync.history
	if _own_base_t < 0:
		_own_display = predicted
	elif newest.t != _own_base_t:
		# Clamped and blocked like the target: holding into an edge or a hole is no correction.
		var moved := _in_zone(_walk_since(player, _own_display, _own_seq))
		_own_error = moved - predicted
		var ack: int = newest.players[i][PF.INPUT_ACK]
		var late: float = OS.get_ticks_msec() - _clock_offset - newest.t
		ClientReport.note_correction(
			_own_error.length(), late, ClientReport.unacked(history, ack), player.get_move_speed()
		)
	_own_base_t = newest.t
	_own_seq = history[-1][0] if not history.empty() else 0
	_own_error *= exp(-delta * PREDICTION_ERROR_DECAY)
	_own_display = predicted + _own_error
	_move(player, "p%s" % i, _own_display)


# Where the own player gets from `from` with the inputs after seq, from history[first] on (nowhere
# unless predicting).
func _walk_since(player: Node2D, from: Vector2, seq: int, first := 0) -> Vector2:
	if not _predicting():
		return from
	var step: float = player.get_move_speed() / float(Engine.iterations_per_second)
	var history: Array = input_sync.history
	for k in range(first, history.size()):
		if history[k][0] > seq:
			from = BattleScene.step(player, from, history[k][1].normalized() * step, _motion_result)
	return from


# The host's world moves: not paused, the wave not over, and the newest snapshot is fresh.
func _predicting() -> bool:
	var fresh: bool = OS.get_ticks_msec() - _newest_rx_msec <= PREDICTION_STALE_MSEC
	return not _paused and not _wave_over and fresh


# A snapshot's events say the host's wave is over (EVENT_WAVE_END, repeated state): the frame that
# set main._cleaning_up also stopped its players (main.clean_up_room -> Player.on_room_cleanup:
# _can_move false), and they stand until the shop or the level-ups replace the battle. So the own
# player is no longer predicted either: it ran ahead on every held input and every snapshot pulled
# it back. Taken on arrival, not at render time like the label (FeedbackMirror), and for the rest
# of this battle (the next one starts with a fresh battle state).
func _note_wave_end(events: Array) -> void:
	for event in events:
		if typeof(event) == TYPE_ARRAY and not event.empty() and typeof(event[0]) == TYPE_INT:
			_wave_over = _wave_over or event[0] == Snapshot.EVENT_WAVE_END


# Host position + the last MAX_REPLAY_INPUTS un-acked inputs; just the host position while the
# host's world or its players stand still (paused, the wave over, or no fresh snapshots): else the
# client would walk through a frozen world and glide back.
func _own_target(player: Node2D, entry: Array) -> Vector2:
	if not _predicting():
		return entry[PF.POSITION]
	var first: int = max(0, input_sync.history.size() - MAX_REPLAY_INPUTS)
	return _in_zone(_walk_since(player, entry[PF.POSITION], entry[PF.INPUT_ACK], first))


static func _in_zone(position: Vector2) -> Vector2:
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	position.x = clamp(position.x, zone.position.x, zone.end.x)
	position.y = clamp(position.y, zone.position.y, zone.end.y)
	return position


# HUD values (the HUD listens to these signals). Level-ups only update visuals here: the game's
# own levelled_up handler would also change stats, which is the host's job.
func _apply_player_stats(player: Node, i: int, entry: Array) -> void:
	_feedback.player_stats(_main, i, entry)  # heal and level-up texts
	BattleScene.apply_hit_protection(_main, i, player, entry)
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


# Every rendered frame, for every mirrored entity: nothing here asks a node what it is (see
# _kind_of), and a node that did not move is not moved.
func _apply_entities(from: Dictionary, to: Dictionary, alpha: float) -> void:
	var new_to: bool = not to == _applied_to  # the set of entities only changes with it
	_applied_to = to
	var ids: PoolIntArray = to.ids
	var types: PoolIntArray = to.types
	var positions: PoolVector2Array = to.positions
	var flags: PoolByteArray = to.flags
	var poses: Dictionary = to.poses
	var from_positions: PoolVector2Array = from.positions
	var from_poses: Dictionary = from.poses
	var angles: Dictionary = to.get("angles_by_id", {})
	var from_angles: Dictionary = from.get("angles_by_id", {})
	Snapshot.index_of(from, 0)  # builds the index
	var from_index: Dictionary = from.index
	var max_jump: float = MAX_INTERP_SPEED * max(to.t - from.t, 1) / 1000.0
	for i in ids.size():
		var id := ids[i]
		var node = _entities.get(id)
		var placed := true
		var fresh := false
		if new_to and node != null and _entity_types.get(id) != types[i]:
			_despawn(node)  # the host reused the id for another kind of entity
			node = null
		if node == null or not is_instance_valid(node):
			node = _spawn(types[i])
			if node == null:
				continue
			_entities[id] = node
			_entity_types[id] = types[i]
			_entity_kinds[id] = _kind_of(node)
			_last_positions.erase(id)
			_forget_despawned(node)  # reused from the pool: no longer the old id's target
			placed = false
			fresh = true
		var kind: int = _entity_kinds[id]
		var position := positions[i]
		var j: int = from_index.get(id, -1)
		# A projectile's rotation is the host's (sync/facing.gd); a spinning one turns between
		# the two snapshots.
		var facing = angles.get(id) if kind & KIND_PROJECTILE else null
		if facing != null:
			var before = from_angles.get(id)
			if before != null and before != facing:
				facing = lerp_angle(before, facing, alpha)
			if node.rotation != facing:
				node.rotation = facing
		if j >= 0:
			var start := from_positions[j]
			if start != position:
				if start.distance_to(position) <= max_jump:
					# Until its angle arrives it faces where it flies (not a laser: its aim
					# is a pose value).
					if kind & KIND_PROJECTILE and facing == null and not kind & KIND_POSE:
						var angle: float = (position - start).angle()
						if node.rotation != angle:
							node.rotation = angle
					position = start.linear_interpolate(position, alpha)
				else:
					# Teleport: no motion, no lerp across the map. A spawn marker the host
					# moved counts down again.
					_last_positions.erase(id)
					placed = false
		var last: Vector2 = _last_positions.get(id, position)
		if not placed or position != last:
			node.global_position = position
			_last_positions[id] = position
			if not placed and kind & KIND_BIRTH:
				PuppetEntity.start_birth(node, str(_type_data.get(types[i])))
			if fresh:
				_pose.spawned(node, _main)
		if kind & KIND_ANIMATED and not node.dead:
			node.update_animation(position - last)
		# The host's facing: behaviors turn units toward their target, not their motion.
		var bit: int = i * Snapshot.FLAG_BITS
		var node_flags: int = flags[bit >> 3] >> (bit & 7)
		if kind & KIND_UNIT:
			var sprite = node.sprite
			if (sprite.scale.x < 0) != bool(node_flags & Snapshot.FLAG_FACING_LEFT):
				sprite.scale.x = -sprite.scale.x
			if sprite.flip_h != bool(node_flags & Snapshot.FLAG_FLIP_H):
				sprite.flip_h = not sprite.flip_h
		# A projectile seen once without its angle has no direction yet: it would sit there for
		# a snapshot with the rotation of the pooled puppet's last flight.
		var unaimed: bool = kind & KIND_PROJECTILE and j < 0 and facing == null
		var hidden: bool = node_flags & Snapshot.FLAG_HIDDEN or unaimed
		if node.visible == hidden:
			node.visible = not hidden
		if kind & KIND_POSE:  # also without values: the host's parts are gone then
			_pose.apply(node, from_poses.get(j, _no_pose), poses.get(i, _no_pose), alpha)
	if not new_to:
		return
	var alive := {}
	for id in ids:
		alive[id] = true
	var now := OS.get_ticks_msec()
	for id in _entities.keys():
		if not alive.has(id):
			FeedbackMirror.gold_gone(_main, _entities[id])  # picked up: its sparkle
			_despawn(_entities[id])
			_despawned[id] = [_entities[id], now + DESPAWN_GRACE_MSEC]
			_entities.erase(id)
			_entity_types.erase(id)
			_entity_kinds.erase(id)
			_last_positions.erase(id)
	for id in _despawned.keys():
		if now > _despawned[id][1]:
			_despawned.erase(id)
	_looks.apply(_entities, to.get("looks_by_id", {}))


# What a puppet needs every frame, decided once when it spawns.
func _kind_of(node: Node) -> int:
	var kind := 0
	if node is Unit and node.sprite != null:
		kind |= KIND_UNIT
	if node is Projectile:
		kind |= KIND_PROJECTILE
	elif node is EntityBirth:
		kind |= KIND_BIRTH
	elif node.has_method("update_animation"):
		# Unit.update_animation only faces the motion, which the host's flags decide; pets
		# switch their animations in it.
		if not (node is Enemy or node is Neutral or node is Structure):
			kind |= KIND_ANIMATED
	var layout: Dictionary = _pose.layout(node)
	if not layout.parts.empty() or not layout.group_parts.empty():
		kind |= KIND_POSE
	return kind


func _forget_despawned(node: Node) -> void:
	for id in _despawned.keys():
		if _despawned[id][0] == node:
			_despawned.erase(id)


func _move(node: Node, key, position: Vector2) -> void:
	var last: Vector2 = _last_positions.get(key, position)
	node.global_position = position
	_last_positions[key] = position
	if not node.get("dead"):
		var motion: Vector2 = _own_motion() if key == "p%s" % _you else position - last
		PuppetEntity.animate(node, motion)


# The own player runs while its keys are held (the move it sends, also zero while the lobby popup
# or its Esc menu has the input), not while a correction still blends out of the displayed
# position (_predict_own): that never quite stops and kept it running for about a second. Facing
# follows the held keys too, as on the host. Nothing runs while the host's world stands still,
# where _own_target predicts nothing either.
func _own_motion() -> Vector2:
	var history: Array = input_sync.history if input_sync != null else []
	if history.empty() or not _predicting():
		return Vector2.ZERO
	return history[-1][1]


func _spawn(type_idx: int) -> Node:
	var scene = _types.get(type_idx)
	if not scene is PackedScene or not _boss_present(scene):
		return null
	# Units go through main's pool like in the game: they return themselves to it when their
	# death animation ends (Entity.free_entity), and are reused from it here. Other puppets
	# (projectiles, gold, consumables) use the client's own pool per type (_despawn).
	var pool_id: int = scene.get_instance_id()
	if not _main._pool.has(pool_id):
		_main._pool[pool_id] = []
	var pooled = _pop_valid(_main._pool[pool_id])
	if pooled == null:
		pooled = _pop_valid(_puppet_pool.get(type_idx, []))
	var node: Node = pooled if pooled != null else scene.instance()
	var container = _container_for(node)
	if container == null:
		if node != pooled:
			node.free()
		return null
	if not node is Entity:
		node.set_meta(PUPPET_TYPE_META, type_idx)
	container.add_child(node)
	if node is Entity:
		node.pool_id = pool_id
		if node == pooled:
			PuppetEntity.revive(node)
	if node is Projectile:
		_anim_mirror.strip_projectile(node)  # its own pool logic must not run here
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
	if Puddles.is_puddle(node):
		Puddles.start(node, data)
	if not node is Hole:  # its body is what the own player's prediction runs into
		PuppetEntity.puppetize(node)
	AnimMirror.detach_game_handlers(node)
	return node


static func _pop_valid(pool: Array):
	while not pool.empty():
		var candidate = pool.pop_back()
		if is_instance_valid(candidate):
			return candidate
	return null


# Boss parts find their boss in _ready (BrachiosaurusFoot: find_node("Brachiosaurus"), then calls
# into it): wait for the boss puppet (snapshots list bosses first; its type may arrive later).
func _boss_present(scene: PackedScene) -> bool:
	var boss_name = BOSS_PARTS.get(scene.resource_path)
	return boss_name == null or _main.find_node(boss_name, true, false) != null


func _container_for(node: Node) -> Node:
	if node is PlayerProjectile:
		return _main.get("_player_projectiles")
	if node is Projectile:
		return _main.get("_enemy_projectiles")
	if node is EntityBirth:
		return _main.get("_births_container")
	if Puddles.is_puddle(node):
		return Puddles.container(_main, node)
	if node is Hole:
		return _main.get("_gpe_container")
	if node.get_script() != null and node.get_script().resource_path.begins_with("res://items/"):
		return _main.get("_materials_container")
	return _main.get("_entities_container")


# Units play their real death animation (cleaning_up: no loot, stats or challenge side effects)
# and pool themselves afterwards; everything else goes to the client's pool for its type.
func _despawn(node) -> void:
	if not is_instance_valid(node):
		return
	if node is Entity:
		if not node.dead:
			var args := Entity.DieArgs.new()
			args.cleaning_up = true
			args.enemy_killed_by_player = false
			node.die(args)
		return
	if Puddles.is_puddle(node) and not node._is_dying:
		var fade := Puddles.fade_out(node)
		var timer := get_tree().create_timer(fade, false)
		timer.connect("timeout", self, "_on_puddle_faded", [node, _battle_id])
		return
	_pool_puppet(node)


# The fade ran on (the puddle's own despawn timer is paused on a puppet); a puppet of a battle
# that is over goes with its scene, never into the next battle's pool.
func _on_puddle_faded(node, battle_id: int) -> void:
	if not is_instance_valid(node):
		return
	if battle_id != _battle_id:
		node.queue_free()
		return
	_pool_puppet(node)


func _pool_puppet(node: Node) -> void:
	var type_idx = node.get_meta(PUPPET_TYPE_META) if node.has_meta(PUPPET_TYPE_META) else null
	var pool: Array = _puppet_pool.get(type_idx, [])
	if type_idx == null or pool.size() >= MAX_POOLED_PER_TYPE or node.get_parent() == null:
		node.queue_free()
		return
	node.get_parent().remove_child(node)
	pool.append(node)
	_puppet_pool[type_idx] = pool


# Pooled puppets are out of the tree: the scene change wouldn't free them.
func _free_puppet_pool() -> void:
	for pool in _puppet_pool.values():
		for node in pool:
			if is_instance_valid(node):
				node.free()
	_puppet_pool.clear()


# One-shot feedback fires when its snapshot's time is rendered, so a damage number appears
# together with the hit it belongs to.
func _fire_events(render_t: float) -> void:
	while not _events.empty() and _events[0][0] <= render_t:
		var entry: Array = _events.pop_front()
		var event = entry[1]
		if typeof(event) != TYPE_ARRAY or event.empty() or typeof(event[0]) != TYPE_INT:
			continue
		# Animations, bonus gold and the wave's end are state and still count.
		if entry[0] < render_t - STALE_EVENT_MSEC and not Snapshot.is_state_event(event[0]):
			continue
		if event[0] == Snapshot.EVENT_DAMAGE and event.size() == 6:
			_show_damage(event)
		elif event[0] == Snapshot.EVENT_SOUND and event.size() == 7:
			var sound = _types.get(event[1])
			if sound is AudioStream and (event[2] == null or typeof(event[2]) == TYPE_VECTOR2):
				SoundRelay.replay(sound, event[2], event[3], event[4], event[5], event[6])
		elif event[0] == Snapshot.EVENT_ANIM:
			_anim_mirror.replay(_entities, event)
		else:
			_feedback.fire(_main, _types, entry[0], event)


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
	FeedbackMirror.shake(_main, target, args)
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
