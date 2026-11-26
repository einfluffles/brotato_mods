extends Reference
# Scenes that exist only in the host's memory: another mod packed them during the run and gave them
# a res:// path with take_over_path, so a client's load() of that type finds no file. The host sends
# each client such a scene's description (sync/scene_description.gd) once per session, as SCENE
# before the first message that names its type (BattleHost._send_scenes). The client rebuilds the
# scene under its own rules, registers it under the host's path (where the type's load(), warm
# pools and pose layouts find it) and holds it for the session. One instance for both roles.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const SceneDescription := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/scene_description.gd"
)
const LOG_NAME := "einfluffles-BrotatoTogether:RuntimeScenes"
# Compressed: an eighth of Steam's 512 KB, its limit for one message and for the send queue (a
# late joiner gets all of the battle's scenes in one burst with its BATTLE_START).
const MAX_PACKED_BYTES := 65536
# The description (var2bytes): an image made at run time is in it byte for byte; a blank copy of
# the biggest boss sprite (770x350) is 1.1 MB, which packs to 2.3 KB.
const MAX_BYTES := 4194304
const MAX_PATH_LENGTH := 512
const MAX_REASON_LENGTH := 200  # a reason can quote the host's names: the log stays short
const COMPRESSION := File.COMPRESSION_ZSTD
# What one session takes from a host: scenes, and bytes of their descriptions.
const MAX_SESSION_SCENES := 512
const MAX_SESSION_BYTES := 67108864

var session: Node = null
var _bodies := {}  # host: scene path -> SCENE body, null: none (on disk, not a scene, too big)
var _sent := {}  # host: steam id -> {scene path: true}
var _held := {}  # client: scene path -> PackedScene rebuilt from the host's, null: not used
var _held_bytes := 0  # client: the descriptions' bytes this session
var _full := false  # client: the session's limit is reached (logged once)


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.connect("message", self, "_on_message")
	session.connect("peer_removed", self, "forget")
	session.transport.connect("lobby_left", self, "clear")


# Host: SCENE bodies for the type keys whose scenes the peer has not had this session.
func bodies_for(steam_id: int, keys: Array) -> Array:
	var bodies := []
	for key in keys:
		var path: String = key.split("#")[0]
		if not _bodies.has(path):
			_bodies[path] = pack(path) if in_memory(path) else null
		var sent: Dictionary = _sent.get(steam_id, {})
		if _bodies[path] != null and not sent.has(path):
			sent[path] = true
			_sent[steam_id] = sent
			bodies.append(_bodies[path])
	return bodies


# Host: the peer left, or is resynced and may have missed a SCENE.
func forget(steam_id: int) -> void:
	_sent.erase(steam_id)


func clear() -> void:
	_bodies.clear()
	_sent.clear()
	_held.clear()
	_held_bytes = 0
	_full = false


# A cached scene without a file behind its path.
static func in_memory(path: String) -> bool:
	if not path.ends_with(".tscn") or not ResourceLoader.has_cached(path):
		return false
	return not SceneDescription.on_disk(path) and ResourceLoader.load(path) is PackedScene


# The SCENE body of a cached scene: its description, compressed. null when it has none or is
# too big (logged).
static func pack(path: String):
	var description = SceneDescription.new().describe(ResourceLoader.load(path))
	if description is String:
		ModLoaderLog.warning("The scene %s cannot go to clients: %s" % [path, description], LOG_NAME)
		return null
	var bytes := var2bytes(description)
	var data := bytes.compress(COMPRESSION)
	if bytes.size() > MAX_BYTES or data.size() > MAX_PACKED_BYTES:
		ModLoaderLog.warning(
			(
				"The scene %s is too big for clients (%d B, %d B packed; at most %d B, %d B packed)"
				% [path, bytes.size(), data.size(), MAX_BYTES, MAX_PACKED_BYTES]
			),
			LOG_NAME
		)
		return null
	ModLoaderLog.info(
		"Sending the scene %s to clients (%d B, %d B packed)" % [path, bytes.size(), data.size()],
		LOG_NAME
	)
	return {"path": path, "size": bytes.size(), "data": data}


func _on_message(steam_id: int, msg_type: int, body) -> void:
	var from_host: bool = session.is_client() and steam_id == session.transport.host_id
	if msg_type == Protocol.Msg.SCENE and from_host:
		receive(body)


# Client: each path once per session, within the session's limits. A scene this game has cached
# itself is kept.
func receive(body) -> void:
	if typeof(body) != TYPE_DICTIONARY or typeof(body.get("path")) != TYPE_STRING:
		return
	var path: String = body.path
	if _held.has(path) or path.length() > MAX_PATH_LENGTH:
		return
	if _held.size() >= MAX_SESSION_SCENES or _held_bytes >= MAX_SESSION_BYTES:
		if not _full:
			_full = true
			ModLoaderLog.warning(
				(
					"The host's scenes reached a session's limit (%d, %d B): %s and later ones"
					+ " stay unresolved"
				)
				% [_held.size(), _held_bytes, path],
				LOG_NAME
			)
		return
	_held[path] = null
	var size: int = body.size if typeof(body.get("size")) == TYPE_INT else 0
	if ResourceLoader.has_cached(path):
		ModLoaderLog.info("The host's scene %s (%d B) is loaded here already" % [path, size], LOG_NAME)
		return
	_held_bytes += int(clamp(size, 0, MAX_BYTES))
	var result = unpack(body)
	if result is PackedScene:
		_held[path] = result
		ModLoaderLog.info("Loaded the host's scene %s (%d B)" % [path, size], LOG_NAME)
	else:
		var why := str(result).left(MAX_REASON_LENGTH)
		ModLoaderLog.warning("Rejected the host's scene %s (%d B): %s" % [path, size, why], LOG_NAME)


# Client: the PackedScene of a SCENE body, registered under the host's path, or why not.
static func unpack(body: Dictionary):
	var path = body.get("path")
	var size = body.get("size")
	var data = body.get("data")
	if typeof(path) != TYPE_STRING or typeof(size) != TYPE_INT or typeof(data) != TYPE_RAW_ARRAY:
		return "malformed"
	if not SceneDescription.res_path(path) or not path.ends_with(".tscn"):
		return "not a scene path"
	if SceneDescription.on_disk(path) or ResourceLoader.has_cached(path):
		return "a scene of this game"
	if size < 1 or size > MAX_BYTES or data.size() > MAX_PACKED_BYTES:
		return "too big"
	var bytes: PoolByteArray = data.decompress(size, COMPRESSION)
	if bytes.size() != size:
		return "not %d B" % size
	var result = SceneDescription.new().rebuild(_decode(bytes))
	if result is PackedScene:
		result.take_over_path(path)
	return result


# bytes2var stops the function it is called in at bytes it cannot read: this one returns null.
static func _decode(bytes: PoolByteArray):
	return bytes2var(bytes, false)
