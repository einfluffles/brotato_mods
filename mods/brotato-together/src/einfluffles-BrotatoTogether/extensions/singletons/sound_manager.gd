extends "res://singletons/sound_manager.gd"
# See session/sound_relay.gd. Only sounds the game actually queues are recorded: play() drops
# sounds while all players are busy or the queue is full, playSingle() also within its cooldown.

const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)


func play(
	sound: Resource, volume_mod: float = 0.0, pitch_rand: float = 0.0, always_play: bool = false
) -> void:
	if SoundRelay.drop_local():
		return
	var queued: bool = always_play or SoundRelay.has_room(self)
	.play(sound, volume_mod, pitch_rand, always_play)
	if queued:
		SoundRelay.record(sound, null, volume_mod, pitch_rand, always_play)


func playSingle(
	sound: Resource,
	volume_mod: float = 0.0,
	pitch_rand: float = 0.0,
	always_play: bool = false,
	duplicate_cooldown: float = 0.0
) -> void:
	if SoundRelay.drop_local():
		return
	var queued: bool = always_play or SoundRelay.has_room(self)
	var had: bool = _last_played.has(sound)
	var last = _last_played.get(sound)
	.playSingle(sound, volume_mod, pitch_rand, always_play, duplicate_cooldown)
	# can_play_sound() stamps the time only when the cooldown has passed.
	var passed: bool = duplicate_cooldown <= 0.0 or not had or _last_played.get(sound) != last
	if queued and passed:
		SoundRelay.record(sound, null, volume_mod, pitch_rand, always_play, duplicate_cooldown)
