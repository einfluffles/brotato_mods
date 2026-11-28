extends Reference
# The damage meter's icon outlines (ui/damage_views.gd, _set_outline): a source's tier, the biggest
# hit's source, the HUD's total. Part of the suite damage (damage_meter_tests.gd). The shader's
# output needs a window: tools\play-local.ps1 -Scenario damage_tiers.

const DamageViews := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/damage_views.gd")
const PISTOL := "weapon_pistol_1"

var _t: Node


func _init(test_mod: Node) -> void:
	_t = test_mod


# A source's icon: tier II and up outlined in the tier's color; the hit's source in the hit's.
func run(views: Node) -> void:
	var icon: TextureRect = DamageViews._icon(DamageViews.HUD_ICON, "Icon")
	var common = _t._find_by_id(ItemService.weapons, PISTOL)
	var rare = _t._find_by_id(ItemService.weapons, "weapon_pistol_3")
	views._set_source_icon(icon, common)
	var none: bool = icon.texture == common.icon and not icon.has_node(DamageViews.OUTLINE_NODE)
	_t._check(none, "a tier I source has no outline")
	views._set_source_icon(icon, rare)
	var outline: TextureRect = icon.get_node_or_null(DamageViews.OUTLINE_NODE)
	var w: float = DamageViews.OUTLINE_WIDTH
	_t._check(
		(
			outline != null
			and outline.visible
			and outline.show_behind_parent
			and [outline.texture, icon.texture] == [rare.icon, rare.icon]
			and [outline.margin_left, outline.margin_bottom] == [-w, w]
			and outline.self_modulate == ItemService.get_color_from_tier(rare.tier)
			and outline.material.shader != null
		),
		"a tier III source has one in its tier's color: behind its icon, %d px past it" % w
	)
	views._set_source_icon(icon, common)
	_t._check(outline == null or not outline.visible, "and loses it for a tier I source")
	icon.free()
	var burst: TextureRect = DamageViews._hit_icon()
	views._show_hit_source(burst, "weapon_pistol_3")
	var gold = burst.get_node_or_null("Source/" + DamageViews.OUTLINE_NODE)
	_t._check(gold != null and gold.self_modulate == DamageViews.HIT_COLOR, "the hit's source: gold")
	burst.free()
	var square: Dictionary = DamageViews.outline_params(Vector2(32, 32), Vector2(96, 96))  # 36 px
	var flat: Dictionary = DamageViews.outline_params(Vector2(32, 32), Vector2(120, 77))
	var code: String = DamageViews.outline_code()  # 16 directions, no loops (GLES2)
	_t._check(
		(
			is_equal_approx(square.scale, 32.0 / 36.0)
			and is_equal_approx(flat.scale, 32.0 / 36.0)
			and square.width.is_equal_approx(Vector2(2.0 / 32, 2.0 / 32))
			and flat.width.is_equal_approx(Vector2(2.0 / 32, 2.0 / (77 * 32.0 / 120)))
			and code.count("alpha_at(TEXTURE") == 1 + DamageViews.OUTLINE_DIRECTIONS
			and not "for (" in code
		),
		"its shader draws the shape at the icon's size, %d px wider" % w
	)
