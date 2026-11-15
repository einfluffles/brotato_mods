extends Node
# One ordered, reliable stream of host state in named sections (STATE: [section, revision, body]).
# Replaces the machinery every sync module had its own copy of: a poll loop with a change key,
# forgetting the key on peer_ready, per-peer sends, and "keep the latest state until the scene
# is ready, then apply it".
#
# Host: register_provider(section, provider, interval) with a provider object that has
#   state_key(section) -> String: what the section's state is right now, "" = inactive (nothing
#     to send). Called every interval, so it must be cheap (text of the state, not the state
#     packed). It must cover everything the body depends on, the per-peer part included.
#   state_body(section): the body, built only when something is sent (compress here). Shared by
#     every peer of one send. Plain data only (no objects).
#   state_patch(section, steam_id) -> Dictionary (optional): merged into a copy of the body for
#     each peer (`you`). Split from state_body so the expensive part is built once per send
#     without the provider caching anything; a patch needs a Dictionary body.
# flush(section, hold = false): check in the next idle frame whatever the interval (state
# changed by deferred game code, like a shop intent); with hold, no check before that frame
# either. mark_dirty(section, steam_id = 0: every ready peer): send the
# current state again at the next check even when the key did not change.
# Only ready peers get anything; nothing is sent while not host. A key change bumps the
# section's revision and goes to every ready peer; a section that turns inactive after having
# been active sends a null body once. On peer_ready the peer gets every section again in section
# order (current revision, null for one that was active once and is not now): a resync must
# re-deliver what the peer may have missed.
#
# Client: register_handler(section, handler, timeout_sec) with a handler object that has
#   apply_state(section, body, revision) -> bool: true = applied, false = not now (scene still
#     loading, control not built). The latest body of the section then stays pending and is
#     retried every frame, in section order, until it applies, a newer one replaces it, a null
#     clears it or timeout_sec passes. Anything but a bool (a handler that hit a script error
#     returns null) drops the body with a warning; the other sections go on.
#   clear_state(section) (optional): the host has no state for the section any more. Only called
#     when the section had a state since the last clear.
# retry(): try every pending section now (e.g. on battle_entered). receive(message): one STATE
# body, validated; the sender check (only the host) is in _on_message.
# Revisions: a lower revision than the last one received for the section is stale and dropped;
# an equal one is applied again (that is a resync or a mark_dirty resend), so handlers must be
# idempotent. lobby_left drops everything on both sides.
#
# Tests drive it by hand: message_for(section, steam_id) is the STATE body the host would send
# that peer now, receive() takes it, step(delta) is one frame (what _process does).

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:StateStream"

# Section ids, in apply order on the client and send order on resync: state that builds controls
# comes before the cursors that point at them.
const RUN_SHOP := 0
const UPGRADES := 1
const MENU := 2
const MENU_GRIDS := 3
const RETRY := 4
const PAUSE_BATTLE := 5
const PAUSE_SHOP := 6
const CURSORS := 7
const NAMES := [
	"shop", "upgrades", "menu", "menu_grids", "retry", "pause_battle", "pause_shop", "cursors"
]
const DEFAULT_INTERVAL := 0.1
const DEFAULT_TIMEOUT_SEC := 10.0

var session: Node = null

# host: section -> {provider, patched, interval, left, key, rev, flush_frame, dirty {steam_id}}
var _providers := {}
# client: section -> {handler, clears, timeout_msec}
var _handlers := {}
var _revs := {}  # section -> last revision received
var _live := {}  # sections with a state received since the last clear
var _pending := {}  # section -> {body, rev, msec}: latest body its handler could not apply yet


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.connect("message", self, "_on_message")
	session.connect("peer_ready", self, "_on_peer_ready")
	session.transport.connect("lobby_left", self, "_on_lobby_left")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func _process(delta: float) -> void:
	step(delta)


func step(delta: float) -> void:
	if session.is_host() and not _providers.empty():
		_host_step(delta)
	if not _pending.empty():
		retry()


# --- host ---


func register_provider(section: int, provider: Object, interval := DEFAULT_INTERVAL) -> void:
	assert(section >= 0 and section < NAMES.size())
	_providers[section] = {
		"provider": provider,
		"patched": provider.has_method("state_patch"),
		"interval": interval,
		"left": 0.0,
		"key": "",
		"rev": 0,
		"flush_frame": -1,
		"hold": false,
		"dirty": {},
	}


# hold: no check at all before that frame (a check in between would send the state half done).
func flush(section: int, hold := false) -> void:
	if _providers.has(section):
		_providers[section].flush_frame = Engine.get_idle_frames() + 1
		_providers[section].hold = hold


func mark_dirty(section: int, steam_id := 0) -> void:
	if not _providers.has(section):
		return
	var dirty: Dictionary = _providers[section].dirty
	if steam_id != 0:
		dirty[steam_id] = true
	else:
		for peer in _ready_peers():
			dirty[peer] = true


# [section, revision, body] for the section's state right now (null body: inactive), with the
# revision of the last check. Builds the body, sends nothing.
func message_for(section: int, steam_id: int) -> Array:
	var entry: Dictionary = _providers[section]
	var key = entry.provider.call("state_key", section)
	var body = null
	if typeof(key) == TYPE_STRING and key != "":
		body = _patched(section, entry, entry.provider.call("state_body", section), steam_id)
	return [section, entry.rev, body]


func _host_step(delta: float) -> void:
	var frame := Engine.get_idle_frames()
	var peers = null  # built only when a section is due
	for section in NAMES.size():
		var entry = _providers.get(section)
		if entry == null:
			continue
		entry.left -= delta
		var flushed: bool = entry.flush_frame >= 0 and frame >= entry.flush_frame
		var held: bool = entry.hold and entry.flush_frame >= 0 and not flushed
		if held or (entry.left > 0.0 and not flushed):
			continue
		if peers == null:
			peers = _ready_peers()
			if peers.empty():
				return  # checked on peer_ready instead
		_check(section, entry, peers, 0)


# Sends the section to every ready peer when its key changed, else to the dirty ones and to
# resend_to (0: nobody).
func _check(section: int, entry: Dictionary, peers: Array, resend_to: int) -> void:
	entry.left = entry.interval
	if entry.flush_frame >= 0 and Engine.get_idle_frames() >= entry.flush_frame:
		entry.flush_frame = -1  # a check before its frame (peer_ready) leaves the flush armed
	var key = entry.provider.call("state_key", section)
	if typeof(key) != TYPE_STRING:
		return  # provider error: keep what was sent, check again next interval
	var targets := []
	if key != entry.key:
		entry.key = key
		entry.rev += 1
		targets = peers
	else:
		for peer in peers:
			if entry.dirty.has(peer) or peer == resend_to:
				targets.append(peer)
	entry.dirty.clear()
	if targets.empty() or (key == "" and entry.rev == 0):
		return  # nobody to send to, or never active: nothing to clear
	var body = entry.provider.call("state_body", section) if key != "" else null
	for peer in targets:
		var message := [section, entry.rev, _patched(section, entry, body, peer)]
		session.send_reliable(peer, Protocol.Msg.STATE, message)


func _patched(section: int, entry: Dictionary, body, steam_id: int):
	if not entry.patched or typeof(body) != TYPE_DICTIONARY:
		return body
	var patch = entry.provider.call("state_patch", section, steam_id)
	if typeof(patch) != TYPE_DICTIONARY:
		return body
	var own: Dictionary = body.duplicate()
	for field in patch:
		own[field] = patch[field]
	return own


func _ready_peers() -> Array:
	var peers := []
	for steam_id in session.peers:
		if session.peers[steam_id].ready:
			peers.append(steam_id)
	return peers


# Every section again for this peer, in section order (sections that changed meanwhile go to
# everyone).
func _on_peer_ready(steam_id: int) -> void:
	if not session.is_host():
		return
	var peers := _ready_peers()
	for section in NAMES.size():
		if _providers.has(section):
			_check(section, _providers[section], peers, steam_id)


# --- client ---


func register_handler(section: int, handler: Object, timeout_sec := DEFAULT_TIMEOUT_SEC) -> void:
	assert(section >= 0 and section < NAMES.size())
	_handlers[section] = {
		"handler": handler,
		"clears": handler.has_method("clear_state"),
		"timeout_msec": int(timeout_sec * 1000.0),
	}


func is_pending(section: int) -> bool:
	return _pending.has(section)


func _on_message(steam_id: int, msg_type: int, body) -> void:
	if msg_type != Protocol.Msg.STATE or not session.is_client():
		return
	if steam_id == session.transport.host_id:
		receive(body)


func receive(message) -> void:
	if typeof(message) != TYPE_ARRAY or message.size() != 3:
		return
	var section = message[0]
	var rev = message[1]
	if typeof(section) != TYPE_INT or typeof(rev) != TYPE_INT or rev < 0:
		return
	if not _handlers.has(section) or rev < _revs.get(section, -1):
		return  # unknown section, nobody handles it, or stale
	_revs[section] = rev
	var body = message[2]
	if body == null:
		_pending.erase(section)
		if _live.erase(section) and _handlers[section].clears:
			_handlers[section].handler.call("clear_state", section)
		return
	_live[section] = true
	_pending[section] = {"body": body, "rev": rev, "msec": OS.get_ticks_msec()}
	retry()


func retry() -> void:
	var now := OS.get_ticks_msec()
	for section in NAMES.size():
		var pending = _pending.get(section)
		if pending == null:
			continue
		var entry: Dictionary = _handlers[section]
		if now - pending.msec > entry.timeout_msec:
			_pending.erase(section)
			ModLoaderLog.debug("%s state never applied; dropped" % NAMES[section], LOG_NAME)
			continue
		var applied = entry.handler.call("apply_state", section, pending.body, pending.rev)
		if typeof(applied) != TYPE_BOOL:
			_pending.erase(section)
			ModLoaderLog.warning("%s handler failed; state dropped" % NAMES[section], LOG_NAME)
		elif applied:
			_pending.erase(section)


func _on_lobby_left() -> void:
	_revs.clear()
	_live.clear()
	_pending.clear()
	for entry in _providers.values():
		entry.left = 0.0
		entry.key = ""
		entry.rev = 0
		entry.flush_frame = -1
		entry.dirty.clear()
