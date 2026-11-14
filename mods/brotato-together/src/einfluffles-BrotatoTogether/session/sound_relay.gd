extends Reference
# Routes game sounds during a mirrored battle (used by the SoundManager/SoundManager2D extensions).
# Host: every sound is also handed to the recording sink (BattleHost) to be replayed on clients.
# Client in a battle: locally triggered sounds are dropped (puppets would e.g. play step sounds
# from their walk animation) — only replays of the host's sounds are played.

const META_SINK := "brotato_together_sound_sink"
const META_MUTE := "brotato_together_mute_local_sounds"
const META_REPLAY := "brotato_together_sound_replay"


# Returns true if the sound must not be played.
static func intercept(sound: Resource, position, volume_mod: float, pitch_rand: float) -> bool:
	if Engine.has_meta(META_SINK):
		var sink = Engine.get_meta(META_SINK)
		if sink != null and is_instance_valid(sink):
			sink.record_sound(sound, position, volume_mod, pitch_rand)
		return false
	if Engine.has_meta(META_MUTE) and Engine.get_meta(META_MUTE):
		return not (Engine.has_meta(META_REPLAY) and Engine.get_meta(META_REPLAY))
	return false


static func set_sink(sink: Object) -> void:
	if sink == null:
		if Engine.has_meta(META_SINK):
			Engine.remove_meta(META_SINK)
	else:
		Engine.set_meta(META_SINK, sink)


static func set_muted(muted: bool) -> void:
	Engine.set_meta(META_MUTE, muted)


static func replay(sound: Resource, position, volume_mod: float, pitch_rand: float) -> void:
	Engine.set_meta(META_REPLAY, true)
	if position == null:
		SoundManager.play(sound, volume_mod, pitch_rand)
	else:
		SoundManager2D.play(sound, position, volume_mod, pitch_rand)
	Engine.set_meta(META_REPLAY, false)
