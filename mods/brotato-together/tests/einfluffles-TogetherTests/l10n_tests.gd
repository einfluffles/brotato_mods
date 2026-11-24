extends Reference
# The mod's texts in the game's languages: translations.csv and its loader (l10n.gd), the game's
# keys the mod reuses, and a language switch on the title screen's lobby frame and lobby page, the
# client view, the pause banner, the options and the damage board (character selection:
# coop_mode_tests.gd).

const L10n := preload("res://mods-unpacked/einfluffles-BrotatoTogether/l10n.gd")
const LobbyPage := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/lobby_page.gd")
const LobbyFrame := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/lobby_frame.gd")
const PauseControl := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/pause_control.gd"
)
const DamageViews := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/damage_views.gd")
const MenuOptionsButton := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/extensions/ui/menu_options.gd"
)
const CLIENT_VIEW_PATH := "res://mods-unpacked/einfluffles-BrotatoTogether/ui/client_view.gd"
const Lifecycle := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/session_lifecycle_tests.gd"
)
const CSV_PATH := "res://mods-unpacked/einfluffles-BrotatoTogether/translations.csv"
const TEST_CSV_PATH := "user://brotato_together_l10n_test.csv"
const HEADER := [
	"key", "en", "fr", "zh", "ja", "ko", "zh_TW", "ru", "pl", "es", "pt", "de", "tr", "it"
]
const PREFIX := "BT_"
# The game's own keys the mod shows: each must have a text in every language of the game.
const VANILLA_KEYS := [
	"MENU_BACK", "COOP_PLAYER", "PAUSE", "RETRY_NUMBER", "STAT_DAMAGE", "WAVE"
]
# The game's Chinese translations name their script; the game's languages zh and zh_TW use them.
const GAME_LOCALES := {"zh": "zh_Hans_CN", "zh_TW": "zh_Hant_TW"}
const LOCAL := 1
const LOBBY := 99
# A folder: the German lobby page and title screen are saved there as PNG (check-window.ps1
# only, the headless run has no image).
const SCREENSHOT_ENV := "TOGETHER_L10N_SCREENSHOTS"

var t: Node = null
var together: Node = null


func run(test_mod: Node, mod: Node):
	t = test_mod
	together = mod
	var rows := _read_csv()
	_test_csv(rows)
	_test_vanilla_keys(rows)
	_test_loader()
	yield(_test_switch(), "completed")
	yield(_test_screens(), "completed")


# [header, row, ...] as the loader reads them.
func _read_csv() -> Array:
	var rows := []
	var file := File.new()
	if file.open(CSV_PATH, File.READ) != OK:
		t._check(false, "l10n: translations.csv is in the mod")
		return rows
	while not file.eof_reached():
		var row := file.get_csv_line()
		if not (row.size() == 1 and row[0] == ""):
			rows.append(Array(row))
	file.close()
	return rows


func _test_csv(rows: Array) -> void:
	if rows.empty():
		return
	t._check(rows[0] == HEADER, "l10n: the CSV header is key and the game's 13 languages")
	var placeholders := RegEx.new()
	placeholders.compile("\\{\\d+\\}")
	var keys := {}
	var problems := []
	var empty_cells := 0
	for row in rows.slice(1, rows.size() - 1):
		var key: String = row[0]
		if row.size() != HEADER.size():
			problems.append("%s: %d cells" % [key, row.size()])
			continue
		if keys.has(key):
			problems.append("%s: twice" % key)
		keys[key] = true
		if not key.begins_with(PREFIX) or key.to_upper() != key or " " in key:
			problems.append("%s: not a %s key" % [key, PREFIX])
		if row[1] == "":
			problems.append("%s: no English text" % key)
		var expected := _placeholders(placeholders, row[1])
		for i in range(2, row.size()):
			if row[i] == "":
				empty_cells += 1
			elif _placeholders(placeholders, row[i]) != expected:
				problems.append("%s/%s: placeholders %s, en has %s" % [
					key, HEADER[i], _placeholders(placeholders, row[i]), expected
				])
	t._check(
		problems.empty(),
		"l10n: %d keys, unique, prefixed, with English, placeholders as in English %s"
		% [keys.size(), problems]
	)
	# Every language filled in is checked once all columns are translated.
	print("  info: l10n: %d empty cells (they show the English text)" % empty_cells)
	var unresolved := []
	for key in keys:
		if tr(key) == key:
			unresolved.append(key)
	t._check(unresolved.empty(), "l10n: the mod loaded every key of its CSV %s" % [unresolved])


static func _placeholders(regex: RegEx, text: String) -> Array:
	var found := []
	for found_one in regex.search_all(text):
		if not found_one.get_string() in found:
			found.append(found_one.get_string())
	found.sort()
	return found


# The game's translations as it ships them, without the mod's.
func _test_vanilla_keys(rows: Array) -> void:
	var game := {}  # locale -> Translation
	for path in ProjectSettings.get_setting("locale/translations"):
		var translation: Translation = load(path)
		if translation != null:
			game[translation.locale] = translation
	var missing := []
	for language in HEADER.slice(1, HEADER.size() - 1):
		var locale: String = GAME_LOCALES.get(language, language)
		if not game.has(locale):
			missing.append(locale)
			continue
		for key in VANILLA_KEYS:
			if game[locale].get_message(key) == "":
				missing.append("%s/%s" % [locale, key])
	t._check(
		missing.empty(), "l10n: the game's keys the mod uses have a text in all 13 languages %s"
		% [missing]
	)
	var taken := []
	for row in rows.slice(1, rows.size() - 1):
		for locale in game:
			if game[locale].get_message(row[0]) != "" and not row[0] in taken:
				taken.append(row[0])
	t._check(taken.empty(), "l10n: no key of the mod is one of the game's %s" % [taken])


# A BOM, a quoted cell with a comma and a line break, empty cells, malformed rows; a missing file.
func _test_loader() -> void:
	var file := File.new()
	if file.open(TEST_CSV_PATH, File.WRITE) != OK:
		t._check(false, "l10n: test CSV written")
		return
	file.store_string(
		char(0xFEFF) + "key,en,de,zh,zh_TW\n"
		+ "L10N_TEST_PLAIN,Plain,Schlicht,简单,\n"
		+ "L10N_TEST_QUOTED,\"One, two\",\"Eins,\nzwei\",,\n"
		+ ",no key,,,\n"
		+ "L10N_TEST_SHORT,only two\n"
	)
	file.close()
	var keys := L10n.load_csv(TEST_CSV_PATH)
	var saved := TranslationServer.get_locale()
	var got := {}
	for locale in ["de", "zh", "zh_TW", "fr"]:
		TranslationServer.set_locale(locale)
		got[locale] = [tr("L10N_TEST_PLAIN"), tr("L10N_TEST_QUOTED"), tr("L10N_TEST_SHORT")]
	TranslationServer.set_locale(saved)
	Directory.new().remove(TEST_CSV_PATH)
	var expected := {
		"de": ["Schlicht", "Eins,\nzwei", "L10N_TEST_SHORT"],
		"zh": ["简单", "One, two", "L10N_TEST_SHORT"],
		"zh_TW": ["简单", "One, two", "L10N_TEST_SHORT"],
		"fr": ["Plain", "One, two", "L10N_TEST_SHORT"],
	}
	t._check(
		keys == 2 and str(got) == str(expected),
		"l10n: the loader reads quoted cells, falls back for empty ones, skips malformed rows"
		+ " (%d keys, %s)" % [keys, got]
	)
	t._check(
		L10n.load_csv("user://no_such_file.csv") == 0, "l10n: no file, no keys (and a warning)"
	)


# The title screen in a lobby this game hosts, with the lobby page over it, from en to de.
func _test_switch():
	var transport: Node = together.transport
	var lobby: Node = together.get_node("LobbyMenu")
	var saved := {
		"steam": transport.steam,
		"local_id": transport.local_id,
		"language": ProgressData.settings.get("language"),
		"locale": TranslationServer.get_locale(),
	}
	transport.steam = Lifecycle.FakeSteam.new()
	transport.local_id = LOCAL
	ProgressData.change_language("en")
	var tree := t.get_tree()
	tree.paused = false
	tree.change_scene(MenuData.title_screen_scene)
	yield(_frames(3), "completed")  # loaded, and seen by LobbyMenu
	var scene := tree.current_scene
	var frame: Control = scene.find_node(LobbyFrame.NODE_NAME, true, false)
	t._check(frame != null, "l10n: the title screen has the lobby frame")
	if frame == null:
		_restore(saved)
		return
	lobby.host()
	transport._on_lobby_created(transport.RESULT_OK, LOBBY)
	var page: Control = LobbyPage.new()
	page.lobby = lobby
	page.framed = true
	scene.add_child(page)
	page.init()
	yield(_frames(2), "completed")
	var english := _shown(frame, page)

	ProgressData.change_language("de")
	yield(_frames(2), "completed")
	var german := _shown(frame, page)
	var same := []
	for name in english:
		if german.get(name) == english[name]:
			same.append(name)
	t._check(
		english.size() >= 9 and german.size() == english.size() and same.empty(),
		"l10n: the frame and the page change language at once (unchanged: %s; de: %s)"
		% [same, german.values()]
	)
	var raw := []
	for name in german:
		if PREFIX in german[name] or "{" in german[name]:
			raw.append(german[name])
	t._check(raw.empty(), "l10n: no key or placeholder shows %s" % [raw])
	var entry: Button = frame.entry_button
	var entry_text := entry.text
	var widest := 0.0
	for key in [frame.CREATING_TEXT, frame.INVITE_TEXT, frame.LEAVE_TEXT, frame.HOST_TEXT]:
		entry.text = key
		widest = max(widest, entry.get_minimum_size().x)
	entry.text = entry_text
	t._check(
		entry.rect_min_size.x >= widest,
		"l10n: the main menu's button fits its German texts (%d, widest %d)"
		% [entry.rect_min_size.x, widest]
	)
	var folder := OS.get_environment(SCREENSHOT_ENV)
	if folder != "":
		yield(_screenshot(folder.plus_file("l10n_de_page.png")), "completed")
		page.visible = false
		yield(_screenshot(folder.plus_file("l10n_de_title.png")), "completed")
	page.queue_free()
	transport.leave_lobby()
	_restore(saved)
	yield(_frames(2), "completed")


# On the title screen: the client view, the pause banner, the options' switch and the damage
# board (the solo stats tab, the run's board with kills, damage taken and the other row).
func _test_screens():
	var saved := {
		"language": ProgressData.settings.get("language"),
		"locale": TranslationServer.get_locale(),
		"steam": together.transport.steam,
		"local_id": together.transport.local_id,
	}
	ProgressData.change_language("en")
	var tree := t.get_tree()
	var scene := tree.current_scene
	var view: Control = load(CLIENT_VIEW_PATH).new()
	view.session = together.session
	scene.add_child(view)
	view.show_menu({"kind": "title_screen"})
	PauseControl.show_banner(scene, true, PauseControl.banner_line("", 0, 0))
	var options: Node = load("res://ui/menus/pages/menu_options.tscn").instance()
	scene.add_child(options)
	var meter: Node = together.damage_meter
	var board: Dictionary = meter.board.duplicate(true)
	var run := {"waves": 3, "time": 60.0, "players": [[150, [], [40, ""], 12, 34]]}
	meter.apply_state(0, {"wave": 3, "players": [[50, []]], "run": run}, 0)
	var stats: Node = load("res://ui/menus/shop/stats_container.tscn").instance()
	scene.add_child(stats)
	together.get_node("DamageViews").add_tab(stats, true)
	yield(_frames(2), "completed")
	var english := _screen_texts(view, scene, options, stats)

	ProgressData.change_language("de")
	yield(_frames(2), "completed")
	var german := _screen_texts(view, scene, options, stats)
	var wrong := []
	for name in english:
		if german.get(name) == english[name] or PREFIX in german[name] or "{" in german[name]:
			wrong.append(name)
	t._check(
		english.size() == 9 and wrong.empty(),
		"l10n: client view, pause banner, options and damage board change language at once"
		+ " (unchanged or raw: %s; de: %s)" % [wrong, german.values()]
	)
	var font: Font = view._status.get_font("font")
	t._check(
		view.theme != null and font is DynamicFont and font.get_fallback_count() > 0,
		"l10n: the client view uses the game's fonts, with the CJK fallbacks"
	)
	var folder := OS.get_environment(SCREENSHOT_ENV)
	var banner: CanvasLayer = scene.get_node(PauseControl.BANNER_NAME)
	if folder != "":
		options.visible = false
		stats.visible = false
		yield(_screenshot(folder.plus_file("l10n_de_pause.png")), "completed")
		banner.visible = false
		yield(_screenshot(folder.plus_file("l10n_de_client_view.png")), "completed")
		view.visible = false
		stats.visible = true
		stats.update_tab(stats.BT_TAB)  # the damage board, not the (empty) game stats
		yield(_screenshot(folder.plus_file("l10n_de_damage.png")), "completed")
	for node in [view, options, stats, banner]:
		node.queue_free()
	if board.empty():
		meter.clear_state(0)
	else:
		meter.apply_state(0, board, 0)
	_restore(saved)
	yield(_frames(2), "completed")


# name -> the text shown.
func _screen_texts(view: Control, scene: Node, options: Node, stats: Node) -> Dictionary:
	var banner: Node = scene.get_node(PauseControl.BANNER_NAME)
	var toggle: Button = options.boss_hp_bar_button.get_parent().get_node_or_null(
		MenuOptionsButton.BUTTON_NAME
	)
	var page: Node = stats._secondary_stats.get_parent().get_node(DamageViews.PAGE_NAME)
	var head: Node = page.get_child(0).get_node("Head")
	var other: Node = page.get_child(0).get_node("Sources/" + DamageViews.OTHER_ROW)
	return {
		"client title": tr(view._title.text),
		"client status": view._status.text,
		"pause": PauseControl.banner_label(banner).text,
		"options": tr(toggle.text) if toggle != null else "",
		"damage tab": tr(stats._bt_button.hint_tooltip),
		"damage title": head.get_node("Wave").text,
		"damage kills": head.get_node("Extra/Kills").text,
		"damage taken": head.get_node("Extra/Taken").text,
		"damage other": tr(other.get_node("Content/Name").text) if other.visible else "",
	}


func _screenshot(path: String):
	yield(_frames(5), "completed")
	yield(VisualServer, "frame_post_draw")
	var image := t.get_viewport().get_texture().get_data()
	image.flip_y()
	var saved := image.save_png(path)
	t._check(saved == OK, "l10n: screenshot %s (%s)" % [path, saved])


# name -> the text shown (a control translates a key in its text itself).
func _shown(frame: Control, page: Control) -> Dictionary:
	var shown := {
		"frame title": tr(LobbyFrame.TITLE),
		"entry button": tr(frame.entry_button.text),
		"frame hint": frame.hint.text,
		"frame note": frame.rows[0].note.text if not frame.rows.empty() else "",
		"leave button": tr(frame.leave_button.text),
		"page details": page._details.text,
	}
	for button in page.nav_buttons():
		shown["page " + button.text] = tr(button.text)
	for label in _labels(page):
		if label.text == LobbyPage.TITLE:
			shown["page title"] = tr(label.text)
	return shown


static func _labels(node: Node) -> Array:
	var found := []
	for child in node.get_children():
		if child is Label:
			found.append(child)
		found += _labels(child)
	return found


func _restore(saved: Dictionary) -> void:
	together.transport.steam = saved.steam
	together.transport.local_id = saved.local_id
	ProgressData.settings["language"] = saved.language
	TranslationServer.set_locale(saved.locale)


func _frames(count: int):
	for _i in count:
		yield(t.get_tree(), "idle_frame")
