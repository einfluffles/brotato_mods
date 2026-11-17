extends Reference
# The Online toggle, Invite friends and the lobby status of the host's character selection
# (ui/online_options.gd) take no space in the game's layout: the player panels and the character
# grid get the same rects as without them (a client's copy, vanilla co-op), the grid scrolls no
# further, and the three controls are on screen and cover nothing. Checked at the viewport sizes
# of the colour hint's check (coop_selection_tests.gd), in the worst case: hosting (Invite friends
# shown), with a long status line. How the cursor reaches them: lobby_menu_tests.gd.
# Run from coop_selection_tests.gd on the host's co-op character selection (no Steam).

# coop_selection_tests.gd preloads this file: loaded when used (no cyclic preload).
const HELPERS_PATH := "res://mods-unpacked/einfluffles-TogetherTests/coop_selection_tests.gd"
const CoopSelection := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/coop_selection.gd"
)
const OnlineOptions := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/online_options.gd"
)
# Status lines the row must hold without growing: the longest count, an error, and a long text
# like a translation or Steam's error message would be.
const STATUSES := [
	"Online: 4 players",
	"! createLobby failed",
	"Online: a much longer status line than any of the mod's own, as a translation could be",
]

var t: Node = null  # the test mod: _check()
var helpers = null  # coop_selection_tests.gd: SIZES, _layout_rects(), _neighbours()


func run(test_mod: Node, scene: Node):
	t = test_mod
	helpers = load(HELPERS_PATH)
	var options: Control = scene.find_node(OnlineOptions.NODE_NAME, true, false)
	t._check(options != null and options.visible, "online options (host): shown")
	if options == null:
		yield(_frames(1), "completed")
		return
	var layout: Control = scene.get_node("MarginContainer")
	t._check(
		not layout.is_a_parent_of(options),
		"online options (host): outside the game's layout containers"
	)
	options.set_process(false)  # it sets what it shows every frame
	options._invite.visible = true
	options._status.visible = true
	var bar: Node = scene.get_node_or_null("%ItemSetBar")  # as co-op lays it out, see the hint's
	var vertical: bool = bar != null and not bar._horizontal
	if vertical:
		bar.set_horizontal(true)
	var base := Vector2(
		ProjectSettings.get_setting("display/window/size/width"),
		ProjectSettings.get_setting("display/window/size/height")
	)
	var failures := []
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
				failures += _overlaps(scene, options, at)
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
	var hint: Control = scene.find_node(CoopSelection.COLOR_HINT, true, false)
	var bar_panel: Control = bar.get_node("Panel") if bar != null else null
	print(
		"  info: online options at %s: row %s, colour hint %s, DLC bar %s"
		% [base, options.get_global_rect(), hint.get_global_rect() if hint != null else null,
		bar_panel.get_global_rect() if bar_panel != null else null]
	)
	if vertical:
		bar.set_horizontal(false)
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


func _frames(count: int):
	for _i in count:
		yield(t.get_tree(), "idle_frame")


# The space a button's / label's text has: its size less the style's margins (and a toggle's
# switch icon).
static func text_room(control: Control) -> Vector2:
	var style: StyleBox = control.get_stylebox("normal")
	var room: Vector2 = control.rect_size - style.get_minimum_size()
	if control is CheckButton:
		room.x -= control.get_icon("off").get_width() + control.get_constant("hseparation")
	return room


# The game lays out a 1920 px wide screen and stretches it to any window (2d / keep). Narrower
# layouts (1280x720 here) have no room left of the colour hint: its own row of panels (1859 px)
# runs off screen there too.
static func _wide_enough(size: Vector2) -> bool:
	return size.x >= ProjectSettings.get_setting("display/window/size/width")


# The visible online controls: on screen, apart from each other, over none of the screen's other
# parts (title, Back, DLC bar, run options box, player panels, colour hint).
func _overlaps(scene: Node, options: Control, at: String) -> Array:
	var failures := []
	var screen: Rect2 = scene.get_viewport().get_visible_rect()
	var others: Array = helpers._neighbours(scene)
	var hint: Control = scene.find_node(CoopSelection.COLOR_HINT, true, false)
	if hint != null:
		others.append(hint)
	var controls := []
	for control in [options._toggle, options._invite, options._status]:
		if control.is_visible_in_tree():
			controls.append(control)
	if controls.size() != 3:
		failures.append("%s: %d of 3 controls shown" % [at, controls.size()])
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
	return failures
