extends "res://ui/menus/ingame/coop_upgrades_ui_player_container.gd"
# The panel's key hints for this player (sync/input_types.gd).

const INPUT_TYPES := "/root/ModLoader/einfluffles-BrotatoTogether/InputTypes"


func _ready() -> void:
	var input_types = get_node_or_null(INPUT_TYPES)
	if input_types != null:
		input_types.adopt(self)
