extends Reference
# A player's open menu on its panel, so every machine shows it: the item popup the game focuses
# on accept on a gear weapon (its buttons, or the meca upgrade's two options), and what other
# mods open in that popup or on the panel. Shop and level-up / crate panels alike.
#
# View (wire format): [] when nothing is open, else [element, id, meca, mods]
#   element  the gear element the popup was opened from, a ui/focus_targets.gd target in the
#            player's own panel ([]: none, a mod opened the popup on something else)
#   id       that element's item my_id ("": none)
#   meca     1 while the popup shows the meca upgrade's options, else 0
#   mods     [popup's menu, panel's menu]: what together_menu() returns on the popup and on the
#            panel (null: none). A mod that opens a menu there defines both methods:
#              together_menu() -> null | a non-empty Array of ints and strings (at most
#                MAX_MENU_BYTES)
#              together_show_menu(menu) shows that menu on a copy of the panel (null: closes it)

const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const MecaChoice := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/meca_choice.gd")
const VIEW_SIZE := 4
const MAX_MENU_BYTES := 256
const MAX_ID := 128


# The view of player p's panel. root: the shop or the UpgradesUI (where the targets start).
static func describe(root: Node, manager: Node, popup: Node, panel: Node, p: int) -> Array:
	var mods := [_menu(popup), _menu(panel)]
	var element = manager._elements_pressed[p] if popup._focused else null
	var target := []
	var id := ""
	if element != null and is_instance_valid(element) and element.get("item") != null:
		target = FocusTargets.describe(element, root, p)
		id = element.item.my_id if not target.empty() else ""
	if target.empty() and mods == [null, null]:
		return []
	var meca: int = 1 if not target.empty() and popup.is_choosing_meca_upgrade() else 0
	return [target, id, meca, mods]


# Shows view on a copy of player p's panel with the game's own code: a press on the element, the
# meca choice (rolls: the host's MecaChoice entries for p; null on the host, which shows the roll
# its popup keeps), then the mods' menus. memo (p -> [view, what it led to]) keeps a view this
# machine cannot show from being tried again and again. True when the panel changed.
static func apply(
	root: Node, manager: Node, popup: Node, panel: Node, p: int, view, rolls, memo: Dictionary
) -> bool:
	var wanted := parse(view)
	var current := describe(root, manager, popup, panel, p)
	if var2str(current) == var2str(wanted):
		# A popup left focused or a panel left dimmed with nothing open (the game hid the popup
		# under a cursor move) counts as open.
		if not current.empty() or not (popup._focused or _dimmed(panel)):
			return false
		var before = _focus_owner(root)
		_close(root, manager, popup, panel, p)
		_give_focus_back(root, before)
		return true
	var element = _element(wanted, root, p)
	# A roll that arrives later makes the meca choice showable, an element that shows later (its
	# carousel page, a gear rebuild) the popup.
	var rolled = rolls if rolls != null else MecaChoice.entries(popup, p)
	var key := var2str([wanted, rolled, element != null])
	var last = memo.get(p)
	if last != null and last == [key, var2str(current)]:
		return false
	var focus_before = _focus_owner(root)
	var mods: Array = wanted[3] if not wanted.empty() else [null, null]
	var holders := [popup, panel]
	var current_mods: Array = current[3] if not current.empty() else [null, null]
	for i in holders.size():
		if current_mods[i] != null and var2str(current_mods[i]) != var2str(mods[i]):
			if holders[i].has_method("together_show_menu"):
				holders[i].together_show_menu(null)
	var open_on = manager._elements_pressed[p] if popup._focused else null
	if popup._focused and (element == null or open_on != element):
		_close(root, manager, popup, panel, p)
	elif popup.is_choosing_meca_upgrade() and (wanted.empty() or wanted[2] == 0):
		popup._update_button_visibilities()  # back to the buttons, as on a pick
	if element != null and not popup._focused:
		# The cursor on the element first, as for the player's own press: leaving a shop item
		# would hide the popup the press opens.
		var emulator = Utils.get_focus_emulator(p, root)
		if emulator != null and emulator.focused_control != element:
			emulator.focused_control = element
		FocusEmulatorSignal.emit(element, "pressed", p)  # the game's press: PopupManager opens it
	if element != null and popup._focused and wanted[2] == 1 and not popup.is_choosing_meca_upgrade():
		if rolls == null:
			MecaChoice.show_kept(popup)
		else:
			var entry := MecaChoice.entry_of(MecaChoice.parse(rolls), popup._item_data, p)
			if not entry.empty():
				MecaChoice.show_roll(popup, popup._item_data, p, entry)
	current = describe(root, manager, popup, panel, p)
	current_mods = current[3] if not current.empty() else [null, null]
	for i in holders.size():
		if mods[i] != null and var2str(current_mods[i]) != var2str(mods[i]):
			if holders[i].has_method("together_show_menu"):
				holders[i].together_show_menu(mods[i])
	_give_focus_back(root, focus_before)
	memo[p] = [key, var2str(describe(root, manager, popup, panel, p))]
	return true


# Network data: a malformed view is [] (nothing open).
static func parse(view) -> Array:
	if typeof(view) != TYPE_ARRAY or view.size() != VIEW_SIZE:
		return []
	if typeof(view[0]) != TYPE_ARRAY or typeof(view[1]) != TYPE_STRING or view[1].length() > MAX_ID:
		return []
	if not view[0].empty() and not FocusTargets.is_valid(view[0]):
		return []
	if typeof(view[2]) != TYPE_INT or (view[2] != 0 and view[2] != 1):
		return []
	if typeof(view[3]) != TYPE_ARRAY or view[3].size() != 2:
		return []
	for menu in view[3]:
		if menu != null and not _is_menu(menu):
			return []
	if view[0].empty() and view[3] == [null, null]:
		return []
	return view


# The gear element the view names, when it shows here with the item the view names; else null.
static func _element(view: Array, root: Node, p: int):
	if view.empty() or view[0].empty():
		return null
	var element = FocusTargets.resolve(view[0], root, p)
	if not element is InventoryElement or not element.is_visible_in_tree():
		return null
	if element.item == null or element.item.get("my_id") != view[1]:
		return null
	return element


# The press runs ItemPopup.focus(), whose grab_focus hands Godot's focus to that player's
# FocusEmulator, which releases it (the meca choice and the mods' menus grab it too). A control
# that held it before is one no emulator takes, such as the lobby popup's buttons (they move by
# Godot's focus): it gets the focus back.
static func _give_focus_back(root: Node, before) -> void:
	if not is_instance_valid(before) or not before is Control or before.is_queued_for_deletion():
		return
	if _focus_owner(root) == before or not before.is_visible_in_tree():
		return
	if before.focus_mode != Control.FOCUS_NONE:
		before.grab_focus()


static func _focus_owner(root: Node):
	return root.get_focus_owner() if root is Control else null


# The view half of the game's Cancel without its deferred grab_focus, which would land after the
# mirrored cursor: the popup closes, the panel is no longer dimmed, and a cursor left on a hidden
# button goes back to the element.
static func _close(root: Node, manager: Node, popup: Node, panel: Node, p: int) -> void:
	var pressed = manager._elements_pressed[p]
	manager.reset_focus(p)
	if popup.visible or popup._focused:
		popup.hide()
	if panel.has_method("on_hide_focused_inventory_popup"):
		panel.on_hide_focused_inventory_popup()
	var emulator = Utils.get_focus_emulator(p, root)
	if emulator == null or not is_instance_valid(pressed) or pressed.is_queued_for_deletion():
		return
	var cursor = emulator.focused_control
	var lost: bool = cursor == null or not is_instance_valid(cursor) or not cursor.is_visible_in_tree()
	if lost and pressed.is_visible_in_tree():
		emulator.focused_control = pressed


static func _dimmed(panel: Node) -> bool:
	var dim = panel.get("_popup_dim_screen")
	return dim is Control and dim.visible


static func _menu(holder: Node):
	if holder == null or not holder.has_method("together_menu"):
		return null
	var menu = holder.together_menu()
	return menu if menu != null and _is_menu(menu) else null


static func _is_menu(menu) -> bool:
	if typeof(menu) != TYPE_ARRAY or menu.empty() or var2bytes(menu).size() > MAX_MENU_BYTES:
		return false
	for value in menu:
		if typeof(value) != TYPE_INT and typeof(value) != TYPE_STRING:
			return false
	return true
