extends Reference
# Routes game sounds for mirroring (used by the SoundManager/SoundManager2D extensions).
# Host: every sound is also handed to a recording sink to be replayed on clients — BattleHost
# during a battle (snapshot events), UiSounds otherwise (shop, menus; sync/ui_sounds.gd).
# Client in a mirrored scene (battle, shop): locally triggered sounds are dropped (puppets would
# e.g. play step sounds from their walk animation, mirrored cursors focus sounds) — only replays
# of the host's sounds are played.

const META_SINK := "brotato_together_sound_sink"
const META_UI_SINK := "brotato_together_ui_sound_sink"
const META_MUTE := "brotato_together_mute_local_sounds"
const META_REPLAY := "brotato_together_sound_replay"
const META_DROPPED := "brotato_together_sounds_dropped"
const SOUND_EXTENSIONS := ["wav", "ogg", "mp3"]


# Returns true if the sound must not be played.
static func intercept(sound: Resource, position, volume_mod: float, pitch_rand: float) -> bool:
	# The battle sink wins: during a battle UI sounds (level-up panels) travel with the snapshots.
	var sink = _get_object(META_SINK)
	# The battle scene is gone a frame before BattleHost notices; sounds of the next screen (the
	# shop's _ready / first focus) belong to the UI sink already.
	if sink != null and not sink.is_in_battle():
		sink = null
	if sink == null:
		sink = _get_object(META_UI_SINK)
	if sink != null:
		sink.record_sound(sound, position, volume_mod, pitch_rand)
		return false
	if Engine.has_meta(META_MUTE) and Engine.get_meta(META_MUTE):
		if Engine.has_meta(META_REPLAY) and Engine.get_meta(META_REPLAY):
			return false
		Engine.set_meta(META_DROPPED, dropped_count() + 1)
		return true
	return false


static func set_sink(sink: Object) -> void:
	_set_object(META_SINK, sink)


static func set_ui_sink(sink: Object) -> void:
	_set_object(META_UI_SINK, sink)


static func set_muted(muted: bool) -> void:
	Engine.set_meta(META_MUTE, muted)


static func is_muted() -> bool:
	return Engine.has_meta(META_MUTE) and Engine.get_meta(META_MUTE)


# Local sounds suppressed so far (debugging / tests).
static func dropped_count() -> int:
	return Engine.get_meta(META_DROPPED) if Engine.has_meta(META_DROPPED) else 0


# Paths arrive from the network: only game/mod sound files.
static func is_sound_path(path) -> bool:
	if typeof(path) != TYPE_STRING or not path.begins_with("res://") or (".." in path):
		return false
	return path.get_extension().to_lower() in SOUND_EXTENSIONS


static func replay(sound: Resource, position, volume_mod: float, pitch_rand: float) -> void:
	Engine.set_meta(META_REPLAY, true)
	if position == null:
		SoundManager.play(sound, volume_mod, pitch_rand)
	else:
		SoundManager2D.play(sound, position, volume_mod, pitch_rand)
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
