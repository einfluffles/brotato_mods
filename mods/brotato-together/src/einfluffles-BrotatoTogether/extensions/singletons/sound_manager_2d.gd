extends "res://singletons/sound_manager_2d.gd"
# See session/sound_relay.gd.

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
	if SoundRelay.intercept(sound, pos, volume_mod, pitch_rand):
		return
	.play(sound, pos, volume_mod, pitch_rand, always_play)
