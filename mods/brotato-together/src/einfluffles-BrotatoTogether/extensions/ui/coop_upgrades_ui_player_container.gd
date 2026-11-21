extends "res://ui/menus/ingame/coop_upgrades_ui_player_container.gd"
# The panel's key hints for this player (sync/input_types.gd).

const UpgradesGear := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/upgrades_gear.gd"
)
const INPUT_TYPES := "/root/ModLoader/einfluffles-BrotatoTogether/InputTypes"


func _ready() -> void:
	var input_types = get_node_or_null(INPUT_TYPES)
	if input_types != null:
		input_types.adopt(self)


# The gear rows' focus neighbours can name each other's elements, which this frees (the game's
# crate weapons list, a client's rebuild, brotato:trade's crate trade).
func update_inventory() -> void:
	.update_inventory()
	UpgradesGear.relink_gear(self)
