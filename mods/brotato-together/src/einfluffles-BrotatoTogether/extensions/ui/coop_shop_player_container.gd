extends "res://ui/menus/shop/coop_shop_player_container.gd"
# The damage meter's page at the end of this player's carousel (ui/damage_views.gd add_page).
# Built here, in the panel's own _ready, so the page exists before a page index from the network
# is applied to the carousel (sync/shop_sync.gd, sync/shop_intents.gd): a page that came later
# would be clamped away.

const VIEWS := "/root/ModLoader/einfluffles-BrotatoTogether/DamageViews"


func _ready() -> void:
	var views = get_node_or_null(VIEWS)
	if views != null:
		views.add_page(self)
