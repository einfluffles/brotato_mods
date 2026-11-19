extends "res://ui/menus/run/coop_end_run_player_container.gd"
# The damage meter's page in this player's carousel, from the panel's own _ready (see add_page).

const VIEWS := "/root/ModLoader/einfluffles-BrotatoTogether/DamageViews"


func _ready() -> void:
	var views = get_node_or_null(VIEWS)
	if views != null:
		views.add_page(self)
