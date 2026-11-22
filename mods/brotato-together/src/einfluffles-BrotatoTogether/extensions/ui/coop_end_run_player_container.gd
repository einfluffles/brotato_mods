extends "res://ui/menus/run/coop_end_run_player_container.gd"
# The damage meter's page in this player's carousel, from the panel's own _ready (see add_page),
# and the panel's key hints for this player (sync/input_types.gd).

const VIEWS := "/root/ModLoader/einfluffles-BrotatoTogether/DamageViews"
const INPUT_TYPES := "/root/ModLoader/einfluffles-BrotatoTogether/InputTypes"


func _ready() -> void:
	var views = get_node_or_null(VIEWS)
	if views != null:
		views.add_page(self, true)  # the run, not the last wave
	var input_types = get_node_or_null(INPUT_TYPES)
	if input_types != null:
		input_types.adopt(self)
