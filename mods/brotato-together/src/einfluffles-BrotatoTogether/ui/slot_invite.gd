extends VBoxContainer
# "Invite friends" and the lobby status inside an empty player slot of character selection (the
# game's CoopJoinPanel), shown by ui/coop_mode.gd while hosting online.

const NODE_NAME := "BrotatoTogetherSlotInvite"
const BUTTON_SCRIPT_PATH := "res://ui/menus/global/my_menu_button.gd"
const BUTTON_FONT_PATH := "res://resources/fonts/actual/base/font_26.tres"  # Back, run options
const LABEL_THEME_PATH := "res://resources/themes/small_label_theme.tres"  # the join hint's
# At least "Invite friends" 174 + the button style's 30, and the status line as wide. A longer
# translation widens the button (its minimum size is its text), the status line follows.
const WIDTH := 260
const BUTTON_TEXT := "BT_INVITE_FRIENDS"  # a translation key: the button translates it
const SEPARATION := 10
const BOTTOM := 50  # space under the status, above the slot's bottom edge

var button := Button.new()
var status := Label.new()


static func add_to(panel: Control) -> Control:
	var existing: Control = panel.get_node_or_null(NODE_NAME)
	if existing != null:
		return existing
	var invite: VBoxContainer = load(
		"res://mods-unpacked/einfluffles-BrotatoTogether/ui/slot_invite.gd"
	).new()
	invite.name = NODE_NAME
	panel.add_child(invite)
	return invite


func _init() -> void:
	visible = false
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_END
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_constant_override("separation", SEPARATION)
	button.set_script(load(BUTTON_SCRIPT_PATH))
	button.name = "InviteButton"
	button.text = BUTTON_TEXT
	button.rect_min_size.x = WIDTH
	# A MyMenuButton takes Godot's focus when the mouse enters it; the focus look then stays.
	button.set("grab_focus_with_mouse", false)
	button.add_font_override("font", load(BUTTON_FONT_PATH))
	add_child(button)
	status.name = "Status"
	status.theme = load(LABEL_THEME_PATH)
	status.align = Label.ALIGN_CENTER
	status.clip_text = true
	status.rect_min_size.x = WIDTH
	status.mouse_filter = Control.MOUSE_FILTER_PASS  # its tooltip has the whole text
	add_child(status)
	var space := Control.new()
	space.rect_min_size.y = BOTTOM
	space.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(space)


func set_status(text: String) -> void:
	if status.text != text:
		status.text = text
		status.hint_tooltip = text
