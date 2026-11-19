extends Reference
# Routes game sounds for mirroring, for the SoundManager / SoundManager2D extensions.
# Host: every sound the game queues goes to a sink (BattleHost in a battle, UiSounds otherwise).
# Client in a mirrored scene: local sounds are dropped (puppets' step sounds, mirrored cursors'
# focus sounds), only the host's are replayed.

const META_SINK := "brotato_together_sound_sink"
const META_UI_SINK := "brotato_together_ui_sound_sink"
const META_MUTE := "brotato_together_mute_local_sounds"
const META_REPLAY := "brotato_together_sound_replay"
const META_DROPPED := "brotato_together_sounds_dropped"
const SOUND_EXTENSIONS := ["wav", "ogg", "mp3"]
const SINGLE_COOLDOWN_SLACK := 0.1  # s, see replay()


static func drop_local() -> bool:
	if _sink() != null:
		return false
	if Engine.has_meta(META_MUTE) and Engine.get_meta(META_MUTE):
		if Engine.has_meta(META_REPLAY) and Engine.get_meta(META_REPLAY):
			return false
		Engine.set_meta(META_DROPPED, dropped_count() + 1)
		return true
	return false


# cooldown: playSingle's duplicate_cooldown (0 for play()).
static func record(
	sound: Resource, position, volume_mod: float, pitch_rand: float, always := false, cooldown := 0.0
) -> void:
	var sink = _sink()
	if sink != null:
		sink.record_sound(sound, position, volume_mod, pitch_rand, always, cooldown)


# SoundManagerParent's own condition for queueing a sound without always_play.
static func has_room(manager: Object) -> bool:
	return (
		not manager.players_available.empty()
		and manager.sounds_to_play.size() < manager.MAX_SOUNDS
	)


static func _sink():
	# The battle sink wins: during a battle UI sounds (level-up panels) travel with the snapshots.
	var sink = _get_object(META_SINK)
	# The battle scene is gone a frame before BattleHost notices; sounds of the next screen (the
	# shop's _ready / first focus) belong to the UI sink already.
	if sink != null and not sink.is_in_battle():
		sink = null
	return sink if sink != null else _get_object(META_UI_SINK)


static func set_sink(sink: Object) -> void:
	_set_object(META_SINK, sink)


static func set_ui_sink(sink: Object) -> void:
	_set_object(META_UI_SINK, sink)


static func set_muted(muted: bool) -> void:
	Engine.set_meta(META_MUTE, muted)


static func is_muted() -> bool:
	return Engine.has_meta(META_MUTE) and Engine.get_meta(META_MUTE)


static func dropped_count() -> int:
	return Engine.get_meta(META_DROPPED) if Engine.has_meta(META_DROPPED) else 0


# Paths arrive from the network: only game/mod sound files.
static func is_sound_path(path) -> bool:
	if typeof(path) != TYPE_STRING or not path.begins_with("res://") or (".." in path):
		return false
	return path.get_extension().to_lower() in SOUND_EXTENSIONS


# cooldown > 0: the host played it with playSingle; so does the client, with a slack for the
# snapshot timing (sounds a cooldown apart on the host can fire a snapshot interval closer here).
static func replay(
	sound: Resource, position, volume_mod: float, pitch_rand: float, always := false, cooldown := 0.0
) -> void:
	Engine.set_meta(META_REPLAY, true)
	if position != null:
		SoundManager2D.play(sound, position, volume_mod, pitch_rand, always)
	elif cooldown > 0.0:
		var client_cooldown: float = max(cooldown - SINGLE_COOLDOWN_SLACK, 0.01)
		SoundManager.playSingle(sound, volume_mod, pitch_rand, always, client_cooldown)
	else:
		SoundManager.play(sound, volume_mod, pitch_rand, always)
	Engine.set_meta(META_REPLAY, false)


static func _get_object(key: String):
	if not Engine.has_meta(key):
		return null
	var value = Engine.get_meta(key)
	return value if value != null and is_instance_valid(value) else null


static func _set_object(key: String, value: Object) -> void:
	if value == null:
		if Engine.has_meta(key):
			Engine.remove_meta(key)
	else:
		Engine.set_meta(key, value)
