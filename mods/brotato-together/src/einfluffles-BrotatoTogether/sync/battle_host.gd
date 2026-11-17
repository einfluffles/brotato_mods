extends Node
# Host: while the battle scene (main.tscn) runs, mirror it to clients.
# - BATTLE_START (reliable) with the run state + entity type table, also for late joiners. The run
#   travels in parts, each client gets only those it lacks (sync/run_parts.gd: the record of
#   what each peer was sent, shared with ShopSync and UpgradesSync; protocol 25). It is the run
#   as the battle scene entered the tree (_on_node_added), before main._ready started the wave:
#   that sets every player's health to its start value (a player part), and the client's own
#   main._ready does the same to the run it gets. After a shop state a start so carries only
#   what Go changed: the wave (the common part "c"), a player's parts only when Go took one of
#   its items (hourglass, lifeform scanner). A peer that becomes ready mid-wave gets the run as
#   it is then, every part (_on_peer_ready). The sends of one start are logged in one line
#   ("Battle 3 start: 2 states, 2 with run parts (1.6 KB: c 2), ...", RunParts.Sender.close).
# - SNAPSHOT (unreliable) at SNAPSHOT_HZ with players, entities and wave time
# - BATTLE_END (reliable) when the battle scene goes away
# - section pause_battle of the state stream while the battle is paused (state_key)

# What is known about a mirrored node once it has its net id (see _record): looked up per
# snapshot instead of asking the node again.
enum Rec { ID, TYPE, KIND, NODE, X, Y, STILL }

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Pose := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/pose.gd")
const AnimMirror := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/anim_mirror.gd")
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const RunCache := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_cache.gd")
const PuppetEntity := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/puppet_entity.gd"
)
const FeedbackMirror := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/feedback_mirror.gd"
)
const Looks := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/looks.gd")
const Facing := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/facing.gd")
const Puddles := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/puddles.gd")
const BattleScene := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/battle_scene.gd")
const StateStream := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd")
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
const KIND_ENTITY := 1  # has `dead` and an AnimationPlayer worth watching
const KIND_UNIT := 2  # has a sprite whose facing is host state
const KIND_POSE := 4  # its scene has parts that sync/pose.gd captures
const KIND_LOOK := 8  # can show a lasting look (sync/looks.gd)
const KIND_FACING := 16  # a projectile whose rotation is sent (sync/facing.gd)
# Snapshot time runs with the simulation; it is set back onto the wall clock when they part
# (a pause, a long hitch, a host that cannot keep 8 physics steps per frame).
const MAX_CLOCK_DRIFT_MSEC := 250.0

var session: Node = null
var state_stream: Node = null  # sync/state_stream.gd (set by mod_main.gd)
var input_sync: Node = null
var snapshot_bytes := 0  # size of the last snapshot, for the lobby page
var pause_control: Node = null  # who paused (section pause_battle)
var run_sender = null  # RunParts.Sender, shared with ShopSync and UpgradesSync (set by mod_main.gd)

var _main: Node = null
var _battle_live := false  # between _start_battle and _end_battle
var _battle_id := 0
var _next_net_id := 1
var _types := {}  # scene path -> type idx
var _records := {}  # instance id -> Rec array of every node in the last snapshot
var _live_ids := {}  # net ids in the last snapshot (not reused while alive)
var _stats := {}  # player index -> [stats Array, snapshot count of the last change]
var _snapshot_count := 0
var _accumulator := 0.0
var _sim_msec := 0.0  # host time of the simulation step being captured
var _fresh_ids := {}  # instance id -> true: got its net id from a spawn signal since the snapshot
var _paused := false
var _events := []  # one-shot feedback since the last snapshot
var _pose = Pose.new()
var _anim_mirror = AnimMirror.new()
var _feedback = FeedbackMirror.new()  # explosions, bonus gold, wave end (protocol 11)
var _looks = Looks.new()
var _facing = Facing.new()
var _battle_scene = BattleScene.new()  # weapons at wave start, sent speeds
var _run_cache = RunCache.new("battle")  # the run of the BATTLE_START being sent, in parts
var _entry_id := 0  # the battle scene whose entry _run_cache holds the run of (0: none)


func setup(netplay_session: Node, remote_input: Node) -> void:
	session = netplay_session
	input_sync = remote_input
	session.connect("peer_ready", self, "_on_peer_ready")
	session.connect("peer_removed", self, "_watch_entry")
	session.transport.connect("lobby_left", self, "_watch_entry", [-1])
	state_stream.register_provider(StateStream.PAUSE_BATTLE, self)
	RunData.connect("stat_added", self, "_on_stat_changed", [1])
	RunData.connect("stat_removed", self, "_on_stat_changed", [-1])
	_watch_entry()


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func is_in_battle() -> bool:
	return _battle_live and is_instance_valid(_main)


func _process(_delta: float) -> void:
	if not session.is_host():
		if _battle_live:
			_end_battle()
		return
	var scene := get_tree().current_scene
	var in_battle_scene := scene != null and scene.filename == BATTLE_SCENE
	if _battle_live and scene != _main:
		_end_battle()
	if in_battle_scene and not _battle_live:
		_start_battle(scene)


func _physics_process(delta: float) -> void:
	if not is_in_battle():
		return
	if not get_tree().paused:
		_sim_msec = advance_clock(_sim_msec, OS.get_ticks_msec())
	if get_tree().paused != _paused:
		_paused = get_tree().paused
		state_stream.flush(StateStream.PAUSE_BATTLE)  # not up to an interval late (host only)
	if not session.is_host():
		return
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


# Below 60 fps the engine runs several physics steps in one frame: stamped with the wall clock,
# two snapshots of one frame would be a few ms apart and the next one a whole frame later, and
# clients would play the wave fast, slow, fast. Each step is 1/60 s of the wave whenever it runs.
static func advance_clock(sim_msec: float, now_msec: int) -> float:
	sim_msec += 1000.0 / Engine.iterations_per_second
	if abs(now_msec - sim_msec) > MAX_CLOCK_DRIFT_MSEC:
		sim_msec = float(now_msec)
	return sim_msec


# --- battle lifecycle ---


func _start_battle(main: Node) -> void:
	if _battle_live:
		_end_battle()
	_main = main
	_battle_live = true
	_battle_id += 1
	_watch_entry()
	# The scene change frees the battle before the next _process could compare scenes.
	main.connect("tree_exited", self, "_on_battle_scene_exited", [_battle_id], CONNECT_ONESHOT)
	_paused = false
	_events.clear()
	_anim_mirror = AnimMirror.new()
	_feedback = FeedbackMirror.new()
	_looks = Looks.new()
	_facing = Facing.new()
	SoundRelay.set_sink(self)
	var main_players: Array = main.get("_players")
	for i in main_players.size():
		main_players[i].connect("took_damage", self, "_on_took_damage", [-(i + 1)])
	_types.clear()
	_records.clear()
	_fresh_ids.clear()
	_stats.clear()
	_sim_msec = float(OS.get_ticks_msec())
	_battle_scene = BattleScene.new()
	_battle_scene.host_start(main)
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
	run_sender.close(_run_cache)


# The game floats an icon and a number over the player for these (FloatingTextManager).
func _on_stat_changed(stat, value, _db_mod, player_index, factor: int) -> void:
	if is_in_battle() and typeof(stat) == TYPE_INT and typeof(player_index) == TYPE_INT:
		_feedback.stat_changed(stat, factor * int(value), player_index)


func _on_battle_scene_exited(battle_id: int) -> void:
	if _battle_live and battle_id == _battle_id:
		_end_battle()


# The battle scene's entry is watched between battles while the host has a ready peer (gone: a
# peer that is leaving, -1: the lobby is gone): inside a battle every pooled projectile that
# comes back would call _on_node_added, and solo play has no handler for every node.
func _watch_entry(gone := 0) -> void:
	var on := false
	if gone != -1 and not _battle_live and session.is_host():
		for steam_id in session.peers:
			on = on or (steam_id != gone and session.peers[steam_id].ready)
	var tree := get_tree()
	if tree == null or on == tree.is_connected("node_added", self, "_on_node_added"):
		return
	if on:
		tree.connect("node_added", self, "_on_node_added")
	else:
		tree.disconnect("node_added", self, "_on_node_added")


# The battle scene enters the tree, its _ready has not run yet: the run of its BATTLE_START
# (_battle_start_body).
func _on_node_added(node: Node) -> void:
	if node.filename == BATTLE_SCENE:
		_run_cache.clear()
		_run_cache.refresh(self)
		_entry_id = node.get_instance_id()


# Nothing of a wave outlives it: endless runs play a hundred of them.
func _end_battle() -> void:
	ModLoaderLog.info("Battle %s ended" % _battle_id, LOG_NAME)
	_main = null
	_battle_live = false
	_watch_entry()
	_types.clear()
	_records.clear()
	_fresh_ids.clear()
	_live_ids.clear()
	_stats.clear()
	_events.clear()
	_anim_mirror = AnimMirror.new()
	_feedback = FeedbackMirror.new()
	_looks = Looks.new()
	_facing = Facing.new()
	_battle_scene = BattleScene.new()
	SoundRelay.set_sink(null)
	if session.is_host():
		session.broadcast_reliable(Protocol.Msg.BATTLE_END, {"battle_id": _battle_id})


# Its run has every part (what a client with nothing needs: tests); _send_battle_start narrows
# it to what the peer lacks. The run the scene entered with for the first body of a battle
# (_on_node_added), else serialized now (a peer joining mid-wave, a battle the host loaded
# without peers). The cache is cleared after the sends (RunParts.Sender.close): no run text is
# kept through the battle.
func _battle_start_body() -> Dictionary:
	var types_by_idx := {}
	for path in _types:
		types_by_idx[_types[path]] = path
	_run_cache.title = "Battle %d start" % _battle_id
	var entered: bool = is_instance_valid(_main) and _entry_id == _main.get_instance_id()
	if not entered or _run_cache.parts.empty():
		_run_cache.clear()
		_run_cache.refresh(self)
	_entry_id = 0
	return {
		"battle_id": _battle_id,
		"run": _run_cache.all(),
		"types": types_by_idx,
		"colors": CoopService.bt_slot_colors.duplicate(),
		"holes": BattleScene.hole_layout(_main),
		"weapon_slots": _battle_scene.start_slots(_main),
	}


# Every part: the peer may have lost its store (a new process) or missed a body. ShopSync and
# UpgradesSync forget it too in this emission (RunParts.Sender.forget: once per idle frame, so
# their call does not drop the record made here). Between battles: the next battle scene's entry
# is watched from now on.
func _on_peer_ready(steam_id: int) -> void:
	if session.is_host() and is_in_battle():
		run_sender.forget(steam_id)
		_send_battle_start(steam_id, _battle_start_body())
		run_sender.close(_run_cache)
	_watch_entry()


# Section pause_battle: active while this battle is paused (a joining peer gets it on peer_ready
# like every section), inactive (null: resumed) otherwise. A pause flushes the section
# (_physics_process), so it does not wait for the next check.
func state_key(_section: int) -> String:
	if not is_in_battle() or not get_tree().paused:
		return ""
	return var2str(state_body(StateStream.PAUSE_BATTLE))


# battle_id, by (name, "": the host), by_id (steam id, 0: the host)
func state_body(_section: int):
	var by: Array = pause_control.paused_by() if pause_control != null else ["", 0]
	return {"battle_id": _battle_id, "by": by[0], "by_id": by[1]}


# Each client also learns which player slot it controls (-1: spectator), and gets the run parts
# it lacks: sent directly, not through the state stream, so recorded as sent at once.
func _send_battle_start(steam_id: int, start: Dictionary) -> void:
	var body := start.duplicate()
	body["you"] = _player_index_of(steam_id)
	body.erase("run")
	var view_bytes := var2bytes(body).size()
	run_sender.offer(_run_cache)
	body["run"] = run_sender.run_for(steam_id)
	session.send_reliable(steam_id, Protocol.Msg.BATTLE_START, body)
	run_sender.commit(steam_id, view_bytes)


func _player_index_of(steam_id: int) -> int:
	var device = input_sync.devices.get(steam_id)
	if device == null:
		return -1
	for i in CoopService.connected_players.size():
		if CoopService.connected_players[i][0] == device:
			return i
	return -1


# Newest INPUT seq the peer controlling player i has moved with, one physics tick each
# (input_sync.last_applied_seq; 0 for local players).
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
	_records.erase(entity.get_instance_id())
	_fresh_ids[entity.get_instance_id()] = true  # the id its first snapshot uses, hits included


func _assign_net_id(node: Node) -> void:
	node.set_meta(NET_ID_META, _new_net_id())
	if not node.is_connected("tree_exiting", self, "_on_tracked_exiting"):
		node.connect("tree_exiting", self, "_on_tracked_exiting", [node])


# Pools take nodes out of the tree: whatever comes back is a new entity, even when it is reused
# before the next snapshot (the game's pools are LIFO).
func _on_tracked_exiting(node: Node) -> void:
	_records.erase(node.get_instance_id())
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
	paths.append(FeedbackMirror.EXPLOSION_SCENE)
	for path in paths:
		if path != "" and not _types.has(path):
			_types[path] = _types.size()


# --- snapshot ---


func _build_snapshot() -> Array:
	var view := {
		"battle_id": _battle_id,
		"t": int(_sim_msec),
		"wave_time_left": 0.0,
		"players": _capture_players(),
		"ids": PoolIntArray(),
		"types": PoolIntArray(),
		"positions": PoolVector2Array(),
		"poses": {},
	}
	var wave_timer = _main.get("_wave_timer")
	view.wave_time_left = wave_timer.time_left if wave_timer != null else 0.0
	# Grouped by type (types travel as runs) in the order the types first appear, so bosses stay
	# first; ids sorted inside a group (they travel as deltas).
	var groups := {}  # type idx -> net ids
	var order := []
	var by_id := {}  # net id -> record
	var records := {}
	for node in _tracked_nodes():
		if not is_instance_valid(node):
			continue
		var key: int = node.get_instance_id()
		var record = _records.get(key)
		if record == null:
			# Not in the last snapshot: a new logical entity (also a pooled node that came back).
			if not node.is_inside_tree() or node.get("dead"):
				continue
			record = _record(node, key)
		elif record[Rec.KIND] & KIND_ENTITY and node.dead:
			continue
		records[key] = record
		var type_idx: int = record[Rec.TYPE]
		var group = groups.get(type_idx)
		if group == null:
			group = []
			groups[type_idx] = group
			order.append(type_idx)
		group.append(record[Rec.ID])
		by_id[record[Rec.ID]] = record
	var flags := []
	var ids := PoolIntArray()  # pool arrays are values: filled locally, stored at the end
	var types := PoolIntArray()
	var positions := PoolVector2Array()
	var live := {}
	for type_idx in order:
		var group: Array = groups[type_idx]
		group.sort()
		for net_id in group:
			var record: Array = by_id[net_id]
			var node: Node2D = record[Rec.NODE]
			var kind: int = record[Rec.KIND]
			var position: Vector2 = node.global_position
			live[net_id] = true
			ids.append(net_id)
			types.append(type_idx)
			positions.append(position)
			# Facing is host state: behaviors turn units toward their target, and knockback would
			# flip a puppet that faced its interpolated motion. flip_h: JumpAttackBehavior turns
			# the sprite toward its landing spot (and leaves it so). Hidden: e.g. stampede dinos
			# before their charge.
			var node_flags := 0 if node.visible else Snapshot.FLAG_HIDDEN
			if kind & KIND_UNIT:
				var sprite = node.sprite
				if sprite != null:
					if sprite.scale.x < 0:
						node_flags |= Snapshot.FLAG_FACING_LEFT
					if sprite.flip_h:
						node_flags |= Snapshot.FLAG_FLIP_H
			if kind & KIND_ENTITY:
				_anim_mirror.capture(node, net_id, _events)
			if kind & KIND_LOOK:
				var entity: bool = kind & KIND_ENTITY
				var unit: bool = kind & KIND_UNIT
				_looks.capture(node, net_id, ids.size() - 1, _snapshot_count, entity, unit)
			if kind & KIND_FACING:
				_facing.capture(node, net_id, ids.size() - 1, _snapshot_count)
			var posed := false
			if kind & KIND_POSE:
				var pose: PoolRealArray = _pose.capture(node)
				if not pose.empty():
					view.poses[ids.size() - 1] = pose
					posed = true
			# Unmoved for REST_AFTER snapshots: the position is left out (clients keep the last
			# one), except in a refresh every REST_REFRESH snapshots for clients that missed it.
			if not posed:
				var x := int(round(position.x * Snapshot.POS_SCALE))
				var y := int(round(position.y * Snapshot.POS_SCALE))
				if x != record[Rec.X] or y != record[Rec.Y]:
					record[Rec.X] = x
					record[Rec.Y] = y
					record[Rec.STILL] = 0
				else:
					record[Rec.STILL] += 1
					if (
						record[Rec.STILL] >= REST_AFTER
						and (_snapshot_count + net_id) % REST_REFRESH != 0
					):
						node_flags |= Snapshot.FLAG_REST
			flags.append(node_flags)
	_records = records
	_fresh_ids.clear()
	_live_ids = live
	_anim_mirror.end_snapshot()
	view.ids = ids
	view.types = types
	view.positions = positions
	view.flags = Snapshot.pack_flags(flags)
	_feedback.capture(_main, _events, _snapshot_count, funcref(self, "_type_idx"))
	view["events"] = Snapshot.select_events(_events, MAX_EVENTS)
	view["looks"] = _looks.end_snapshot()
	view["angles"] = _facing.end_snapshot()
	_events = []
	_snapshot_count += 1
	return [Protocol.Msg.SNAPSHOT, Snapshot.encode(view)]


# A node enters the snapshots: its net id (the one a spawn signal just gave it, else a new
# one), its type, what kind of thing it is, the damage hook.
func _record(node: Node, key: int) -> Array:
	if not node.has_meta(NET_ID_META) or not _fresh_ids.has(key):
		_assign_net_id(node)
	var kind := 0
	if node is Entity:
		kind |= KIND_ENTITY
	if node is Unit:
		kind |= KIND_UNIT
		if not node.is_connected("took_damage", self, "_on_took_damage"):
			node.connect("took_damage", self, "_on_took_damage", [0])
	_feedback.track(node)
	var layout: Dictionary = _pose.layout(node)
	if not layout.parts.empty() or layout.group != Pose.Group.NONE:
		kind |= KIND_POSE
	elif node is Projectile:
		kind |= KIND_FACING  # a laser's aim is a pose value
	if Looks.can_have_look(node):
		kind |= KIND_LOOK
	# X / Y: no position yet (out of the wire's range), so the first snapshot never rests.
	return [node.get_meta(NET_ID_META), _type_idx(_type_key(node)), kind, node, 1 << 20, 0, 0]


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
		entry.append(_battle_scene.weapon_slots(i, player))
		entry.append(_battle_scene.speed(i, player, _snapshot_count))
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
	# Spawn markers: where the next enemies, trees and turrets appear.
	var births = _main.get("_births_container")
	if births != null:
		for child in births.get_children():
			if child is EntityBirth and child.visible:
				nodes.append(child)
	nodes += Puddles.tracked(_main)  # acid, petrol, fire: static like gold
	nodes += BattleScene.spawned_holes(_main)
	# Pooled projectiles are removed from the tree, so container children are the live ones.
	for container_name in ["_player_projectiles", "_enemy_projectiles"]:
		var container = _main.get(container_name)
		# clean_up_room frees the enemy projectiles' container while the scene lives on.
		if is_instance_valid(container):
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
	if node is EntityBirth:
		return "%s#%s" % [node.filename, PuppetEntity.birth_tag(node)]
	if Puddles.is_puddle(node):  # sprite and size (sync/puddles.gd)
		return "%s#%s" % [node.filename, Puddles.tag(node)]
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
