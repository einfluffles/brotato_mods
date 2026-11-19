extends Reference
# Entity animations the game starts from physics code, which never runs on frozen puppets.
# The host sends an EVENT_ANIM when an entity's AnimationPlayer starts an animation:
#   [Snapshot.EVENT_ANIM, net id, animation name, position (s), playback speed]

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const REFRESH_SNAPSHOTS := 30  # ~1 s at 30 Hz, staggered by net id
const REFRESH_AFTER_CHANGE := 90  # snapshots: also refresh the autoplay animation this long
const RESTART_EPSILON := 0.001
const SEEK_TOLERANCE := 0.1  # s: closer than this, the puppet's own playback is left alone
const MAX_SPEED := 16.0
const DETACHED_META := "brotato_together_anim_detached"

# Host: instance id -> [net id, animation name, position, snapshot of the last change or -1]
var _state := {}
var _next := {}
var _count := 0
# Client: original Animation -> copy without method tracks, and the set of copies
var _copies := {}
var _is_copy := {}


# Death is not mirrored: the client plays it itself when an entity leaves the snapshots.
static func is_mirrored_name(name: String) -> bool:
	return name != "" and name != "RESET" and not name.begins_with("death")


func capture(node: Node, net_id: int, events: Array) -> void:
	if not node is Entity:
		return
	var player = node.get("_animation_player")
	if not player is AnimationPlayer:
		return
	var name: String = player.current_animation
	var position: float = player.current_animation_position if name != "" else 0.0
	var key: int = node.get_instance_id()
	var state = _state.get(key)
	var started := false
	if state == null or state[0] != net_id:
		started = name != player.autoplay  # puppets start in the autoplay animation
		state = [net_id, name, position, -1]
	elif name != state[1]:
		started = true
	elif name != "" and position < state[2] - RESTART_EPSILON:
		started = not player.get_animation(name).loop  # looping ones wrap around
	var refresh: bool = (
		state[3] >= 0
		and (name != player.autoplay or _count - state[3] < REFRESH_AFTER_CHANGE)
		and (_count + net_id) % REFRESH_SNAPSHOTS == 0
	)
	if started:
		state[3] = _count
	if (started or refresh) and is_mirrored_name(name):
		events.append([Snapshot.EVENT_ANIM, net_id, name, position, player.playback_speed])
	state[1] = name
	state[2] = position
	_next[key] = state


func end_snapshot() -> void:
	_state = _next
	_next = {}
	_count += 1


# entities: net id -> puppet.
func replay(entities: Dictionary, event: Array) -> bool:
	if (
		event.size() != 5
		or typeof(event[1]) != TYPE_INT
		or typeof(event[2]) != TYPE_STRING
		or typeof(event[3]) != TYPE_REAL
		or typeof(event[4]) != TYPE_REAL
	):
		return false
	var node = entities.get(event[1])
	if node == null or not is_instance_valid(node) or not node is Entity or node.dead:
		return false
	var player = node.get("_animation_player")
	var name: String = event[2]
	if not player is AnimationPlayer or not is_mirrored_name(name) or not player.has_animation(name):
		return false
	var position: float = event[3]
	var speed: float = event[4]
	if is_nan(position) or is_inf(position) or is_nan(speed) or is_inf(speed):
		return false
	detach_game_handlers(node)
	var animation := _without_method_tracks(player, name)
	position = clamp(position, 0.0, animation.length)
	player.playback_speed = clamp(speed, 0.0, MAX_SPEED)
	if player.current_animation != name:
		player.play(name)
		player.seek(position, true)
	elif abs(player.current_animation_position - position) > SEEK_TOLERANCE:
		player.seek(position, true)
	return true


# The game's animation_finished handlers compute cooldowns from stats puppets lack and call attack
# behaviors that were never initialized. The host sends the animation that follows instead.
static func detach_game_handlers(node: Node) -> void:
	var player = node.get("_animation_player") if node is Entity else null
	if not player is AnimationPlayer or node.has_meta(DETACHED_META):
		return
	node.set_meta(DETACHED_META, true)
	for connection in player.get_signal_connection_list("animation_finished"):
		if connection.target == node:
			player.disconnect("animation_finished", node, connection.method)


# An enemy pillar's autoplay "shoot" ends in stop(), which returns it to the game's pool; puppets
# have no pool id, so a projectile puppet plays its animation without method tracks.
func strip_projectile(projectile: Node) -> Animation:
	var player = projectile.get("_animation_player")
	if not player is AnimationPlayer or player.assigned_animation == "":
		return null
	return _without_method_tracks(player, player.assigned_animation)


# Method tracks call game logic (shoot() spawns projectiles). The Animation is shared with real
# entities, so the puppet gets a copy without them.
func _without_method_tracks(player: AnimationPlayer, name: String) -> Animation:
	var animation: Animation = player.get_animation(name)
	if _is_copy.has(animation) or not _has_method_tracks(animation):
		return animation
	if not _copies.has(animation):
		var copy: Animation = animation.duplicate()
		for i in range(copy.get_track_count() - 1, -1, -1):
			if copy.track_get_type(i) == Animation.TYPE_METHOD:
				copy.remove_track(i)
		_copies[animation] = copy
		_is_copy[copy] = true
	player.remove_animation(name)
	player.add_animation(name, _copies[animation])
	return _copies[animation]


static func _has_method_tracks(animation: Animation) -> bool:
	for i in animation.get_track_count():
		if animation.track_get_type(i) == Animation.TYPE_METHOD:
			return true
	return false
