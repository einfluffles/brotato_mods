extends "res://ui/menus/run/coop_end_run_player_container.gd"
# The damage meter's page at the end of this player's carousel on the co-op end of run, the last
# wave's board (ui/damage_views.gd add_page). Built in the panel's own _ready, before a client's
# puppet applies the host's pages (sync/menu_puppet.gd).

const VIEWS := "/root/ModLoader/einfluffles-BrotatoTogether/DamageViews"


func _ready() -> void:
	var views = get_node_or_null(VIEWS)
	if views != null:
		views.add_page(self)
