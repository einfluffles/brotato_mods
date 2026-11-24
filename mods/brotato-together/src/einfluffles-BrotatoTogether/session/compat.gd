extends Reference
# Join compatibility, checked by the host on HELLO. Game and mod version must match: the client
# loads the host's scenes / resources by path and runs the same mirror code. DLC need not: a
# client borrows what it lacks (session/dlc_borrow.gd).

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const DlcBorrow := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/dlc_borrow.gd")
const MOD_ID := "einfluffles-BrotatoTogether"
# A rejection's code in WELCOME -> its text (translations.csv, {0}: the client's, {1}: the host's).
const REJECTION_KEYS := {
	"protocol": "BT_REJECT_PROTOCOL", "game": "BT_REJECT_GAME", "mod": "BT_REJECT_MOD"
}


# What this machine sends in HELLO / compares against.
static func local_info(persona: String) -> Dictionary:
	return {
		"version": Protocol.VERSION,
		"name": persona,
		"game_version": str(ProgressData.VERSION),
		"mod_version": mod_version(),
		"dlcs": DlcBorrow.owned_ids(),  # never borrowed ones
	}


static func mod_version() -> String:
	var mod_data = ModLoaderMod.get_mod_data(MOD_ID)
	if mod_data == null or mod_data.manifest == null:
		return "?"
	return str(mod_data.manifest.version_number)


# "" when the client may join the host, else the reason in English (the host's log).
static func incompatibility(host: Dictionary, client) -> String:
	return rejection(host, client).reason


# {code, args, reason} for WELCOME: code "" when the client may join. The client shows the code
# in its own language (describe), the English reason is the host's log line and the fallback.
static func rejection(host: Dictionary, client) -> Dictionary:
	if typeof(client) != TYPE_DICTIONARY:
		return _rejected("", [], "malformed HELLO")
	var version = client.get("version")
	if typeof(version) != TYPE_INT or version != host.version:
		var args := [str(version), str(host.version)]
		return _rejected("protocol", args, "mod protocol %s, host has %s" % args)
	var game_version := str(client.get("game_version", "?"))
	if game_version != host.game_version:
		var args := [game_version, str(host.game_version)]
		return _rejected("game", args, "game version %s, host has %s" % args)
	var mod_version := str(client.get("mod_version", "?"))
	if mod_version != host.mod_version:
		var args := [mod_version, str(host.mod_version)]
		return _rejected(
			"mod", args, "brotato:together %s, host has %s (update via the Workshop)" % args
		)
	if typeof(client.get("dlcs")) != TYPE_ARRAY:
		return _rejected("", [], "malformed DLC list")
	return {"code": "", "args": [], "reason": ""}


static func _rejected(code: String, args: Array, reason: String) -> Dictionary:
	return {"code": code, "args": args, "reason": reason}


# The host's reason from a WELCOME body, in this machine's language: by its code, else (no or an
# unknown code, a malformed HELLO) the English reason as sent.
static func describe(body: Dictionary) -> String:
	var key: String = REJECTION_KEYS.get(body.get("code"), "")
	var args = body.get("args")
	if key == "" or typeof(args) != TYPE_ARRAY or args.size() != 2:
		return str(body.get("reason", "?"))
	return Text.text(key, [str(args[0]), str(args[1])])


static func missing_dlcs(host_dlcs: Array, client_dlcs) -> Array:
	var missing := []
	for dlc_id in host_dlcs:
		if typeof(client_dlcs) != TYPE_ARRAY or not dlc_id in client_dlcs:
			missing.append(dlc_id)
	return missing
