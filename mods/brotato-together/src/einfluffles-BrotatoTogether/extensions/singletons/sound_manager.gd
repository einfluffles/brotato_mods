extends "res://singletons/sound_manager.gd"
# See session/sound_relay.gd.

const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)


func play(
	sound: Resource, volume_mod: float = 0.0, pitch_rand: float = 0.0, always_play: bool = false
) -> void:
	if SoundRelay.intercept(sound, null, volume_mod, pitch_rand):
		return
	.play(sound, volume_mod, pitch_rand, always_play)


func playSingle(
	sound: Resource,
	volume_mod: float = 0.0,
	pitch_rand: float = 0.0,
	always_play: bool = false,
	duplicate_cooldown: float = 0.0
) -> void:
	if SoundRelay.intercept(sound, null, volume_mod, pitch_rand):
		return
	.playSingle(sound, volume_mod, pitch_rand, always_play, duplicate_cooldown)
