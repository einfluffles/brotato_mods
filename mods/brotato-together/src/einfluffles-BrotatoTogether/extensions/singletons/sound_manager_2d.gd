extends "res://singletons/sound_manager_2d.gd"
# See session/sound_relay.gd. Only sounds the game actually queues are recorded.

const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)


func play(
	sound: Resource,
	pos: Vector2,
	volume_mod: float = 0.0,
	pitch_rand: float = 0.0,
	always_play: bool = false
) -> void:
	if SoundRelay.drop_local():
		return
	var queued: bool = always_play or SoundRelay.has_room(self)
	.play(sound, pos, volume_mod, pitch_rand, always_play)
	if queued:
		SoundRelay.record(sound, pos, volume_mod, pitch_rand, always_play)
