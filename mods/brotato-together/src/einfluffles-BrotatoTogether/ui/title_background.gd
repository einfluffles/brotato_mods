extends Control
# The title screen's animated key art behind the client's waiting screen, so a client in the
# host's lobby sees Brotato rather than a blank screen. Follows the client's own key-art setting
# (ProgressData.settings.main_screen_keyart: 0 = newest available, 1 = random, n = fixed), dimmed
# like the game's menu pages so the status text and player cards stay readable.

const DIM := Color(0, 0, 0, 0.6)


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = MOUSE_FILTER_IGNORE
	var art = _pick_key_art()
	if art != null and art.get("scene") is PackedScene:
		var scene: Node = art.scene.instance()
		add_child(scene)
	else:
		var plain := ColorRect.new()  # no key art registered (headless / modded): plain backdrop
		plain.color = Color(0.08, 0.08, 0.1)
		plain.anchor_right = 1.0
		plain.anchor_bottom = 1.0
		add_child(plain)
	var dim := ColorRect.new()
	dim.color = DIM
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(dim)


static func _pick_key_art():
	var arts: Array = ItemService.title_screen_backgrounds
	if arts.empty():
		return null
	var mode := int(ProgressData.settings.get("main_screen_keyart", 0))
	if mode == 1:
		return arts[randi() % arts.size()]
	if mode >= 2 and mode - 2 < arts.size():
		return arts[mode - 2]
	var newest = null  # mode 0: highest priority among the currently available ones
	for art in arts:
		if art.has_method("is_available") and not art.is_available():
			continue
		if newest == null or int(art.index_priority) > int(newest.index_priority):
			newest = art
	return newest if newest != null else arts[0]
