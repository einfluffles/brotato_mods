extends "res://ui/menus/shop/coop_shop_hint.gd"
# "Press [glyph] to trade" in the popup of a shop item or of the own gear. The game's hints take
# their glyph from CoopService, which knows only the game's actions. brotato:together sets
# player_index on every CoopShopHint when a client's device changes: the setter lands here.

const Hotkey := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/hotkey.gd")
const TRADE_TEXT := "BTR_TRADE_HINT"  # a key (translations.csv) with {0} for the glyph


# The game's set_text translates the text once: a language chosen later builds the labels again.
func _notification(what: int) -> void:
	if what == MainLoop.NOTIFICATION_TRANSLATION_CHANGED:
		_update_key_icon()


func _update_key_icon() -> void:
	# brotato:together also hands the hints of an empty slot's panel to that slot; set_text reads
	# the player's run data.
	if not is_inside_tree() or player_index >= RunData.players_data.size():
		return
	var glyph = Hotkey.glyph(player_index)
	_key_icon.visible = glyph is Texture
	if glyph is Texture:
		_key_icon.texture = glyph
		set_text(TRADE_TEXT)
	else:
		# A key name in place of an image: it joins the text before the icon's place ("Press Y").
		set_text(tr(TRADE_TEXT).replace("{0}", "%s {0}" % glyph))
