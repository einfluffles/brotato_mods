extends Reference
# Logs the path of Steam's message session to each lobby member (direct, or relayed and through
# which relay POP), its changes, and what followed a failed session.

const LOG_NAME := "einfluffles-BrotatoTogether:Transport"
const POLL_MSEC := 1000
const FOLLOW_UP_MSEC := 15000

# ESteamNetworkingConnectionState
const STATE_CONNECTING := 1
const STATE_FINDING_ROUTE := 2
const STATE_CONNECTED := 3
const STATE_CLOSED_BY_PEER := 4
const STATE_PROBLEM_DETECTED_LOCALLY := 5
# k_nSteamNetworkConnectionInfoFlags_Relayed (SteamNetConnectionInfo_t::m_nFlags, "info_flags")
const FLAG_RELAYED := 16

# ESteamNetConnectionEnd values worth naming (the number is logged too).
const END_REASONS := {
	3001: "Steam is offline here",
	3002: "no relay reachable from here",
	3004: "network configuration not available here",
	3006: "no public address here (ICE)",
	4001: "the peer timed out",
	4007: "the peer has no public address (ICE)",
	5003: "timed out",
	5005: "lost the connection to Steam",
	5006: "relay could not reach the peer",
	5008: "P2P rendezvous failed",
	5009: "NAT / firewall blocked the direct connection",
	5010: "the peer sent no connection",
}

var paths := {}  # steam id -> what describe() said at the last poll ("" before a session)
var lines := 0  # logged so far
var last_line := ""
var relay_only := false  # the transport switched Steam's direct route off
var direct_warnings := 0  # logged so far
var _failures := {}  # steam id -> msec of a failed session whose outcome is not logged yet
var _direct_warned := {}  # steam id -> true: its session came up direct under relay-only
var _next_poll_msec := 0


func poll(steam: Object, members: Array, now: int) -> void:
	if now < _next_poll_msec or steam == null or not steam.has_method("getSessionConnectionInfo"):
		return
	_next_poll_msec = now + POLL_MSEC
	for steam_id in paths.keys():
		if not members.has(steam_id):
			paths.erase(steam_id)
			_failures.erase(steam_id)
			_direct_warned.erase(steam_id)
	for steam_id in members:
		var info = steam.getSessionConnectionInfo(steam_id, true, true)
		_update(steam_id, info if typeof(info) == TYPE_DICTIONARY else {}, now)


func _update(steam_id: int, info: Dictionary, now: int) -> void:
	_update_path(steam_id, info, now)
	if relay_only and paths.get(steam_id, "") == "direct" and not _direct_warned.has(steam_id):
		_direct_warned[steam_id] = true
		direct_warnings += 1
		_log(
			(
				"Connection to %s is direct although relay-only is on here: the other side may run"
				+ " an older build of the mod or +bt_direct"
			) % steam_id,
			true
		)


func _update_path(steam_id: int, info: Dictionary, now: int) -> void:
	var path := describe(info)
	var ping := ""
	if int(info.get("connection_state", 0)) == STATE_CONNECTED and info.has("ping"):
		ping = " (Steam ping %s ms)" % info.ping
	if _failures.has(steam_id):
		var since: int = now - _failures[steam_id]
		if int(info.get("connection_state", 0)) == STATE_CONNECTED:
			_failures.erase(steam_id)
			paths[steam_id] = path
			_log("Session with %s up again %d ms after it failed: %s%s" % [steam_id, since, path, ping])
		elif since >= FOLLOW_UP_MSEC:
			_failures.erase(steam_id)
			paths[steam_id] = path
			var state := path if path != "" else "no session"
			_log(
				(
					"Session with %s still not up %d s after it failed (%s)"
					% [steam_id, since / 1000, state]
				),
				true
			)
		return
	if path == paths.get(steam_id, ""):
		return
	paths[steam_id] = path
	if path != "":
		_log("Connection to %s: %s%s" % [steam_id, path, ping])


# network_messages_session_failed (GodotSteam 3.x: reason, remote steam id, connection state,
# debug message). Other argument lists (other GodotSteam versions) are logged as they come.
func session_failed(args: Array, now: int) -> String:
	if (
		args.size() < 4
		or typeof(args[0]) != TYPE_INT
		or typeof(args[1]) != TYPE_INT
		or typeof(args[3]) != TYPE_STRING
	):
		return "Networking session failed: %s" % [args]
	var steam_id: int = args[1]
	_failures[steam_id] = now
	paths[steam_id] = "failed"
	var text := (
		"Networking session with %s failed: %s (reason %s, state %s: %s)"
		% [steam_id, END_REASONS.get(args[0], "?"), args[0], args[2], args[3]]
	)
	return text + "; the next message opens a new one"


# "direct", "relayed via fra (peer's POP ams)", "connecting", "closed: ..."; "" without a session.
static func describe(info: Dictionary) -> String:
	var state := int(info.get("connection_state", 0))
	if state == STATE_CONNECTING or state == STATE_FINDING_ROUTE:
		return "connecting"
	if state == STATE_CLOSED_BY_PEER or state == STATE_PROBLEM_DETECTED_LOCALLY:
		var reason := int(info.get("end_reason", 0))
		return (
			"closed: %s (reason %d: %s)"
			% [END_REASONS.get(reason, "?"), reason, str(info.get("end_debug", ""))]
		)
	if state != STATE_CONNECTED:
		return ""
	var relay := int(info.get("pop_relay", 0))
	if relay == 0 and not int(info.get("info_flags", 0)) & FLAG_RELAYED:
		return "direct"
	var text := "relayed"
	if relay != 0:
		text += " via %s" % pop_code(relay)
	var remote_pop := int(info.get("remote_pop", 0))
	if remote_pop != 0 and remote_pop != relay:
		text += " (peer's POP %s)" % pop_code(remote_pop)
	return text


# SteamNetworkingPOPID -> its data center code (GetSteamNetworkingLocationPOPStringFromID).
static func pop_code(id: int) -> String:
	var chars := PoolByteArray([(id >> 16) & 0xFF, (id >> 8) & 0xFF, id & 0xFF, (id >> 24) & 0xFF])
	var code := ""
	for byte in chars:
		if byte >= 0x20 and byte < 0x7F:
			code += char(byte)
	return code if code != "" else str(id)


func _log(text: String, warning := false) -> void:
	lines += 1
	last_line = text
	if warning:
		ModLoaderLog.warning(text, LOG_NAME)
	else:
		ModLoaderLog.info(text, LOG_NAME)
