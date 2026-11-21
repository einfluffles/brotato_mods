extends "res://ui/menus/shop/coop_shop_hint.gd"
# "Press [glyph] to trade" in the popup of a shop item or of the own gear. The game's hints take
# their glyph from CoopService, which knows only the game's actions. brotato:together sets
# player_index on every CoopShopHint when a client's device changes: the setter lands here.

const Hotkey := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/hotkey.gd")
const TRADE_TEXT := "Press {0} to trade"


func _update_key_icon() -> void:
	if not is_inside_tree():
		return
	var glyph = Hotkey.glyph(player_index)
	_key_icon.visible = glyph is Texture
	if glyph is Texture:
		_key_icon.texture = glyph
		set_text(TRADE_TEXT)
	else:
		set_text(TRADE_TEXT.replace("{0}", "%s {0}" % glyph))
