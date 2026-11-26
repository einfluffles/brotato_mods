extends Reference
# What the language tests check in every language of the game: the glyphs of translations.csv in
# the game's fonts, and texts that fit (no clipped text, nothing past the screen, the places that
# keep their width keep it). Used by l10n_tests.gd and coop_mode_tests.gd.

const L10n := preload("res://mods-unpacked/einfluffles-BrotatoTogether/l10n.gd")
const CSV_PATH := "res://mods-unpacked/einfluffles-BrotatoTogether/translations.csv"
const MOD_DIR := "res://mods-unpacked/einfluffles-BrotatoTogether/"
# The game's languages in its order (translations.csv's columns).
const LOCALES := ["en", "fr", "zh", "ja", "ko", "zh_TW", "ru", "pl", "es", "pt", "de", "tr", "it"]
# A folder: screenshots of these languages are saved there (check-window.ps1 only).
const SCREENSHOT_ENV := "TOGETHER_L10N_SCREENSHOTS"
const SCREENSHOT_LOCALES := ["de", "ru", "ja", "zh"]
const SLACK := 1.0  # px: rounding


# key -> {locale: text}, read as the mod's loader reads it (no File.get_csv_line: l10n.gd).
static func read_csv() -> Dictionary:
	var texts := {}
	var file := File.new()
	if file.open(CSV_PATH, File.READ) != OK:
		return texts
	var rows := L10n.parse_csv(file.get_buffer(file.get_len()).get_string_from_utf8())
	if rows.empty():
		return texts
	var header: Array = rows[0]
	for r in range(1, rows.size()):
		var row: Array = rows[r]
		if row.size() != header.size():
			continue
		var cells := {}
		for i in range(1, header.size()):
			cells[header[i]] = row[i]
		texts[row[0]] = cells
	file.close()
	return texts


# Every font file and theme the mod's scripts load: name -> Font (a theme: its default font).
static func source_fonts() -> Dictionary:
	var regex := RegEx.new()
	regex.compile("\"(res://resources/(fonts|themes)/[^\"]+\\.tres)\"")
	var fonts := {}
	for path in _scripts(MOD_DIR):
		var file := File.new()
		file.open(path, File.READ)
		for hit in regex.search_all(file.get_as_text()):
			var resource = load(hit.get_string(1))
			if resource is Theme:
				resource = resource.default_font
			if resource is Font:
				fonts[hit.get_string(1).get_file()] = resource
		file.close()
	return fonts


static func _scripts(dir_path: String) -> Array:
	var found := []
	var dir := Directory.new()
	if dir.open(dir_path) != OK:
		return found
	dir.list_dir_begin(true, true)
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			found += _scripts(dir_path.plus_file(entry))
		elif entry.ends_with(".gd"):
			found.append(dir_path.plus_file(entry))
		entry = dir.get_next()
	dir.list_dir_end()
	return found


# "font: KEY/locale 'c'" for each character of a text no glyph of the font (with its Noto Sans CJK
# fallbacks) draws: it would show as a box. fonts: name -> Font.
static func missing_glyphs(fonts: Dictionary, texts: Dictionary) -> Array:
	var placeholders := RegEx.new()
	placeholders.compile("\\{\\d+\\}")
	var used := {}  # character -> the first KEY/locale with it
	for key in texts:
		for locale in texts[key]:
			var text: String = placeholders.sub(texts[key][locale], "", true)
			for i in text.length():
				if not text[i] in [" ", "\n"] and not used.has(text[i]):
					used[text[i]] = "%s/%s" % [key, locale]
	var missing := []
	for font_name in fonts:
		var font = fonts[font_name]
		if not font is DynamicFont:
			missing.append("%s: no DynamicFont" % font_name)
			continue
		var chars: String = font.get_available_chars()  # with the fallbacks
		if chars.find("A") == -1 or chars.find("渡") == -1 or chars.find("ᚠ") != -1:
			missing.append("%s: the check cannot tell (A, 渡, no runic ᚠ)" % font_name)
			continue
		for character in used:
			if chars.find(character) == -1:
				missing.append("%s: %s '%s'" % [font_name, used[character], character])
	return missing


# Under root, as laid out: a text cut by its control (a label or button that clips) and a control
# past the screen. "path: what".
static func overflow(root: Control, screen: Rect2) -> Array:
	var found := []
	_overflow(root, root, screen, found)
	return found


static func _overflow(root: Control, control: Control, screen: Rect2, found: Array) -> void:
	if not control.visible:
		return
	var where := str(root.get_path_to(control))
	var rect := control.get_global_rect()
	if (control is Label or control is Button) and (
		rect.position.x < screen.position.x - SLACK or rect.end.x > screen.end.x + SLACK
		or rect.position.y < screen.position.y - SLACK or rect.end.y > screen.end.y + SLACK
	):
		found.append("%s: past the screen %s" % [where, rect])
	var cut := clipped(control)
	if cut != "":
		found.append("%s: %s" % [where, cut])
	for child in control.get_children():
		if child is Control:
			_overflow(root, child, screen, found)


# "": the control's text fits (or it does not clip). Else what is cut and by how much.
static func clipped(control: Control) -> String:
	var texts := []
	var room := control.rect_size.x
	if control is Label and control.clip_text and not control.autowrap:
		texts.append(control.tr(control.text))
	elif control is Button and control.clip_text:
		room -= control.get_stylebox("normal").get_minimum_size().x
		if control is OptionButton:
			room -= control.get_icon("arrow").get_width() + control.get_constant("arrow_margin")
			for i in control.get_item_count():
				texts.append(control.tr(control.get_item_text(i)))
		else:
			texts.append(control.tr(control.text))
	var font: Font = control.get_font("font")
	for text in texts:
		var width := font.get_string_size(text).x
		if width > room + SLACK:
			return "'%s' needs %d px, has %d" % [text, width, room]
	return ""


static func screen_rect(node: Node) -> Rect2:
	return node.get_viewport().get_visible_rect()


# Every language in turn, as the game's language menu switches it: target.call(method, locale)
# returns the problems in that language (en first: it can note the English widths). With
# check-window.ps1 the screen is saved as l10n_<locale>_<shot>.png for SCREENSHOT_LOCALES
# ("" shot: none). Back to the language before. Returns the problems, each with its locale.
static func sweep(t: Node, target: Object, method: String, shot: String):
	var saved := [ProgressData.settings.get("language"), TranslationServer.get_locale()]
	var folder := OS.get_environment(SCREENSHOT_ENV)
	var problems := []
	for locale in LOCALES:
		ProgressData.change_language(locale)
		for _i in 2:
			yield(t.get_tree(), "idle_frame")
		for problem in target.call(method, locale):
			problems.append("%s %s" % [locale, problem])
		if folder != "" and shot != "" and locale in SCREENSHOT_LOCALES:
			yield(screenshot(t, folder.plus_file("l10n_%s_%s.png" % [locale, shot])), "completed")
	ProgressData.settings["language"] = saved[0]
	TranslationServer.set_locale(saved[1])
	yield(t.get_tree(), "idle_frame")
	return problems


static func screenshot(t: Node, path: String):
	for _i in 5:
		yield(t.get_tree(), "idle_frame")
	yield(VisualServer, "frame_post_draw")
	var image := t.get_viewport().get_texture().get_data()
	image.flip_y()
	t._check(image.save_png(path) == OK, "l10n: screenshot %s" % path)
