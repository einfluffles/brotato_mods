extends "res://ui/menus/pages/menu_options.gd"
# The damage meter's switch in the game's options, Gameplay tab, under "life bars on bosses": a
# copy of that check button (its look and script, not its handler). The Mod Loader keeps
# settings but has no screen for them.

const METER := "/root/ModLoader/einfluffles-BrotatoTogether/DamageMeter"
const BUTTON_NAME := "DamageMeterButton"

var _damage_meter_button: CheckButton = null


func _ready() -> void:
	var meter = get_node_or_null(METER)
	var after: CheckButton = boss_hp_bar_button
	if meter == null or after == null or after.get_parent().has_node(BUTTON_NAME):
		return
	_damage_meter_button = after.duplicate(DUPLICATE_SCRIPTS)
	_damage_meter_button.name = BUTTON_NAME
	_damage_meter_button.unique_name_in_owner = false
	_damage_meter_button.text = "Damage meter"
	_damage_meter_button.pressed = meter.shown
	after.get_parent().add_child_below_node(after, _damage_meter_button)
	_damage_meter_button.connect("toggled", meter, "set_shown")


# The page is set up again every time it opens.
func init() -> void:
	.init()
	var meter = get_node_or_null(METER)
	if meter != null and is_instance_valid(_damage_meter_button):
		_damage_meter_button.set_pressed_no_signal(meter.shown)
