extends Node
# The host's sounds outside battle (shop, selection screens, end of run) for clients.
# Host: SoundRelay hands every sound played outside a battle to record_sound(); they're batched per
#   frame and sent as UI_SOUNDS (reliable: discrete events, a few res:// paths per batch).
#   In battle BattleHost records instead (snapshot events) — that includes the level-up/crate
#   panels, which live in main.tscn.
# Client: replays them. Local sounds are muted while the puppet shop runs: its mirrored state and
#   cursors would play the same sounds a second time. ClientView isn't mirrored: it stays audible.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SHOP_SCENE := "res://ui/menus/shop/coop_shop.tscn"
const MAX_PER_BATCH := 16  # SoundManager.MAX_SOUNDS: more would not play in one frame anyway
const MAX_CACHED := 256
const VOLUME_RANGE := Vector2(-60.0, 12.0)
const MAX_PITCH_RAND := 0.9  # pitch_scale = 1 +- rand: must stay positive

var session: Node = null

var _recording := false
var _batch := []  # host: [[path, volume, pitch, position or null]] since the last send
var _streams := {}  # client: path -> AudioStream, null if rejected


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.connect("message", self, "_on_message")
	get_tree().connect("node_added", self, "_on_node_added")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


# --- host ---


func _process(_delta: float) -> void:
	var recording: bool = session.is_host() and _has_ready_peer()
	if recording != _recording:
		_recording = recording
		SoundRelay.set_ui_sink(self if recording else null)
		_batch.clear()
	if not recording or _batch.empty():
		return
	session.broadcast_reliable(Protocol.Msg.UI_SOUNDS, take_batch())


# Called by SoundRelay for every sound the host plays outside a battle.
func record_sound(sound: Resource, position, volume_mod: float, pitch_rand: float) -> void:
	# Paused: the host's pause menu is not shown on clients.
	if get_tree().paused or sound == null or _batch.size() >= MAX_PER_BATCH:
		return
	if not SoundRelay.is_sound_path(sound.resource_path):
		return  # generated at runtime / embedded: clients can't load it by path
	_batch.append([sound.resource_path, volume_mod, pitch_rand, position])


# Message body for the sounds recorded since the last call ({} if none).
func take_batch() -> Dictionary:
	if _batch.empty():
		return {}
	var body := {"sounds": _batch}
	_batch = []
	return body


func _has_ready_peer() -> bool:
	for steam_id in session.peers:
		if session.peers[steam_id].ready:
			return true
	return false


# --- client ---


func _on_message(steam_id: int, msg_type: int, body) -> void:
	if msg_type != Protocol.Msg.UI_SOUNDS or not session.is_client():
		return
	if steam_id != session.transport.host_id:
		return
	play_batch(body)


# Returns the number of sounds played; malformed entries and non-sound paths are skipped.
func play_batch(body) -> int:
	if typeof(body) != TYPE_DICTIONARY or typeof(body.get("sounds")) != TYPE_ARRAY:
		return 0
	var played := 0
	var sounds: Array = body.sounds
	for i in int(min(sounds.size(), MAX_PER_BATCH)):
		var entry = sounds[i]
		if typeof(entry) != TYPE_ARRAY or entry.size() != 4:
			continue
		if not (_is_number(entry[1]) and _is_number(entry[2])):
			continue
		var position = entry[3]
		if position != null and typeof(position) != TYPE_VECTOR2:
			continue
		var stream = _stream(entry[0])
		if stream == null:
			continue
		var volume: float = clamp(float(entry[1]), VOLUME_RANGE.x, VOLUME_RANGE.y)
		var pitch: float = clamp(float(entry[2]), 0.0, MAX_PITCH_RAND)
		SoundRelay.replay(stream, position, volume, pitch)
		played += 1
	return played


func _stream(path):
	if typeof(path) != TYPE_STRING:
		return null
	if _streams.has(path):
		return _streams[path]
	var stream = null
	if SoundRelay.is_sound_path(path) and ResourceLoader.exists(path):
		var loaded = load(path)
		stream = loaded if loaded is AudioStream else null
	if _streams.size() >= MAX_CACHED:
		_streams.clear()
	_streams[path] = stream
	return stream


static func _is_number(value) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	return typeof(value) == TYPE_REAL and not is_nan(value) and not is_inf(value)


# The puppet shop reacts to mirrored state/cursors with its own sounds; the host's replace them.
# node_added (not ready) so sounds from the shop's own _ready are covered too.
func _on_node_added(node: Node) -> void:
	if Puppet.is_active() and node.filename == SHOP_SCENE:
		SoundRelay.set_muted(true)
		node.connect("tree_exited", self, "_on_puppet_shop_exited", [], CONNECT_ONESHOT)


# The old scene leaves the tree before the next one is added, so this never undoes the battle's
# mute (BattleClient mutes when main.tscn is ready).
func _on_puppet_shop_exited() -> void:
	SoundRelay.set_muted(false)
