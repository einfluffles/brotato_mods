extends Reference
# Join compatibility, checked by the host on HELLO (the lobby tag only carries Protocol.VERSION).
#  - game version (ProgressData.VERSION) and mod version (manifest version_number) must match:
#    the client loads the host's scenes/resources by path and runs the same mirror code
#  - the client must own every DLC the host owns: DLC characters/items/enemies are only
#    registered where the DLC is installed (ItemService.init_dlc_content), and a host's runs can
#    use them at any time (character selection, shop pools, zones). Extra DLCs on the client
#    are fine.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const MOD_ID := "einfluffles-BrotatoTogether"


# What this machine sends in HELLO / compares against.
static func local_info(persona: String) -> Dictionary:
	return {
		"version": Protocol.VERSION,
		"name": persona,
		"game_version": str(ProgressData.VERSION),
		"mod_version": mod_version(),
		"dlcs": ProgressData.available_dlc_ids.duplicate(),
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
	var dlcs = client.get("dlcs")
	if typeof(dlcs) != TYPE_ARRAY:
		return "malformed DLC list"
	var missing := []
	for dlc_id in host.dlcs:
		if not dlc_id in dlcs:
			missing.append(dlc_id)
	if not missing.empty():
		return (
			"the host has DLC you don't (%s); its characters, items and enemies can't be shown"
			% PoolStringArray(missing).join(", ")
		)
	return ""
