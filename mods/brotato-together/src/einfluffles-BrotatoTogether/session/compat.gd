extends Reference
# Join compatibility, checked by the host on HELLO. Game and mod version must match: the client
# loads the host's scenes / resources by path and runs the same mirror code. So must every other
# mod and its version, UI-only ones included: another mod changes content and rules. DLC need not:
# a client borrows what it lacks (session/dlc_borrow.gd).

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const DlcBorrow := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/dlc_borrow.gd")
const MOD_ID := "einfluffles-BrotatoTogether"
# A rejection's code in WELCOME -> its text (translations.csv, {0}: the client's, {1}: the host's).
const REJECTION_KEYS := {
	"protocol": "BT_REJECT_PROTOCOL",
	"game": "BT_REJECT_GAME",
	"mod": "BT_REJECT_MOD",
	"mods": "BT_REJECT_MODS",
}
const MODS_SHOWN := 3  # a side's mods in a rejection's text, the rest as "+N"
const MODS_LOGGED := 50  # the same in the host's log line
const MOD_ENTRY_MAX := 80  # characters of one "<mod id> <version>" entry, longer ones cut


# What this machine sends in HELLO / compares against.
static func local_info(persona: String) -> Dictionary:
	return {
		"version": Protocol.VERSION,
		"name": persona,
		"game_version": str(ProgressData.VERSION),
		"mod_version": mod_version(),
		"dlcs": DlcBorrow.owned_ids(),  # never borrowed ones
		"mods": local_mods(),
	}


static func mod_version() -> String:
	var mod_data = ModLoaderMod.get_mod_data(MOD_ID)
	if mod_data == null or mod_data.manifest == null:
		return "?"
	return str(mod_data.manifest.version_number)


# Every other mod the Mod Loader loaded and runs: mod id -> version_number.
static func local_mods() -> Dictionary:
	var mods := {}
	var all: Dictionary = ModLoaderMod.get_mod_data_all()
	for mod_id in all:
		var mod_data = all[mod_id]
		if mod_id == MOD_ID or not mod_data.is_loadable or not mod_data.is_active:
			continue
		if mod_data.manifest != null:
			mods[mod_id] = str(mod_data.manifest.version_number)
	return mods


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
	var mods = client.get("mods")
	if typeof(mods) != TYPE_DICTIONARY:
		return _rejected("", [], "malformed mod list")
	var differences := mod_differences(host.mods, mods)
	if not differences.client.empty() or not differences.host.empty():
		var args := [mods_text(differences.client), mods_text(differences.host)]
		var all := [
			mods_text(differences.client, MODS_LOGGED), mods_text(differences.host, MODS_LOGGED)
		]
		return _rejected("mods", args, "different mods (client: %s; host: %s)" % all)
	return {"code": "", "args": [], "reason": ""}


# client: the entries "<mod id> <version>" the client has and the host lacks or has in another
# version; host: the other way round. Each sorted.
static func mod_differences(host_mods: Dictionary, client_mods: Dictionary) -> Dictionary:
	return {"client": _only_in(client_mods, host_mods), "host": _only_in(host_mods, client_mods)}


static func _only_in(mods: Dictionary, other: Dictionary) -> Array:
	var entries := []
	for mod_id in mods:
		var version := str(mods[mod_id])
		if not other.has(mod_id) or str(other[mod_id]) != version:
			var entry := "%s %s" % [mod_id, version]
			if entry.length() > MOD_ENTRY_MAX:  # a client's id or version can be any length
				entry = entry.left(MOD_ENTRY_MAX - 3) + "..."
			entries.append(entry)
	entries.sort()
	return entries


# A side of the rejection: "-" for none, past `shown` entries (-1: all) "+N".
static func mods_text(entries: Array, shown: int = MODS_SHOWN) -> String:
	if entries.empty():
		return "-"
	if shown < 0 or entries.size() <= shown:
		return PoolStringArray(entries).join(", ")
	var text := PoolStringArray(entries.slice(0, shown - 1)).join(", ")
	return "%s +%d" % [text, entries.size() - shown]


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
