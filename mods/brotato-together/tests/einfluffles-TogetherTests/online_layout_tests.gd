extends Reference
# The mod's panel at the top right of the host's co-op character selection (ui/top_bar.gd): the
# colour hint (ui/coop_selection.gd) and the Online toggle, Invite friends and the lobby status
# (ui/online_options.gd).
#  - Layout: the player panels and the character grid get the same rects as without the online
#    controls (a client's copy, vanilla co-op), the grid scrolls no further, the controls are on
#    screen and cover nothing.
#  - Look: one panel with the DLC bar's style, top and strip (with the Back button); the hint and
#    the online controls in one font, one height and on one line; clear of the title.
# Checked at the viewport sizes of the colour hint's check (coop_selection_tests.gd), in the worst
# case: hosting, with a long status line. How the cursor reaches them: lobby_menu_tests.gd.
# Run from coop_selection_tests.gd on the host's co-op character selection (no Steam).

# coop_selection_tests.gd preloads this file: loaded when used (no cyclic preload).
const HELPERS_PATH := "res://mods-unpacked/einfluffles-TogetherTests/coop_selection_tests.gd"
const CoopSelection := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/coop_selection.gd"
)
const OnlineOptions := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/online_options.gd"
)
const TopBar := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/top_bar.gd")
# Status lines the row must hold without growing: the longest count, an error, and a long text
# like a translation or Steam's error message would be.
const STATUSES := [
	"Online: 4 players",
	"! createLobby failed",
	"Online: a much longer status line than any of the mod's own, as a translation could be",
]
const MIN_TITLE_GAP := 5.0  # between the panel and the title label (its letters start ~9 px lower)
const ROUNDING := 1.0  # px: the 1920x1200 layout is scaled by a fraction

var t: Node = null  # the test mod: _check()
var helpers = null  # coop_selection_tests.gd: SIZES, _layout_rects(), _neighbours()


func run(test_mod: Node, scene: Node):
	t = test_mod
	helpers = load(HELPERS_PATH)
	var options: Control = scene.find_node(OnlineOptions.NODE_NAME, true, false)
	var bar: Control = scene.get_node_or_null(TopBar.NODE_NAME)
	t._check(
		options != null and options.visible and bar != null and bar.is_a_parent_of(options),
		"online options (host): shown, in the top bar"
	)
	if options == null or bar == null:
		yield(_frames(1), "completed")
		return
	t._check(
		not scene.get_node("MarginContainer").is_a_parent_of(bar),
		"online options (host): outside the game's layout containers"
	)
	options.set_process(false)  # it sets what it shows every frame
	options._invite.disabled = false  # hosting
	var dlc: Node = scene.get_node_or_null("%ItemSetBar")  # as co-op lays it out, see the hint's
	var vertical: bool = dlc != null and not dlc._horizontal
	if vertical:
		dlc.set_horizontal(true)
	var base := Vector2(
		ProjectSettings.get_setting("display/window/size/width"),
		ProjectSettings.get_setting("display/window/size/height")
	)
	var failures := []
	var look := []
	var skipped := []
	for size in helpers.SIZES:
		for status in STATUSES:
			options._status.text = status
			helpers._stretch_tree(t.get_tree(), size)
			options.visible = false
			yield(_frames(3), "completed")
			var vanilla: Dictionary = helpers._layout_rects(scene)
			options.visible = true
			yield(_frames(3), "completed")
			var shown: Dictionary = helpers._layout_rects(scene)
			var at := "%dx%d, %s" % [size.x, size.y, status]
			if shown.rects != vanilla.rects:
				failures.append("%s: layout moved (%s vs %s)" % [at, shown.rects, vanilla.rects])
			if shown.scroll > vanilla.scroll:
				failures.append(
					"%s: grid scrolls %d instead of %d" % [at, shown.scroll, vanilla.scroll]
				)
			if _wide_enough(size):
				failures += _overlaps(scene, bar, options, at)
				look += _look(scene, bar, options, at)
			elif not size in skipped:
				skipped.append(size)
	helpers._stretch_tree(t.get_tree(), base)
	options._status.text = STATUSES[0]
	yield(_frames(3), "completed")
	var cut := []
	for control in [options._toggle, options._invite, options._status]:
		var room := text_room(control)
		var text: Vector2 = control.get_font("font").get_string_size(control.text)
		if text.x > room.x or text.y > room.y:
			cut.append("%s %s in %s" % [control.text, text, room])
	t._check(cut.empty(), "online options (host): texts shown whole %s" % [cut])
	_print_rects(scene, bar, options, dlc, base)
	if vertical:
		dlc.set_horizontal(false)
	options._update()
	options.set_process(true)
	yield(_frames(3), "completed")
	if not skipped.empty():
		print(
			"  info: online options: at %s the game's layout is wider than the screen;"
			% [skipped] + " only the layout compared there"
		)
	t._check(
		failures.empty(),
		"online options (host): same layout, no extra grid scrolling, on screen, covers nothing,"
		+ " at %s %s" % [helpers.SIZES, failures]
	)
	t._check(
		look.empty(),
		"top bar: the DLC bar's style, top and strip; colour hint and online controls in one"
		+ " font, height and line; %s px or more above the title %s" % [MIN_TITLE_GAP, look]
	)


func _frames(count: int):
	for _i in count:
		yield(t.get_tree(), "idle_frame")


# The space a button's / label's text has: its size less the style's margins (and a toggle's
# switch icon at the button's height).
static func text_room(control: Control) -> Vector2:
	var style: StyleBox = control.get_stylebox("normal")
	var room: Vector2 = control.rect_size - style.get_minimum_size()
	if control is Button and control.icon != null:
		var icon: Vector2 = control.icon.get_size()
		room.x -= icon.x * room.y / icon.y + control.get_constant("hseparation")
	return room


# The game lays out a 1920 px wide screen and stretches it to any window (2d / keep). Narrower
# layouts (1280x720 here) have no room left of the colour hint: its own row of panels (1859 px)
# runs off screen there too.
static func _wide_enough(size: Vector2) -> bool:
	return size.x >= ProjectSettings.get_setting("display/window/size/width")


# The panel and its visible parts: on screen, the parts apart from each other, none of them over
# the screen's other parts (title, Back, DLC bar, run options box, player panels).
func _overlaps(scene: Node, bar: Control, options: Control, at: String) -> Array:
	var failures := []
	var screen: Rect2 = scene.get_viewport().get_visible_rect()
	var others: Array = helpers._neighbours(scene)
	var hint: Control = scene.find_node(CoopSelection.COLOR_HINT, true, false)
	var controls := []
	for control in [options._toggle, options._invite, options._status, hint]:
		if control != null and control.is_visible_in_tree():
			controls.append(control)
	if controls.size() != 4:
		failures.append("%s: %d of 4 parts shown" % [at, controls.size()])
	for i in controls.size():
		var rect: Rect2 = controls[i].get_global_rect()
		var name: String = controls[i].name
		if not screen.encloses(rect):
			failures.append("%s: %s %s off screen" % [at, name, rect])
		for other in others + controls:
			if other == controls[i] or not other.is_visible_in_tree():
				continue
			if other in controls and controls.find(other) < i:  # that pair was checked already
				continue
			if rect.intersects(other.get_global_rect()):
				failures.append(
					"%s: %s %s over %s %s" % [at, name, rect, other.name, other.get_global_rect()]
				)
	var panel: Rect2 = bar.get_global_rect()
	if not screen.encloses(panel):
		failures.append("%s: top bar %s off screen" % [at, panel])
	for other in others:
		if other.is_visible_in_tree() and panel.intersects(other.get_global_rect()):
			failures.append(
				"%s: top bar %s over %s %s" % [at, panel, other.name, other.get_global_rect()]
			)
	return failures


# One element: the DLC bar's panel style and top, within the strip of the Back button and the DLC
# bar, clear of the title; the colour hint and the online controls in one font, one height, one
# centre line, a separator between them.
func _look(scene: Node, bar: Control, options: Control, at: String) -> Array:
	var failures := []
	var panel: Rect2 = bar.get_global_rect()
	var back: Rect2 = scene.get_node("BackButton").get_global_rect()
	var dlc: Control = scene.get_node_or_null("%ItemSetBar/Panel")
	if dlc == null or not dlc.is_visible_in_tree():
		failures.append("%s: no DLC bar to compare with" % at)
		return failures
	var strip: Rect2 = dlc.get_global_rect().merge(back)
	if bar.get_stylebox("panel") != dlc.get_stylebox("panel"):
		failures.append("%s: not the DLC bar's panel style" % at)
	if abs(panel.position.y - dlc.get_global_rect().position.y) > ROUNDING:
		failures.append("%s: top %s, the DLC bar's %s" % [at, panel, dlc.get_global_rect()])
	if panel.position.y < strip.position.y or panel.end.y > strip.end.y:
		failures.append("%s: %s outside the strip of Back / DLC bar %s" % [at, panel, strip])
	var title: Rect2 = scene.get_node("MarginContainer/VBoxContainer/Title").get_global_rect()
	if title.position.y - panel.end.y < MIN_TITLE_GAP:
		failures.append("%s: %s ends %s px above the title %s" % [
			at, panel, title.position.y - panel.end.y, title
		])
	var hint: Control = scene.find_node(CoopSelection.COLOR_HINT, true, false)
	var parts := [options._toggle, options._invite, options._status]
	for child in hint.get_children():
		parts.append(child)
	var line: float = options._toggle.get_global_rect().get_center().y
	for part in parts:
		var rect: Rect2 = part.get_global_rect()
		if abs(rect.get_center().y - line) > ROUNDING:
			failures.append("%s: %s centred at %s, not %s" % [at, part.name, rect, line])
		if (part is Label or part is Button) and part.get_font("font") != TopBar.font():
			failures.append("%s: %s in another font" % [at, part.name])
	for part in [options._toggle, options._invite, hint]:
		if abs(part.rect_size.y - TopBar.CONTROL_HEIGHT) > ROUNDING:
			failures.append("%s: %s %s high, not %d" % [
				at, part.name, part.rect_size.y, TopBar.CONTROL_HEIGHT
			])
	var separator: Control = bar._separator
	var between: bool = (
		separator.is_visible_in_tree()
		and separator.get_global_rect().position.x >= hint.get_global_rect().end.x
		and separator.get_global_rect().end.x <= options.get_global_rect().position.x
	)
	if not between:
		failures.append("%s: no separator between the colour hint and the online controls" % at)
	return failures


func _print_rects(scene: Node, bar: Control, options: Control, dlc: Node, base: Vector2) -> void:
	var hint: Control = scene.find_node(CoopSelection.COLOR_HINT, true, false)
	var dlc_panel: Control = dlc.get_node("Panel") if dlc != null else null
	var title: Control = scene.get_node("MarginContainer/VBoxContainer/Title")
	print(
		"  info: top bar at %s: panel %s (%s), colour hint %s, Online %s, Invite friends %s,"
		% [base, bar.get_global_rect(), bar.get_stylebox("panel").resource_path,
		hint.get_global_rect(), options._toggle.get_global_rect(),
		options._invite.get_global_rect()]
		+ " status %s; Back %s, DLC bar %s, title %s"
		% [options._status.get_global_rect(), scene.get_node("BackButton").get_global_rect(),
		dlc_panel.get_global_rect() if dlc_panel != null else null, title.get_global_rect()]
	)
