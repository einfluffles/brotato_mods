extends Reference
# Join compatibility, checked by the host on HELLO (the lobby tag only carries Protocol.VERSION).
#  - game version (ProgressData.VERSION) and mod version (manifest version_number) must match:
#    the client loads the host's scenes/resources by path and runs the same mirror code
#  - DLC doesn't matter: a client lacking one of the host's DLCs borrows it for the session
#    (session/dlc_borrow.gd, from the host's list in WELCOME), like Steam Remote Play Together.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const DlcBorrow := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/dlc_borrow.gd")
const MOD_ID := "einfluffles-BrotatoTogether"


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


# "" when a client with `client` info may join a host with `host` info, else a reason for the
# client (shown in its F9 menu).
static func incompatibility(host: Dictionary, client) -> String:
	if typeof(client) != TYPE_DICTIONARY:
		return "malformed HELLO"
	var version = client.get("version")
	if typeof(version) != TYPE_INT or version != host.version:
		return "mod protocol %s, host has %s" % [version, host.version]
	var game_version := str(client.get("game_version", "?"))
	if game_version != host.game_version:
		return "game version %s, host has %s" % [game_version, host.game_version]
	var mod_version := str(client.get("mod_version", "?"))
	if mod_version != host.mod_version:
		return (
			"brotato:together %s, host has %s (update via the Workshop)"
			% [mod_version, host.mod_version]
		)
	if typeof(client.get("dlcs")) != TYPE_ARRAY:
		return "malformed DLC list"
	return ""


# The host's DLCs a client lacks (it borrows them; logged by the host).
static func missing_dlcs(host_dlcs: Array, client_dlcs) -> Array:
	var missing := []
	for dlc_id in host_dlcs:
		if typeof(client_dlcs) != TYPE_ARRAY or not dlc_id in client_dlcs:
			missing.append(dlc_id)
	return missing
