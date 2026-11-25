extends "res://mods-unpacked/einfluffles-BrotatoTogether/net/steam_transport.gd"
# Installed by the dev mod's _init only when local play is active (mod_main.gd), so it is in
# place before brotato:together's _ready creates the transport: setup() hands the transport to the
# dev mod instead of binding the engine's GodotSteam. That is not logged on in a local instance,
# and its "Steam not logged on" / "Steam transport unavailable" errors would end up in the log the
# game reads at the next boot (it turns mods off after a logged mod error).

const LOCAL_PATH := "/root/ModLoader/einfluffles-TogetherLocal"


func setup(lobby_tag: String) -> bool:
	var local = get_node_or_null(LOCAL_PATH)
	if local == null or not local.has_method("take_transport"):
		return .setup(lobby_tag)
	_lobby_tag = lobby_tag
	return local.take_transport(self)
