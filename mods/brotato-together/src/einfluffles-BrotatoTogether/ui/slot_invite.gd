extends VBoxContainer
# Character selection, inside an empty player slot (the game's CoopJoinPanel, "Player N" and the
# hold-to-join hint): "Invite friends" (the Steam overlay's invite dialog) and the lobby status
# under the hint, at the slot's bottom. Shown by ui/coop_mode.gd in the slot the next player
# takes, while hosting online (the status alone after a failed lobby); never on a client.
# The game's own looks: a MyMenuButton in the theme the slot inherits (base_theme: the black
# rounded button, white on hover / focus) with the run options' 26 px font, like the Back button;
# the status in the join hint's label theme (small_label_theme: 26 px).
# Its minimum size (about 205x140) is far below the slot's (370x500): the slot keeps its size.
# The button does not take Godot's focus when the mouse enters it (grab_focus_with_mouse off): a
# MyMenuButton does by default, and the focus look then stayed after the mouse had left. Hover is
# Godot's own (gone when the mouse leaves); keys and pads move player 1's FocusEmulator cursor.

const NODE_NAME := "BrotatoTogetherSlotInvite"
const BUTTON_SCRIPT_PATH := "res://ui/menus/global/my_menu_button.gd"
const BUTTON_FONT_PATH := "res://resources/fonts/actual/base/font_26.tres"  # Back, run options
const LABEL_THEME_PATH := "res://resources/themes/small_label_theme.tres"  # the join hint's
const WIDTH := 260  # "Invite friends" 174 + the button style's 30; status lines up to that
const SEPARATION := 10
const BOTTOM := 50  # space under the status, above the slot's bottom edge

var button := Button.new()
var status := Label.new()


# Into the bottom of `panel` (a CoopJoinPanel), hidden. Its existing one if it has it.
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
	button.text = "Invite friends"
	button.clip_text = true
	button.rect_min_size.x = WIDTH
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
